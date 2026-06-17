//
//  TextOutput.swift
//  Recorpaster
//
//  上屏 / 复制 + 中文标点规整。对应 Python 版 app.py 的 _paste / _output_worker /
//  normalize_cjk_punct。两个重点：
//   · 坑 #3 中文标点：normalizeCJKPunct 仅当 ASCII 标点“两侧都是 CJK 汉字”时转全角。
//   · 上屏用剪贴板 + ⌘V（对中文最稳），用完**有条件地**还原用户原本的剪贴板。
//
//  注意：投递 ⌘V 到其它 App 需要「辅助功能」权限（见 Permissions）。
//

import AppKit
import CoreGraphics

// MARK: - 中文标点规整（纯函数，可单测）

/// 仅当 ASCII 标点**两侧都是 CJK 汉字**时转成全角；不动英文/数字/小数点（3,000 / v1.2 / OK,我）。
/// 等价于 Python 的 `(?<=[一-鿿㐀-䶿])([,.!?;:])(?=[一-鿿㐀-䶿])` 替换。
func normalizeCJKPunct(_ text: String) -> String {
    let map: [Character: Character] = [
        ",": "，", ".": "。", "!": "！", "?": "？", ";": "；", ":": "：",
    ]
    let chars = Array(text)
    guard chars.count >= 3 else { return text }

    func isCJK(_ c: Character) -> Bool {
        guard let s = c.unicodeScalars.first, c.unicodeScalars.count == 1 else { return false }
        let v = s.value
        return (0x4E00...0x9FFF).contains(v) || (0x3400...0x4DBF).contains(v)
    }

    var out = chars
    for i in 1..<(chars.count - 1) {
        guard let full = map[chars[i]] else { continue }
        // 依据**原始**相邻字符判定（与正则的 lookbehind/lookahead 语义一致）。
        if isCJK(chars[i - 1]) && isCJK(chars[i + 1]) {
            out[i] = full
        }
    }
    return String(out)
}

// MARK: - 输出器（独立串行队列，绝不阻塞主线程；按入队顺序逐句上屏）

nonisolated final class TextOutput: @unchecked Sendable {
    private let queue = DispatchQueue(label: "io.sam.Recorpaster.output")

    /// 入队一段文本，按 mode 上屏或复制。先做标点规整。
    func enqueue(_ raw: String, mode: OutputMode) {
        let text = normalizeCJKPunct(raw)
        guard !text.isEmpty else { return }
        // (d) 粘贴/复制前把要输出的文字打出来（标点规整后）。
        Log.info("(d) 即将\(mode == .paste ? "上屏" : "复制"): \"\(text)\"")
        queue.async { [weak self] in
            switch mode {
            case .copy:
                _ = Self.setClipboard(text)
            case .paste:
                self?.paste(text)
            }
        }
    }

    // 剪贴板 + 模拟 ⌘V（对中文最稳）；用完**有条件地**还原剪贴板。在串行队列上执行，sleep 无碍。
    private func paste(_ text: String) {
        let pb = NSPasteboard.general
        let prev = pb.string(forType: .string)
        let myCount = Self.setClipboard(text)       // 记录我们这次写入后的 changeCount
        Thread.sleep(forTimeInterval: 0.05)         // 等剪贴板写入稳定
        Self.postCommandV()
        Thread.sleep(forTimeInterval: 0.18)         // 等粘贴动作被目标 App 消费
        // 仅当剪贴板自我们写入后**未被改动**才还原：
        //  · 若用户/其它 App 期间复制了别的东西（changeCount 变了）→ 不还原，避免覆盖用户的复制；
        //  · 也避免在目标 App 尚未消费粘贴时就把旧内容塞回去导致粘错（宁可把识别文本留在剪贴板）。
        if pb.changeCount == myCount, let prev {
            _ = Self.setClipboard(prev)
        }
    }

    @discardableResult
    private static func setClipboard(_ s: String) -> Int {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(s, forType: .string)
        return pb.changeCount
    }

    /// 用 CGEvent 投递 ⌘V（虚拟键码 9 = 'v'）。需要「辅助功能」权限才能落到其它 App。
    private static func postCommandV() {
        let src = CGEventSource(stateID: .combinedSessionState)
        let vKey: CGKeyCode = 9
        let down = CGEvent(keyboardEventSource: src, virtualKey: vKey, keyDown: true)
        down?.flags = .maskCommand
        let up = CGEvent(keyboardEventSource: src, virtualKey: vKey, keyDown: false)
        up?.flags = .maskCommand
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
    }
}
