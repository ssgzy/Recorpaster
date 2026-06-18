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

    // 呼吸（缓慢缩放 + 柔光起伏，~2.5s）
    @State private var breathe = false

    private var hasText: Bool { !model.text.isEmpty }
    private var showStatus: Bool { !model.statusLine.isEmpty && !hasText }
    private var shown: Bool { previewStatic || model.presented }

    var body: some View {
        // 底部留白：胶囊靠近屏幕底部，呼吸/柔光向上扩展。
        VStack {
            Spacer(minLength: 0)
            capsule
                .scaleEffect(breathe ? 1.03 : 1.0)
                .animation(.easeInOut(duration: 2.5).repeatForever(autoreverses: true), value: breathe)
                // 出现/消失：弹簧放大 + 从底部淡入 / 缩小淡出
                .scaleEffect(shown ? 1.0 : 0.84, anchor: .bottom)
                .offset(y: shown ? 0 : 18)
                .opacity(shown ? 1 : 0)
                .animation(.spring(response: 0.40, dampingFraction: 0.72), value: model.presented)
                .padding(.bottom, 30)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { breathe = model.isListening }
        .onChange(of: model.isListening) { _, on in breathe = on }
    }

    private var capsule: some View {
        HStack(spacing: 12) {
            PulseOrb(level: model.level, listening: model.isListening)
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
        .glassCapsule(preview: previewStatic)
        .overlay(
            Capsule().strokeBorder(
                LinearGradient(colors: [.white.opacity(0.5), .white.opacity(0.06), .white.opacity(0.18)],
                               startPoint: .top, endPoint: .bottom),
                lineWidth: 0.8)
        )
        .shadow(color: .black.opacity(0.28), radius: 16, y: 7)
        .shadow(color: (model.isListening ? Color.accentColor : .clear)
            .opacity(breathe ? 0.30 : 0.14), radius: 22, y: 0)   // 柔光呼吸
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
    let level: Float
    let listening: Bool
    @State private var breathe = false

    // RMS→强度：感知曲线 + 封顶。安静≈0，正常说话≈0.4-0.9。
    private var intensity: CGFloat {
        guard listening else { return 0 }
        return min(1, CGFloat((level * 9).squareRoot()))
    }
    private var color: Color { listening ? .accentColor : .secondary }

    var body: some View {
        ZStack {
            // 外圈脉冲：随音量扩张 + 变淡
            Circle()
                .fill(color.opacity(0.22 + 0.30 * intensity))
                .scaleEffect(0.7 + 0.9 * intensity + (breathe ? 0.06 : 0))
                .blur(radius: 1.5)
            // 实心核心：轻微随音量
            Circle()
                .fill(color)
                .scaleEffect(0.42 + 0.16 * intensity + (breathe ? 0.04 : 0))
                .shadow(color: color.opacity(0.7), radius: 4 + 6 * intensity)
        }
        .animation(.spring(response: 0.22, dampingFraction: 0.55), value: intensity)
        .onAppear { breathe = true }
        .animation(.easeInOut(duration: 2.4).repeatForever(autoreverses: true), value: breathe)
        .opacity(listening ? 1 : 0.5)
    }
}

// MARK: - 逐字 spring pop 文本

struct PopText: View {
    let text: String
    var staticFull = false                     // 静态渲染（ImageRenderer 截图）时一次全显
    private static let maxVisible = 28          // 条上只显示尾部最近 N 字（全文仍照常粘贴）
    @State private var revealed: Int
    @State private var task: Task<Void, Never>?

    init(text: String, staticFull: Bool = false) {
        self.text = text
        self.staticFull = staticFull
        let n = min(Self.maxVisible, Array(text).count)
        _revealed = State(initialValue: staticFull ? n : 0)
    }

    var body: some View {
        let chars = Array(text.suffix(Self.maxVisible))
        HStack(spacing: 1) {
            ForEach(chars.indices, id: \.self) { i in
                Text(String(chars[i]))
                    .opacity(i < revealed ? 1 : 0)
                    .scaleEffect(i < revealed ? 1 : 0.85, anchor: .bottom)
                    .offset(y: i < revealed ? 0 : 5)
            }
        }
        .font(.system(size: 16, weight: .semibold, design: .rounded))
        .foregroundStyle(.primary)
        .fixedSize()                            // 自然宽度，胶囊随文字撑开
        .onAppear { reveal(to: chars.count) }
        .onChange(of: text) { _, new in reveal(to: min(Self.maxVisible, Array(new).count)) }
    }

    private func reveal(to target: Int) {
        guard revealed < target else { return }
        task?.cancel()
        task = Task { @MainActor in
            while revealed < target {
                try? await Task.sleep(for: .milliseconds(28))
                if Task.isCancelled { return }
                withAnimation(.spring(response: 0.34, dampingFraction: 0.60)) { revealed += 1 }
            }
        }
    }
}
