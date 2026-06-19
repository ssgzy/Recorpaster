//
//  SettingsView.swift
//  Recorpaster
//
//  设置面板（Phase 2）。原生 macOS 分组 Form，单页滚动。
//  ⚠️ 本 app 是 accessory（无 Dock）；打开设置窗临时切 .regular + activate 让窗口能前置/聚焦，
//  关闭时切回 .accessory。注意：不抢焦点的红线只针对浮条 HUD，设置窗口是正常窗口、允许聚焦。
//

import AppKit
import SwiftUI

// MARK: - 窗口控制（激活策略切换）

@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private let store: ConfigStore
    private let floatingModel: FloatingModel
    private let modelName: String
    private let pauseHotkey: (Bool) -> Void

    init(store: ConfigStore, floatingModel: FloatingModel, modelName: String,
         pauseHotkey: @escaping (Bool) -> Void) {
        self.store = store
        self.floatingModel = floatingModel
        self.modelName = modelName
        self.pauseHotkey = pauseHotkey
        super.init()
    }

    func show() {
        if window == nil {
            let root = SettingsView(store: store, floatingModel: floatingModel,
                                    modelName: modelName, pauseHotkey: pauseHotkey)
            let host = NSHostingController(rootView: root)
            let w = NSWindow(contentViewController: host)
            w.title = "Recorpaster 设置"
            // 不加 .miniaturizable：最小化不触发 windowWillClose，会把 App 永久卡在 .regular（Dock 图标不消失）。
            w.styleMask = [.titled, .closable, .resizable]
            w.setContentSize(NSSize(width: 460, height: 600))
            w.isReleasedWhenClosed = false
            w.delegate = self
            w.center()
            window = w
        }
        NSApp.setActivationPolicy(.regular)        // 让窗口能前置/聚焦（accessory app 经典坑）
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        pauseHotkey(false)                         // 兜底：若关窗时正在录制快捷键，别把全局 tap 留在暂停态
        NSApp.setActivationPolicy(.accessory)      // 关窗 → 回 accessory（无 Dock、不抢前台）
    }
}

// MARK: - 设置表单

struct SettingsView: View {
    @ObservedObject var store: ConfigStore
    @ObservedObject var floatingModel: FloatingModel
    let modelName: String
    let pauseHotkey: (Bool) -> Void

    @State private var recording = false
    @State private var monitor: Any?

    // v1 仅允许修饰键类（避免吃掉正常打字）。keyCode → 显示名。
    private static let allowed: [Int64: String] = [
        61: "右 ⌥", 58: "左 ⌥", 54: "右 ⌘", 55: "左 ⌘",
        59: "左 ⌃", 62: "右 ⌃", 63: "fn",
    ]

    var body: some View {
        Form {
            Section("快捷键（长按说话）") {
                HStack {
                    Text("触发键")
                    Spacer()
                    Text(Self.allowed[store.config.hotkeyKeyCode] ?? "keyCode \(store.config.hotkeyKeyCode)")
                        .foregroundStyle(.secondary)
                    Button(recording ? "按下要用的修饰键…" : "录制") { recording ? stopRecording() : startRecording() }
                        .buttonStyle(.bordered)
                }
                if recording {
                    Text("按 ⌥ / ⌘ / ⌃ / fn 之一；普通字母键不可用。")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            Section("识别") {
                Picker("语言", selection: $store.config.language) {
                    ForEach(LanguageSetting.allCases, id: \.self) { Text($0.display).tag($0) }
                }
                Toggle("中文标点（BERT 后处理）", isOn: $store.config.punctuationEnabled)
                if store.config.language == .english {
                    Text("英文使用 Whisper 自带标点，已自动跳过中文标点。")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            Section("输出") {
                Picker("上屏方式", selection: $store.config.outputMode) {
                    ForEach(OutputMode.allCases, id: \.self) { Text($0.display).tag($0) }
                }
                Text(store.config.outputMode == .paste
                     ? "需『辅助功能』权限；用完自动还原剪贴板。"
                     : "只放剪贴板、不自动粘贴，需手动 ⌘V（无需辅助功能）。")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("外观") {
                LabeledContent("浮条强调色") {
                    HStack(spacing: 10) {
                        ForEach(Self.presets, id: \.self) { hex in
                            Circle().fill(Color(hex: hex) ?? .accentColor)
                                .frame(width: 18, height: 18)
                                .overlay(Circle().strokeBorder(.primary.opacity(isSelected(hex) ? 0.9 : 0), lineWidth: 2))
                                .onTapGesture { store.config.accentColorHex = hex }
                        }
                        ColorPicker("", selection: Binding(
                            get: { store.config.accentColor },
                            set: { store.config.accentColorHex = $0.hexRGB }
                        )).labelsHidden()
                    }
                }
            }

            Section("行为") {
                Toggle("开机自启", isOn: $store.config.launchAtLogin)
                Toggle("实时逐字预览（边说边出）", isOn: $store.config.streamingPreview)
                Toggle("开始 / 停止提示音", isOn: $store.config.playSounds)
            }

            Section("模型") {
                LabeledContent("当前模型", value: modelName)
                if floatingModel.isLoading {
                    HStack {
                        Text(floatingModel.statusLine).foregroundStyle(.secondary)
                        Spacer()
                        if let p = floatingModel.loadProgress { Text("\(Int(p * 100))%").foregroundStyle(.secondary) }
                    }
                    LoadBar(progress: floatingModel.loadProgress, color: store.config.accentColor)
                        .frame(height: 4)
                } else {
                    Text("已就绪").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 420, minHeight: 520)
        .onDisappear { stopRecording() }
    }

    private static let presets = ["#0A84FF", "#30D158", "#FF453A", "#FF9F0A", "#BF5AF2", "#64D2FF"]

    /// 当前强调色是否等于该预设（归一化两侧再比，避免格式/色域差异导致不点亮）。
    private func isSelected(_ hex: String) -> Bool {
        let cur = Color(hex: store.config.accentColorHex)?.hexRGB ?? store.config.accentColorHex
        return cur.caseInsensitiveCompare(hex) == .orderedSame
    }

    // MARK: 录制快捷键（暂停全局 tap，只捕修饰键）

    private func startRecording() {
        recording = true
        pauseHotkey(true)
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged]) { event in
            let code = Int64(event.keyCode)
            if Self.allowed[code] != nil {
                store.config.hotkeyKeyCode = code
                stopRecording()
            }
            return nil   // 吞掉录制期间的按键
        }
    }

    private func stopRecording() {
        if let m = monitor { NSEvent.removeMonitor(m); monitor = nil }
        recording = false
        pauseHotkey(false)
    }
}
