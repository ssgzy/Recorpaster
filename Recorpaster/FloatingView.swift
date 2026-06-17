//
//  FloatingView.swift
//  Recorpaster
//
//  悬浮窗的 SwiftUI 内容：状态点 + 状态行 + 实时识别文本。玻璃质感用 .ultraThinMaterial（坑 #9：
//  桌面模糊来自原生材质层；macOS 26 的液态玻璃可在后续升级为 .glassEffect）。
//

import SwiftUI
import Combine

@MainActor
final class FloatingModel: ObservableObject {
    @Published var statusLine: String = ""    // “聆听中…” / “下载模型中…” 等
    @Published var text: String = ""          // 实时识别文本
    @Published var isListening: Bool = false
}

struct FloatingView: View {
    @ObservedObject var model: FloatingModel

    var body: some View {
        HStack(spacing: 12) {
            Circle()
                .fill(model.isListening ? Color.red : Color.secondary)
                .frame(width: 10, height: 10)
                .shadow(color: model.isListening ? .red.opacity(0.6) : .clear, radius: 4)

            VStack(alignment: .leading, spacing: 2) {
                if !model.statusLine.isEmpty {
                    Text(model.statusLine)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text(model.text.isEmpty ? "聆听中…" : model.text)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                    .truncationMode(.head)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .frame(width: 480, height: 64, alignment: .leading)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(.white.opacity(0.14), lineWidth: 1)
        )
    }
}
