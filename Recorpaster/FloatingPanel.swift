//
//  FloatingPanel.swift
//  Recorpaster
//
//  非激活悬浮窗（坑 #1：绝不抢焦点）。
//   · NSPanel + .nonactivatingPanel；canBecomeKey/Main 恒 false → 永远成不了 key window。
//   · 显示用 orderFrontRegardless()（绝不 makeKeyAndOrderFront / activate），App 又是 .accessory，
//     于是弹窗不夺取目标输入框焦点，⌘V 落到原 App。
//   · ignoresMouseEvents = true：纯展示、点击穿透。
//   · 显隐淡入淡出 + epoch 取消（坑 #8）：淡出后的 orderOut 仅在期间未被新「显示」覆盖时才执行。
//   · 多屏（坑 #10）：每次显示按鼠标所在屏底部居中重算位置。
//

import AppKit
import SwiftUI

/// 永远成不了 key/main 的非激活面板。
final class FloatingPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class FloatingPanelController {
    let model = FloatingModel()
    private let panel: FloatingPanel
    // 画布比胶囊大：容纳呼吸缩放、柔光、阴影、底部留白（胶囊在其内底部居中）。
    private let size = NSSize(width: 640, height: 150)
    private var epoch = 0

    init() {
        panel = FloatingPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.hidesOnDeactivate = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.ignoresMouseEvents = true          // 纯展示、点击穿透
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.alphaValue = 0

        let host = NSHostingView(rootView: FloatingView(model: model))
        host.frame = NSRect(origin: .zero, size: size)
        host.wantsLayer = true
        host.layer?.backgroundColor = NSColor.clear.cgColor
        panel.contentView = host
    }

    /// 切到目标可见态（幂等 + 可取消）。
    func setVisible(_ visible: Bool) {
        epoch += 1
        let e = epoch
        if visible {
            positionOnActiveScreen()
            panel.orderFrontRegardless()         // 关键：不激活本 App、不抢焦点
            model.presented = true               // 触发 SwiftUI 弹簧放大 + 淡入
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.16
                panel.animator().alphaValue = 1
            }
        } else {
            model.presented = false              // 触发 SwiftUI 缩小淡出
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.30              // 比弹簧缩小略长，让缩小动画读得出来
                panel.animator().alphaValue = 0
            }, completionHandler: { [weak self] in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    // epoch 复检：淡出途中若又有「显示」（epoch 自增），放弃这次隐藏，避免卡住隐藏态。
                    if self.epoch == e { self.panel.orderOut(nil) }
                }
            })
        }
    }

    private func positionOnActiveScreen() {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) }
            ?? NSScreen.main
        guard let visible = screen?.visibleFrame else { return }
        let x = visible.midX - size.width / 2
        let y = visible.minY + 8                 // 胶囊由 SwiftUI 底部留白抬到距屏底 ~38pt
        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }
}
