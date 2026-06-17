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
            return false
        }
        self.tap = tap
        let src = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        self.source = src
        CFRunLoopAddSource(CFRunLoopGetMain(), src, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
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
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            // 被禁用期间可能漏掉一次「松开」→ isDown 与真实键态失配、hold 模式卡在会话中
            // （坑 #8 幻影会话：没按键却开着麦克风）。重启后用系统真实修饰键状态对账。
            reconcileModifierState()
            return
        }
        guard type == .flagsChanged else { return }
        let code = event.getIntegerValueField(.keyboardEventKeycode)
        guard code == keyCode else { return }

        // 该物理键变化：alt 标志现在为 on=按下、off=松开。去抖：只在状态真正翻转时触发。
        let alt = event.flags.contains(.maskAlternate)
        if alt && !isDown {
            isDown = true
            MainActor.assumeIsolated { onPress?() }
        } else if !alt && isDown {
            isDown = false
            MainActor.assumeIsolated { onRelease?() }
        }
    }
}
