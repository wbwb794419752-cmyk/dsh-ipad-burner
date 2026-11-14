//
//  SystemMetrics.swift
//  Burner
//
//  整机 CPU 占用 + 本进程常驻内存（RSS）。
//  注：iOS / Metal 没有公开的 GPU 利用率 API，所以这里刻意不提供 GPU%，
//  面板用 pass 数 + FPS + 定性标签代替（见 MetalRenderer.loadLabel）。
//

import Foundation
import Darwin

final class SystemMetrics {

    private var prevBusy: [UInt64] = []
    private var prevTotal: [UInt64] = []

    // MARK: - CPU 占用（整机，所有核心平均）

    /// 读取 mach 的 per-CPU tick 计数，用「与上次采样的差值」算占用。
    /// 每次调用都会推进基线，所以调用频率 = 统计窗口（面板里 2.5s 一次）。
    ///
    /// 内核返回的每个核心固定 4 个 int32，顺序按 <mach/machine.h>：
    ///   0 = CPU_STATE_USER, 1 = CPU_STATE_SYSTEM, 2 = CPU_STATE_IDLE, 3 = CPU_STATE_NICE
    /// 这里直接用字面量下标，避免依赖宏是否被导入。
    func cpuPercent() -> Double {
        var cpuCount: natural_t = 0
        var info: processor_info_array_t?
        var infoCount: mach_msg_type_number_t = 0

        let result = host_processor_info(mach_host_self(),
                                         PROCESSOR_CPU_LOAD_INFO,
                                         &cpuCount,
                                         &info,
                                         &infoCount)
        guard result == KERN_SUCCESS, let info = info, cpuCount > 0 else {
            return 0
        }
        defer {
            let size = vm_size_t(infoCount) * vm_size_t(MemoryLayout<integer_t>.stride)
            _ = vm_deallocate(mach_task_self_, vm_address_t(bitPattern: info), size)
        }

        let cores = Int(cpuCount)
        var busy = [UInt64](repeating: 0, count: cores)
        var total = [UInt64](repeating: 0, count: cores)

        for core in 0..<cores {
            let base = core * 4
            let user = UInt64(UInt32(bitPattern: info[base + 0]))
            let system = UInt64(UInt32(bitPattern: info[base + 1]))
            let idle = UInt64(UInt32(bitPattern: info[base + 2]))
            let nice = UInt64(UInt32(bitPattern: info[base + 3]))
            busy[core] = user &+ system &+ nice
            total[core] = busy[core] &+ idle
        }

        var deltaTotal: UInt64 = 0
        var deltaBusy: UInt64 = 0
        if prevTotal.count == cores {
            for core in 0..<cores {
                guard total[core] >= prevTotal[core] else { continue }
                deltaTotal &+= total[core] - prevTotal[core]
                if busy[core] >= prevBusy[core] {
                    deltaBusy &+= busy[core] - prevBusy[core]
                }
            }
        }
        prevBusy = busy
        prevTotal = total

        guard deltaTotal > 0 else { return 0 }
        let pct = Double(deltaBusy) / Double(deltaTotal) * 100.0
        return min(100.0, max(0.0, pct))
    }

    // MARK: - 本进程常驻内存

    /// task_basic_info.resident_size（字节）。面板里除以 1048576 显示 MB。
    func residentBytes() -> UInt64 {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<integer_t>.size)

        let result: kern_return_t = withUnsafeMutablePointer(to: &info) { ptr in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { intPtr in
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), intPtr, &count)
            }
        }

        guard result == KERN_SUCCESS else { return 0 }
        return info.resident_size
    }
}
