//
//  FloatingView.swift
//  Recorpaster
//
//  聆听条（重设计）：macOS 26 原生液态玻璃 Clear 胶囊 + 呼吸 + 随麦克风 RMS 律动的脉冲球
//  + 文字逐字 spring pop。视图无背景窗，玻璃透出桌面；绝不抢焦点由 FloatingPanel 保证。
//

import SwiftUI
import Combine

@MainActor
final class FloatingModel: ObservableObject {
    @Published var statusLine: String = ""    // “聆听中…” / “下载模型中…” 等
    @Published var text: String = ""          // 识别文本（逐字 pop 显示）
    @Published var isListening: Bool = false
    @Published var level: Float = 0           // 采集回调喂入的瞬时 RMS（律动用）
    @Published var presented: Bool = false    // 出现/消失：弹簧放大+淡入 / 缩小+淡出
}

struct FloatingView: View {
    @ObservedObject var model: FloatingModel
    var previewStatic = false                  // ImageRenderer 静态渲染（调样式用）
    var accent: Color = .accentColor           // 单一可覆盖配色（Phase 2 设置接入）

    private var hasText: Bool { !model.text.isEmpty }
    private var showStatus: Bool { !model.statusLine.isEmpty && !hasText }
    private var shown: Bool { previewStatic || model.presented }
    // 已被引擎包络平滑的 RMS → 0..1 感知强度（安静≈0，正常说话≈0.4-0.9）。
    private var intensity: CGFloat {
        guard model.isListening else { return 0 }
        return min(1, CGFloat((max(0, model.level) * 9).squareRoot()))
    }

    var body: some View {
        // TimelineView 驱动 60fps 连续呼吸；呼吸幅度 + 脉冲随 RMS 联动。静态/非聆听时暂停（省电、不动）。
        TimelineView(.animation(paused: previewStatic || !model.isListening)) { tl in
            let phase = CGFloat(0.5 + 0.5 * sin(tl.date.timeIntervalSinceReferenceDate * (.pi * 2 / 2.6)))
            let amp = 0.012 + 0.05 * intensity                       // 呼吸幅度：安静基线，越大声越大
            let breath = model.isListening ? 1.0 + amp * phase : 1.0
            let shadowOpacity = 0.24 + (model.isListening ? 0.10 * Double(phase) : 0)
            VStack {
                Spacer(minLength: 0)
                capsule(phase: phase)
                    .scaleEffect(breath, anchor: .center)
                    // 干净单药丸的柔和对称悬浮投影：透明度随呼吸均匀起伏，无描边、无第二层。
                    .shadow(color: .black.opacity(shadowOpacity), radius: 16, y: 8)
                    // 出现/消失：弹簧放大 + 从底部淡入 / 缩小淡出
                    .scaleEffect(shown ? 1.0 : 0.84, anchor: .bottom)
                    .offset(y: shown ? 0 : 18)
                    .opacity(shown ? 1 : 0)
                    .animation(.spring(response: 0.40, dampingFraction: 0.72), value: model.presented)
                    .padding(.bottom, 30)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func capsule(phase: CGFloat) -> some View {
        HStack(spacing: 12) {
            PulseOrb(intensity: intensity, idle: phase, listening: model.isListening, color: accent)
                .frame(width: 22, height: 22)

            if showStatus {
                Text(model.statusLine)
                    .font(.system(size: 14, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)
                    .transition(.opacity)
            } else if hasText {
                PopText(text: model.text, staticFull: previewStatic)
            } else {
                Text("聆听中…")
                    .font(.system(size: 14, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)
                    .transition(.opacity)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 13)
        .frame(minWidth: 96)
        .glassCapsule(preview: previewStatic)   // 唯一形状：干净玻璃药丸（无外圈/描边/第二背景）
        .animation(.spring(response: 0.42, dampingFraction: 0.78), value: hasText)
        .animation(.spring(response: 0.42, dampingFraction: 0.78), value: showStatus)
    }
}

// MARK: - 液态玻璃胶囊（macOS 26 .glassEffect；不可用时退回材质）

private extension View {
    @ViewBuilder
    func glassCapsule(preview: Bool = false) -> some View {
        if preview {
            // ImageRenderer 无法渲染 .glassEffect（会丢内容），离屏预览退回材质以看构图。
            self.background(.ultraThinMaterial, in: Capsule())
        } else if #available(macOS 26.0, *) {
            self.glassEffect(.clear, in: Capsule())
        } else {
            self.background(.ultraThinMaterial, in: Capsule())
        }
    }
}

// MARK: - RMS 律动脉冲球（呼吸基线 + 随音量脉冲）

struct PulseOrb: View {
    let intensity: CGFloat      // 0..1 已平滑的音量强度（律动主驱动）
    let idle: CGFloat           // 0..1 呼吸相位（安静时的基线脉动；来自父 TimelineView）
    let listening: Bool
    var color: Color = .accentColor

    var body: some View {
        let base = listening ? 0.05 * idle : 0      // 安静时也有轻微基线呼吸
        let p = intensity                            // 越大声脉冲越强
        ZStack {
            // 外圈脉冲：随音量扩张 + 变亮
            Circle()
                .fill(color.opacity(0.16 + 0.34 * p))
                .scaleEffect(0.68 + 0.95 * p + base)
                .blur(radius: 1.5)
            // 实心核心：随音量轻微胀大 + 发光
            Circle()
                .fill(color)
                .scaleEffect(0.40 + 0.18 * p + base)
                .shadow(color: color.opacity(0.6), radius: 3 + 6 * p)
        }
        .opacity(listening ? 1 : 0.5)
    }
}

// MARK: - 逐字 spring pop 文本

struct PopText: View {
    let text: String
    var staticFull = false                     // 静态渲染（ImageRenderer 截图）时一次全显
    private static let maxVisible = 28          // 条上只显示尾部最近 N 字（全文仍照常粘贴）
    // 用**绝对字索引**记录已 pop 到哪：流式增长时新尾字始终会 pop（即便滑窗已满），
    // 已显示的字不重 pop，靠后修订只换字不跳（id 按位置稳定）。
    @State private var revealedUpTo: Int
    @State private var task: Task<Void, Never>?

    init(text: String, staticFull: Bool = false) {
        self.text = text
        self.staticFull = staticFull
        _revealedUpTo = State(initialValue: staticFull ? Int.max : 0)
    }

    var body: some View {
        let all = Array(text)
        let start = max(0, all.count - Self.maxVisible)
        let visible = (start..<all.count).map { (i: $0, ch: all[$0]) }   // 尾部窗口 + 绝对索引
        HStack(spacing: 1) {
            ForEach(visible, id: \.i) { item in
                Text(String(item.ch))
                    .opacity(item.i < revealedUpTo ? 1 : 0)
                    .scaleEffect(item.i < revealedUpTo ? 1 : 0.85, anchor: .bottom)
                    .offset(y: item.i < revealedUpTo ? 0 : 5)
            }
        }
        .font(.system(size: 16, weight: .semibold, design: .rounded))
        .foregroundStyle(.primary)
        .fixedSize()                            // 自然宽度，胶囊随文字撑开
        .onAppear { reveal(to: all.count) }
        .onChange(of: text) { _, _ in reveal(to: Array(text).count) }
    }

    private func reveal(to total: Int) {
        if revealedUpTo > total { revealedUpTo = total }   // 文本变短（修订/重置）→ 收回
        guard !staticFull, revealedUpTo < total else { return }
        task?.cancel()
        task = Task { @MainActor in
            while revealedUpTo < total {
                try? await Task.sleep(for: .milliseconds(28))
                if Task.isCancelled { return }
                withAnimation(.spring(response: 0.34, dampingFraction: 0.60)) { revealedUpTo += 1 }
            }
        }
    }
}
