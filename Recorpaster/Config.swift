//
//  Config.swift
//  Recorpaster
//
//  Phase 1 配置：硬编码默认值（Phase 2 再做设置面板 + JSON 持久化）。
//  字段与 Python 版 settings.py / engine.Config 对齐，便于后续 1:1 映射。
//

import Foundation

/// 热键触发模式：长按推杆 / 按一下切换。
enum HotkeyMode: String {
    case hold      // 按下开始、松开停止
    case toggle    // 按一下开、再按一下关
}

/// 上屏方式。
enum OutputMode: String {
    case paste     // 剪贴板 + ⌘V 上屏（用完还原剪贴板）
    case copy      // 仅复制到剪贴板
}

/// 全局配置。Phase 1 用默认值；Phase 2 起从 JSON 读写。
struct Config {
    // —— 热键 ——
    /// 默认右 ⌥ Option，keyCode = 61（捕获稳定；别用 fn）。
    var hotkeyKeyCode: Int64 = 61
    var hotkeyMode: HotkeyMode = .hold

    // —— 输出 ——
    var outputMode: OutputMode = .paste

    // —— 识别引擎（WhisperKit）——
    /// WhisperKit 模型名 = argmaxinc/whisperkit-coreml 仓库里的**精确文件夹名**。
    /// 用全名（而非短名 "large-v3-turbo"）避免 glob 匹配歧义：WhisperKit 用 `*<model>/*` 去仓库匹配，
    /// 而仓库 turbo 文件夹是下划线写法 `openai_whisper-large-v3-v20240930_turbo`（OpenAI 官方 large-v3-turbo），
    /// 短横线写法的 "large-v3-turbo" 匹配不到。该全名唯一匹配该文件夹（不含量化的 _632MB 版）。
    var model: String = "openai_whisper-large-v3-v20240930_turbo"
    /// 识别语言；nil = 自动检测。中文固定 "zh" 质量与稳定性最好。
    var language: String? = "zh"
    /// 标点风格引导：一段“本身带标点”的中文，让 Whisper 跟随该风格输出标点（不是当指令）。置空关闭。
    var initialPrompt: String = "以下是普通话的句子，请加上标点。"

    // —— VAD / 断句 ——
    /// 断句灵敏度：检测到这么久的静音才判定一句结束。大=更完整，小=更快出字。
    var minSilenceMs: Int = 300
    /// 环境灵敏度：相对噪声基底的能量倍数门限。嘈杂环境可调高。
    var vadThreshold: Float = 0.5
    /// 句首回看帧数，避免吞掉句子开头（10 帧 ≈ 320ms）。
    var lookbackChunks: Int = 10
    /// 短于此时长的片段丢弃，过滤噪声/误触发。
    var minUtterSec: Double = 0.3

    static let `default` = Config()
}

/// 引擎层公用常量（与 engine.py 对齐）。nonisolated：供音频线程等非 MainActor 上下文直接引用。
enum AudioConstants {
    nonisolated static let sampleRate = 16_000   // WhisperKit 固定 16kHz
    nonisolated static let chunk = 512           // 每帧 512 样本（32ms），与 silero/engine.py 一致
}
