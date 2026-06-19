//
//  Config.swift
//  Recorpaster
//
//  全局配置 + JSON 持久化（Phase 2）。单一文件 ~/Library/Application Support/Recorpaster/config.json。
//  缺失/损坏 → 用默认值，绝不崩。改动即存、尽量热生效（见 ConfigStore / AppController.applyConfig）。
//

import Foundation
import SwiftUI

/// 热键触发模式：长按推杆 / 按一下切换。
enum HotkeyMode: String, Codable { case hold, toggle }

/// 上屏方式。
enum OutputMode: String, Codable, CaseIterable { case paste, copy
    var display: String { self == .paste ? "自动粘贴（⌘V）" : "仅复制到剪贴板" }
}

/// 识别语言设置。auto = 让 WhisperKit 自动检测。
enum LanguageSetting: String, Codable, CaseIterable {
    case auto, chinese, english
    /// 传给 WhisperKit DecodingOptions.language；nil = 自动。
    var code: String? { switch self { case .auto: nil; case .chinese: "zh"; case .english: "en" } }
    var display: String { switch self { case .auto: "自动检测"; case .chinese: "中文"; case .english: "英文" } }
}

/// 全局配置。Codable 持久化；新增字段都要给默认值，保证旧/缺字段的 JSON 也能解码。
struct Config: Codable, Equatable {
    // —— 快捷键（hold-to-talk）——
    var hotkeyKeyCode: Int64 = 61          // 默认右 ⌥
    var hotkeyMode: HotkeyMode = .hold

    // —— 识别 ——
    var language: LanguageSetting = .auto   // 默认自动检测
    var punctuationEnabled: Bool = true     // 中文 BERT 标点后处理开关

    // —— 输出 ——
    var outputMode: OutputMode = .paste

    // —— 外观 ——
    var accentColorHex: String = "#0A84FF"  // 浮条强调色（默认 macOS 系统蓝）

    // —— 行为 ——
    var launchAtLogin: Bool = false
    var playSounds: Bool = false            // 开始/停止轻提示音
    var streamingPreview: Bool = true       // 实时逐字预览（轮询重转写）

    // —— 引擎内部（不在 UI 编辑，但持久化）——
    var model: String = "openai_whisper-large-v3-v20240930_turbo"
    var initialPrompt: String = "以下是普通话的句子，请加上标点。"   // 仅 dev 诊断用
    var minUtterSec: Double = 0.3

    // —— 派生 ——
    var languageCode: String? { language.code }
    var accentColor: Color { Color(hex: accentColorHex) ?? .accentColor }

    static let `default` = Config()
}

// 逐字段容错 Codable：**缺字段/类型不符 → 用该字段默认值**（forward-compat：加新设置不会重置旧配置）。
// 放在 extension 里，保留合成的无参 init()（即 Config() / Config.default）。
extension Config {
    enum CodingKeys: String, CodingKey {
        case hotkeyKeyCode, hotkeyMode, language, punctuationEnabled, outputMode
        case accentColorHex, launchAtLogin, playSounds, streamingPreview
        case model, initialPrompt, minUtterSec
    }
    init(from decoder: Decoder) throws {
        var c = Config()   // 从默认值起，只覆盖 JSON 里存在且合法的字段
        let k = try decoder.container(keyedBy: CodingKeys.self)
        c.hotkeyKeyCode      = (try? k.decode(Int64.self, forKey: .hotkeyKeyCode)) ?? c.hotkeyKeyCode
        c.hotkeyMode         = (try? k.decode(HotkeyMode.self, forKey: .hotkeyMode)) ?? c.hotkeyMode
        c.language           = (try? k.decode(LanguageSetting.self, forKey: .language)) ?? c.language
        c.punctuationEnabled = (try? k.decode(Bool.self, forKey: .punctuationEnabled)) ?? c.punctuationEnabled
        c.outputMode         = (try? k.decode(OutputMode.self, forKey: .outputMode)) ?? c.outputMode
        c.accentColorHex     = (try? k.decode(String.self, forKey: .accentColorHex)) ?? c.accentColorHex
        c.launchAtLogin      = (try? k.decode(Bool.self, forKey: .launchAtLogin)) ?? c.launchAtLogin
        c.playSounds         = (try? k.decode(Bool.self, forKey: .playSounds)) ?? c.playSounds
        c.streamingPreview   = (try? k.decode(Bool.self, forKey: .streamingPreview)) ?? c.streamingPreview
        c.model              = (try? k.decode(String.self, forKey: .model)) ?? c.model
        c.initialPrompt      = (try? k.decode(String.self, forKey: .initialPrompt)) ?? c.initialPrompt
        c.minUtterSec        = (try? k.decode(Double.self, forKey: .minUtterSec)) ?? c.minUtterSec
        self = c
    }
    func encode(to encoder: Encoder) throws {
        var k = encoder.container(keyedBy: CodingKeys.self)
        try k.encode(hotkeyKeyCode, forKey: .hotkeyKeyCode)
        try k.encode(hotkeyMode, forKey: .hotkeyMode)
        try k.encode(language, forKey: .language)
        try k.encode(punctuationEnabled, forKey: .punctuationEnabled)
        try k.encode(outputMode, forKey: .outputMode)
        try k.encode(accentColorHex, forKey: .accentColorHex)
        try k.encode(launchAtLogin, forKey: .launchAtLogin)
        try k.encode(playSounds, forKey: .playSounds)
        try k.encode(streamingPreview, forKey: .streamingPreview)
        try k.encode(model, forKey: .model)
        try k.encode(initialPrompt, forKey: .initialPrompt)
        try k.encode(minUtterSec, forKey: .minUtterSec)
    }
}

// MARK: - Color ↔ hex（强调色持久化用）

extension Color {
    /// 从 "#RRGGBB" / "RRGGBB" 解析（失败返回 nil → 退回系统强调色）。
    init?(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let v = UInt32(s, radix: 16) else { return nil }
        self = Color(.sRGB,
                     red: Double((v >> 16) & 0xFF) / 255,
                     green: Double((v >> 8) & 0xFF) / 255,
                     blue: Double(v & 0xFF) / 255)
    }

    /// 转成 "#RRGGBB"（用 NSColor 取 sRGB 分量）。
    var hexRGB: String {
        let ns = NSColor(self).usingColorSpace(.sRGB) ?? .systemBlue
        let r = Int((ns.redComponent * 255).rounded())
        let g = Int((ns.greenComponent * 255).rounded())
        let b = Int((ns.blueComponent * 255).rounded())
        return String(format: "#%02X%02X%02X", r, g, b)
    }
}

/// 引擎层公用常量（与 engine.py 对齐）。nonisolated：供音频线程等非 MainActor 上下文直接引用。
enum AudioConstants {
    nonisolated static let sampleRate = 16_000   // WhisperKit 固定 16kHz
    nonisolated static let chunk = 512           // 每帧 512 样本（32ms），与 silero/engine.py 一致
}
