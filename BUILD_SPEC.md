# 轻量化本地语音转文字工具 — 构建规格（交给 Claude Code）

## 0. 角色与方式
你是这个项目的开发执行者。**先完整读一遍 `engine.py`**（已存在，引擎层已完成，**不要改它的对外接口**），再按本规格分阶段实现。每个阶段做完先自测能跑通，再进下一阶段。遇到 macOS 权限、线程/run-loop 等问题主动解决，并记进 README。

## 1. 产品一句话
一个 **macOS 桌面听写工具**：长按热键唤出 → 实时把语音转成文字 → 自动上屏 / 复制到剪贴板。强调轻量、本地、隐私（**音频转完即弃，绝不落盘**）。

## 2. 已定架构（不要推翻）
- **引擎层 `engine.py`（已完成）**：封装 faster-whisper(CPU) / mlx-whisper(Apple Silicon GPU)、Silero VAD 切句、麦克风流。所有可调项集中在 `Config`，识别结果通过 `on_result` 回调吐出。
- **UI / 壳：pywebview**（Web 前端 HTML/CSS/JS + Python 后端），复用 `engine.py`。选它是因为用系统自带 webview、轻量、跨平台，且前端做悬浮动画 / 设置面板最顺手。
- **不要**引入 Electron 或其它重型 UI 框架。

### `engine.py` 对接点（只读，勿改接口）
```python
from engine import Config, DictationEngine, Result, default_engine

cfg = Config()                       # 字段见下
eng = DictationEngine(cfg, on_result=on_result, on_status=on_status)
eng.start()      # 开始听写（内部起后台线程）
eng.stop()       # 停止
# on_result(r: Result): r.text / r.audio_sec / r.cost_sec / r.rtf
# on_status(s: str): 状态字符串（"listening"、加载提示等）
```
- `Config` 字段：`engine`、`model`、`mlx_repo`、`language`、`min_silence_ms`、`vad_threshold`、`quality_mode`（`lookback_chunks`/`min_utter_sec` 一般不动）。
- **改配置 = 重建 engine**：先 `stop()`，用新的 `Config` 新建实例，再 `start()`。
- **回调在后台线程触发**：往前端推文字时注意线程安全（pywebview 用 `window.evaluate_js(...)` 推 JS；如遇线程限制按 pywebview 的方式处理）。
- 要扩展引擎能力（见 Phase 1 的 flush）就**加向后兼容的新方法**，别动现有签名。

## 3. MVP 范围（只做这些，别照搬整张产品脑图）

### Phase 1 — 核心闭环（最高优先，先把这个跑给用户看）
- **全局热键（hold-to-talk 推杆式）**：长按指定键 → 唤出悬浮窗 + `eng.start()`；松开 → `eng.stop()` + 悬浮窗淡出。
  - 默认键选一个 pynput 在 macOS 上**能稳定捕获**的（如右 ⌥ Option = `Key.alt_r`）；**别用 fn**（pynput 在 mac 上抓不稳）。热键可配置。也可留一个 toggle 模式作为备选。
  - **松开收尾**：松开瞬间当前可能有句子还没被 VAD 收尾。给 `engine` 加一个向后兼容的 `flush()`（把当前 buffer 立即送识别）在 `stop()` 前调用；或松开后多采集约 400ms 再停。别让最后半句丢失。
- **悬浮窗（🎈）**：小、无边框（`frameless`）、置顶（`on_top`）、半透明（`transparent` + CSS，透明度按平台实际效果调）。**默认隐藏**，唤起时淡入显示实时文字，结束后淡出。默认位置屏幕下方居中。
- **上屏 / 复制**：识别结果用「剪贴板 + 模拟 Cmd+V 粘贴」上屏（对中文最稳；**用完还原剪贴板**）。另提供「仅复制到剪贴板」模式。默认上屏。
- **托盘 / 菜单栏图标**：开始/停止、打开设置、退出。
  - 注意：pywebview 和托盘库可能各自要占主线程 run-loop。可选 rumps / pystray / 原生 pyobjc `NSStatusItem`，需要协调主线程（常见：`webview.start()` 占主线程、其余逻辑放线程，或反之）。以实际跑通为准。
- **隐私**：音频只在内存里转，转完即弃，**绝不写盘**。Phase 1 不做历史记录。

### Phase 2 — 设置面板
Web 设置窗口，配置项分两层，**改完即时生效**（重建 engine）并**持久化到 JSON**（如 `~/Library/Application Support/<app>/config.json`，启动时读取）：
- **基础**：
  - 模型（tiny / base / small / large-v3-turbo）——一个下拉，内部映射到两个字段：faster-whisper 用 `model`、mlx 用 `mlx_repo`。已知：`large-v3-turbo` → `mlx-community/whisper-large-v3-turbo`。**其它尺寸的 mlx 仓库名不统一，落地前去 HF 的 mlx-community 核对真实仓库名，别瞎拼。**
  - 断句灵敏度（`min_silence_ms` 滑块）
  - 上屏 / 仅复制 切换
  - 热键设置
- **高级**：
  - 引擎（自动 / faster-whisper / mlx；"自动"用 `engine.py` 的 `default_engine()` 逻辑）
  - 环境灵敏度（`vad_threshold` 滑块）
  - 质量模式（`quality_mode` 开关）
- **不要**把 `beam` 这种暴露给用户——藏在"质量模式"背后即可。

### Phase 3 — AI 润色（可选，做成开关）
- 一个开关：开启后识别结果先经 LLM 润色（**口语转书面 + 术语纠正**）再输出。
- 实现成**可插拔函数 + 设置项**（API endpoint / key / 预设 system prompt）。**默认关闭**，缺 key 时优雅降级为输出原文（不报错）。
- 润色有网络往返延迟：UI 给"润色中…"指示；**别阻塞下一句识别**（识别与润色解耦，润色走独立队列）。

## 4. 体验要求
- **文字"浮现"**：悬浮窗里每句以淡入 / 轻微上移动画出现，顺滑（CSS 动画）。
- 启动快、常驻轻。
- 全程不打断：用户说下一句时，上一句在后台识别 / 输出。

## 5. 工程要求
- **结构建议**（可按需调整）：`app.py`（入口 + 窗口 + 托盘 + 热键）、`web/`（`index.html` / `style.css` / `app.js` 悬浮窗，设置页等）、`settings.py`（配置读写）、`engine.py`（已存在）。
- **依赖**：`pip install pywebview`；托盘按所选方案装（pystray / rumps）；热键用已装的 pynput；mac 上 pywebview 可能拉 pyobjc。ASR 相关依赖已装好（faster-whisper / mlx-whisper / sounddevice / silero-vad / pynput / pyperclip）。
- **macOS 权限**：需要**麦克风** + **辅助功能**（发 Cmd+V、捕获全局热键）。README 写清授权步骤；缺权限时给清晰提示，别静默失败。
- **跨平台**：mlx 仅 Apple Silicon；其它平台 `default_engine()` 已回退到 faster-whisper，UI 的引擎选项要相应处理（非 Apple Silicon 隐藏 / 禁用 mlx）。

## 6. 完成判据
- **Phase 1**：后台运行，长按热键能在任意输入框（微信 / 备忘录 / 浏览器）把说的话上屏，松开停止且最后半句不丢；托盘能退出；音频不落盘。
- **Phase 2**：改模型 / 断句灵敏度 / 引擎即时生效并持久化，重启后保留。
- **Phase 3**：开润色后输出是书面化、术语更准的文本；关掉或无 key 时回到原始文本。

## 7. 边界 / 别做
- 别改 `engine.py` 的对外接口（扩展就加向后兼容新方法）。
- 别引入 Electron / 重型框架。
- MVP **不做**：历史记录 / 文档归档、批量转写、上传音频、说话人分离、远程接口二次纠正、插件层、多语言切换 UI（语言先固定走 `Config.language`）。
- 不把音频写盘；不收集用户数据。
