//
//  MetalRenderer.swift
//  Burner
//
//  全屏 Metal 重负载渲染器：
//    · 每帧 1–3 个全屏 pass（自适应），每个 pass 都跑一遍
//      6 octaves fbm × 5 光源 × 3 子光源 ≈ 每像素 90 次噪声求值
//    · pass 之间用两张 offscreen 纹理 ping-pong，读上一帧结果做反馈
//    · 输出接近纯白（LCD 背光全开），只有极淡的噪声纹理在动
//
//  像素格式统一 bgra8Unorm，所以同一条 pipeline 既能渲染到 offscreen
//  纹理，也能直接渲染到 MTKView 的 drawable。
//

import Foundation
import Metal
import MetalKit
import QuartzCore

/// 与 shaders.metal 里的 struct Uniforms 严格对应（两个 float4 = 32 字节，16 字节对齐）
struct BurnerUniforms {
    var p0: SIMD4<Float> = SIMD4<Float>(0, 0, 0, 0)   // x=时间 y=seed z=pass序号 w=上一帧权重
    var p1: SIMD4<Float> = SIMD4<Float>(0, 0, 0, 0)   // xy=分辨率 zw=保留
}

final class MetalRenderer: NSObject, MTKViewDelegate {

    let device: MTLDevice?
    private let queue: MTLCommandQueue?
    private let pipeline: MTLRenderPipelineState?
    private let sampler: MTLSamplerState?
    private var offscreen: [MTLTexture] = []
    private var dummy: MTLTexture?

    /// MTKView 由 SwiftUI 创建，这里弱引用一份用于暂停/恢复
    weak var view: MTKView?

    private(set) var fps: Double = 0
    private(set) var passCount: Int = 3
    private(set) var gpuState: String = "待机"
    /// iOS 没有公开的 GPU 利用率 API，这里用「帧率是否被算力压住」做定性判断：
    /// 帧率持续低于 15fps 说明 GPU 已经跑满 → 饱和；否则 → 活跃。
    private(set) var loadLabel: String = "待机"

    private var frameCount = 0
    private var windowStart: CFTimeInterval = 0
    private var startTime: CFTimeInterval = 0
    private var lastTexturesSize: CGSize = .zero

    // MARK: - 初始化

    override init() {
        let dev = MTLCreateSystemDefaultDevice()
        let cmdQueue = dev?.makeCommandQueue()

        var pipe: MTLRenderPipelineState?
        var smp: MTLSamplerState?
        var state = "待机"

        if let dev = dev, cmdQueue != nil {
            do {
                let library = try dev.makeDefaultLibrary(bundle: Bundle.main)
                guard let vfn = library.makeFunction(name: "burner_vertex"),
                      let ffn = library.makeFunction(name: "burner_fragment") else {
                    throw NSError(domain: "Burner", code: 1,
                                  userInfo: [NSLocalizedDescriptionKey: "找不到着色器函数"])
                }

                let desc = MTLRenderPipelineDescriptor()
                desc.vertexFunction = vfn
                desc.fragmentFunction = ffn
                desc.colorAttachments[0].pixelFormat = .bgra8Unorm
                desc.label = "burner.pipeline"
                pipe = try dev.makeRenderPipelineState(descriptor: desc)

                let sd = MTLSamplerDescriptor()
                sd.minFilter = .linear
                sd.magFilter = .linear
                sd.sAddressMode = .clampToEdge
                sd.tAddressMode = .clampToEdge
                smp = dev.makeSamplerState(descriptor: sd)

                state = "正常"
            } catch {
                state = "初始化失败"
                BurnCounters.shared.bumpError()
            }
        } else {
            state = "无 Metal 设备"
            BurnCounters.shared.bumpError()
        }

        self.device = dev
        self.queue = cmdQueue
        self.pipeline = pipe
        self.sampler = smp

        super.init()

        self.gpuState = state
        if let dev = dev, pipe != nil {
            self.dummy = MetalRenderer.makeDummyTexture(dev)
        }
    }

    // MARK: - 对外控制

    func setPaused(_ paused: Bool) {
        view?.isPaused = paused
        if paused {
            fps = 0
            frameCount = 0
            windowStart = 0
            loadLabel = "待机"
        } else {
            loadLabel = "活跃"
        }
    }

    private var isReady: Bool {
        pipeline != nil && sampler != nil && dummy != nil
    }

    // MARK: - MTKViewDelegate

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        rebuildTextures(size: size)
    }

    func draw(in view: MTKView) {
        let now = CACurrentMediaTime()
        if startTime == 0 { startTime = now }

        guard isReady,
              let pipeline = pipeline,
              let sampler = sampler,
              let queue = queue,
              let dummy = dummy,
              let drawable = view.currentDrawable,
              let commandBuffer = queue.makeCommandBuffer() else {
            return
        }

        rebuildTextures(size: view.drawableSize)
        guard offscreen.count == 2 else { return }

        let t = Float(fmod(now - startTime, 1000.0))
        let passes = max(1, min(3, passCount))

        for p in 0..<passes {
            let isLast = (p == passes - 1)
            let target = isLast ? drawable.texture : offscreen[p % 2]
            let source = (p == 0) ? dummy : offscreen[(p - 1) % 2]

            let rp = MTLRenderPassDescriptor()
            rp.colorAttachments[0].texture = target
            rp.colorAttachments[0].loadAction = .dontCare
            rp.colorAttachments[0].storeAction = .store

            guard let enc = commandBuffer.makeRenderCommandEncoder(descriptor: rp) else { continue }
            enc.label = "burner.pass.\(p)"
            enc.setRenderPipelineState(pipeline)
            enc.setFragmentTexture(source, index: 0)
            enc.setFragmentSamplerState(sampler, index: 0)

            var uniforms = BurnerUniforms()
            uniforms.p0 = SIMD4<Float>(t,
                                       Float(p) * 37.17,          // 每个 pass 换 seed
                                       Float(p),
                                       p == 0 ? Float(0.0) : Float(0.5))   // 第一个 pass 不采样
            uniforms.p1 = SIMD4<Float>(Float(target.width), Float(target.height), 0, 0)
            enc.setFragmentBytes(&uniforms,
                                 length: MemoryLayout<BurnerUniforms>.stride,
                                 index: 0)

            enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            enc.endEncoding()
        }

        commandBuffer.present(drawable)
        commandBuffer.commit()

        // FPS 统计 + 自适应 pass 数
        frameCount += 1
        if windowStart == 0 { windowStart = now }
        let elapsed = now - windowStart
        if elapsed >= 1.0 {
            fps = Double(frameCount) / elapsed
            frameCount = 0
            windowStart = now
            // GPU 定性：帧率被算力压住 = 饱和
            loadLabel = fps < 15.0 ? "饱和" : "活跃"
            adaptPasses()
        }
    }

    // MARK: - 内部

    /// 帧率太低（<2fps，已经看不清在动）就减一档；富余（>45fps）就加回来。
    /// 目标始终是 3 pass 满载，这个只是防止设备被彻底拖死的安全阀。
    private func adaptPasses() {
        if fps < 2.0 && passCount > 1 {
            passCount -= 1
            BurnCounters.shared.bumpRestart()
        } else if fps > 45.0 && passCount < 3 {
            passCount += 1
        }
    }

    private func rebuildTextures(size: CGSize) {
        guard pipeline != nil, let device = device else { return }
        let w = Int(size.width.rounded())
        let h = Int(size.height.rounded())
        guard w >= 1, h >= 1 else { return }
        // 同一个尺寸只尝试一次，避免分配失败时每帧重试造成抖动
        if lastTexturesSize.width == CGFloat(w), lastTexturesSize.height == CGFloat(h) {
            return
        }

        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm,
                                                        width: w,
                                                        height: h,
                                                        mipmapped: false)
        d.usage = [.renderTarget, .shaderRead]
        d.storageMode = .private

        var list: [MTLTexture] = []
        list.reserveCapacity(2)
        for _ in 0..<2 {
            if let t = device.makeTexture(descriptor: d) { list.append(t) }
        }
        offscreen = list
        lastTexturesSize = CGSize(width: w, height: h)

        if list.count != 2 {
            gpuState = "纹理分配失败"
            BurnCounters.shared.bumpError()
        } else if gpuState != "正常" {
            gpuState = "正常"
        }
    }

    private static func makeDummyTexture(_ device: MTLDevice) -> MTLTexture? {
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm,
                                                        width: 1,
                                                        height: 1,
                                                        mipmapped: false)
        d.usage = [.shaderRead]
        d.storageMode = .shared
        guard let t = device.makeTexture(descriptor: d) else { return nil }
        var pixel: UInt32 = 0xFFFF_FFFF
        t.replace(region: MTLRegionMake2D(0, 0, 1, 1),
                  mipmapLevel: 0,
                  withBytes: &pixel,
                  bytesPerRow: 4)
        return t
    }
}
