//
//  DictationEngine.swift
//  Recorpaster
//
//  听写引擎（UI 无关）。对接口与 Python engine.py 对齐：start / stop + onResult / onStatus。
//
//  ⚙️ 当前为 MVP「停止即整段转写」：会话期间只累积 16kHz 音频；停止时把**整段** buffer 一次性交给
//  WhisperKit.transcribe，拿结果输出。先保证「有字」，VAD 边说边出留到下一步再加（EnergyVAD.swift 已就绪）。
//
//   · 采集：自管 AVAudioEngine（MicCapture）→ 16kHz mono Float32 增量，hop 主线程追加进 sessionSamples。
//   · 收尾（坑 #4 尾句）：stop() 先 sleep ~0.3s（采纳闸门仍开）→ 停 tap → 排空主队列 → recording=false →
//     整段转写。整段转写天然包含尾句。
//   · 全链路日志：(a) 喂给 transcribe 多少样本 (b) 何时调 transcribe (c) transcribe 返回什么/报错。
//   · 隐私：全程内存 [Float]，绝不写音频文件。
//

import Foundation
import WhisperKit

/// 一句识别结果（对应 engine.py 的 Result）。
struct DictationResult: Sendable {
    let text: String
    let audioSec: Double
    let costSec: Double
    var rtf: Double { audioSec > 0 ? costSec / audioSec : 0 }
}

/// 引擎对外状态。
enum EngineStatus: Sendable {
    case loadingModel
    case ready
    case listening
    case modelError(String)
}

@MainActor
final class DictationEngine {
    private let config: Config
    private let onResult: @MainActor (DictationResult) -> Void
    private let onStatus: @MainActor (EngineStatus) -> Void

    private var whisperKit: WhisperKit?
    private(set) var isReady = false

    private let mic = MicCapture()
    private var promptTokens: [Int] = []

    // 电平表：每秒打印 buffer 数 + RMS，确认确实有声音进来（采集自测用）。
    private var meterCount = 0
    private var meterSum: Float = 0
    private var meterStart = Date()

    private var sessionSamples: [Float] = []   // 本次会话累积的 16kHz 单声道音频（内存）
    private var recording = false
    private var stopping = false               // 防止 stop() 重入（endSession 与 quit 可能并发）

    init(config: Config,
         onResult: @escaping @MainActor (DictationResult) -> Void,
         onStatus: @escaping @MainActor (EngineStatus) -> Void) {
        self.config = config
        self.onResult = onResult
        self.onStatus = onStatus
    }

    // MARK: - 模型加载（启动时一次）

    func loadModel() async {
        onStatus(.loadingModel)
        do {
            let wkConfig = WhisperKitConfig(
                model: config.model,
                verbose: false,
                logLevel: .error,
                prewarm: false,
                load: true,
                download: true
            )
            let wk = try await WhisperKit(wkConfig)
            self.whisperKit = wk

            if !config.initialPrompt.isEmpty, let tok = wk.tokenizer {
                let begin = tok.specialTokens.specialTokenBegin
                promptTokens = tok.encode(text: " " + config.initialPrompt).filter { $0 < begin }
                Log.info("标点风格 prompt tokens=\(promptTokens.count) 个")
            }
            isReady = true
            onStatus(.ready)
            Log.ok("引擎就绪（模型=\(config.model)）。")
        } catch {
            Log.error("引擎加载失败: \(error)")
            onStatus(.modelError(Self.friendlyError(error)))
        }
    }

    private static func friendlyError(_ e: Error) -> String {
        let s = "\(e)".lowercased()
        let netKeys = ["network", "connection", "timed out", "timeout", "offline",
                       "could not connect", "internet", "host", "resolve", "ssl"]
        if netKeys.contains(where: { s.contains($0) }) {
            return "模型下载失败，请检查网络后重启"
        }
        return "模型加载失败，详见日志"
    }

    // MARK: - 会话开关

    func start() throws {
        guard isReady, !recording else { return }
        sessionSamples.removeAll(keepingCapacity: true)
        meterCount = 0
        meterSum = 0
        meterStart = Date()

        recording = true   // 先开闸门，避免开头几帧被守卫丢；失败回滚
        do {
            try mic.start { [weak self] delta in
                DispatchQueue.main.async {
                    guard let self, self.recording else { return }
                    self.sessionSamples.append(contentsOf: delta)
                    self.meter(delta)
                }
            }
        } catch {
            recording = false
            throw error
        }
        onStatus(.listening)
        Log.info("会话开始（采集中）。")
    }

    private func meter(_ delta: [Float]) {
        meterCount += 1
        if !delta.isEmpty {
            var s: Float = 0
            for v in delta { s += v * v }
            meterSum += s / Float(delta.count)
        }
        let now = Date()
        if now.timeIntervalSince(meterStart) >= 1.0 {
            let rms = meterCount > 0 ? (meterSum / Float(meterCount)).squareRoot() : 0
            Log.info("🎙️ buffers/s=\(meterCount) RMS=\(String(format: "%.4f", rms)) 累计samples=\(sessionSamples.count)")
            meterCount = 0
            meterSum = 0
            meterStart = now
        }
    }

    /// 停止 → 整段转写（MVP）。**保证有字**（坑 #4 尾句天然包含在整段里）。
    func stop() async {
        guard recording, !stopping else { return }
        stopping = true
        defer { stopping = false }

        // 收尾：保持闸门开 ~0.3s 让尾音抵达，再停 tap、排空主队列，最后关闸门。
        try? await Task.sleep(for: .milliseconds(300))
        mic.stop()
        await drainMainQueue()
        recording = false
        onStatus(.ready)

        await transcribeWhole()
    }

    /// 等已入队的主队列 block（录音回调）全部跑完——它们 FIFO 排在本 block 之前，故先执行。
    private func drainMainQueue() async {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            DispatchQueue.main.async { cont.resume() }
        }
    }

    // MARK: - 整段转写（MVP）

    private func transcribeWhole() async {
        let audio = sessionSamples                     // 16kHz / mono / Float32 数组（WhisperKit 要的形式）
        let dur = Double(audio.count) / Double(AudioConstants.sampleRate)

        // (a) 喂给 transcribe 多少
        Log.info("(a) 喂给 transcribe: \(audio.count) samples（\(String(format: "%.2f", dur))s @16kHz mono Float32）")

        guard audio.count >= Int(Double(AudioConstants.sampleRate) * config.minUtterSec) else {
            Log.warn("(a) 音频过短（\(String(format: "%.2f", dur))s < \(config.minUtterSec)s），跳过转写")
            return
        }
        guard let wk = whisperKit else {
            Log.error("(b) whisperKit 未就绪，无法转写")
            return
        }

        var opts = DecodingOptions()
        opts.language = config.language
        opts.temperature = 0
        opts.usePrefillPrompt = true
        opts.promptTokens = promptTokens.isEmpty ? nil : promptTokens
        opts.detectLanguage = false
        opts.skipSpecialTokens = true
        opts.withoutTimestamps = true

        // (b) 何时调 transcribe
        Log.info("(b) 调用 WhisperKit.transcribe …（MVP：停止即整段转写，language=\(config.language ?? "auto")）")
        let t0 = Date()
        do {
            let results = try await wk.transcribe(audioArray: audio, decodeOptions: opts)
            let raw = results.map(\.text).joined()
            let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            let cost = Date().timeIntervalSince(t0)
            // (c) transcribe 返回什么（空也打）
            Log.info("(c) transcribe 返回: \"\(raw)\"（segments=\(results.count), 耗时\(String(format: "%.2f", cost))s, RTF=\(String(format: "%.2f", dur > 0 ? cost / dur : 0))）")
            guard !text.isEmpty else {
                Log.warn("(c) transcribe 返回空文本（可能没说话/太轻/被判静音）")
                return
            }
            onResult(DictationResult(text: text, audioSec: dur, costSec: cost))
        } catch {
            // (c) 报错绝不静默吞
            Log.error("(c) transcribe 抛错: \(error)")
        }
    }
}
