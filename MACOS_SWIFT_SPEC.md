# Recorpaster — macOS 原生听写 App（Swift + WhisperKit）实现规格

> 本文是 macOS 原生版的**活文档（living spec）**。它由 `../Whisper/` 的 Python 实现 + 其 README
> 的 11 条「已知坑」翻译而来——`Whisper/app.py` 开头已声明：**macOS 原生版改用 Swift 重做，Python
> 库从此只服务 Windows**。所以 Python 版是本次重写的**权威行为蓝本**；本文把它映射到 AppKit /
> WhisperKit，并把验收标准、踩坑对策固化下来，按 Phase 推进、每 Phase 自测通过再进下一阶段。

---

## 0. 一句话定义

长按热键（默认右 ⌥ Option）唤出屏幕底部居中的**悬浮窗** → WhisperKit 实时把语音转成中文（带标点）
→ 自动**上屏**（剪贴板 + ⌘V，用完还原剪贴板）到当前光标处 / 仅复制 → **松开停止**，最后半句补全后
再淡出。常驻**菜单栏**（无 Dock 图标）。**本地、轻量、隐私**：音频只在内存处理，**转完即弃，绝不写盘**。

## 0.1 目标环境（已实测）

- Xcode 26.1 / Swift 6.2（语言模式 5.0，approachable concurrency，默认 actor 隔离 = MainActor）
- macOS 26（Tahoe），部署目标 `MACOSX_DEPLOYMENT_TARGET = 26.1`
- Apple Silicon（arm64）。WhisperKit 走 CoreML / ANE，无需 Python / mlx。
- 依赖：**WhisperKit**（SPM，`upToNextMajor from 0.9.0` → 实测解析到 0.18.0；避开 v1.0 的 argmax-oss 重构）。

## 0.2 与 Python 版的对应关系

| Python（`Whisper/`） | Swift（本工程） |
|---|---|
| pywebview 悬浮窗（`focus=False`） | **非激活 `NSPanel`**（`.nonactivatingPanel`，`canBecomeKey=false`） |
| pyobjc `NSStatusItem` 托盘 | `NSStatusItem`（原生，直接复用） |
| pynput 全局热键 | **`CGEventTap`** 监听 `flagsChanged`（右 ⌥，keyCode 61） |
| pyperclip + 模拟 ⌘V | `NSPasteboard` + `CGEvent` 投递 ⌘V，用完有条件还原 |
| faster-whisper / mlx-whisper | **WhisperKit**（CoreML） |
| sounddevice 采集 | **自管 `AVAudioEngine`**（`MicCapture`，硬件格式 tap + `AVAudioConverter` → 16kHz mono） |
| silero-vad 切句 | `EnergyVAD`（Phase 1，能量法，协议可插拔；Silero 留作升级） |
| `engine.py` `DictationEngine` | `DictationEngine`（同名同接口：`start/stop/flush` + 回调） |
| `normalize_cjk_punct` | 同名函数，逐字符等价移植 |
| `~/Library/Application Support/Whisper听写/config.json` | `~/Library/Application Support/Recorpaster/config.json`（Phase 2） |

---

## 1. 四个重点坑（最高优先级，每 Phase 自测必查）

用户从 Python 版踩坑总结，**这四条是验收红线**：

1. **浮窗绝不抢焦点。** 用**非激活 `NSPanel`**：`styleMask` 含 `.nonActivatingPanel`，`canBecomeKey`/
   `canBecomeMain` 返回 `false`，`hidesOnDeactivate=false`，`level=.statusBar`，显示用
   **`orderFrontRegardless()`**（绝不用 `makeKeyAndOrderFront(_:)` / `activate(...)`），
   `ignoresMouseEvents=true`。App 激活策略设 `.accessory`。
   **验收**：在任意输入框里打字 → 长按热键说话 → 浮窗出现期间光标插入点不动、焦点不离开输入框，⌘V 落在原输入框。

2. **权限只弹一次，绝不循环。** 三项权限各自「检查 → 未授时引导一次 → 记住已引导」：
   - 麦克风：`AVCaptureDevice.requestAccess(for:.audio)`，notDetermined 才弹一次。
   - 辅助功能：`AXIsProcessTrustedWithOptions([prompt:true])` **只首次**调一次；之后只 `AXIsProcessTrusted()` 无弹窗轮询。
   - 输入监控：`IOHIDCheckAccess(.listenEvent)` 查状态；未决定时 `IOHIDRequestAccess` 请求一次。
   - 用 `UserDefaults` 标记「已引导过」。**看门狗重试建 tap 必须 gate 在 `accessibilityTrusted() && inputMonitoringGranted()`**，
     否则 `CGEvent.tapCreate` 缺输入监控时会每 2s 触发 TCC 弹窗（绕过「只弹一次」）。缺权限菜单栏 ⚠️ + 菜单给「打开系统设置」。
   **验收**：冷启动最多每项弹一次；拒绝后再启动不再弹；菜单栏 ⚠️ 常驻直到授权。

3. **中文标点要实测带上。** 两步（本地、不依赖 AI 润色）：
   - **风格引导 prompt**：给 `DecodingOptions` 注入「以下是普通话的句子，请加上标点。」作为 prompt tokens
     （`usePrefillPrompt + promptTokens`，编码后过滤掉 special token）。
   - **本地标点规整** `normalizeCJKPunct`：仅当 ASCII 标点「两侧都是 CJK 汉字」时转全角，**不动** `3,000`/`v1.2`/`OK,我`。
   **验收**：连说两三句中文，上屏带「，。？」全角标点；数字/版本号不被误转。

4. **松开别丢尾句。** 引擎 `flush()` + 收尾排空：
   - **采纳闸门不变量**：录音回调里的 `guard recording` 必须开到**最后一个在途 delta 被追加之后**；
     用「移除 tap」停止新音频，而**不是提前翻 `recording=false`**（否则尾音被守卫吞掉）。
   - `stop()`：sleep ~0.3s（闸门仍开）→ 停 tap → 排空主队列 → **最后**才 `recording=false` → step+flush 兜底当前句 →
     关识别流并 await 排空（含尾句）。
   **验收**：说一句话紧接着立刻松手（不留尾静音），最后几个字仍被识别并上屏。

> 这四条之外，第 6 节列出从 Python 版继承的完整坑表。

---

## 2. 交互与状态机

### 2.1 热键
- 默认右 ⌥（keyCode 61）。`hold` 长按 / `toggle` 切换。`CGEventTap`（listenOnly）监听 `flagsChanged`，按 keyCode 区分左右 ⌥。
- 去抖：`isDown` 守卫过滤重复。tap 被系统禁用（超时/用户输入）后自动重启，并用 `CGEventSource.flagsState` **对账真实键态**补发漏掉的「松开」（防幻影会话）。

### 2.2 会话状态机（移植自 `app.py`）
```
idle ──begin──▶ active ──end──▶ stopping ──(收尾完成)──▶ idle
                  ▲                  │
                  └───── pendingBegin (stopping 期间又按下，停完无缝重开)
```
- **关键不变量**：stopping 态的「松开/再 toggle」必须清 `pendingBegin` 并复位菜单栏图标（用 `resetIconForStoppingCancel`，
  不能用只在 idle 生效的 `refreshIdleIcon`），否则会复活幻影会话或图标卡在「聆听中」。

### 2.3 浮窗可见性（幂等 + 可取消）
- 可见性严格跟随热键意图，与引擎收尾**解耦**（`onResult` 不碰可见性）。
- 每次切换自增 `epoch`；淡出后的 `orderOut` 在动画 completion 里复检 epoch，被新「显示」覆盖则放弃隐藏。

---

## 3. 引擎层（`DictationEngine`，UI 无关，接口与 `engine.py` 对齐）

- 对外：`start()` / `stop()` / `flush()` + `onResult(DictationResult)` / `onStatus(EngineStatus)`。
- 采集：**自管 `AVAudioEngine`（`MicCapture`）**——用 `inputNode.inputFormat(forBus:0)`（硬件原生格式，常见 48kHz）
  装 tap，再用 `AVAudioConverter` 把每个 buffer 转 **16kHz / mono / Float32**。回调在音频线程，hop 回主线程把增量
  追加进自有缓冲做切句。**不用 WhisperKit `AudioProcessor` 的采集**：它在本机逐帧重采样抛 `-10877`
  (`kAudioUnitErr_InvalidElement`) 并**静默丢弃**每个 buffer（只 `Logging.error` 不抛），表现为「浮窗显示聆听中但其实没在录」。
- 切句：`EnergyVAD` 逐 512 帧吐 `start`/`end`（含 `lookbackChunks` 句首回看）；Silero ONNX 留作 Phase 2 升级。
- 识别：每句 `whisperKit.transcribe(audioArray:decodeOptions:)`；`language="zh"`、标点 prompt、`temperature=0`、
  `skipSpecialTokens/withoutTimestamps=true`。串行消费（AsyncStream），不阻塞下一句。
- 自测可观测：每秒打印 `buffers/s + RMS`，确认有声音进来；采集失败显式抛错由总控反馈到浮窗（不静默吞）。
- 隐私：全程内存 `[Float]`，绝不写音频文件。
- 默认：`minSilenceMs=300`、`vadThreshold=0.5`、`minUtterSec=0.3`、`lookbackChunks=10`。

## 4. 输出层

- `paste`：保存当前剪贴板 → 写文本 → `CGEvent` ⌘V → 短延时 → **有条件还原**（用 `changeCount` 判定：自我们写入后
  未被改动才还原，避免覆盖用户期间的复制 / 在目标 App 尚未消费时塞回旧内容）。
- `copy`：仅写剪贴板。顺序上屏（串行队列），不阻塞下一句。上屏前过 `normalizeCJKPunct`。

## 5. 菜单栏（`NSStatusItem`）

- Template SF Symbol：idle=`mic`、listening=`mic.fill`、loading=`arrow.triangle.2.circlepath`、warn=`exclamationmark.triangle.fill`。
- 菜单：开始/停止、设置…（Phase 2，禁用占位）、（缺权限时）打开系统设置·辅助功能/输入监控/麦克风、退出。
- 强引用 statusItem 与 target（坑 #5）。

---

## 6. 完整坑表（从 Python README 继承，映射到 Swift）

1. 主线程 run-loop：AppKit 主线程即 run-loop；UI 切 `MainActor`；CGEventTap source 加到主 run loop。
2. 浮窗抢焦点 → ⌘V 落错地方：见重点坑 #1。
3. 后台回调推 UI 切主线程：引擎回调类型标 `@MainActor`，在主 actor 上调用。
4. 松开丢尾句：见重点坑 #4（采纳闸门不变量 + flush + 排空）。
5. 菜单栏点了没反应/失效：强引用 statusItem + target。
6. 权限没给=静默失效：见重点坑 #2；缺权限 ⚠️ + 引导。
7. （pywebview 透明窗弃用警告——不适用 Swift。）
8. 窗口显隐与引擎收尾解耦：见 2.3；stopping 态清 pendingBegin + 专用图标复位。
9. 玻璃质感：Phase 1 用 SwiftUI `.ultraThinMaterial`；macOS 26 液态玻璃 `.glassEffect` 留作升级。
10. 多屏定位：每次显示按鼠标所在 `NSScreen` 底部居中 `setFrameOrigin`。
11. 菜单栏 template SF Symbol：见第 5 节。

---

## 7. Phase 划分与验收

### Phase 1 ✅ 核心闭环（已实现 + 自测）
全局热键（右 ⌥ 长按）、非激活悬浮窗、WhisperKit 实时识别（中文带标点）、上屏/复制、菜单栏托盘、
音频不落盘、权限引导（只弹一次）、松开补全尾句。

> **本轮自测结果（2026-06-18）**
> - ✅ `xcodebuild` Debug/arm64 编译通过（WhisperKit 0.18.0 via SPM）。
> - ✅ 启动冒烟：`.accessory`、无 Dock、菜单栏托盘、浮窗、日志、不崩溃。
> - ✅ 模型管线端到端：下载 `openai_whisper-large-v3-v20240930_turbo`（1.5GB）→ CoreML 加载 → 「引擎就绪」。
> - ✅ 坑 #3 中文标点 `normalizeCJKPunct`：10 条断言全过（含 `3,000`/`v1.2`/`OK,我` 负例）。
> - ✅ 多智能体对抗式审查 → 修掉 1 critical（`stop()` 丢尾音）、2 high（看门狗漏输入监控反复弹窗；尾音）、
>   3 medium（收尾图标卡死、粘贴还原剪贴板用 changeCount 守卫、tap 禁用漏松开→重启对账）、1 low（toast 覆盖错误提示）。
> - ✅ 采集修复：原用 WhisperKit `AudioProcessor` 在本机抛 `-10877` 静默丢帧（浮窗「聆听中」却没录音）→
>   改为自管 `AVAudioEngine`（`MicCapture`：硬件格式 tap + `AVAudioConverter` → 16kHz mono），加 RMS 电平表 + 失败反馈到浮窗。
> - 待**人工**验收（需授权 + 对麦说话）：实时上屏到光标、浮窗不抢焦点、松开补尾句、权限只弹一次。

### Phase 2 ⏳ 设置面板 + 持久化
基础/高级两层；改完即时生效（必要时重建 engine）并持久化 JSON。Silero VAD 可选升级。sessionSamples 滑窗封顶内存。

### Phase 3 ⏳ AI 润色（v1.1，可插拔，默认关）

### Phase 4 ⏳ 打包分发
Developer ID 签名 + hardened runtime + 麦克风 entitlement + 公证 + DMG。日志写 `~/Library/Logs/Recorpaster.log`。

---

## 8. 配置默认值（Phase 1 硬编码，Phase 2 入面板）

| 项 | 默认 | 说明 |
|---|---|---|
| `hotkeyKeyCode` | 61（右 ⌥） | 捕获稳定；别用 fn |
| `hotkeyMode` | `hold` | 长按推杆 |
| `outputMode` | `paste` | 剪贴板+⌘V，有条件还原 |
| `model` | `openai_whisper-large-v3-v20240930_turbo` | WhisperKit 仓库精确文件夹名；中文最佳 |
| `language` | `zh` | |
| `minSilenceMs` | `300` | 断句灵敏度 |
| `vadThreshold` | `0.5` | 环境灵敏度 |
| `initialPrompt` | `以下是普通话的句子，请加上标点。` | 标点风格引导；置空关闭 |
| `minUtterSec` | `0.3` | 过短丢弃 |
| `lookbackChunks` | `10` | 句首回看 ~320ms |

## 9. 工程配置要点

- **关闭 App Sandbox**（`ENABLE_APP_SANDBOX = NO`）：听写需全局热键、辅助功能、向其它 app 投递 ⌘V、读写通用剪贴板。
- **Accessory app**：`INFOPLIST_KEY_LSUIElement = YES` + 运行时 `setActivationPolicy(.accessory)`。
- **Info.plist**（`GENERATE_INFOPLIST_FILE=YES`）：`NSMicrophoneUsageDescription`。
- **WhisperKit** SPM 依赖；模型首次运行下载到 `~/Documents/huggingface/models/...`，有进度反馈。
- 无默认窗口：`App.body` 用空 `Settings {}`，全部 UI 由 `AppDelegate` 驱动。

## 10. 文件布局（Phase 1）
```
Recorpaster/
  RecorpasterApp.swift      @main + NSApplicationDelegateAdaptor + 空 Settings 场景
  AppDelegate.swift         设 .accessory 策略；构建 AppController
  AppController.swift       会话状态机 + 各组件接线（对应 app.py 的 App）
  Permissions.swift         麦克风/辅助功能/输入监控：检查 + 引导一次 + 记忆
  HotKeyMonitor.swift       CGEventTap 监听右 ⌥ 按下/松开 + 禁用后对账
  FloatingPanel.swift       非激活 NSPanel + 显隐/定位/承载 SwiftUI
  FloatingView.swift        悬浮窗 SwiftUI（状态点 + 实时文字 + 玻璃底）
  DictationEngine.swift     WhisperKit + 采集接线 + VAD 切句 + flush 收尾 + 回调
  MicCapture.swift          自管 AVAudioEngine 采集（硬件格式 tap + AVAudioConverter → 16kHz mono）
  VAD.swift                 VAD 协议 + EnergyVAD
  TextOutput.swift          上屏/复制 + normalizeCJKPunct
  Config.swift              配置结构 + 默认值
  Log.swift                 控制台 + ~/Library/Logs/Recorpaster.log
```
