//
//  AppController.swift
//  Recorpaster
//
//  总控：会话状态机 + 各组件接线（对应 Python 版 app.py 的 App）。
//
//  核心设计（移植自 Python，避开同样的坑）：
//   · 状态机 idle → active → stopping → idle，stopping 期间又按下用 pendingBegin 无缝重开（坑：幻影会话）。
//   · 浮窗「可见性」与引擎「收尾」彻底解耦：松开即淡出；引擎 flush/stop/排空尾句在后台 await，
//     尾句识别好了照常上屏（坑 #4 + #8）。
//   · 权限只引导一次（坑 #2）：启动各弹一次；之后看门狗只无弹窗轮询，授权后自动启用热键 tap。
//   · 麦克风懒授权：首次 idle 按下若未决定 → 触发一次系统弹窗并提示重试，绝不在异步里抢状态。
//   · 采集失败显式反馈到浮窗（不静默吞）。
//

import AppKit
import AVFoundation

@MainActor
final class AppController {
    private enum SessionState { case idle, active, stopping }

    private let config = Config.default
    private let floating = FloatingPanelController()
    private let statusItem = StatusItemController()
    private let textOutput = TextOutput()
    private let hotKey: HotKeyMonitor
    private var engine: DictationEngine!

    private var state: SessionState = .idle
    private var pendingBegin = false
    private var engineReady = false
    private var hotkeyActive = false
    private var loadingShown = false
    private var toastToken = 0
    private var watchdogTask: Task<Void, Never>?

    private let firstRunKey = "didLoadModelOnce"

    init() {
        hotKey = HotKeyMonitor(keyCode: config.hotkeyKeyCode)
        engine = DictationEngine(
            config: config,
            onResult: { [weak self] r in self?.handleResult(r) },
            onStatus: { [weak self] s in self?.handleStatus(s) }
        )
    }

    // MARK: - 启动

    func start() {
        // 菜单栏动作
        statusItem.onToggle = { [weak self] in self?.toggleSession() }
        statusItem.onQuit = { [weak self] in self?.quit() }

        // 热键回调
        hotKey.onPress = { [weak self] in self?.handlePress() }
        hotKey.onRelease = { [weak self] in self?.handleRelease() }

        // 权限：各引导一次（之后看门狗只轮询，不再弹）
        Permissions.promptAccessibilityOnce()
        Permissions.requestInputMonitoringOnce()

        // 打印三项权限状态，便于排查热键不触发。
        let ax = Permissions.accessibilityTrusted()
        let im = Permissions.inputMonitoringGranted()
        let mic = Permissions.microphoneStatus().rawValue
        Log.info("权限状态: 辅助功能=\(ax) 输入监控=\(im) 麦克风(rawValue)=\(mic)")

        // 启动全局热键 tap（缺权限会失败，看门狗会择机重试）
        hotkeyActive = hotKey.start()
        if !hotkeyActive {
            Log.warn("热键 tap 启动失败：右⌥ 热键需要『辅助功能 + 输入监控』权限（菜单手动开/停不受影响）。")
            // 主动提示：缺权限的话热键用不了，引导去授权。
            Task {
                try? await Task.sleep(for: .seconds(1))
                if !self.hotkeyActive {
                    self.toast("右⌥ 热键需在『系统设置 · 隐私 · 辅助功能 + 输入监控』里勾选 Recorpaster（见菜单）", seconds: 5)
                }
            }
        }

        // 首次加载提示 + 加载模型
        let firstRun = !UserDefaults.standard.bool(forKey: firstRunKey)
        showLoading(firstRun ? "首次运行 · 下载模型中…（约 1.5GB，请保持联网）" : "加载模型中…")
        Task { await engine.loadModel() }

        startPermissionWatchdog()
        refreshIdleIcon()
    }

    // MARK: - 热键

    private func handlePress() {
        switch config.hotkeyMode {
        case .hold:   beginSession()
        case .toggle: toggleSession()
        }
    }

    private func handleRelease() {
        if config.hotkeyMode == .hold { endSession() }
    }

    // MARK: - 会话状态机

    private func beginSession() {
        guard engineReady else { toast("模型还在加载，请稍候…"); return }

        switch state {
        case .active:
            floating.setVisible(true)   // 已在听，确保可见
            return
        case .stopping:
            pendingBegin = true         // 上一段还在收尾，停完再开
            return
        case .idle:
            break
        }

        // 麦克风懒授权（只弹一次；未决定就请求并提示重试，不在此次开会话）
        switch Permissions.microphoneStatus() {
        case .authorized:
            break
        case .notDetermined:
            Task { _ = await Permissions.requestMicrophone(); refreshIdleIcon() }
            toast("请在弹窗中允许麦克风后，再长按右 ⌥ 说话")
            return
        case .denied, .restricted:
            statusItem.setPermissionWarning(true)
            toast("麦克风权限被拒，请在菜单·系统设置里开启")
            return
        @unknown default:
            return
        }

        do {
            try engine.start()
            state = .active
            floating.model.text = ""
            floating.model.statusLine = "聆听中…"
            floating.model.isListening = true
            floating.setVisible(true)
            statusItem.setState(.listening, tooltip: "听写中…")
        } catch {
            // 采集失败显式反馈（不静默吞），并明确不进入 active。
            Log.error("启动采集失败: \(error.localizedDescription)")
            floating.model.isListening = false
            statusItem.setState(.warn, tooltip: "采集启动失败")
            toast("采集启动失败：\(error.localizedDescription)", seconds: 4)
        }
    }

    private func endSession() {
        // 松开：浮窗立即淡出（与引擎收尾解耦），无论引擎处于什么状态。
        floating.model.isListening = false
        floating.setVisible(false)

        switch state {
        case .stopping:
            // 收尾中又松开：取消「停完重开」，别让幻影会话复活。
            pendingBegin = false
            resetIconForStoppingCancel()
            return
        case .idle:
            return
        case .active:
            state = .stopping
            resetIconForStoppingCancel()
        }

        // 后台优雅收尾（flush + 排空尾句，坑 #4），完成后处理 pendingBegin。
        Task {
            await engine.stop()
            state = .idle
            let restart = pendingBegin
            pendingBegin = false
            if restart {
                beginSession()
            } else {
                refreshIdleIcon()
            }
        }
    }

    private func toggleSession() {
        switch state {
        case .stopping:
            pendingBegin.toggle()
            if pendingBegin {
                floating.model.statusLine = "聆听中…"
                floating.model.isListening = true
                floating.setVisible(true)
                statusItem.setState(.listening, tooltip: "听写中…")
            } else {
                floating.model.isListening = false
                floating.setVisible(false)
                resetIconForStoppingCancel()
            }
        case .active:
            endSession()
        case .idle:
            beginSession()
        }
    }

    // MARK: - 引擎回调

    private func handleResult(_ r: DictationResult) {
        Log.info("📝 \(r.text)  (音频 \(String(format: "%.1f", r.audioSec))s · 识别 \(String(format: "%.2f", r.costSec))s · RTF \(String(format: "%.2f", r.rtf)))")
        floating.model.text = r.text                 // 实时展示最新一句
        textOutput.enqueue(r.text, mode: config.outputMode)   // 上屏 / 复制（已含标点规整）
    }

    private func handleStatus(_ s: EngineStatus) {
        switch s {
        case .loadingModel:
            statusItem.setState(.loading, tooltip: "加载模型中…")
        case .ready:
            engineReady = true
            UserDefaults.standard.set(true, forKey: firstRunKey)
            hideLoadingIfShown()
            refreshIdleIcon()
        case .listening:
            break   // 由 beginSession 统一处理 UI
        case .modelError(let msg):
            engineReady = false
            statusItem.setState(.warn, tooltip: msg)
            floating.model.statusLine = msg
            floating.model.text = ""
            floating.setVisible(true)
            loadingShown = true
        }
    }

    // MARK: - 浮窗提示

    private func showLoading(_ msg: String) {
        floating.model.statusLine = msg
        floating.model.text = ""
        floating.model.isListening = false
        floating.setVisible(true)
        loadingShown = true
    }

    private func hideLoadingIfShown() {
        guard loadingShown else { return }
        loadingShown = false
        floating.setVisible(false)
    }

    /// 临时提示一句，到点自动淡出（被新会话/新提示取代则不隐藏）。
    private func toast(_ msg: String, seconds: Double = 2.0) {
        loadingShown = false   // toast 接管浮窗，不再视为常驻加载提示
        floating.model.statusLine = ""
        floating.model.isListening = false
        floating.model.text = msg
        floating.setVisible(true)
        toastToken += 1
        let token = toastToken
        Task {
            try? await Task.sleep(for: .seconds(seconds))
            // 仅当未被新 toast 取代、当前空闲、且没有常驻加载/错误提示接管时才隐藏。
            if token == toastToken && state == .idle && !loadingShown {
                floating.setVisible(false)
            }
        }
    }

    // MARK: - 权限看门狗 + 图标

    private func startPermissionWatchdog() {
        watchdogTask = Task { [weak self] in
            while !Task.isCancelled {
                self?.tickPermissions()
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    private func tickPermissions() {
        let ax = Permissions.accessibilityTrusted()
        let im = Permissions.inputMonitoringGranted()   // IOHIDCheckAccess：纯查询，不弹窗，可安心轮询
        // 只有辅助功能 + 输入监控都已授予才尝试建 tap：CGEvent.tapCreate 监听键盘实际需要输入监控，
        // 缺权限时它会触发输入监控 TCC 弹窗；若每 2s 无条件重试就会反复弹窗（坑 #2）。
        if !hotkeyActive && ax && im {
            hotkeyActive = hotKey.start()
            if hotkeyActive { Log.ok("已获辅助功能 + 输入监控权限，热键监听已启用。") }
        }
        let micDenied = Permissions.microphoneStatus() == .denied
        let needWarn = !ax || !im || !hotkeyActive || micDenied
        statusItem.setPermissionWarning(needWarn)
        refreshIdleIcon()
    }

    /// 收尾期间（state==.stopping）取消重开时复位图标——不能用 refreshIdleIcon（它只在 idle 生效，
    /// 否则图标会卡在 mic.fill「聆听中」直到后台 stop() 完成）。
    private func resetIconForStoppingCancel() {
        if !engineReady {
            statusItem.setState(.loading, tooltip: "加载模型中…")
        } else if !Permissions.hotkeyAndPasteReady || !hotkeyActive {
            statusItem.setState(.warn, tooltip: "缺少辅助功能/输入监控权限 · 见菜单")
        } else {
            statusItem.setState(.loading, tooltip: "收尾中…")   // 引擎仍在排空尾句
        }
    }

    /// 仅在 idle 态刷新菜单栏图标（不打断 listening/stopping 的显示）。
    private func refreshIdleIcon() {
        guard state == .idle else { return }
        if !engineReady {
            statusItem.setState(.loading, tooltip: "加载模型中…")
        } else if !Permissions.hotkeyAndPasteReady || !hotkeyActive {
            statusItem.setState(.warn, tooltip: "缺少辅助功能/输入监控权限 · 见菜单")
        } else {
            statusItem.setState(.idle, tooltip: "听写就绪 · 长按右 ⌥ 说话")
        }
    }

    // MARK: - 退出

    private func quit() {
        Log.info("正在退出…")
        watchdogTask?.cancel()
        hotKey.stop()
        Task {
            await engine.stop()
            NSApp.terminate(nil)
        }
        // 兜底：即便引擎收尾卡住也别让退出无响应。
        Task {
            try? await Task.sleep(for: .seconds(2))
            NSApp.terminate(nil)
        }
    }
}
