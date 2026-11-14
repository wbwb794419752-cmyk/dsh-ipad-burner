//
//  PowerMeter.swift
//  Burner
//
//  用电池放电速率反推整机功耗（瓦）。
//
//  原理：iPad 的电量按 1% 步进上报，记下 (时间, 电量) 点列，
//  取窗口首末两点算平均放电速率：
//      Δ% / Δ小时  = 每小时掉几个百分点
//      W = 电池容量(Wh) × (Δ% / 100) / Δ小时
//
//  28.65Wh 是 iPad Pro 11 英寸 (M1) 的标称电池能量。
//  换机型时改 `packWh` 即可：iPad Pro 12.9 M1 ≈ 40.88Wh，iPad Air 5 ≈ 28.6Wh。
//
//  注意：模拟器上 batteryLevel 恒为 -1，这里会标记 available = false，
//  面板显示「需真机」。
//

import Foundation
import UIKit

final class PowerMeter {

    /// 电池总能量（Wh）—— iPad Pro 11" M1
    static let packWh: Double = 28.65

    /// 统计窗口：5 分钟
    static let window: TimeInterval = 300

    /// 采样间隔：2.5 秒（电量本身是 1% 步进，采太密没有意义）
    private static let sampleInterval: TimeInterval = 2.5

    private var samples: [(t: TimeInterval, pct: Double)] = []
    private var lastSampleAt: TimeInterval = 0
    private var lastValidWatts: Double?

    private(set) var watts: Double?
    private(set) var span: TimeInterval = 0
    private(set) var charging = false
    private(set) var available = false

    func reset() {
        samples.removeAll()
        lastSampleAt = 0
        lastValidWatts = nil
        watts = nil
        span = 0
        charging = false
        available = false
    }

    /// 每个刷新周期（0.5s）调用一次，内部按 2.5s 限流。
    func record(level: Float, state: UIDevice.BatteryState, now: TimeInterval) {
        available = level >= 0
        guard available else {
            watts = nil
            span = 0
            charging = false
            return
        }

        charging = (state == .charging || state == .full)
        if charging {
            // 插着电时「放电速率」没有意义：清空窗口，拔电后重新采样
            samples.removeAll()
            lastSampleAt = 0
            lastValidWatts = nil
            watts = nil
            span = 0
            return
        }

        guard now - lastSampleAt >= PowerMeter.sampleInterval else { return }
        lastSampleAt = now

        let pct = Double(level) * 100.0
        samples.append((t: now, pct: pct))

        // 丢掉 5 分钟窗口之外的点（滚动窗口）
        while let first = samples.first, now - first.t > PowerMeter.window {
            samples.removeFirst()
        }
        // 点数兜底（5min / 2.5s = 120 个，留点余量）
        if samples.count > 400 {
            samples.removeFirst(samples.count - 400)
        }

        guard let first = samples.first, let last = samples.last else { return }
        span = last.t - first.t

        // 窗口没铺满 → 继续采样（保留上一个有效值，避免数字乱跳）
        guard span >= PowerMeter.window - 5.0 else {
            if lastValidWatts == nil { watts = nil }
            return
        }

        let dPct = last.pct - first.pct
        let dHours = span / 3600.0
        guard dHours > 0 else { return }

        if dPct > 0 {
            let w = PowerMeter.packWh * (dPct / 100.0) / dHours
            watts = w
            lastValidWatts = w
        } else {
            // 5 分钟一个点都没掉：负载太轻或读数卡住，维持上一个有效值，绝不输出 NaN
            watts = lastValidWatts
        }
    }

    /// 面板文案
    func text() -> String {
        guard available else { return "需真机" }
        if charging { return "充电中·不估算" }
        if let w = watts {
            return String(format: "≈%.1fW", w)
        }
        if span <= 0 {
            return "采样中…"
        }
        return "采样中… \(Int(span))s"
    }
}
