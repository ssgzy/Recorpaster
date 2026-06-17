//
//  HotKeyMonitor.swift
//  Recorpaster
//
//  全局热键监听（对应 Python 版的 pynput）。用 CGEventTap 监听 flagsChanged，按 keyCode 区分
//  左右 ⌥（右 Option = 61）。listenOnly：不吞事件，⌥ 照常作用于系统。
//
//  权限：建键盘事件 tap 需要「辅助功能 / 输入监控」。若 tapCreate 返回 nil 即权限缺失，start() 返回
//  false，由上层显示 ⚠️ 并稍后重试（绝不在这里反复弹窗）。
//
//  回调是 C 函数指针，跑在主 run loop（主线程）上；用 MainActor.assumeIsolated 安全回到主 actor。
//
//  ⚙️ 诊断：tap 创建结果、收到的每个 flagsChanged(keyCode/alt)、press/release 触发都打日志，
//  便于排查「热键不触发」是没建 tap / 没收到事件 / keyCode 不对 / 还是 press-release 逻辑。
//

import AppKit
import CoreGraphics

nonisolated final class HotKeyMonitor {
    private let keyCode: Int64
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var isDown = false

    /// 按下 / 松开回调（在主线程触发）。
    var onPress: (@MainActor () -> Void)?
    var onRelease: (@MainActor () -> Void)?

    init(keyCode: Int64) {
        self.keyCode = keyCode
    }

    /// 启动监听。成功返回 true；权限缺失（tapCreate 失败）返回 false。
    @discardableResult
    func start() -> Bool {
        guard tap == nil else { return true }
        let mask: CGEventMask = (1 << CGEventType.flagsChanged.rawValue)
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: mask,
            callback: Self.eventCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            Log.warn("热键: CGEvent.tapCreate 返回 nil（缺辅助功能/输入监控权限）。")
            return false
        }
        self.tap = tap
        let src = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        self.source = src
        CFRunLoopAddSource(CFRunLoopGetMain(), src, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        Log.ok("热键: tap 已创建、加入主 run loop 并 enable（监听 flagsChanged，目标 keyCode=\(keyCode)）。")
        return true
    }

    func stop() {
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        source = nil
        tap = nil
        isDown = false
    }

    // C 回调：非捕获闭包 → 可转成 @convention(c)。从 refcon 取回 self。
    private static let eventCallback: CGEventTapCallBack = { _, type, event, refcon in
        guard let refcon else { return Unmanaged.passUnretained(event) }
        let monitor = Unmanaged<HotKeyMonitor>.fromOpaque(refcon).takeUnretainedValue()
        monitor.handle(type: type, event: event)
        return Unmanaged.passUnretained(event)
    }

    /// 用系统真实修饰键状态校正 isDown：若键已松开却仍标记按下，补发一次 onRelease 收尾会话。
    private func reconcileModifierState() {
        let altNow = CGEventSource.flagsState(.combinedSessionState).contains(.maskAlternate)
        if isDown && !altNow {
            isDown = false
            MainActor.assumeIsolated { onRelease?() }
        }
    }

    private func handle(type: CGEventType, event: CGEvent) {
        // 系统可能因超时/用户输入临时禁用 tap → 立即重新启用，保证热键长期可用。
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            Log.warn("热键: tap 被系统禁用（\(type == .tapDisabledByTimeout ? "timeout" : "userInput")），重新 enable。")
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            reconcileModifierState()
            return
        }
        guard type == .flagsChanged else { return }
        let code = event.getIntegerValueField(.keyboardEventKeycode)
        let alt = event.flags.contains(.maskAlternate)
        // 诊断：每个 flagsChanged 都打（看事件是否到达 tap、keyCode 是否为 61）。
        Log.info("热键: flagsChanged keyCode=\(code) alt=\(alt)（目标=\(keyCode)）")

        guard code == keyCode else { return }
        if alt && !isDown {
            isDown = true
            Log.ok("热键: 右⌥ 按下 → onPress")
            MainActor.assumeIsolated { onPress?() }
        } else if !alt && isDown {
            isDown = false
            Log.info("热键: 右⌥ 松开 → onRelease")
            MainActor.assumeIsolated { onRelease?() }
        }
    }
}
