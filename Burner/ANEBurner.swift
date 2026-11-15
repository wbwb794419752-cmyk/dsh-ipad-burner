//
//  ANEBurner.swift
//  Burner
//
//  ANE（Apple Neural Engine）常驻推理负载。
//
//  为什么用 1×1 卷积：
//    ANE 没有独立的 GEMM 指令，它最擅长的就是 2D 卷积。一个 batch=512、
//    64→64 通道的 1×1 卷积（[1,64,512,1] → [1,64,512,1]）在数学上就是一个
//    (512×64)×(64×64) 的 GEMM，但走的是 ANE 的卷积通路，能被稳定调度到 16 核
//    Neural Engine 上。
//
//  为什么用 .cpuAndNeuralEngine：
//    不要用 .all。.all 会把算子分给 GPU，和 Metal 那条满载的 GPU 流水线抢同一份
//    功耗/带宽预算；.cpuAndNeuralEngine 明确排除 GPU，让 ANE 这条独立供电轨
//    成为纯粹的净增量。
//
//  结构：后台 Thread 死循环 predict()，try/catch 包住每次推理；
//        另一个看门狗线程每 2 秒检查一次心跳，超过 3 秒没心跳就换一代工作线程
//        （模型对象复用，不重新加载）。
//

import Foundation
import CoreML
import QuartzCore

/// 极简 MLFeatureProvider：值在初始化时建好，热循环里零分配。
final class ANEFeatureProvider: MLFeatureProvider {
    private let names: Set<String>
    private let values: [String: MLFeatureValue]

    init(_ values: [String: MLFeatureValue]) {
        self.values = values
        self.names = Set(values.keys)
    }

    var featureNames: Set<String> { names }

    func featureValue(for featureName: String) -> MLFeatureValue? {
        values[featureName]
    }
}

final class ANEBurner {

    struct Snapshot {
        var state: String = "停止"     // 停止 / 加载中 / 运行中 / 模型加载失败
        var rate: Double = 0           // 每秒 predict 次数
        var shape: String = "-"        // 模型实际输入形状（从模型描述里读的）
        var device: String = ""        // iOS 17.4+ 用 MLComputePlan 读到的算子落点
    }

    private static let modelName = "ane_burner"
    private static let inputName = "input"
    private static let outputName = "output"
    /// 生成脚本的默认形状（[1, C, T, 1]），只有读不到模型描述时才用到
    private static let defaultShape: [NSNumber] = [
        NSNumber(value: 1), NSNumber(value: 64), NSNumber(value: 512), NSNumber(value: 1),
    ]
    /// 看门狗：超过这个秒数没有心跳就重启工作线程
    private static let stallTimeout: CFTimeInterval = 3.0

    private let lock = NSLock()
    private var running = false
    private var generation = 0
    private var worker: Thread?
    private var watchdog: Thread?

    private var cachedModel: MLModel?
    private var cachedShape: String = "-"
    private var cachedDevice: String = ""
    private var loadFailed = false

    // 统计（全部在 lock 内读写）
    private var totalIterations: UInt64 = 0
    private var prevTotal: UInt64 = 0
    private var prevTime: CFTimeInterval = 0
    private var rateValue: Double = 0
    private var lastBeat: CFTimeInterval = 0
    private var stateText: String = "停止"

    // MARK: - 对外控制

    func start() {
        lock.lock()
        if running {
            lock.unlock()
            return
        }
        running = true
        loadFailed = false
        generation &+= 1
        let gen = generation
        totalIterations = 0
        prevTotal = 0
        prevTime = 0
        rateValue = 0
        lastBeat = CACurrentMediaTime()
        stateText = cachedModel == nil ? "加载中" : "运行中"
        lock.unlock()

        spawnWorker(gen: gen)
        spawnWatchdog()
    }

    func stop() {
        lock.lock()
        running = false
        generation &+= 1
        worker = nil
        watchdog = nil
        rateValue = 0
        stateText = "停止"
        lock.unlock()
    }

    func snapshot() -> Snapshot {
        lock.lock()
        defer { lock.unlock() }
        var s = Snapshot()
        s.state = running ? stateText : "停止"
        s.rate = rateValue
        s.shape = cachedShape
        s.device = cachedDevice
        return s
    }

    // MARK: - 线程

    private func spawnWorker(gen: Int) {
        let t = Thread { [weak self] in
            self?.workerBody(gen: gen)
        }
        t.name = "burner.ane.\(gen)"
        // .utility：ANE 的活主要不占 CPU 核，但喂数据/收结果的那点线程不要抢 P 核
        t.qualityOfService = .utility
        t.stackSize = 1 << 20
        lock.lock()
        worker = t
        lastBeat = CACurrentMediaTime()
        lock.unlock()
        t.start()
    }

    private func spawnWatchdog() {
        lock.lock()
        if watchdog != nil {
            lock.unlock()
            return
        }
        let t = Thread { [weak self] in
            while true {
                guard let self = self else { return }
                Thread.sleep(forTimeInterval: 2.0)
                guard self.isRunning() else {
                    self.clearWatchdog()
                    return
                }
                self.checkHealth()
            }
        }
        t.name = "burner.ane.watchdog"
        t.qualityOfService = .utility
        watchdog = t
        lock.unlock()
        t.start()
    }

    private func isRunning() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return running
    }

    private func clearWatchdog() {
        lock.lock()
        watchdog = nil
        lock.unlock()
    }

    private func isActive(_ gen: Int) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return running && generation == gen
    }

    private func setState(_ text: String, shape: String?, device: String? = nil) {
        lock.lock()
        stateText = text
        if let shape = shape { cachedShape = shape }
        if let device = device { cachedDevice = device }
        lastBeat = CACurrentMediaTime()
        lock.unlock()
    }

    private func markLoadFailed() {
        lock.lock()
        loadFailed = true
        stateText = "模型加载失败"
        lock.unlock()
    }

    private func noteError() {
        BurnCounters.shared.bumpError()
    }

    /// 把这一批迭代次数记进统计（每 0.5 秒一次，热循环里不做除法）
    private func flush(gen: Int, count: UInt64) {
        lock.lock()
        guard running, generation == gen else {
            lock.unlock()
            return
        }
        totalIterations &+= count
        lastBeat = CACurrentMediaTime()

        let now = CACurrentMediaTime()
        if prevTime > 0 {
            let dt = now - prevTime
            if dt >= 0.2 {
                let delta = totalIterations >= prevTotal ? totalIterations - prevTotal : 0
                rateValue = Double(delta) / dt
                prevTotal = totalIterations
                prevTime = now
            }
        } else {
            prevTime = now
            prevTotal = totalIterations
        }
        lock.unlock()
    }

    // MARK: - 看门狗

    private func checkHealth() {
        lock.lock()
        let stalled = running && !loadFailed && CACurrentMediaTime() - lastBeat > ANEBurner.stallTimeout
        if stalled {
            generation &+= 1
        }
        let gen = generation
        lock.unlock()

        guard stalled else { return }
        BurnCounters.shared.bumpRestart()
        NSLog("%@", "[Burner][ANE] 看门狗：超过 \(Int(ANEBurner.stallTimeout))s 没有心跳，"
                + "重启工作线程 (gen \(gen))")
        spawnWorker(gen: gen)
    }

    // MARK: - 工作线程

    private struct Prepared {
        let model: MLModel
        let input: MLMultiArray
        let output: MLMultiArray
        let inputProvider: ANEFeatureProvider
        let shapeText: String

        /// 每 256 次推理轻轻动一下输入：不花什么钱，但保证波形一直在变
        func jitter() {
            guard input.count > 0, input.shape.count == 4 else { return }
            let v = Float((Int(CACurrentMediaTime() * 1000) & 0xFF)) * 0.0039 - 0.5
            input[[0, 0, 0, 0] as [NSNumber]] = NSNumber(value: v)
        }
    }

    private func workerBody(gen: Int) {
        autoreleasepool {
            let prepared: Prepared
            do {
                prepared = try prepare()
                setState("运行中", shape: prepared.shapeText, device: snapshot().device)
                NSLog("[Burner][ANE] 模型就绪 shape=%@", prepared.shapeText)
            } catch {
                noteError()
                markLoadFailed()
                NSLog("[Burner][ANE] 模型加载失败: %@", String(describing: error))
                return
            }

            let model = prepared.model
            let options = MLPredictionOptions()
            var useOutputBackings = true
            // outputBackings 是 [输出名: 缓冲区]，把预分配的 MLMultiArray 塞进去，
            // 这样每次推理不用让 Core ML 再分配一块 128KB 的输出。
            options.outputBackings = [ANEBurner.outputName: prepared.output]

            var pending: UInt64 = 0
            var stamp = CACurrentMediaTime()
            var consecutiveErrors = 0

            while isActive(gen) {
                do {
                    // autoreleasepool：Core ML 每次推理都会产生临时对象，
                    // 不在这里排空的话，长时间运行会一路涨内存。
                    _ = try autoreleasepool {
                        try model.prediction(from: prepared.inputProvider, options: options)
                    }
                } catch {
                    consecutiveErrors += 1
                    noteError()
                    if useOutputBackings {
                        // 某些模型/系统版本不接受 outputBackings（输出形状对不上等），
                        // 退回到「框架自己分配输出」再试一次，不要因此停掉整条负载。
                        useOutputBackings = false
                        options.outputBackings = [:]
                        NSLog("%@", "[Burner][ANE] 带 outputBackings 的推理失败，退回默认输出: "
                                + String(describing: error))
                        continue
                    }
                    NSLog("%@", "[Burner][ANE] 推理连续失败 \(consecutiveErrors) 次，"
                            + "退出循环等看门狗: " + String(describing: error))
                    break
                }

                consecutiveErrors = 0
                pending &+= 1

                if (pending & 255) == 0 {
                    prepared.jitter()
                }

                let now = CACurrentMediaTime()
                if now - stamp >= 0.5 {
                    flush(gen: gen, count: pending)
                    pending = 0
                    stamp = now
                }
            }

            if pending > 0 {
                flush(gen: gen, count: pending)
            }
        }
    }

    // MARK: - 模型加载

    private func prepare() throws -> Prepared {
        let model: MLModel
        if let cached = cachedModel {
            model = cached
        } else {
            let cfg = MLModelConfiguration()
            // 关键：只用 CPU + ANE，把 GPU 完整留给 Metal 那条流水线
            cfg.computeUnits = .cpuAndNeuralEngine
            cfg.allowLowPrecisionAccumulationOnGPU = false
            guard let url = ANEBurner.locateModel() else {
                throw NSError(domain: "Burner.ANE", code: 1,
                              userInfo: [NSLocalizedDescriptionKey:
                                            "bundle 里找不到 \(ANEBurner.modelName).mlmodelc"])
            }
            model = try MLModel(contentsOf: url, configuration: cfg)
            cachedModel = model
            // iOS 17.4+ 才能问「这个模型的算子准备在哪个计算单元上跑」；
            // 这是 App 内唯一能确认 ANE 路由的手段（GHA 的 macOS VM 没有 ANE，看不出来）。
            let device = ANEBurner.probeComputeDevice(url: url, config: cfg)
            lock.lock()
            cachedDevice = device
            lock.unlock()
            NSLog("[Burner][ANE] 计算单元探测: %@", device)
        }

        let desc = model.modelDescription
        let inShape: [NSNumber] = desc.inputDescriptionsByName[ANEBurner.inputName]?
            .multiArrayConstraint?.shape ?? ANEBurner.defaultShape
        let outShape: [NSNumber] = desc.outputDescriptionsByName[ANEBurner.outputName]?
            .multiArrayConstraint?.shape ?? inShape

        let input = try MLMultiArray(shape: inShape, dataType: .float32)
        let output = try MLMultiArray(shape: outShape, dataType: .float32)

        // 固定模式的输入：确定性、非零，避免任何形式的常量折叠/短路
        let n = input.count
        if n > 0 {
            let p = input.dataPointer.bindMemory(to: Float.self, capacity: n)
            for i in 0..<n {
                p[i] = Float(i % 251) * 0.004 - 0.5
            }
        }
        if output.count > 0 {
            let q = output.dataPointer.bindMemory(to: Float.self, capacity: output.count)
            for i in 0..<output.count { q[i] = 0 }
        }

        let inProvider = ANEFeatureProvider(
            [ANEBurner.inputName: MLFeatureValue(multiArray: input)]
        )

        let shapeText = inShape.map { String($0.intValue) }.joined(separator: "x")
        return Prepared(model: model,
                        input: input,
                        output: output,
                        inputProvider: inProvider,
                        shapeText: shapeText)
    }

    /// iOS 17.4+：用 `MLComputePlan` 读模型每一层「准备在哪个计算单元上跑」。
    /// 这是 App 内唯一能确认 ANE 路由的手段（GHA 的 macOS VM 不暴露 ANE，看不出来）。
    /// 返回例如 "ANE 1/1" / "CPU 1/1"；拿不到就返回空串。
    private static func probeComputeDevice(url: URL, config: MLModelConfiguration) -> String {
        if #available(iOS 17.4, *) {
            return probeWithComputePlan(url: url, config: config)
        }
        return ""
    }

    @available(iOS 17.4, *)
    private static func probeWithComputePlan(url: URL, config: MLModelConfiguration) -> String {
        let sem = DispatchSemaphore(value: 0)
        var text = ""
        MLComputePlan.load(contentsOf: url, configuration: config) { plan, _ in
            defer { sem.signal() }
            guard let plan = plan,
                  let nn = plan.modelStructure?.neuralNetwork else { return }
            var ne = 0
            var total = 0
            for layer in nn.layers {
                total += 1
                if let usage = plan.computeDeviceUsage(for: layer),
                   let device = usage.preferredComputeDevice,
                   device is MLNeuralEngineComputeDevice {
                    ne += 1
                }
            }
            text = ne > 0 ? "ANE \(ne)/\(total)" : "CPU \(total) 层"
        }
        _ = sem.wait(timeout: .now() + 8)
        return text
    }

    /// 找编译好的模型：Xcode 会把 .mlmodel 自动编译成 .mlmodelc 放进 bundle；
    /// 万一没有（本地直接跑源码），退化成运行时编译一次。
    private static func locateModel() -> URL? {
        let bundle = Bundle.main
        if let url = bundle.url(forResource: modelName, withExtension: "mlmodelc") {
            return url
        }
        if let url = bundle.url(forResource: modelName, withExtension: "mlmodel") {
            if let compiled = try? MLModel.compileModel(at: url) {
                return compiled
            }
        }
        if let url = bundle.url(forResource: modelName, withExtension: "mlpackage") {
            if let compiled = try? MLModel.compileModel(at: url) {
                return compiled
            }
        }
        return nil
    }
}
