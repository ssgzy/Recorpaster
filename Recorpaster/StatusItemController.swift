//
//  StatusItemController.swift
//  Recorpaster
//
//  菜单栏托盘（对应 Python 版 NSStatusItem）。
//   · 坑 #11：用 template SF Symbol，随系统明暗自适应。idle=mic / listening=mic.fill /
//     loading=旋转箭头 / warn=警告三角。
//   · 坑 #5：statusItem 与菜单项都用属性强引用，避免被释放后点击失效。
//   · 缺权限时显示「打开系统设置 · 辅助功能 / 输入监控」入口，引导用户手动开（不弹窗轰炸）。
//

import AppKit

@MainActor
final class StatusItemController: NSObject {
    enum State { case loading, idle, listening, warn }

    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let menu = NSMenu()

    private let toggleItem = NSMenuItem(title: "开始 / 停止听写", action: nil, keyEquivalent: "")
    private let settingsItem = NSMenuItem(title: "设置…（Phase 2）", action: nil, keyEquivalent: "")
    private let axItem = NSMenuItem(title: "打开系统设置 · 辅助功能", action: nil, keyEquivalent: "")
    private let imItem = NSMenuItem(title: "打开系统设置 · 输入监控", action: nil, keyEquivalent: "")
    private let micItem = NSMenuItem(title: "打开系统设置 · 麦克风", action: nil, keyEquivalent: "")
    private let permSeparator = NSMenuItem.separator()
    private let quitItem = NSMenuItem(title: "退出 Recorpaster", action: nil, keyEquivalent: "q")

    var onToggle: (@MainActor () -> Void)?
    var onQuit: (@MainActor () -> Void)?

    override init() {
        super.init()
        buildMenu()
        setState(.loading, tooltip: "加载模型中…")
    }

    private func buildMenu() {
        toggleItem.target = self; toggleItem.action = #selector(toggleAction)
        settingsItem.isEnabled = false
        axItem.target = self;  axItem.action = #selector(openAX)
        imItem.target = self;  imItem.action = #selector(openIM)
        micItem.target = self; micItem.action = #selector(openMic)
        quitItem.target = self; quitItem.action = #selector(quitAction)

        menu.addItem(toggleItem)
        menu.addItem(settingsItem)
        menu.addItem(permSeparator)
        menu.addItem(axItem)
        menu.addItem(imItem)
        menu.addItem(micItem)
        menu.addItem(.separator())
        menu.addItem(quitItem)
        statusItem.menu = menu
        setPermissionWarning(false)
    }

    func setState(_ state: State, tooltip: String) {
        let symbol: String
        switch state {
        case .loading:   symbol = "arrow.triangle.2.circlepath"
        case .idle:      symbol = "mic"
        case .listening: symbol = "mic.fill"
        case .warn:      symbol = "exclamationmark.triangle.fill"
        }
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: tooltip)
        image?.isTemplate = true
        statusItem.button?.image = image
        statusItem.button?.toolTip = tooltip
    }

    /// 显示/隐藏「打开系统设置」引导项（缺权限时显示）。
    func setPermissionWarning(_ show: Bool) {
        permSeparator.isHidden = !show
        axItem.isHidden = !show
        imItem.isHidden = !show
        micItem.isHidden = !show
    }

    // MARK: - 菜单动作
    @objc private func toggleAction() { onToggle?() }
    @objc private func quitAction()   { onQuit?() }
    @objc private func openAX()  { Permissions.openSystemSettings(.accessibility) }
    @objc private func openIM()  { Permissions.openSystemSettings(.inputMonitoring) }
    @objc private func openMic() { Permissions.openSystemSettings(.microphone) }
}
