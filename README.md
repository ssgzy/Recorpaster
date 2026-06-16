# 轻量化本地语音转文字工具（macOS 听写）

长按热键唤出 → 实时把语音转成文字 → 自动上屏 / 复制到剪贴板。
**本地、轻量、隐私**：音频只在内存里转写，**转完即弃，绝不写盘**。

引擎层 `engine.py` 封装 faster-whisper(CPU) / mlx-whisper(Apple Silicon GPU) +
Silero VAD 切句；UI 用 **pywebview**（系统自带 WebView，无 Electron）+ 原生菜单栏托盘。

---

## 进度

- **Phase 1 ✅ 核心闭环**：全局热键（长按推杆）、悬浮窗、上屏/复制、菜单栏托盘、音频不落盘。
- **Phase 2 ✅ 设置面板**：基础/高级两层，改完即时生效（重建 engine）并持久化到 JSON、重启保留。
- Phase 3 ⏳ AI 润色（可插拔开关，默认关闭）。

---

## 快速开始

### 1. 依赖

ASR 相关依赖（faster-whisper / mlx-whisper / sounddevice / silero-vad / pynput / pyperclip）应已装好。
本项目额外需要 pywebview：

```bash
pip install pywebview        # 会自动带上 pyobjc-framework-WebKit 等
```

> mlx-whisper 仅 Apple Silicon 可用；Intel Mac / 其它平台会自动回退到 faster-whisper(CPU)。

### 2. 授权（**最关键，缺了热键和上屏都不工作**）

本程序需要 3 项 macOS 权限。**权限是授给“运行它的那个程序”** —— 你从哪个终端启动，就要给**那个终端**授权（如 `Terminal.app` / `iTerm` / `VS Code`）。打包成 `.app` 后则授给该 app。

| 权限 | 用途 | 缺了会怎样 |
|---|---|---|
| **麦克风 Microphone** | 采集语音 | 听写无声、报错 |
| **输入监控 Input Monitoring** | pynput 捕获全局热键 | 长按热键完全没反应 |
| **辅助功能 Accessibility** | 发送 Cmd+V 上屏、读取按键 | 上屏失败、热键收不到 |

授权步骤：

1. 打开 **系统设置 → 隐私与安全性**。
2. 分别进入 **麦克风**、**输入监控**、**辅助功能** 三项，点 `+` 或打开开关，
   把**你用来启动本程序的终端**加进去并勾选。
3. **改完权限后必须重启该终端 / 本程序**，权限才生效。

首次启动时程序会：
- 自动弹出“辅助功能”授权引导对话框（来自 `AXIsProcessTrustedWithOptions`）。
- 第一次按热键开始说话时，系统会弹“麦克风”授权请求。
- 若检测到未授权，菜单栏图标会显示 `⚠️`，终端也会打印提示。

> 终端日志里出现 `This process is not trusted! Input event monitoring will not be possible`
> 就是**输入监控/辅助功能没给**——按上面步骤授权并重启即可。

### 3. 运行

```bash
python3 app.py
```

启动后：
- 菜单栏出现图标：`⏳` 加载模型 →（首次 mlx 模型若没缓存会下载约 1.5GB）→ `🎤` 就绪。
- **长按右 Option（⌥）** 说话 → 屏幕下方中央浮现悬浮窗显示实时文字，并自动上屏到当前光标处；
- **松开** → 停止，最后半句也会补全后再淡出。
- 菜单栏图标菜单：开始/停止、设置（Phase 2）、退出。

自测引擎层（不带 UI，纯命令行）：

```bash
python3 engine.py     # Ctrl+C 退出
```

---

## 默认行为 / 可配置项

配置文件：`~/Library/Application Support/Whisper听写/config.json`（首次运行用默认值，Phase 2 起可在设置面板里改）。

| 项 | 默认 | 说明 |
|---|---|---|
| `hotkey` | `alt_r` | 右 Option。pynput 在 mac 上对它捕获稳定；**别用 fn**（抓不稳）。 |
| `hotkey_mode` | `hold` | `hold` 长按推杆 / `toggle` 按一下开再按一下关。 |
| `output_mode` | `paste` | `paste` 剪贴板+Cmd+V 上屏（**用完还原剪贴板**）/ `copy` 仅复制。 |
| `engine` | `auto` | `auto`→Apple Silicon 用 mlx、其它用 faster-whisper。 |
| `model` | `large-v3-turbo` | 见 `settings.py` 的 `MODEL_MAP`。 |
| `min_silence_ms` | `300` | 断句灵敏度：大=更完整，小=更快出字。 |
| `vad_threshold` | `0.5` | 环境灵敏度：嘈杂调高。 |

---

## 设置面板（Phase 2）

菜单栏图标 → **设置…** 打开。分两层，**点「保存并应用」即时生效并持久化**（写入上面的 JSON，重启保留）：

- **基础**：模型（tiny / base / small / large-v3-turbo，下拉内部映射到 faster-whisper 的 `model` 与 mlx 的 `mlx_repo`）、断句灵敏度（`min_silence_ms` 滑块）、上屏/仅复制、热键（下拉 + 长按/切换）。
- **高级**：引擎（自动 / faster-whisper / mlx；非 Apple Silicon 自动禁用 mlx）、环境灵敏度（`vad_threshold` 滑块）、质量模式（`quality_mode` 开关；`beam` 藏在它背后，不直接暴露）。

改**模型 / 断句灵敏度 / 引擎**会**重建 engine**（重载模型，切到没下载过的模型时首次会下载；面板与托盘显示「应用中/重载中」）；改**输出方式 / 热键**即时切换、无需重载。关闭设置窗只是隐藏（实例复用）。

> mlx 仓库名已逐个核对（HF API）：`whisper-tiny-mlx` / `whisper-base-mlx` / `whisper-small-mlx`（注意带 `-mlx` 后缀，无后缀的 `whisper-base`/`whisper-small` 不存在）、`whisper-large-v3-turbo`。见 `settings.py` 的 `MODEL_MAP`。

## 架构 & 文件

```
app.py        入口：pywebview 悬浮窗 + 设置窗 + 原生菜单栏托盘 + 全局热键 + 上屏/复制
engine.py     引擎层（已存在，未改对外接口；仅新增向后兼容的 flush()）
settings.py   配置读写（JSON 持久化）+ 设置→engine.Config 映射 + MODEL_MAP
web/          前端：index.html/style.css/app.js（悬浮窗）+ settings.html/css/js（设置面板）
```

### 引擎的扩展点（向后兼容，未动原有签名）
- 新增 `DictationEngine.flush()`：把当前正在收集的语音**立即**送识别。用于热键松开收尾，
  避免最后半句被丢。配套改动（均为内部实现，对外接口不变）：VAD 主循环退出时兜底送出尾句、
  识别线程在 `stop()` 后短暂排空队列。原有 `start()/stop()/Config/Result/on_result/on_status` 完全不变。

---

## 已知坑 & 解决办法（macOS）

1. **主线程 run-loop 之争（pywebview vs 托盘）**
   pywebview 的 `webview.start()` 会占用主线程的 `NSApplication` run-loop。rumps / pystray 也想自己起一个
   run-loop → 冲突。**解决**：托盘改用原生 `pyobjc NSStatusItem`，注入到 pywebview 已经在跑的同一个
   run-loop 里（用 `PyObjCTools.AppHelper.callAfter` 切回主线程创建），不再起第二个 run-loop。
   全局热键用 pynput，其监听器自带独立线程，不碰主线程。

2. **悬浮窗抢焦点导致 Cmd+V 上屏到错误位置**
   普通窗口弹出会夺取键盘焦点，于是 Cmd+V 粘到了我们自己的窗口而不是用户的输入框。
   **解决**：① 用 `focus=False` 创建窗口（pywebview 的 `WindowHost.canBecomeKeyWindow()` 返回 `self.focus`，
   于是窗口**不能成为 key window**）；② 显示时用原生 `orderFrontRegardless()` 而非 pywebview 默认的
   `makeKeyAndOrderFront:`+`activateIgnoringOtherApps:`（后者会激活本 App）；③ 把 App 设为
   `Accessory` 激活策略（菜单栏 App、无 Dock 图标）；④ 窗口设 `ignoresMouseEvents`，纯展示、点击穿透。

3. **回调在后台线程，往前端推字要切主线程**
   引擎的 `on_result` 在识别线程触发。pywebview 的 `window.evaluate_js()` 内部已经用
   `AppHelper.callAfter` 把 JS 执行 marshalling 到主线程（并阻塞调用方直到完成），所以可从后台线程安全调用。
   注意：**不要在主线程自己的 `callAfter` 回调里再去 `evaluate_js`**，那会等自己、死锁。

4. **松开热键丢最后半句**
   松开瞬间，最后一句可能还没被 VAD 判定结束。**解决**：松开时先 `engine.flush()` 强制断句送识别，
   再延时 ~0.35s 让尾音入队、`stop()`，识别线程在 stop 后仍会把队列里的尾句处理完（已写单测验证）。

5. **菜单栏图标点了没反应 / 程序跑着跑着托盘失效**
   pyobjc 的 `NSStatusItem` 和它的 action target 必须保持**强引用**，否则会被 GC，菜单项点击即失效。
   本项目把它们存在 `App` 实例上。

6. **权限没给 = 静默失效**
   见上面「授权」。日志里 `This process is not trusted!` 即权限缺失；菜单栏 `⚠️` 同样表示缺权限。

7. **`_setDrawsTransparentBackground: is deprecated` 警告**
   pywebview 实现透明窗口时打印的无害弃用警告，可忽略。

8. **悬浮窗显隐要和引擎收尾解耦**
   窗口可见性单独由 `_set_window_visible`（带 `_vis_epoch` 取消机制）控制，**严格跟随热键**；
   引擎收尾（flush/stop/排空尾句）在后台线程独立进行，**不碰窗口**——松开即淡出，尾句识别好了照常上屏。
   两个易错点：① 淡出后的 `orderOut` 必须把 epoch 复检放进**主线程的 callAfter 块内**（与 orderFront 串行、后者优先），否则连按时会被“显示再下沉”覆盖成卡住隐藏；② `stopping`（收尾中）状态下的“松开/再 toggle”必须显式清掉 `_pending_begin` 并复位托盘，否则 `finish()` 会读到过期意图、**在没按键的情况下复活一个幻影会话**（麦克风还开着）。

9. **玻璃质感：原生层负责模糊桌面，CSS 只叠质感**
   CSS `backdrop-filter` 只模糊网页内容、不模糊桌面，所以桌面模糊必须来自原生层：
   - **macOS 26+（Tahoe）**：用原生 **`NSGlassEffectView`（液态玻璃）**。WWDC25 要点是把**透明 webview 设成
     `NSGlassEffectView` 的 `contentView`**（不是把玻璃当 sibling 垫在内容后面）。用 Clear 风格（更透更亮、镜面感）、
     极低透明度 tintColor、圆角 ~18；多个玻璃元素相邻才用 `NSGlassEffectContainerView` 归组。
   - **< macOS 26**：自动回退到 `NSVisualEffectView`（本项目用 Popover material，比 HUD 更亮更通透），CSS 再叠
     Clear 质感（亮边 + 顶部镜面 sheen + 通透白底）。注意：**`NSVisualEffectView` 给的是奶白磨砂，到不了真液态玻璃的
     镜面/折射感**——那只有 macOS 26 才有。代码用 `macos_major()>=26 and hasattr(AppKit,'NSGlassEffectView')` 门控，
     原生装配任何环节失败都 `try/except` 回退，绝不崩。
   - 该原生视图挂在 WKWebView 之下、且可能在 `window.native` 就绪后才挂上，需**递归查找 + 短重试**。
   - 玻璃参数（material / tint / 圆角 / Clear|Regular）集中在 app.py 顶部常量 + `web/style.css` 的 `:root`，易调。
   - `web/glass_preview.html`（+ 截图 `glass_preview.png`）是 Clear vs Regular 的 CSS 仿真对比，可在浏览器打开比对。

10. **多屏：每次唤起按“活动屏”重算位置**
    用 `NSEvent.mouseLocation()` 找鼠标所在 `NSScreen`（退回 key window 屏/主屏），在每次显示前 `setFrameOrigin_`。
    否则多显示器下悬浮窗会固定出现在某块屏、用户看不到反馈。

11. **菜单栏图标用 template SF Symbol**
    `NSImage.imageWithSystemSymbolName_…` + `setTemplate_(True)`，随系统明暗自适应；idle=`mic`、listening=`mic.fill`、
    loading=旋转箭头、warn=警告三角。比 emoji/位图省心且统一。

---

## 隐私

- 音频仅在内存中处理，识别完即释放，**不写任何音频文件**。
- Phase 1 不保存历史记录、不上传、不收集任何数据。
