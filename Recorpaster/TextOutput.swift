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
    private let restorer = PunctuationRestorer()

    /// 后台准备标点模型（按需下载 + 编译 + 加载），避免首句上屏时才加载导致卡顿；失败则降级无标点。
    func preloadPunctuation() {
        Task.detached { [restorer] in await restorer.prepare() }
    }

    /// 入队一段文本，按 mode 上屏或复制。标点恢复 + 规整都在串行队列（off-main、按入队有序）。
    /// punctuate=false（设置关标点 / 语言=英文）则跳过 BERT 后处理、输出原始文本。
    func enqueue(_ raw: String, mode: OutputMode, punctuate: Bool = true) {
        guard !raw.isEmpty else { return }
        queue.async { [weak self] in
            guard let self else { return }
            let processed = punctuate ? self.restorer.restore(raw) : raw   // 补中文标点 / 输出原始
            let text = normalizeCJKPunct(processed)       // 把残留 ASCII 标点在 CJK 间转全角（不增删字）
            guard !text.isEmpty else { return }
            // (d) 粘贴/复制前把最终文字打出来。
            Log.info("(d) 即将\(mode == .paste ? "上屏" : "复制"): \"\(text)\"")
            switch mode {
            case .copy:  _ = Self.setClipboard(text)
            case .paste: self.paste(text)
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
        // 等粘贴动作被目标 App 真正消费再还原；0.25s 比 0.18s 更稳地避开「还没粘完就塞回旧值」。
        Thread.sleep(forTimeInterval: 0.25)
        // 仅当剪贴板自我们写入后**未被改动**、且旧值确有内容且不同于本次文本时才还原：
        //  · changeCount 变了 → 期间有人改了剪贴板 → 不还原，避免覆盖用户的复制（明确记日志，不静默）。
        //  · prev == text（罕见）→ 无需还原。
        guard let prev, prev != text else { return }
        if pb.changeCount == myCount {
            _ = Self.setClipboard(prev)
        } else {
            Log.info("剪贴板期间被改动（changeCount \(myCount)→\(pb.changeCount)），跳过还原以免覆盖用户复制。")
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
    /// 关键：用 `.privateState` 事件源——它的修饰键状态**独立于硬件/会话**，故即便用户此刻正物理按住
    /// 右 ⌥（hold 模式触发键），合成事件也只带 .maskCommand，不会被并成 ⌘⌥V。
    private static func postCommandV() {
        let src = CGEventSource(stateID: .privateState)
        let vKey: CGKeyCode = 9
        let down = CGEvent(keyboardEventSource: src, virtualKey: vKey, keyDown: true)
        down?.flags = .maskCommand
        let up = CGEvent(keyboardEventSource: src, virtualKey: vKey, keyDown: false)
        up?.flags = []          // 抬起时清空修饰键，避免残留 Command 影响后续输入
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
    }
}
