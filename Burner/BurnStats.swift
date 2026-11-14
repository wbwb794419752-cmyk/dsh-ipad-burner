//
//  BurnStats.swift
//  Burner
//
//  状态面板的数据模型 + 跨线程错误计数。
//

import Foundation

/// 面板快照。全部是值类型，SwiftUI 做差分刷新很便宜。
struct BurnStats {
    var running: Bool = false        // 正在烤（未暂停）
    var paused: Bool = false         // 被切到后台而暂停
    var uptime: TimeInterval = 0     // 秒
    var fps: Double = 0
    var gpuPasses: Int = 0
    var gpuState: String = "待机"
    var gpuLoad: String = "待机"      // 饱和/活跃/待机（GPU% 无公开 API，用定性标签）
    var cpuAlive: Int = 0
    var cpuThreads: Int = 0
    var cpuRate: Double = 0          // 每秒钟完成的工作轮数（8 线程合计）
    var cpuPercent: Double = 0       // 整机 8 核平均占用（mach host_processor_info）
    var rssMB: Int = 0               // 本进程常驻内存（task_basic_info.resident_size）
    var memMB: Int = 0
    var memGBps: Double = 0
    var memState: String = "待机"
    var memWarnings: Int = 0
    var thermal: Int = 0             // 0-4（iOS 目前只上报 0-3，4=危急 为预留档）
    var thermalText: String = "-"
    var battery: Int = -1            // 0-100，-1 表示未知（模拟器恒为 -1）
    var batteryText: String = "-"
    var powerText: String = "采样中…"  // 由放电速率反推的整机功耗估算
    var errors: Int = 0
    var restarts: Int = 0
}

/// 全局异常/重启计数：写少读多，NSLock 足够
final class BurnCounters {
    static let shared = BurnCounters()

    private let lock = NSLock()
    private var _errors = 0
    private var _restarts = 0

    var errors: Int {
        lock.lock()
        defer { lock.unlock() }
        return _errors
    }

    var restarts: Int {
        lock.lock()
        defer { lock.unlock() }
        return _restarts
    }

    func bumpError() {
        lock.lock()
        _errors += 1
        lock.unlock()
    }

    func bumpRestart() {
        lock.lock()
        _restarts += 1
        lock.unlock()
    }

    private init() {}
}
