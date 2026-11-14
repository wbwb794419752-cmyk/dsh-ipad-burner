//
//  shaders.metal
//  Burner
//
//  全屏三角形 + 重负载片元着色器。
//  单个像素的计算量：5 个光源 × 3 个子光源 × fbm(6 octaves) = 90 次噪声求值，
//  每次噪声 = 4 次 hash + 2 次 mix，另外还有 normalize/dot/exp 等。
//  颜色输出接近纯白（1.0 - 极小的扰动），让 LCD 背光保持在最大电流。
//

#include <metal_stdlib>
using namespace metal;

// 必须与 Swift 侧 BurnerUniforms 完全一致（两个 float4，32 字节）
struct Uniforms {
    float4 p0;   // x=时间(秒) y=seed z=pass序号 w=上一帧权重
    float4 p1;   // xy=目标分辨率 zw=保留
};

struct VOut {
    float4 pos [[position]];
    float2 uv;
};

// ---------------------------------------------------------------------------
// 顶点：一个覆盖全屏的大三角形，不需要顶点缓冲
// ---------------------------------------------------------------------------
vertex VOut burner_vertex(uint vid [[vertex_id]]) {
    float2 p = float2(float((vid << 1) & 2u), float(vid & 2u));  // (0,0) (2,0) (0,2)
    VOut o;
    o.pos = float4(p * 2.0 - 1.0, 0.0, 1.0);
    o.uv = p;
    return o;
}

// ---------------------------------------------------------------------------
// 值噪声
// ---------------------------------------------------------------------------
static inline float hash21(float2 p) {
    p = fract(p * float2(123.34, 456.21));
    p += dot(p, p + 45.32);
    return fract(p.x * p.y);
}

static inline float vnoise(float2 p) {
    float2 i = floor(p);
    float2 f = fract(p);
    float2 u = f * f * (3.0 - 2.0 * f);
    float a = hash21(i);
    float b = hash21(i + float2(1.0, 0.0));
    float c = hash21(i + float2(0.0, 1.0));
    float d = hash21(i + float2(1.0, 1.0));
    return mix(mix(a, b, u.x), mix(c, d, u.x), u.y);
}

// 6 个八度的 fbm
static inline float fbm6(float2 p) {
    float v = 0.0;
    float a = 0.5;
    for (int i = 0; i < 6; ++i) {
        v += a * vnoise(p);
        p = p * 2.02 + float2(7.31, 3.17);
        a *= 0.5;
    }
    return v;
}

// ---------------------------------------------------------------------------
// 片元：5 光源 × 3 子光源，全部真实参与运算（结果只用于极淡的灰度扰动）
// ---------------------------------------------------------------------------
fragment float4 burner_fragment(VOut in [[stage_in]],
                                constant Uniforms &u [[buffer(0)]],
                                texture2d<float> prevTex [[texture(0)]],
                                sampler smp [[sampler(0)]]) {

    float2 res = max(u.p1.xy, float2(1.0));
    float2 p = (in.pos.xy - 0.5 * res) / res.y;

    float t = u.p0.x;
    float seed = u.p0.y;
    float prevW = u.p0.w;

    float acc = 0.0;
    float3 lit = float3(0.0);

    for (int i = 0; i < 5; ++i) {
        float fi = float(i);
        float2 q = p * (1.4 + fi * 0.42)
                 + float2(sin(t * 0.11 + fi * 1.7), cos(t * 0.09 + fi * 2.3)) * 0.35;

        for (int j = 0; j < 3; ++j) {
            float fj = float(j);

            // 90 次噪声求值的主要来源
            float n = fbm6(q + float2(fj * 0.53, fi * 0.37) + seed);
            acc += n / (1.0 + fi + fj);

            float3 L = normalize(float3(sin(fi * 1.3 + t * 0.05),
                                        cos(fj * 1.7 + t * 0.04),
                                        0.75));
            float3 N = normalize(float3(n * 1.6 - 0.8, n * 1.1 - 0.55, 0.9));
            float d = max(dot(N, L), 0.0);
            lit += float3(0.9, 0.85, 0.8) * (d * d) * (0.09 / (1.0 + fj * 0.3));
        }
    }

    float v = clamp(acc * 0.012 + (lit.r + lit.g + lit.b) * 0.006, 0.0, 0.05);

    // 第二个 pass 起：读上一次 pass 的结果做反馈，强迫 GPU 走一遍纹理采样
    if (prevW > 0.0) {
        float3 fb = prevTex.sample(smp, in.uv, level(0.0)).rgb;
        v = clamp(v + (1.0 - fb.r) * prevW * 0.02, 0.0, 0.06);
    }

    // 接近纯白：只有 0~6% 的亮度扰动
    float3 col = float3(1.0) - float3(v * 0.85, v * 0.92, v);
    return float4(col, 1.0);
}
