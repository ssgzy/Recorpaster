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
    /// 实时电平回调（每个采集 buffer 一次，~10-12/s 的瞬时 RMS）。供浮窗律动用，可选设置。
    var onLevel: (@MainActor (Float) -> Void)?
    /// 流式预览回调：会话期间不断吐出「到目前为止」的临时识别文本（无标点、用完即弃，仅供条上预览）。
    var onPartial: (@MainActor (String) -> Void)?
    /// 模型加载进度回调：(状态文案, 进度)。进度 nil = 不确定式（加载/编译，不透明）；0..1 = 确定式（下载字节）。
    var onLoadProgress: (@MainActor (String, Double?) -> Void)?
    /// 流式预览开关（兜底：关掉即退回 Step1「松开后才出字」）。RECOR_NO_STREAM=1 也可强制关。
    var streamingEnabled = true
    private var streamTask: Task<Void, Never>?
    private var lastStreamCount = 0

    // 转写互斥：WhisperKit 内部无串行（共享 currentTimings/modelState），并发转写不安全。
    // FIFO 异步互斥锁，保证流式临时转写与最终整段转写绝不重叠；不靠 cancel，避免污染 WhisperKit。
    private var transcribeBusy = false
    private var transcribeWaiters: [CheckedContinuation<Void, Never>] = []

    private func acquireTranscribe() async {
        if !transcribeBusy { transcribeBusy = true; return }
        await withCheckedContinuation { transcribeWaiters.append($0) }
        // 被上一笔 release 唤醒 → 此刻已持有锁（busy 保持 true）。
    }
    private func releaseTranscribe() {
        if transcribeWaiters.isEmpty {
            transcribeBusy = false
        } else {
            transcribeWaiters.removeFirst().resume()   // 把锁交给下一个等待者（FIFO）
        }
    }

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

    // 内存封顶：单次会话最多保留 maxSessionSec 秒音频（16kHz×4B ≈ 64KB/s → 180s ≈ 11.5MB）。
    // 超出按滑窗丢弃最早样本，防极端长按把 [Float] 撑爆（正常按几秒~几十秒绝不触发）。
    private static let maxSessionSec = 180
    private var maxSessionSamples: Int { AudioConstants.sampleRate * Self.maxSessionSec }
    private var didWarnCap = false
    private var levelEnv: Float = 0            // RMS 包络（呼吸/脉冲律动用）

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
            // 模型缓存默认在 ~/Documents/huggingface/models/argmaxinc/whisperkit-coreml/<model>。
            let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            let folder = docs.appendingPathComponent("huggingface/models/argmaxinc/whisperkit-coreml/\(config.model)")

            let modelFolder: URL
            if FileManager.default.fileExists(atPath: folder.path) {
                modelFolder = folder                                  // 已缓存：本地加载，不联网
            } else {
                // 首次：真实字节下载，确定式 %（WhisperKit.download → HubApi snapshot）。
                onLoadProgress?("下载模型…", 0)
                modelFolder = try await WhisperKit.download(variant: config.model, progressCallback: { p in
                    let f = p.fractionCompleted
                    Task { @MainActor [weak self] in self?.onLoadProgress?("下载模型", f) }
                })
            }

            // 加载/编译 CoreML（modelState 仅 .loading→.loaded，不透明）→ 不确定式动画 + 诚实时长提示。
            onLoadProgress?("加载模型中…（约 1–2 分钟）", nil)
            let wkConfig = WhisperKitConfig(
                model: config.model,
                modelFolder: modelFolder.path,
                verbose: false,
                logLevel: .error,
                prewarm: false,
                load: true,
                download: false
            )
            let wk = try await WhisperKit(wkConfig)
            self.whisperKit = wk

            // 仅供 dev A/B 自测（RECOR_WAV_FILE）复核 prompt 行为；生产路径不喂（turbo 吃 prompt 会塌成空）。
            if !config.initialPrompt.isEmpty, let tok = wk.tokenizer {
                let begin = tok.specialTokens.specialTokenBegin
                promptTokens = tok.encode(text: " " + config.initialPrompt).filter { $0 < begin }
                Log.info("标点风格 prompt tokens=\(promptTokens.count) 个（仅诊断用，生产不喂）")
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
        didWarnCap = false
        levelEnv = 0
        lastStreamCount = 0
        meterCount = 0
        meterSum = 0
        meterStart = Date()

        recording = true   // 先开闸门，避免开头几帧被守卫丢；失败回滚
        do {
            try mic.start { [weak self] delta in
                DispatchQueue.main.async {
                    guard let self, self.recording else { return }
                    self.sessionSamples.append(contentsOf: delta)
                    if self.sessionSamples.count > self.maxSessionSamples {
                        self.sessionSamples.removeFirst(self.sessionSamples.count - self.maxSessionSamples)
                        if !self.didWarnCap {
                            self.didWarnCap = true
                            Log.warn("会话超 \(Self.maxSessionSec)s 上限，已滑窗丢弃最早音频以封顶内存（整段转写不含最早部分）。")
                        }
                    }
                    self.meter(delta)
                    if let onLevel = self.onLevel, !delta.isEmpty {
                        var s: Float = 0
                        for v in delta { s += v * v }
                        let raw = (s / Float(delta.count)).squareRoot()
                        // 包络跟随：快起慢落，去抖动 → 视图呼吸/脉冲平滑不闪。
                        let coeff: Float = raw > self.levelEnv ? 0.6 : 0.15
                        self.levelEnv += (raw - self.levelEnv) * coeff
                        onLevel(self.levelEnv)
                    }
                }
            }
        } catch {
            recording = false
            throw error
        }
        onStatus(.listening)
        Log.info("会话开始（采集中）。")
        startStreamingPreview()
    }

    // MARK: - 流式预览（轮询重转写，复用 MicCapture+transcribe；不碰 AudioProcessor / 粘贴路径）

    private func startStreamingPreview() {
        guard streamingEnabled,
              ProcessInfo.processInfo.environment["RECOR_NO_STREAM"] != "1",
              onPartial != nil else { return }
        streamTask = Task { @MainActor in
            while recording, !stopping, !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(450))
                guard recording, !stopping, !Task.isCancelled else { break }
                let samples = sessionSamples                       // 主线程拷贝，安全
                guard samples.count >= Int(Double(AudioConstants.sampleRate) * 0.4),
                      samples.count != lastStreamCount else { continue }
                lastStreamCount = samples.count
                let text = await transcribePartial(samples)        // 期间主线程空闲，采集继续
                guard recording, !stopping, !Task.isCancelled, let text, !text.isEmpty else { continue }
                onPartial?(text)
            }
        }
    }

    /// 临时转写（快、无 prompt、无标点）。仅供预览。
    private func transcribePartial(_ audio: [Float]) async -> String? {
        await acquireTranscribe()
        defer { releaseTranscribe() }
        guard !stopping, let wk = whisperKit else { return nil }   // 等锁期间若已进入收尾，放弃这笔
        var opts = DecodingOptions()
        opts.language = config.language
        opts.temperature = 0
        opts.usePrefillPrompt = true
        opts.promptTokens = nil
        opts.detectLanguage = false
        opts.skipSpecialTokens = true
        opts.withoutTimestamps = true
        do {
            let results = try await wk.transcribe(audioArray: audio, decodeOptions: opts)
            return results.map(\.text).joined().trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            return nil   // 单次失败不影响（下次重试 / 最终整段转写兜底）
        }
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
        Log.info("收尾：停止中…")

        // 关键：**不 cancel 流式任务**——cancel 会把取消传进 WhisperKit 内部、疑似卡住在途转写不返回，
        // 导致 stop() 永久挂起、收尾永不执行。改为只置 stopping：轮询循环会因 stopping 自行退出（≤450ms）；
        // 最终整段转写经下面的转写互斥锁排在在途临时转写之后（有界等待、绝不并发），无需在此 await 流式任务。
        streamTask = nil

        // 收尾：保持闸门开 ~0.3s 让尾音抵达，再停 tap、排空主队列，最后关闸门。
        try? await Task.sleep(for: .milliseconds(300))
        mic.stop()
        await drainMainQueue()
        recording = false
        onStatus(.ready)
        Log.info("收尾：采集已停，开始最终整段转写。")

        await transcribeWhole()
        Log.info("收尾：完成。")
    }

    /// 等已入队的主队列 block（录音回调）全部跑完——它们 FIFO 排在本 block 之前，故先执行。
    private func drainMainQueue() async {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            DispatchQueue.main.async { cont.resume() }
        }
    }

    // MARK: - 整段转写（MVP）+ 🔬 诊断插桩

    private func transcribeWhole() async {
        let audio = sessionSamples                     // 16kHz / mono / Float32 数组（WhisperKit 要的形式）
        let dur = Double(audio.count) / Double(AudioConstants.sampleRate)

        // (a) 喂给 transcribe 多少
        Log.info("(a) 喂给 transcribe: \(audio.count) samples（\(String(format: "%.2f", dur))s @16kHz mono Float32）")

        guard audio.count >= Int(Double(AudioConstants.sampleRate) * config.minUtterSec) else {
            Log.warn("(a) 音频过短（\(String(format: "%.2f", dur))s < \(config.minUtterSec)s），跳过转写")
            return
        }
        guard let wk = whisperKit else { Log.error("(b) whisperKit 未就绪，无法转写"); return }

        // 隐私：默认绝不写盘。仅 RECOR_DUMP_WAV=1 时把这段 buffer dump 到 /tmp 供人工试听（dev）。
        if ProcessInfo.processInfo.environment["RECOR_DUMP_WAV"] == "1" {
            DebugAudio.writeWAV(audio, to: "/tmp/recor_debug.wav")
        }

        var opts = DecodingOptions()
        opts.language = config.language
        opts.temperature = 0
        opts.usePrefillPrompt = true
        // ⚠️ 不喂 promptTokens：large-v3-turbo 只要吃到 <|startofprev|> 前文就立即 EOT → 整段空。
        //（已用已知 WAV 复现：任意 prompt 内容/temperature/时间戳都塌；唯一恢复输出=不喂 prompt。）
        //  标点改靠模型原生输出；如换非-turbo 模型可在此恢复 opts.promptTokens = promptTokens。
        opts.promptTokens = nil
        opts.detectLanguage = false
        opts.skipSpecialTokens = true
        opts.withoutTimestamps = true

        // (b) 何时调 transcribe（经互斥锁：若有在途流式临时转写，先等它跑完，绝不并发）
        Log.info("(b) 调用 WhisperKit.transcribe …（整段转写，language=\(config.language ?? "auto")，原生标点）")
        await acquireTranscribe()
        let t0 = Date()
        let results: [TranscriptionResult]
        do {
            results = try await wk.transcribe(audioArray: audio, decodeOptions: opts)
            releaseTranscribe()
        } catch {
            releaseTranscribe()
            Log.error("(c) transcribe 抛错: \(error)")
            return
        }
        let cost = Date().timeIntervalSince(t0)
        let raw = results.map(\.text).joined()
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        for r in results {
            for s in r.segments {
                Log.info("(c) seg#\(s.id) avgLogprob=\(String(format: "%.3f", s.avgLogprob)) noSpeechProb=\(String(format: "%.3f", s.noSpeechProb)) compRatio=\(String(format: "%.2f", s.compressionRatio)) tokens=\(s.tokens.count)")
            }
        }
        // (c) transcribe 返回什么（空也打）
        Log.info("(c) transcribe 返回: \"\(raw)\"（segments=\(results.count), 耗时\(String(format: "%.2f", cost))s, RTF=\(String(format: "%.2f", dur > 0 ? cost / dur : 0))）")
        guard !text.isEmpty else {
            Log.warn("(c) transcribe 返回空文本（可能没说话/太轻/被判静音）")
            return
        }
        onResult(DictationResult(text: text, audioSec: dur, costSec: cost))
    }

    // MARK: - 🔬 诊断转写（同段音频跑两遍：A=带标点 prompt / B=不带 prompt）

    /// 定位「拿到音频却返回空」：A 空而 B 非空 ⇒ 标点 prompt tokens 喂坏解码；A/B 都空 ⇒ 查音频或用法。
    /// 每遍打印完整 DecodingOptions + 每个 segment 的 avgLogprob/noSpeechProb/compressionRatio/temperature/tokens/text。
    @discardableResult
    func diagnosticTranscribe(_ audio: [Float], label: String) async -> (text: String, cost: Double)? {
        guard let wk = whisperKit else { Log.error("[\(label)] whisperKit 未就绪，无法转写"); return nil }

        // 先把 prompt 本身解码回文本，确认编码没坏。
        if let tok = wk.tokenizer {
            let decoded = promptTokens.isEmpty ? "(空)" : tok.decode(tokens: promptTokens)
            Log.info("[\(label)] 标点 promptTokens=\(promptTokens.count) 个 → 解码=\"\(decoded)\" 头16=\(Array(promptTokens.prefix(16)))")
        }

        let a = await runPass(wk, audio, withPrompt: true,  label: "\(label)·A带prompt")
        let b = await runPass(wk, audio, withPrompt: false, label: "\(label)·B无prompt")

        let at = (a?.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let bt = (b?.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if at.isEmpty, !bt.isEmpty {
            Log.warn("🔬 倾向结论：带 prompt 空、去 prompt 出字 ⇒ **标点 prompt tokens 喂坏了解码**（与怀疑高度吻合）。")
            return (bt, b?.cost ?? 0)
        }
        if at.isEmpty, bt.isEmpty {
            Log.warn("🔬 倾向结论：A/B 都空 ⇒ 不是 prompt 问题；听 /tmp/recor_debug.wav 判断音频，或查 WhisperKit 用法。")
            return nil
        }
        if !at.isEmpty, bt.isEmpty {
            Log.info("🔬 注意：带 prompt 出字、去 prompt 反而空（少见）。")
        }
        return (at, a?.cost ?? 0)
    }

    /// 单遍转写 + 打印原始 segments（不只 .text）。
    private func runPass(_ wk: WhisperKit, _ audio: [Float], withPrompt: Bool, label: String)
        async -> (text: String, cost: Double)? {
        var opts = DecodingOptions()
        opts.language = config.language
        opts.temperature = 0
        opts.usePrefillPrompt = true
        opts.promptTokens = withPrompt ? (promptTokens.isEmpty ? nil : promptTokens) : nil
        opts.detectLanguage = false
        opts.skipSpecialTokens = true
        opts.withoutTimestamps = true

        // 🔬 调试开关：扫「保住 prompt 不塌」的组合（仅诊断用）。
        let env = ProcessInfo.processInfo.environment
        if let t = env["RECOR_TEMP"], let tv = Float(t) { opts.temperature = tv }
        if env["RECOR_TS"] == "1" { opts.withoutTimestamps = false }     // 开启时间戳
        if env["RECOR_PREFILL"] == "0" { opts.usePrefillPrompt = false } // 关 prefill prompt

        let dur = Double(audio.count) / Double(AudioConstants.sampleRate)
        Log.info("[\(label)] DecodingOptions: language=\(opts.language ?? "nil") temperature=\(opts.temperature) usePrefillPrompt=\(opts.usePrefillPrompt) promptTokens=\(opts.promptTokens?.count ?? 0) detectLanguage=\(opts.detectLanguage) skipSpecialTokens=\(opts.skipSpecialTokens) withoutTimestamps=\(opts.withoutTimestamps)")
        let t0 = Date()
        do {
            let results = try await wk.transcribe(audioArray: audio, decodeOptions: opts)
            let cost = Date().timeIntervalSince(t0)
            let raw = results.map(\.text).joined()
            Log.info("[\(label)] 返回 text=\"\(raw)\"（results=\(results.count), 耗时\(String(format: "%.2f", cost))s, RTF=\(String(format: "%.2f", dur > 0 ? cost / dur : 0))）")
            for (i, r) in results.enumerated() {
                Log.info("[\(label)]   result#\(i) lang=\(r.language) segments=\(r.segments.count)")
                for s in r.segments {
                    Log.info("[\(label)]     seg#\(s.id) t=[\(String(format: "%.2f", s.start))~\(String(format: "%.2f", s.end))] avgLogprob=\(String(format: "%.3f", s.avgLogprob)) noSpeechProb=\(String(format: "%.3f", s.noSpeechProb)) compRatio=\(String(format: "%.2f", s.compressionRatio)) temp=\(String(format: "%.1f", s.temperature)) tokens=\(s.tokens.count) text=\"\(s.text)\"")
                }
            }
            return (raw, cost)
        } catch {
            Log.error("[\(label)] transcribe 抛错: \(error)")
            return nil
        }
    }
}
