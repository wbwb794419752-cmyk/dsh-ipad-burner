# Burner — 原生 iOS 满载烤机 App（Swift + Metal）

给 **iPad Pro 11" (M1, iPadOS 27.2)** 用的专用烤机 App。目标只有一个：比 Safari 网页版
（`burner.html`）更狠、更稳地把 SoC、内存控制器和 LCD 背光同时拉满，用来快速消耗电池。

- **纯原生**：Swift 5 + MetalKit + SwiftUI，无第三方依赖、无网络、无音频、无 entitlements。
- **不需要 Mac**：用 GitHub Actions 的 macOS runner 编译出未签名 IPA。
- **不需要开发者账号**：Sideloadly + 免费 Apple ID 签名，7 天重签一次。

---

## 1. 它到底在烧什么

| 负载 | 实现 | 强度 |
|---|---|---|
| **GPU** | 全屏 `MTKView`，重型片元着色器：8 octaves fbm × 5 光源 × 3 子光源 ≈ **每像素 120 次噪声求值**；每帧 **固定 4 个全屏 pass**（两张 offscreen 纹理 ping-pong，读上一 pass 做反馈） | 原生分辨率（2388×1668 @2x ≈ 400 万像素）× 固定 4 pass |
| **CPU** | **8 条独立 `Thread`**（`activeProcessorCount`，M1 正好 8 核全占），每条线程独立工作集：64×64 矩阵乘（262k 次乘加）+ 4096 个元素 `sin/cos/exp` + 8MB scratch 跨步扫描 + 结果衰减 | 热循环里无锁、无 ARC、无数组边界检查（全 `UnsafeMutablePointer`） |
| **内存带宽** | `malloc` **1024MB**，逐页触碰落成常驻，然后无限次全量「读→改→写」；失败自动降级 512 / 256MB | 单线程连续扫，实测会把内存控制器压到接近饱和 |
| **屏幕** | 输出接近纯白（`1.0 - 0~6%` 灰度扰动），LCD 背光全开；运行期间把系统亮度强制拉到 100%，停止时恢复原值 | 背光 + GPU 双重发热 |
| **防锁屏** | `UIApplication.shared.isIdleTimerDisabled = true`（进程级原生 API，AppDelegate 启动时设、回前台再设一次） | 不依赖系统设置，不依赖 Wake Lock |
| **静默** | 完全不创建 `AVAudioSession`、不播任何声音 | — |

### 相对网页版的优势

| | 网页版 `burner.html` | 原生 Burner |
|---|---|---|
| 防锁屏 | `navigator.wakeLock` 只在 HTTPS/localhost 安全上下文可用，局域网 HTTP 打开时**完全没有** | `isIdleTimerDisabled` 进程级，**100% 生效**，还能顺手强制亮度 |
| CPU 并发 | Web Worker 数量受 Safari 限制，通常只敢开 4–6 个 | 8 条 `Thread`，8 核全吃 |
| GPU | WebGL1，受 WebKit 合成器/进程模型限制 | Metal 直接提交，4 pass ping-pong 全屏 |
| 内存 | WebContent 有配额，256MB 且可能被回收 | 1024MB 常驻，失败才降级 |
| 额外开销 | WebKit 渲染进程、JS GC、DOM 合成都在抢 CPU | 没有中间层，CPU 时间几乎全给浮点循环 |

---

## 2. 目录结构

```
native-burner/                     ← 仓库根目录（推到 GitHub 的就是这一层）
├─ project.yml                     ← XcodeGen 工程描述（不手写 .xcodeproj）
├─ Burner/
│  ├─ BurnerApp.swift              ← @main SwiftUI App，监听 scenePhase
│  ├─ AppDelegate.swift            ← isIdleTimerDisabled = true
│  ├─ ContentView.swift            ← 全屏 MTKView + 左上角可折叠状态面板
│  ├─ BurnerEngine.swift           ← 总调度：启停、前后台、亮度、0.5s 汇总状态
│  ├─ MetalRenderer.swift          ← MTKViewDelegate：pipeline、ping-pong 纹理、固定 4 pass、FPS 统计
│  ├─ shaders.metal                ← MSL：全屏三角形 + 重负载片元着色器
│  ├─ CPUBurner.swift              ← 8 线程矩阵乘 / 超越函数 / 8MB 扫描
│  ├─ MemoryBurner.swift           ← 1024MB 全量读写扫描（带降级阶梯）
│  ├─ SystemMetrics.swift          ← 整机 CPU%（mach per-CPU tick）+ 本进程 RSS（task_info）
│  ├─ BurnStats.swift              ← 面板数据模型 + 全局异常计数
│  └─ Assets.xcassets/             ← AppIcon（1024 单尺寸）
├─ .github/workflows/build.yml     ← GHA：xcodegen → xcodebuild archive → 打包未签名 IPA
└─ README.md
```

`Burner-Info.plist` 由 `xcodegen generate` 自动生成（在 `project.yml` 的 `info:` 里定义），
不需要提交到仓库。

---

## 3. 用 GitHub Actions 编译（本机没有 Mac 也能做）

### 3.1 推仓库

1. 在 GitHub 新建一个仓库（Public 的 Actions 分钟数无限；Private 每月 2000 分钟，也够用）。
2. 把 **`native-burner/` 里面的内容**（不是这个目录本身）推到仓库根：

```bash
cd C:/Users/Administrator/Documents/ipad-battery/native-burner
git init
git add .
git commit -m "native burner"
git branch -M main
git remote add origin https://github.com/<你的用户名>/<仓库名>.git
git push -u origin main
```

### 3.2 跑 workflow

- 打开仓库 → **Actions** → 左侧 **Build unsigned IPA** → 右上 **Run workflow** → `main` → Run。
- 推送到 `main`/`master` 也会自动触发。
- 全流程约 **3–6 分钟**：`brew install xcodegen` → `xcodegen generate` → `xcodebuild archive`（`CODE_SIGNING_ALLOWED=NO`）→ 从 `.xcarchive` 里取出 `Burner.app` 装进 `Payload/` → `zip` 成 `Burner-unsigned.ipa` → 上传 artifact。

### 3.3 下载产物

- 跑完后进入这次 run 的页面，底部 **Artifacts** → **Burner-unsigned-ipa**。
- 下载到的是一个 **zip**（GitHub 会把 artifact 再打一层包），解压后得到 **`Burner-unsigned.ipa`**（约 1–3MB）。
- 如果失败，下载 **xcodebuild-log** artifact 看编译错误。

### 3.4 本机有 Mac 的话

```bash
brew install xcodegen
xcodegen generate
open Burner.xcodeproj          # 或者直接命令行 archive
```

---

## 4. 用 Sideloadly + 免费 Apple ID 安装

> 免费 Apple ID 签名的 App **7 天过期**，到期重签即可；同时最多 3 个自签 App。
> Bundle ID 固定为 `com.dsh.ipadburner`，重签是覆盖安装，不会丢数据（本 App 也没有数据）。

1. **Windows 准备**：装 [iTunes](https://www.apple.com/itunes/)（微软商店版或 Apple 官网版都行，提供 Apple 驱动）
   或新的 **Apple Devices** 应用；再装 [Sideloadly](https://sideloadly.io/)（务必用最新版，旧版不认 iOS 26/27）。
2. **连线**：iPad 用数据线连电脑 → iPad 上点「信任此电脑」→ 输入锁屏密码。
3. **Sideloadly**：
   - `IPA` 选择刚下载的 `Burner-unsigned.ipa`；
   - `Apple ID` 填你的免费 Apple ID；
   - 点 **Start**，输入 Apple ID 密码（只用于向 Apple 换取签名证书），有双重认证就填验证码。
4. **信任证书**：iPad → 设置 → 通用 → **VPN 与设备管理** → 开发者 App → 你的 Apple ID → **信任**。
5. **开发者模式**（iOS 16+ 必须）：设置 → 隐私与安全性 → **开发者模式** → 打开 → 重启 → 重启后确认。
   > 如果找不到「开发者模式」这一项，先把 App 装一次（第 3 步），它才会出现。
6. 回桌面点开 **烧机**，App 启动即自动开始烤，**不需要点任何按钮**。

**7 天后**：App 打不开（提示「不再可用」）→ 重新跑一次 Sideloadly（第 3 步）即可，不需要删掉重装。

---

## 5. 运行时的样子

- 全屏纯白，只有极淡的灰度噪声在缓慢流动（不是黑屏、不是花屏）。
- 左上角一个 380pt 宽的面板，点标题栏可折叠；展开后分**两栏**（左=负载，右=电源），
  折叠时标题栏只显示 `时长 · fps · CPU%`。

| 栏 | 行 | 含义 |
|---|---|---|
| 左 | 运行 | 已运行时长（切后台会显示「暂停」） |
| 左 | FPS | GPU 实际帧率 |
| 左 | GPU | 着色器状态 · pass 数 · FPS · 定性负载（`正常 · 4p · 4.2fps · 饱和`） |
| 左 | CPU | 存活线程数/总线程数 · 每秒工作轮数（M1 应为 `8/8`） |
| 左 | CPU% | **整机 8 核平均占用**（mach `host_processor_info` 的 tick 差值） |
| 左 | 内存 | 压测缓冲区大小 · 实测带宽（正常 `1024MB · 40GB/s` 左右） |
| 左 | RSS | **本 App 常驻内存**（`task_basic_info.resident_size` / 1048576） |
| 右 | 电池 | 电量% + 状态（放电中 / 充电中 / 已充满 / 未知） |
| 右 | 热状态 | `0 正常` / `1 轻微` / `2 适中` / `3 严重`（`4 危急` 为预留档） |

面板底部还有一行汇总 `异常 N · 重启 N · 内存警告 N`，以及
`GPU% 无公开 API，以 pass/FPS/定性替代` 的说明。
再下面是 **停止 / 开始** 按钮（暂停会恢复亮度、放开锁屏）。

### 5.1 为什么没有 GPU 占用率

Metal / iOS **没有公开 API** 能读 GPU 利用率（`MTLDevice` 只暴露 `recommendedMaxWorkingSetSize`
这类静态信息，没有计数器）。所以面板不编数字，只用：
`pass 数`（当前每帧几个全屏 pass）+ `FPS` + `定性标签`（帧率被算力压住 = `饱和`，否则 `活跃`）。

### 5.2 采样节流

只有**一个** 0.5s 主定时器（刷新运行时长、FPS、CPU 线程心跳），
CPU% / RSS / 热状态 / 电池 统一走同一个 **2.5s 慢采样门**，不额外起定时器。

---

## 6. 想调更狠 / 调轻一点

| 想改什么 | 改哪里 |
|---|---|
| GPU pass 数（默认固定 4，不降档） | `MetalRenderer.swift` 的 `passCount` 初值 |
| 每像素噪声量 | `shaders.metal` 里 `fbm8` 的八度数（8）、外层 `i < 5`、内层 `j < 3` |
| CPU 线程数 | `CPUBurner.start()` 里 `min(8, activeProcessorCount)`，可改成 9/10 超订 |
| 矩阵规模 / scratch 大小 | `CPUBurner` 的 `matrixN`、`scratchCount` |
| 内存占用 | `MemoryBurner.ladder`（默认 `[1024, 512, 256]`） |
| 慢采样周期 | `BurnerEngine.refresh()` 里的 `now - lastSlowAt >= 2.5` |
| 渲染分辨率 | `ContentView.swift` 里给 `MTKView` 设 `drawableSize`，或加 `contentScaleFactor` 限制 |

> 调高之前先想清楚：这是烤机 App，不是跑分 App。机身温度、手感、电池损耗都是真实成本。

---

## 7. 注意 / 风险

- **散热**：放硬质桌面、别放床/沙发/被子上，别套壳。屏幕自动变暗 = 已经过热保护，属正常。
- **电池**：长期满功率放电 + 高温会加速电池老化，这是烤机的代价，不是 bug。
- **后台**：切到后台会被系统挂起（GPU/CPU 线程自动停），回前台自动恢复，这是 iOS 的限制。
- **亮度**：运行期间 App 会把系统亮度改成 100%，正常停止会恢复；如果 App 被强杀，亮度会停在 100%，手动调回即可。
- **内存**：1024MB 在 8GB 的 M1 iPad Pro 上前台运行没问题；如果被 jetsam 杀掉，把 `MemoryBurner.ladder` 首项改成 512。
- **不做温控保护**：和网页版一致，过热交给 iPad 自己降频。要保护电池就手动点停止。

---

## 8. 待 GHA 实测验证（没在真机/真 Xcode 上编译过，逐条核对）

> 本工程是在没有 Swift 工具链的 Windows 上写的，以下点在第一次 GHA 跑通前都属于「待验证」：

1. **XcodeGen 版本**：`minimumXcodeGenVersion: 2.35.0`，brew 装到的 2.4x 应满足；如果 `generate` 报 schema 错误，先看是不是 `info.properties` 里的 `UILaunchScreen: {}`（空字典）序列化问题。
2. **`xcodebuild archive` 参数**：`-destination 'generic/platform=iOS'` + `CODE_SIGNING_ALLOWED=NO` 预期能生成 `build/Burner.xcarchive/Products/Applications/Burner.app`；若 Xcode 版本较新报 destination 不匹配，改成 `-sdk iphoneos`。
3. **MSL 编译**：`shaders.metal` 里 `static inline` 辅助函数、`prevTex.sample(smp, uv, level(0.0))`、`float4(float2, float, float)` 构造均为标准写法，但没跑过 `metal` 编译器，首次 GHA 若报错看 `xcodebuild-log`。
4. **Uniform 布局**：Swift `BurnerUniforms`（两个 `SIMD4<Float>`）与 MSL `struct Uniforms`（两个 `float4`）都是 32 字节 / 16 字节对齐，若画面异常先查这里。
5. **`MTL_FAST_MATH`**：设为 YES 让 Metal 走 fast-math（更快更热），极少数驱动版本可能对精度敏感，出问题设为 NO。
6. **Swift 并发**：`SWIFT_VERSION 5.0` + `SWIFT_STRICT_CONCURRENCY minimal`，`NotificationCenter` 闭包捕获 `self` 可能出 warning（不是 error）。
7. **`persistentSystemOverlays(.hidden)` / 双参数 `onChange(of:)`**：均为 iOS 17 API，部署目标 17.0 应该没问题；若 Xcode 报「only available in iOS 17.0 or newer」，确认 `IPHONEOS_DEPLOYMENT_TARGET` 真的是 17.0。
8. **1024MB 分配**：`malloc` 一定成功（虚拟内存），真正考验是逐页触碰时是否触发 jetsam；面板的「内存警告」计数可用来判断。
9. **真机帧率**：4 pass × 全分辨率在 M1 iPad 上预计 1–5fps（这是有意的，pass 数锁死 4 不降档）。
10. **Sideloadly 对 iOS 27.2**：需要较新版本；若签名失败，先升级 Sideloadly / iTunes，或改用 AltStore。
11. **`host_processor_info`**：`PROCESSOR_CPU_LOAD_INFO` 每个核心返回 4 个 `integer_t`
    （USER/SYSTEM/IDLE/NICE，按 `<mach/machine.h>` 的顺序），代码用字面量下标读取；
    若 CPU% 恒为 0 或恒定 100%，先查这里的下标和 tick 差值。
12. **`task_basic_info.resident_size`**：RSS 只统计常驻页，比 Xcode 的 memory gauge 略小，
    和「活动监视器」的口径一致；要更接近 footprint 可换 `task_vm_info.phys_footprint`。

---

## 9. 常见问题

**Q: 装完打开是白屏，面板也没有？**
A: 说明 App 起来了但 Metal 初始化失败，面板会显示「无 Metal 设备 / 初始化失败」。多半是 IPA 没签好或设备不支持，重签一次再看。

**Q: 为什么 FPS 只有个位数？**
A: 故意的。每帧要算 400 万像素 × 120 次噪声 × 4 pass，帧率低代表 GPU 真的在满负荷跑。

**Q: 能不能后台继续烤？**
A: 不能。iOS 会挂起后台进程，任何 App 都绕不过去（除非申请后台音频等权限，那会违反「静默」要求）。

**Q: 和网页版哪个更狠？**
A: 原生版。多出 2–4 个 CPU 线程、1024MB 常驻内存扫描、4 pass Metal 渲染，以及真正生效的防锁屏。
