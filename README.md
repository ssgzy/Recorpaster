# Recorpaster

长按热键说话 → 本地实时把语音转成带标点的文字 → 自动上屏到光标处。**本地、轻量、隐私**：音频只在内存处理，转完即弃，绝不写盘。

本仓库有**两条独立的线**（同名不同实现）：

| 分支 | 平台 | 内容 |
|---|---|---|
| **`main`** | **macOS** | 🟢 **原生版（主线）**：Swift + WhisperKit，本仓当前开发线 |
| `macos-native` / `feature/listening-bar` | macOS | 与 `main` 相同的历史快照（冗余，可删） |
| `windows-python-main` | Windows | Python 版**完整备份**（pywebview + faster-whisper / mlx） |
| `track-a-windows-port` | Windows | Python 版，GitHub Actions 出 `.exe` |

> macOS 原生版是从 Python 版重做而来：Python 库从此只服务 Windows，macOS 改用 Swift + WhisperKit（CoreML / ANE），无需 Python。

---

## macOS 原生版（`main`）

### 功能
- **长按热键**（默认右 ⌥，设置里可改 ⌥ / ⌘ / ⌃ / fn）唤出屏幕底部 **液态玻璃聆听条**（macOS 26 `.glassEffect`，呼吸 + 随麦克风 RMS 律动 + 文字逐字 pop）。
- **WhisperKit `large-v3-turbo`（CoreML）** 本地识别，松开即整段转写；**实时逐字预览**（边说边出，轮询重转写）。
- **中文标点**：`bert-base-chinese` 标点模型（CoreML int8）后处理，只插不改写原字；英文/自动检测到英文自动跳过。
- **上屏**：剪贴板 + ⌘V（用完有条件还原剪贴板）/ 仅复制。
- 常驻**菜单栏**、无 Dock 图标、`.accessory`；浮条**绝不抢焦点**（⌘V 落在原输入框）。
- **设置面板**（菜单「设置…」）：快捷键 / 语言（自动·中·英）/ 标点开关 / 上屏方式 / 强调色 / 开机自启 / 提示音 / 实时预览开关；JSON 持久化、热生效不重启、配置损坏→默认不崩。
- 模型加载进度反馈（首次下载真 % / 冷加载不确定式动画 + 时长提示）。

### 环境
- Xcode 26.1 / Swift 6.2（语言模式 5.0）/ 部署目标 macOS 26.1 / Apple Silicon（arm64）。
- 依赖：WhisperKit（SPM, 0.18.0）。Bundle ID：`io.sam.Recorpaster`。App Sandbox 关闭（需全局热键 / 辅助功能 / 向其它 app 投递 ⌘V / 读写剪贴板）。

### 构建与运行
```bash
bash tools/build-signed.sh
```
该脚本：编译 → 用一张**稳定的本地自签名证书**签名 → 拷一份到桌面 `~/Desktop/Recorpaster.app`。
用本地证书签名是为了让 **TCC 授权（辅助功能 / 输入监控 / 麦克风）跨重编持久**——否则 `xcodebuild` 默认产 ad-hoc 二进制，身份每次变、授权每次掉。首次授权一次，之后重跑脚本再双击桌面 app，授权都还在。

> 也可直接用 Xcode 打开 `Recorpaster.xcodeproj` Run（首次运行会下载 ~1.5GB 的 WhisperKit 模型；冷加载约 1–2 分钟）。

### ⚠️ 标点模型不在仓库里
中文标点用的 **`PunctZh`（bert-base-chinese 标点，~97MB CoreML）不随仓库分发**（见 `.gitignore`）。仿 WhisperKit 走**运行时下载**到 `~/Library/Application Support/Recorpaster/`，没有模型时标点功能**优雅降级**（输出无标点，其余照常）。

克隆后要启用中文标点，二选一：
1. **手动放模型**：把 `PunctZh.mlpackage`（或编译好的 `PunctZh.mlmodelc`）放进 `~/Library/Application Support/Recorpaster/`。
2. **配运行时下载**：把模型上传到一个 HuggingFace 仓库，填进 `Recorpaster/PunctuationRestorer.swift` 的 `modelRepo`（首次启动自动下载）。

模型可一键复现：`tools/convert_punct.py` 从 `p208p2002/zh-wiki-punctuation-restore` 转成 CoreML int8（需 `coremltools` + `transformers==4.46`，详见脚本头注）。

详细设计见 [`MACOS_SWIFT_SPEC.md`](MACOS_SWIFT_SPEC.md)（活文档）与 [`SETTINGS_SPEC.md`](SETTINGS_SPEC.md)。

---

## Windows Python 版（`windows-python-main` / `track-a-windows-port`）

pywebview 悬浮窗 + pynput 全局热键 + faster-whisper / mlx-whisper 识别 + pyperclip 上屏。

```bash
git switch windows-python-main      # 或 track-a-windows-port
python app.py                       # 依赖见该分支 requirements / BUILD_SPEC.md
```
`track-a-windows-port` 配了 GitHub Actions，可自动打包出 `.exe`（见该分支的 workflow 与 `build_mac.sh` / `Recorpaster.spec`）。

---

## 隐私
音频全程内存 `[Float]`，转完即弃，**绝不写音频文件**。识别/标点全部本地（仅首次按需下载模型权重）。
