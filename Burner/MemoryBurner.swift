//
//  MemoryBurner.swift
//  Burner
//
//  单线程内存带宽压榨：分配 1024MB（失败自动降级 512/256MB），
//  然后无限次「全量读 → 改 → 写」。
//  原生 App 没有 WebContent 的 3GB 上限，可以贪一点；
//  1GB 在 8GB 的 M1 iPad Pro 上前台运行是安全的（触发 jetsam 就看面板的内存警告）。
//

import Foundation
import QuartzCore

final class MemoryBurner {

    /// 降级阶梯（MB）
    private static let ladder = [1024, 512, 256]

    private let lock = NSLock()
    private var running = false
    private var wanted = false     // 用户是否真的想跑（防止 stop 后重试又把它拉起来）
    private var thread: Thread?
    private var mb = 0
    private var gbps = 0.0
    private var state = "待机"
    private var warnings = 0
    private var checksum = 0.0     // 让读改写结果逃逸，防止被优化掉

    // MARK: - 生命周期

    func start(retry: Int = 0) {
        lock.lock()
        if retry == 0 { wanted = true }        // 只有显式调用才算「用户要跑」
        if !wanted {                           // stop() 之后到来的重试直接丢弃
            lock.unlock()
            return
        }
        if thread != nil {
            // 上一轮线程还在释放内存，稍后重试一次（最多 6 次 ≈ 2.4s）
            lock.unlock()
            if retry < 6 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
                    self?.start(retry: retry + 1)
                }
            }
            return
        }
        if running {
            lock.unlock()
            return
        }
        running = true
        warnings = 0
        mb = 0
        gbps = 0
        state = "分配中"
        lock.unlock()

        let t = Thread { [weak self] in
            self?.run()
        }
        t.name = "burner.mem"
        t.qualityOfService = .userInitiated
        t.stackSize = 1 << 19

        lock.lock()
        thread = t
        lock.unlock()
        t.start()
    }

    func stop() {
        lock.lock()
        wanted = false
        running = false
        lock.unlock()
    }

    func noteMemoryWarning() {
        lock.lock()
        warnings += 1
        lock.unlock()
    }

    /// 返回 (MB, GB/s, 状态文案, 内存警告次数)
    func sample() -> (mb: Int, gbps: Double, state: String, warnings: Int) {
        lock.lock()
        defer { lock.unlock() }
        return (mb, gbps, state, warnings)
    }

    // MARK: - 工作体

    private func run() {
        var chosenMB = 0
        var base: UnsafeMutablePointer<Double>?
        var count = 0

        for candidate in MemoryBurner.ladder {
            let bytes = candidate * 1024 * 1024
            if let raw = malloc(bytes) {
                base = raw.assumingMemoryBound(to: Double.self)
                chosenMB = candidate
                count = bytes / MemoryLayout<Double>.size
                break
            }
        }

        guard let buf = base, count > 0 else {
            lock.lock()
            state = "分配失败"
            mb = 0
            running = false
            thread = nil
            lock.unlock()
            return
        }

        // 每 4KB（512 个 Double）触碰一次，把虚拟内存落成真实常驻页
        var i = 0
        while i < count {
            buf[i] = 0.5
            i += 512
        }

        lock.lock()
        mb = chosenMB
        state = chosenMB >= 1024 ? "正常" : "降级"
        lock.unlock()

        var firstRound = true
        while isRunning() {
            let t0 = CACurrentMediaTime()

            var total = 0.0
            var k = 0
            while k < count {
                let v = buf[k]
                buf[k] = v * 0.9999999 + 1e-9
                total += v
                k += 1
            }

            let dt = CACurrentMediaTime() - t0
            let throughput = dt > 0 ? (Double(chosenMB) / 1024.0) / dt : 0

            lock.lock()
            gbps = throughput
            checksum += total
            if firstRound {
                state = chosenMB >= 1024 ? "正常" : "降级(\(chosenMB)MB)"
                firstRound = false
            }
            lock.unlock()
        }

        free(buf)

        lock.lock()
        thread = nil
        running = false
        mb = 0
        gbps = 0
        state = "已停止"
        lock.unlock()
    }

    private func isRunning() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return running
    }
}
