//
//  ContentView.swift
//  Burner
//
//  全屏 Metal 视图 + 左上角可折叠状态面板。
//  面板是唯一明显非白的区域（380pt 宽、两栏），其余像素全部接近纯白。
//

import SwiftUI
import MetalKit
import QuartzCore
import Foundation

struct ContentView: View {

    @ObservedObject var engine: BurnerEngine
    @State private var collapsed = false

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.white
                .ignoresSafeArea()

            MetalView(renderer: engine.renderer)
                .ignoresSafeArea()

            if engine.renderer.device == nil {
                Text("当前设备不支持 Metal")
                    .font(.system(size: 15, weight: .bold, design: .monospaced))
                    .foregroundColor(.black)
                    .padding(12)
                    .overlay(Rectangle().stroke(Color.black, lineWidth: 1.5))
                    .padding(24)
            }

            panel
                .padding(.top, 10)
                .padding(.leading, 10)
        }
        .background(Color.white)
        .preferredColorScheme(.light)
        .onAppear {
            engine.start()   // 启动即开烤
        }
    }

    // MARK: - 面板

    private var panel: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button(action: {
                withAnimation(.easeInOut(duration: 0.12)) {
                    collapsed.toggle()
                }
            }) {
                HStack(spacing: 6) {
                    Text("烤机监控")
                        .font(.system(size: 12, weight: .bold, design: .monospaced))
                    Spacer(minLength: 4)
                    if collapsed {
                        Text("\(timeText(engine.stats.uptime)) · \(Int(engine.stats.fps))fps · \(Int(engine.stats.cpuPercent))%")
                            .font(.system(size: 10.5, design: .monospaced))
                            .opacity(0.9)
                    }
                    Text(collapsed ? "▸" : "▾")
                        .font(.system(size: 11, design: .monospaced))
                }
                .foregroundColor(.white)
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .frame(width: 380)
                .background(Color.black)
            }
            .buttonStyle(.plain)

            if !collapsed {
                VStack(alignment: .leading, spacing: 6) {
                    // 两栏：左边是负载，右边是电源
                    HStack(alignment: .top, spacing: 10) {
                        VStack(alignment: .leading, spacing: 3) {
                            row("运行", timeText(engine.stats.uptime) + (engine.stats.paused ? " 暂停" : ""))
                            row("FPS", String(format: "%.1f", engine.stats.fps))
                            row("GPU", gpuText)
                            row("CPU", "\(engine.stats.cpuAlive)/\(engine.stats.cpuThreads) · \(rateText(engine.stats.cpuRate))/s")
                            row("CPU%", String(format: "%.0f%%", engine.stats.cpuPercent))
                            row("内存", memText)
                            row("RSS", "\(engine.stats.rssMB)MB")
                            row("ANE", aneText)
                        }
                        .frame(width: 208, alignment: .leading)

                        VStack(alignment: .leading, spacing: 3) {
                            row("电池", engine.stats.batteryText)
                            row("热状态", "\(engine.stats.thermal) \(engine.stats.thermalText)")
                        }
                        .frame(width: 144, alignment: .leading)
                    }

                    Rectangle()
                        .fill(Color(white: 0.6))
                        .frame(height: 1)

                    Text("异常 \(engine.stats.errors) · 重启 \(engine.stats.restarts) · 内存警告 \(engine.stats.memWarnings)")
                        .font(.system(size: 9.5, design: .monospaced))
                        .foregroundColor(Color(white: 0.35))

                    Text("GPU% 无公开 API，以 pass/FPS/定性替代")
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundColor(Color(white: 0.45))

                    if !engine.stats.aneDevice.isEmpty {
                        Text("ANE 算子落点: \(engine.stats.aneDevice)")
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundColor(Color(white: 0.45))
                    }

                    Text("保持通风、勿覆盖机身；过热时 iPad 会自动降频。")
                        .font(.system(size: 9.5, design: .monospaced))
                        .foregroundColor(Color(white: 0.3))
                        .fixedSize(horizontal: false, vertical: true)

                    Button(action: {
                        if engine.stats.running {
                            engine.stop()
                        } else {
                            engine.start()
                        }
                    }) {
                        Text(engine.stats.running ? "停 止" : "开 始")
                            .font(.system(size: 12, weight: .bold, design: .monospaced))
                            .foregroundColor(.black)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 6)
                            .background(Color(white: 0.9))
                            .overlay(Rectangle().stroke(Color.black, lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                    .padding(.top, 6)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 7)
                .frame(width: 380, alignment: .leading)
                .background(Color(white: 0.97))
            }
        }
        .frame(width: 380, alignment: .leading)
        .overlay(Rectangle().stroke(Color.black, lineWidth: 1.5))
        .shadow(color: Color.black.opacity(0.25), radius: 8, x: 0, y: 3)
    }

    private func row(_ key: String, _ value: String) -> some View {
        HStack(spacing: 6) {
            Text(key)
                .foregroundColor(Color(white: 0.35))
            Spacer(minLength: 4)
            Text(value)
                .foregroundColor(.black)
                .lineLimit(1)
                .minimumScaleFactor(0.65)
        }
        .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
    }

    // MARK: - 文案

    private var gpuText: String {
        let s = engine.stats
        let fps = String(format: "%.1f", s.fps)
        return "\(s.gpuState) · \(s.gpuPasses)p · \(fps)fps · \(s.gpuLoad)"
    }

    private var memText: String {
        let s = engine.stats
        if s.memMB > 0 {
            let bw = String(format: "%.1f", s.memGBps)
            return "\(s.memMB)MB · \(bw)GB/s"
        }
        return s.memState
    }

    /// ANE 行：运行中 / 停止 + 每秒推理次数
    private var aneText: String {
        let s = engine.stats
        if s.aneState == "运行中" {
            return "运行中 · \(rateText(s.aneRate))/s"
        }
        return s.aneState
    }

    private func rateText(_ v: Double) -> String {
        if v >= 1000 {
            return String(format: "%.1fk", v / 1000.0)
        }
        return String(format: "%.0f", v)
    }

    private func timeText(_ t: TimeInterval) -> String {
        let total = max(0, Int(t))
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        return String(format: "%02d:%02d:%02d", h, m, s)
    }
}

// MARK: - MTKView 包装

struct MetalView: UIViewRepresentable {

    let renderer: MetalRenderer

    func makeUIView(context: Context) -> MTKView {
        let v = MTKView(frame: .zero, device: renderer.device)
        v.delegate = renderer
        v.colorPixelFormat = .bgra8Unorm
        v.framebufferOnly = true
        v.isOpaque = true
        v.backgroundColor = .white
        v.clearColor = MTLClearColorMake(1.0, 1.0, 1.0, 1.0)
        // 3 个 drawable + 3 个 in-flight command buffer：GPU 队列里永远有活干。
        // maximumDrawableCount 在 CAMetalLayer 上（iOS 只允许 2 或 3），必须在出第一帧前设。
        if let metalLayer = v.layer as? CAMetalLayer {
            metalLayer.maximumDrawableCount = MetalRenderer.inFlightCount
        }
        v.isPaused = false
        v.enableSetNeedsDisplay = false
        v.autoResizeDrawable = true
        v.isUserInteractionEnabled = false      // 触摸交给上面的 SwiftUI 面板
        renderer.view = v
        return v
    }

    func updateUIView(_ uiView: MTKView, context: Context) {
        // 渲染循环完全由 MTKView 自己驱动，这里不需要做事
    }
}
