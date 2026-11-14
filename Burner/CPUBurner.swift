//
//  CPUBurner.swift
//  Burner
//
//  8 线程 CPU 满载器。每个 worker 一条独立 Thread、独立工作集：
//    ① 40×40 矩阵乘（64k 次乘加）
//    ② 1600 个元素的 sin / cos / exp 超越函数
//    ③ 2MB scratch 跨步扫描（每 4 个取 1 个，制造非连续访存）
//    ④ 结果衰减，防止数值发散
//
//  锁只在「每秒上报一次」和「停止检查」时用到，热循环里没有锁。
//

import Foundation
import QuartzCore

final class CPUBurner {

    private static let matrixN = 40
    private static let cells = matrixN * matrixN      // 1600
    private static let scratchCount = 262_144         // 2MB / 8B

    private let lock = NSLock()
    private var running = false
    private var generation = 0                        // 每轮启动自增，旧线程自动失效
    private var threads: [Thread] = []

    private var beats: [Double] = []                  // 每线程最后一次心跳（CACurrentMediaTime）
    private var iterations: [UInt64] = []             // 每线程累计轮数
    private var totalIterations: UInt64 = 0
    private var prevTotal: UInt64 = 0
    private var prevTime: Double = 0
    private var rate: Double = 0
    private var checksum: Double = 0                  // 让编译器无法把计算优化掉（值会逃逸到属性）
    private(set) var threadCount = 0

    // MARK: - 生命周期

    func start() {
        lock.lock()
        if running {
            lock.unlock()
            return
        }
        running = true
        generation &+= 1
        let gen = generation

        // M1 的 8 核全用；小于 8 核的设备按实际核数（不超过 8）
        let n = max(1, min(8, ProcessInfo.processInfo.activeProcessorCount))
        threadCount = n
        beats = Array(repeating: 0.0, count: n)
        iterations = Array(repeating: 0, count: n)
        totalIterations = 0
        prevTotal = 0
        prevTime = 0
        rate = 0
        checksum = 0

        var list: [Thread] = []
        list.reserveCapacity(n)
        for i in 0..<n {
            let t = Thread { [weak self] in
                self?.worker(index: i, gen: gen)
            }
            t.name = "burner.cpu.\(i)"
            t.qualityOfService = .userInteractive
            t.stackSize = 1 << 20
            list.append(t)
        }
        threads = list
        lock.unlock()

        for t in list { t.start() }
    }

    func stop() {
        lock.lock()
        running = false
        generation &+= 1     // 让在跑的旧线程下一轮检查时退出
        threads.removeAll()
        lock.unlock()
    }

    // MARK: - 采样

    /// 返回 (存活线程数, 线程总数, 每秒轮数)
    func sample() -> (alive: Int, threads: Int, rate: Double) {
        lock.lock()
        defer { lock.unlock() }

        let now = CACurrentMediaTime()
        var alive = 0
        for i in 0..<beats.count {
            if beats[i] > 0 && now - beats[i] < 3.0 { alive += 1 }
        }

        if prevTime > 0 {
            let dt = now - prevTime
            if dt >= 0.2 {
                let delta = totalIterations >= prevTotal ? totalIterations - prevTotal : 0
                rate = Double(delta) / dt
                prevTotal = totalIterations
                prevTime = now
            }
        } else {
            prevTime = now
            prevTotal = totalIterations
        }

        return (alive, threadCount, rate)
    }

    // MARK: - 内部

    private func isActive(_ gen: Int) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return running && generation == gen
    }

    private func report(index: Int, gen: Int, iters: UInt64, value: Double) {
        lock.lock()
        defer { lock.unlock() }
        guard running, generation == gen, index < iterations.count else { return }
        iterations[index] &+= iters
        totalIterations &+= iters
        beats[index] = CACurrentMediaTime()
        checksum += value
    }

    /// 单线程工作体。注意：这里的热循环全部用 UnsafeMutablePointer，
    /// 没有数组边界检查、没有 ARC，编译器能稳定生成紧凑的浮点循环。
    private func worker(index: Int, gen: Int) {
        autoreleasepool {
            let n = CPUBurner.matrixN
            let cells = CPUBurner.cells
            let scratchLen = CPUBurner.scratchCount

            let a = UnsafeMutablePointer<Double>.allocate(capacity: cells)
            let b = UnsafeMutablePointer<Double>.allocate(capacity: cells)
            let c = UnsafeMutablePointer<Double>.allocate(capacity: cells)
            let scratch = UnsafeMutablePointer<Double>.allocate(capacity: scratchLen)
            defer {
                a.deallocate()
                b.deallocate()
                c.deallocate()
                scratch.deallocate()
            }

            for i in 0..<cells {
                let x = Double(i) + Double(index) * 3.7
                a[i] = sin(x * 0.017) * 0.5 + 0.5
                b[i] = cos(x * 0.031) * 0.5 + 0.5
                c[i] = 0.0
            }
            for i in 0..<scratchLen {
                scratch[i] = Double(i) * 1e-6
            }

            var localIters: UInt64 = 0
            var iter: UInt64 = 0
            var stamp = CACurrentMediaTime()
            var acc = 0.0
            var sum = 0.0

            report(index: index, gen: gen, iters: 0, value: 0)   // 立刻打一次心跳，面板马上显示存活

            while true {
                if (iter & 63) == 0, !isActive(gen) { break }

                // ① 40×40 矩阵乘
                var i = 0
                while i < n {
                    let row = i * n
                    var k = 0
                    while k < n {
                        let aik = a[row + k]
                        let brow = k * n
                        var j = 0
                        while j < n {
                            c[row + j] += aik * b[brow + j]
                            j += 1
                        }
                        k += 1
                    }
                    i += 1
                }

                // ② 超越函数
                acc = 0.0
                i = 0
                while i < cells {
                    let x = c[i] * 0.0005
                    acc += sin(x) + cos(x * 1.7) + exp(-abs(x))
                    i += 1
                }

                // ③ 2MB scratch 跨步扫描
                sum = 0.0
                i = 0
                while i < scratchLen {
                    let v = scratch[i] * 1.0000001 + acc * 1e-12
                    scratch[i] = v
                    sum += v
                    i += 4
                }

                // ④ 衰减
                i = 0
                while i < cells {
                    c[i] *= 0.5
                    i += 1
                }

                iter &+= 1
                localIters &+= 1

                let now = CACurrentMediaTime()
                if now - stamp >= 1.0 {
                    report(index: index, gen: gen, iters: localIters, value: acc + sum)
                    localIters = 0
                    stamp = now
                }
            }
        }
    }
}
