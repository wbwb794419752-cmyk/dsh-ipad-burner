//
//  BurnerEngine.swift
//  Burner
//
//  总调度：持有 GPU / CPU / 内存三路负载，每 0.5 秒汇总一次状态给 SwiftUI。
//  所有对 @Published stats 的写入都发生在主线程（Timer 主 RunLoop / SwiftUI 回调），
//  因此不需要额外的 actor 隔离。
//

import Foundation
import UIKit
import QuartzCore
import Combine

final class BurnerEngine: ObservableObject {

    @Published private(set) var stats = BurnStats()

    let renderer = MetalRenderer()
    private let cpu = CPUBurner()
    private let memory = MemoryBurner()

    private var timer: Timer?
    private var memoryObserver: NSObjectProtocol?
    private var startedAt: Date?
    private var running = false
    private var suspended = false
    private var brightnessBefore: CGFloat?

    // MARK: - 生命周期

    init() {
        UIDevice.current.isBatteryMonitoringEnabled = true

        memoryObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.memory.noteMemoryWarning()
        }
    }

    deinit {
        if let o = memoryObserver {
            NotificationCenter.default.removeObserver(o)
        }
        timer?.invalidate()
    }

    // MARK: - 开始 / 停止

    func start() {
        if running {
            // 已经在跑：如果只是被切后台暂停了，这里直接恢复
            if suspended { handleForeground() }
            return
        }
        running = true
        suspended = false
        startedAt = Date()

        UIApplication.shared.isIdleTimerDisabled = true   // 核心：原生防锁屏
        boostBrightness()

        lastSlowAt = 0                                    // 下一帧立刻做一次慢采样
        renderer.setPaused(false)
        cpu.start()
        memory.start()
        startTimer()
        refresh()
    }

    func stop() {
        guard running else { return }
        running = false
        suspended = false

        cpu.stop()
        memory.stop()
        renderer.setPaused(true)
        stopTimer()
        restoreBrightness()

        UIApplication.shared.isIdleTimerDisabled = false
        refresh()
    }

    // MARK: - 前后台

    func handleForeground() {
        // 只有还在烤的时候才重新占住锁屏和亮度；用户点过「停止」就不该再抢
        guard running else { return }
        UIApplication.shared.isIdleTimerDisabled = true
        boostBrightness()
        guard suspended else { return }
        suspended = false
        renderer.setPaused(false)
        cpu.start()
        memory.start()
        refresh()
    }

    func handleBackground() {
        // 后台不允许持续跑 GPU/CPU，先停掉，回前台自动恢复
        guard running, !suspended else { return }
        suspended = true
        cpu.stop()
        memory.stop()
        renderer.setPaused(true)
        refresh()
    }

    // MARK: - 状态汇总

    /// 慢采样缓存：CPU% / RSS / 热状态 / 电池 统一 2.5s 采一次
    /// （只用一个主定时器 + 一个节流门，避免多个定时器互相打架）。
    /// FPS、运行时长这类便宜数据仍然 0.5s 刷新。
    private struct SlowSample {
        var cpuPercent: Double = 0
        var rssMB: Int = 0
        var thermal: Int = 0
        var thermalText: String = "-"
        var battery: Int = -1
        var batteryText: String = "需真机"
    }

    private var slow = SlowSample()
    private var lastSlowAt: CFTimeInterval = 0
    private let metrics = SystemMetrics()

    func refresh() {
        let now = CACurrentMediaTime()
        if now - lastSlowAt >= 2.5 {
            lastSlowAt = now
            slow = collectSlow()
        }

        let c = cpu.sample()
        let m = memory.sample()

        var s = BurnStats()
        s.running = running && !suspended
        s.paused = running && suspended
        s.uptime = startedAt.map { Date().timeIntervalSince($0) } ?? 0
        s.fps = renderer.fps
        s.gpuPasses = renderer.passCount
        s.gpuState = renderer.gpuState
        s.gpuLoad = renderer.loadLabel
        s.cpuAlive = c.alive
        s.cpuThreads = c.threads
        s.cpuRate = c.rate
        s.cpuPercent = slow.cpuPercent
        s.rssMB = slow.rssMB
        s.memMB = m.mb
        s.memGBps = m.gbps
        s.memState = m.state
        s.memWarnings = m.warnings
        s.thermal = slow.thermal
        s.thermalText = slow.thermalText
        s.battery = slow.battery
        s.batteryText = slow.batteryText
        s.errors = BurnCounters.shared.errors
        s.restarts = BurnCounters.shared.restarts
        stats = s
    }

    private func collectSlow() -> SlowSample {
        var r = SlowSample()

        // 整机 8 核平均占用（mach per-CPU tick 差值）
        r.cpuPercent = metrics.cpuPercent()
        // 本进程常驻内存
        r.rssMB = Int(metrics.residentBytes() / 1_048_576)

        let level = UIDevice.current.batteryLevel
        let state = UIDevice.current.batteryState

        if level >= 0 {
            r.battery = Int((level * 100).rounded())
            r.batteryText = "\(r.battery)% \(BurnerEngine.batteryName(state))"

            let th = ProcessInfo.processInfo.thermalState
            r.thermal = BurnerEngine.thermalIndex(th)
            r.thermalText = BurnerEngine.thermalNames[min(r.thermal, 4)]
                + (ProcessInfo.processInfo.isLowPowerModeEnabled ? "·省电" : "")
        } else {
            // 模拟器：batteryLevel 恒为 -1，电池/热状态两行都标「需真机」
            r.battery = -1
            r.batteryText = "需真机"
            r.thermal = 0
            r.thermalText = "需真机"
        }
        return r
    }

    private func startTimer() {
        stopTimer()
        let t = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.refresh()
        }
        // .common 模式：面板被按住/滚动时也不停
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    // MARK: - 亮度

    private func activeScreen() -> UIScreen? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        if let s = scenes.first(where: { $0.activationState == .foregroundActive })?.screen {
            return s
        }
        return scenes.first?.screen
    }

    /// 强制屏幕亮度 100%（LCD 背光电流最大），停止时恢复用户原值
    private func boostBrightness() {
        guard let screen = activeScreen() else { return }
        if brightnessBefore == nil { brightnessBefore = screen.brightness }
        if screen.brightness < 0.999 {
            screen.brightness = 1.0
        }
    }

    private func restoreBrightness() {
        guard let screen = activeScreen(), let before = brightnessBefore else { return }
        screen.brightness = before
        brightnessBefore = nil
    }

    // MARK: - 枚举转文案

    /// 热状态名称表：0=正常 1=轻微 2=适中 3=严重 4=危急
    /// 注意：iOS 的 ProcessInfo.ThermalState 目前只上报 0-3，
    /// 4（危急）是预留给未来系统版本的档位，@unknown default 会落到这一档。
    static let thermalNames = ["正常", "轻微", "适中", "严重", "危急"]

    private static func thermalIndex(_ state: ProcessInfo.ThermalState) -> Int {
        switch state {
        case .nominal:    return 0
        case .fair:       return 1
        case .serious:    return 2
        case .critical:   return 3
        @unknown default: return 4
        }
    }

    private static func batteryName(_ state: UIDevice.BatteryState) -> String {
        switch state {
        case .unknown:    return "未知"
        case .unplugged:  return "放电中"
        case .charging:   return "充电中"
        case .full:       return "已充满"
        @unknown default: return "未知"
        }
    }
}
