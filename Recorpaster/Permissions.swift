//
//  Permissions.swift
//  Recorpaster
//
//  三项 macOS 权限的检查与「只弹一次」引导（坑 #2：权限只弹一次，绝不循环）：
//   · 麦克风 Microphone：采集语音。首次开麦时系统弹一次（AVCaptureDevice，notDetermined 才弹）。
//   · 辅助功能 Accessibility：投递 ⌘V 上屏 + 建全局键盘事件 tap。首次带 prompt 调一次，之后只无弹窗轮询。
//   · 输入监控 Input Monitoring：CGEventTap 监听键盘。首次 IOHIDRequestAccess 请求一次，之后只查状态。
//
//  原则：用 UserDefaults 标记「已引导过」，绝不每次启动/每次失败都弹。缺权限时上层显示 ⚠️ + 在菜单里
//  提供「打开系统设置对应面板」的入口，靠用户手动开，而不是弹窗轰炸。
//

import AVFoundation
import AppKit
import ApplicationServices
import IOKit.hid

@MainActor
enum Permissions {
    private static let defaults = UserDefaults.standard
    private static let kPromptedAX = "didPromptAccessibility"
    private static let kPromptedIM = "didPromptInputMonitoring"

    // MARK: 麦克风

    static func microphoneStatus() -> AVAuthorizationStatus {
        AVCaptureDevice.authorizationStatus(for: .audio)
    }

    /// 请求麦克风权限：notDetermined 时系统弹一次；已决定则直接返回结果（不再弹）。
    static func requestMicrophone() async -> Bool {
        switch microphoneStatus() {
        case .authorized: return true
        case .denied, .restricted: return false
        case .notDetermined:
            return await withCheckedContinuation { cont in
                AVCaptureDevice.requestAccess(for: .audio) { granted in
                    cont.resume(returning: granted)
                }
            }
        @unknown default: return false
        }
    }

    // MARK: 辅助功能

    /// 无弹窗查询是否已信任（用于轮询状态，绝不触发弹窗）。
    static func accessibilityTrusted() -> Bool {
        AXIsProcessTrusted()
    }

    /// 引导一次：带系统弹窗 + 引导到设置。仅首次调用真正弹，之后是空操作。
    static func promptAccessibilityOnce() {
        guard !defaults.bool(forKey: kPromptedAX) else { return }
        defaults.set(true, forKey: kPromptedAX)
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    // MARK: 输入监控

    static func inputMonitoringGranted() -> Bool {
        IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted
    }

    /// 引导一次：未决定时请求一次（系统弹窗）。已决定/已引导则不再弹。
    static func requestInputMonitoringOnce() {
        guard !defaults.bool(forKey: kPromptedIM) else { return }
        defaults.set(true, forKey: kPromptedIM)
        if IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) != kIOHIDAccessTypeGranted {
            _ = IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
        }
    }

    // MARK: 汇总 + 打开系统设置

    /// 热键 + 上屏所需的关键权限是否齐全（辅助功能是最关键的门）。
    static var hotkeyAndPasteReady: Bool { accessibilityTrusted() }

    enum Pane { case accessibility, inputMonitoring, microphone }

    static func openSystemSettings(_ pane: Pane) {
        let anchor: String
        switch pane {
        case .accessibility:   anchor = "Privacy_Accessibility"
        case .inputMonitoring: anchor = "Privacy_ListenEvent"
        case .microphone:      anchor = "Privacy_Microphone"
        }
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") {
            NSWorkspace.shared.open(url)
        }
    }
}
