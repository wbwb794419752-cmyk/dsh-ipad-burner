#!/usr/bin/env python3
"""
generate_ane_model.py — 生成 ANE 常驻推理用的 Core ML 模型（构建期生成，不进 git）

思路
----
ANE（Apple Neural Engine）唯一的合法入口是 Core ML，而 ANE 的原生指令是 2D 卷积
（没有独立 GEMM 单元），所以「喂满 ANE」最稳的形状就是一个大 batch 的 1×1 卷积：
    输入  [1, C, T, 1]  (C=64, T=512, 共 512 个 token)
    权重  [64, 64, 1, 1]
    输出  [1, 64, 512, 1]
数学上等价于 (512×64) × (64×64) 的 GEMM，但走的是 ANE 的卷积通路。
注意 token 维要放在 H 轴、W 轴留 1（ANE 用 [1, C, T, 1] 表达 GEMM 最省事）。

产物：Burner/Resources/ane_burner.mlmodel（单文件，权重内联在 protobuf 里）
      用 legacy neuralnetwork spec：单文件、权重内联，Xcode 构建时会自动编译成
      ane_burner.mlmodelc 打进 app bundle；App 里 MLModel(computeUnits=.cpuAndNeuralEngine) 加载。

用法
----
    python3 generate_ane_model.py --out Burner/Resources/ane_burner.mlmodel
    python3 generate_ane_model.py --out ... --verify     # macOS：额外编译 + 查 ANE 路由

--verify 只在 macOS 上有效（需要 libcoremlpython）：编译 .mlmodel → 用 MLComputePlan
读每一层的 preferred compute device，打印成日志，方便在 CI 里确认算子真的落在
Neural Engine 而不是 CPU。多个候选形状时，优先选「全部层都落在 ANE」的那个。
"""

import argparse
import os
import shutil
import sys
import tempfile

import numpy as np

import coremltools as ct
from coremltools.models import datatypes
from coremltools.models.neural_network import NeuralNetworkBuilder

# ---------------------------------------------------------------------------
# 模型超参
# ---------------------------------------------------------------------------

CHANNELS = 64          # 输入/输出通道数（ANE 喜欢 16/32/64 的整数倍）
TOKENS = 512           # batch=512 个 token，和「batch 512 的 GEMM」等价
SEED = 20261115        # 权重固定，构建可复现

# 候选布局：都是 512 个 token × 64 通道，只是 H/W 摆放不同。
# 第一个是规格里的 [1,C,T,1]；后面几个是更「常规」的 2D 特征图，
# 万一这个 Core ML 版本的 ANE 编译器不吃 W=1 的卷积，可以自动退到能上 ANE 的形状。
CANDIDATE_SHAPES = [
    (1, CHANNELS, TOKENS, 1),
    (1, CHANNELS, 32, 16),
    (1, CHANNELS, 64, 8),
    (1, CHANNELS, 128, 4),
]

input_name = "input"
output_name = "output"


def make_weights():
    """确定性的小权重：幅度小，保证单层卷积输出不发散。"""
    rng = np.random.default_rng(SEED)
    w = rng.uniform(-0.125, 0.125, size=(CHANNELS, CHANNELS, 1, 1)).astype(np.float32)
    return w


def build_model(shape, weights):
    """用 legacy neuralnetwork spec 搭一个 1×1 卷积（单文件 .mlmodel，权重内联）。"""
    builder = NeuralNetworkBuilder(
        input_features=[(input_name, datatypes.Array(*shape))],
        output_features=[(output_name, datatypes.Array(*shape))],
        disable_rank5_shape_mapping=True,
    )
    builder.add_convolution(
        name="ane_gemm_1x1",
        kernel_channels=CHANNELS,
        output_channels=CHANNELS,
        height=1,
        width=1,
        stride_height=1,
        stride_width=1,
        border_mode="valid",
        groups=1,
        W=weights,
        b=None,
        has_bias=False,
        input_name=input_name,
        output_name=output_name,
    )
    spec = builder.spec
    # 4D ranked shape（不是老的 rank-5 映射）需要 Core ML 3 / iOS 13+ 的 spec；
    # 我们部署目标是 iOS 17，写 5 保守又完全够用。
    if spec.specificationVersion < 5:
        spec.specificationVersion = 5
    return spec


def spec_summary(spec):
    nn = spec.neuralNetwork
    lines = []
    lines.append("specificationVersion = %d" % spec.specificationVersion)
    lines.append("model type          = %s" % spec.WhichOneof("Type"))
    for feat in spec.description.input:
        if feat.type.WhichOneof("Type") == "multiArrayType":
            ma = feat.type.multiArrayType
            lines.append("input  %-8s shape=%s dtype=%s"
                         % (feat.name, list(ma.shape), ma.dataType))
    for feat in spec.description.output:
        if feat.type.WhichOneof("Type") == "multiArrayType":
            ma = feat.type.multiArrayType
            lines.append("output %-8s shape=%s dtype=%s"
                         % (feat.name, list(ma.shape), ma.dataType))
    for layer in nn.layers:
        params = layer.WhichOneof("layer")
        extra = ""
        if params == "convolution":
            c = layer.convolution
            extra = (" kernel=%dx%d stride=%dx%d outCh=%d groups=%d bias=%s weightBytes=%d"
                     % (c.kernelSize[0], c.kernelSize[1], c.stride[0], c.stride[1],
                        c.outputChannels, c.nGroups, c.hasBias,
                        len(c.weights.floatValue)))
        lines.append("layer  %-14s type=%s%s" % (layer.name, params, extra))
    return "\n".join(lines)


def compile_and_probe(path, workdir):
    """macOS only：编译模型并用 MLComputePlan 读每层的 preferred device。"""
    tmp = os.path.join(workdir, "compiled.mlmodelc")
    if os.path.isdir(tmp):
        import shutil
        shutil.rmtree(tmp)
    compiled = ct.models.utils.compile_model(path, tmp)
    plan = ct.models.compute_plan.MLComputePlan.load_from_path(
        compiled, compute_units=ct.ComputeUnit.CPU_AND_NE
    )
    structure = plan.model_structure
    devices = []
    if structure.neuralnetwork is not None:
        for layer in structure.neuralnetwork.layers:
            usage = plan.get_compute_device_usage_for_neuralnetwork_layer(layer)
            preferred = None
            supported = []
            if usage is not None:
                if usage.preferred_compute_device is not None:
                    preferred = type(usage.preferred_compute_device).__name__
                supported = [type(d).__name__ for d in (usage.supported_compute_devices or [])]
            devices.append((layer.name, layer.type, preferred, supported))
    else:
        raise RuntimeError("模型不是 neuralnetwork 类型，无法按层探测")
    return compiled, devices


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", default="Burner/Resources/ane_burner.mlmodel")
    ap.add_argument("--verify", action="store_true",
                    help="macOS: 编译模型 + 用 MLComputePlan 检查 ANE 路由")
    ap.add_argument("--shape", default=None,
                    help="手动指定形状，例如 1,64,512,1（跳过自动挑选）")
    args = ap.parse_args()

    if args.shape:
        candidates = [tuple(int(x) for x in args.shape.split(","))]
    else:
        candidates = CANDIDATE_SHAPES

    weights = make_weights()
    print("=" * 78)
    print("ANE burner model generator")
    print("coremltools %s | numpy %s | python %s"
          % (ct.__version__, np.__version__, sys.version.split()[0]))
    print("coremltools 可用后端: %s" % ("macOS 原生 (可编译/可探测)"
                                      if _has_native_coreml() else "仅转换 (无 libcoremlpython)"))
    print("=" * 78)

    probe_dir = tempfile.mkdtemp(prefix="ane_probe_")
    chosen_shape = candidates[0]
    chosen_spec = None
    chosen_devices = None
    chosen_compiled = None

    if args.verify and _has_native_coreml():
        try:
            devs = ct.models.compute_device.MLComputeDevice.get_all_compute_devices()
            print("本机可用计算单元: %s" % ", ".join(type(d).__name__ for d in devs))
            if not any(type(d).__name__ == "MLNeuralEngineComputeDevice" for d in devs):
                print("!! 本机没有 Neural Engine（Intel runner？）——无法验证 ANE 路由")
        except Exception as exc:                                  # noqa: BLE001
            print("!! 枚举计算单元失败: %s: %s" % (type(exc).__name__, exc))

    for shape in candidates:
        spec = build_model(shape, weights)
        npop = int(np.prod(shape))
        print("\n--- 候选形状 %s（%d 个 float，%.1f KB 输入）---"
              % (list(shape), npop, npop * 4 / 1024.0))
        print(spec_summary(spec))

        if not args.verify or not _has_native_coreml():
            if chosen_spec is None:
                chosen_spec, chosen_shape = spec, shape
            continue

        # 写一个临时 .mlmodel 试探这个形状能不能整层落到 ANE
        probe_path = os.path.join(probe_dir, "ane_probe.mlmodel")
        ct.models.utils.save_spec(spec, probe_path)
        try:
            compiled, devices = compile_and_probe(probe_path, probe_dir)
        except Exception as exc:                                  # noqa: BLE001
            print("!! 编译/探测失败（跳过该形状）: %s: %s" % (type(exc).__name__, exc))
            continue

        all_ne = True
        for name, ltype, preferred, supported in devices:
            flag = "NE" if preferred == "MLNeuralEngineComputeDevice" else "  "
            print("    [%s] %-14s %-14s preferred=%-28s supported=%s"
                  % (flag, name, ltype, preferred, ",".join(supported)))
            if preferred != "MLNeuralEngineComputeDevice":
                all_ne = False

        if all_ne:
            print("    => 全部层落在 Neural Engine，采用这个形状")
            chosen_shape, chosen_spec = shape, spec
            chosen_devices, chosen_compiled = devices, compiled
            break
        else:
            print("    => 有层没落在 ANE，继续试下一个形状")

    if chosen_spec is None:
        # 没有任何形状能整层落到 ANE：退回第一个候选，模型照样生成（日志里有警告），
        # 至少 CPU+ANE 组合下还能跑，不至于把整条构建卡死。
        chosen_shape = candidates[0]
        chosen_spec = build_model(chosen_shape, weights)
        print("\n!! 警告: 没有候选形状能整层落到 ANE，退回 %s" % (list(chosen_shape),))

    out = args.out
    os.makedirs(os.path.dirname(out) or ".", exist_ok=True)
    ct.models.utils.save_spec(chosen_spec, out)
    size = os.path.getsize(out)
    print("\n" + "=" * 78)
    print("已生成: %s  (%.1f KB)" % (out, size / 1024.0))
    print("形状: %s   通道: %d   token: %d" % (list(chosen_shape), CHANNELS,
                                               int(np.prod(chosen_shape) / CHANNELS)))
    if chosen_devices:
        ne = sum(1 for d in chosen_devices if d[2] == "MLNeuralEngineComputeDevice")
        print("ANE 路由: %d/%d 层 preferred = NeuralEngine" % (ne, len(chosen_devices)))
        print("编译产物: %s" % chosen_compiled)
    elif args.verify:
        print("ANE 路由: 未探测（coremltools 无原生后端或探测失败）")
    else:
        print("ANE 路由: 未探测（本机非 macOS / 未传 --verify）")
    print("=" * 78)
    shutil.rmtree(probe_dir, ignore_errors=True)
    return 0


def _has_native_coreml():
    """能不能在本机编译/探测模型（只有 macOS 装了 libcoremlpython 才行）。"""
    try:
        from coremltools import libcoremlpython  # noqa: F401
        return True
    except Exception:                                            # noqa: BLE001
        return False


if __name__ == "__main__":
    sys.exit(main())
