//
//  PunctuationRestorer.swift
//  Recorpaster
//
//  本地中文标点恢复（方案2）：turbo 对中文原生零标点 → 这里用 bert-base-chinese 标点模型
//  （CoreML int8）逐**字**预测「该字后接哪个标点」，把「，、。？！；」插回。
//   · 纯本机推理、不联网（仅首次按需下载模型）、不写盘音频；只在字后插标点、绝不增删改写原字。
//   · 词表 PunctZhVocab.txt（~110KB）随 App 内置；97MB 模型**仿 WhisperKit 运行时下载**到
//     ~/Library/Application Support/Recorpaster/，不进 bundle、不进 git。
//   · 加载顺序：已编译缓存(.mlmodelc) → 本地 .mlpackage(dev 预置)编译 → 从 HF 下载 .mlpackage 编译。
//   · 任一步失败/离线/未配置仓库 → 原样返回（降级为无标点，绝不丢字）。
//

import CoreML
import Foundation

nonisolated final class PunctuationRestorer: @unchecked Sendable {
    private static let seqLen = 256          // 模型固定序列长（转换时 trace 定死）
    private static let maxChars = 254        // 每窗最多字数（留 [CLS]/[SEP]）
    private static let labelCount = 7
    private static let punct: [Character?] = [nil, "，", "、", "。", "？", "！", "；"]

    // 运行时模型缓存位置 + 下载源。上传 PunctZh.mlpackage 到 HF 后把 modelRepo 填上即可首启自动下载。
    private static let cacheDir: URL = FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Recorpaster", isDirectory: true)
    private static var compiledURL: URL { cacheDir.appendingPathComponent("PunctZh.mlmodelc") }
    private static var packageURL: URL { cacheDir.appendingPathComponent("PunctZh.mlpackage") }
    /// TODO(分发): 上传 PunctZh.mlpackage 到 HF 后填仓库 id（如 "你的用户名/recorpaster-punct-zh"）。
    /// 留空 = 不下载、降级为无标点（dev 机可把 .mlpackage 预置到上面的 packageURL 直接用）。
    private static let modelRepo = ""
    private static let pkgFiles = [
        "Manifest.json",
        "Data/com.apple.CoreML/model.mlmodel",
        "Data/com.apple.CoreML/weights/weight.bin",
    ]

    private let clsID: Int32 = 101
    private let sepID: Int32 = 102
    private let unkID: Int32 = 100

    private let lock = NSLock()
    private var model: MLModel?
    private var vocab: [Character: Int32] = [:]

    private var isReady: Bool { lock.lock(); defer { lock.unlock() }; return model != nil }

    // MARK: - 准备（启动时 async 调用一次）

    /// 确保模型就绪：已编译缓存 → 本地 .mlpackage 编译 → HF 下载编译。失败则保持降级（无标点）。
    func prepare() async {
        if isReady { return }
        loadVocab()
        do {
            if FileManager.default.fileExists(atPath: Self.compiledURL.path) {
                try loadModel(from: Self.compiledURL); return
            }
            if FileManager.default.fileExists(atPath: Self.packageURL.path) {
                try await compileAndCache(Self.packageURL)
                try loadModel(from: Self.compiledURL); return
            }
            guard !Self.modelRepo.isEmpty else {
                Log.warn("标点模型未就绪且未配置下载仓库（PunctuationRestorer.modelRepo）→ 降级为无标点。")
                return
            }
            Log.info("首次运行：下载中文标点模型（约 97MB）…")
            try await downloadPackage(repo: Self.modelRepo)
            try await compileAndCache(Self.packageURL)
            try loadModel(from: Self.compiledURL)
        } catch {
            Log.error("标点模型准备失败（降级为无标点）: \(error)")
        }
    }

    private func loadVocab() {
        lock.lock(); let has = !vocab.isEmpty; lock.unlock()
        if has { return }
        guard let url = Bundle.main.url(forResource: "PunctZhVocab", withExtension: "txt"),
              let raw = try? String(contentsOf: url, encoding: .utf8) else {
            Log.warn("标点词表 PunctZhVocab.txt 缺失。"); return
        }
        // 只按 "\n" 切分对齐训练 vocab 行号：enumerateLines 会在 U+000C/U+0085/U+2028 等处误断行，
        // 而 bert 词表早期有这类控制字符作单 token，会让其后所有字 id 整体 +1、模型输入错位。
        var map: [Character: Int32] = [:]
        var id: Int32 = 0
        for sub in raw.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = sub.hasSuffix("\r") ? sub.dropLast() : sub
            if line.count == 1, let c = line.first { map[c] = id }
            id += 1
        }
        lock.lock(); vocab = map; lock.unlock()
    }

    private func loadModel(from url: URL) throws {
        let cfg = MLModelConfiguration()
        cfg.computeUnits = .all
        let m = try MLModel(contentsOf: url, configuration: cfg)
        lock.lock(); model = m; lock.unlock()
        Log.ok("标点模型已加载（\(url.lastPathComponent)，单字 token \(vocab.count) 个）。")
    }

    private func compileAndCache(_ pkg: URL) async throws {
        let compiled = try await MLModel.compileModel(at: pkg)
        try FileManager.default.createDirectory(at: Self.cacheDir, withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: Self.compiledURL)
        try FileManager.default.moveItem(at: compiled, to: Self.compiledURL)
    }

    private func downloadPackage(repo: String) async throws {
        for rel in Self.pkgFiles {
            guard let src = URL(string: "https://huggingface.co/\(repo)/resolve/main/PunctZh.mlpackage/\(rel)") else { continue }
            let (tmp, resp) = try await URLSession.shared.download(from: src)
            guard (resp as? HTTPURLResponse)?.statusCode == 200 else {
                throw NSError(domain: "Recorpaster.Punct", code: -1,
                              userInfo: [NSLocalizedDescriptionKey: "下载失败 \(rel)：HTTP \((resp as? HTTPURLResponse)?.statusCode ?? -1)"])
            }
            let dst = Self.packageURL.appendingPathComponent(rel)
            try FileManager.default.createDirectory(at: dst.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? FileManager.default.removeItem(at: dst)
            try FileManager.default.moveItem(at: tmp, to: dst)
        }
    }

    // MARK: - 推理（同步，由 TextOutput 串行队列调用；未就绪则原样返回）

    func restore(_ text: String) -> String {
        lock.lock(); let m = model; let v = vocab; lock.unlock()
        guard let m, !v.isEmpty, !text.isEmpty else { return text }
        let chars = Array(text)
        var out = ""
        var i = 0
        while i < chars.count {
            let end = min(i + Self.maxChars, chars.count)
            out += restoreWindow(Array(chars[i..<end]), model: m, vocab: v)
            i = end
        }
        return out
    }

    private func restoreWindow(_ chars: [Character], model: MLModel, vocab: [Character: Int32]) -> String {
        let n = chars.count
        guard n > 0, n <= Self.maxChars else { return String(chars) }
        let shape = [1, NSNumber(value: Self.seqLen)]
        guard let ids = try? MLMultiArray(shape: shape, dataType: .int32),
              let mask = try? MLMultiArray(shape: shape, dataType: .int32),
              let types = try? MLMultiArray(shape: shape, dataType: .int32) else {
            return String(chars)
        }
        let zero = NSNumber(value: 0), one = NSNumber(value: 1)
        for k in 0..<Self.seqLen { ids[k] = zero; mask[k] = zero; types[k] = zero }   // pad=0
        ids[0] = NSNumber(value: clsID); mask[0] = one                                // [CLS]
        for (k, c) in chars.enumerated() {
            ids[k + 1] = NSNumber(value: vocab[c] ?? unkID)
            mask[k + 1] = one
        }
        ids[n + 1] = NSNumber(value: sepID); mask[n + 1] = one                        // [SEP]

        guard let input = try? MLDictionaryFeatureProvider(dictionary: [
            "input_ids": ids, "attention_mask": mask, "token_type_ids": types,
        ]),
        let pred = try? model.prediction(from: input) else { return String(chars) }

        let outName = pred.featureNames.contains("logits") ? "logits" : (pred.featureNames.first ?? "logits")
        guard let logits = pred.featureValue(for: outName)?.multiArrayValue else { return String(chars) }

        // logits 连续存储 [1, seq, 7]：位置 pos、标签 l 的线性下标 = pos*7 + l。pos 比字 index 多 1（[CLS]）。
        var result = ""
        for (k, c) in chars.enumerated() {
            result.append(c)
            let base = (k + 1) * Self.labelCount
            var best = 0
            var bestV = logits[base].floatValue
            for l in 1..<Self.labelCount {
                let v = logits[base + l].floatValue
                if v > bestV { bestV = v; best = l }
            }
            if let p = Self.punct[best] { result.append(p) }
        }
        return result
    }
}
