//
//  DictationEngine.swift
//  Recorpaster
//
//  听写引擎（UI 无关）。对接口与 Python engine.py 对齐：start / stop / flush + onResult / onStatus。
//   · 采集：自管 AVAudioEngine（见 MicCapture）——硬件原生格式装 tap + AVAudioConverter 转 16kHz mono
//     Float32。回调在音频线程吐增量样本，hop 回**主线程**追加进自有缓冲，分段全程在主 actor 上串行。
//     （不用 WhisperKit AudioProcessor 的采集：它在本机逐帧重采样抛 -10877 并静默丢弃每个 buffer。）
//   · 切句：EnergyVAD 逐 512 帧吐 start/end，切出一句句送识别。
//   · 识别：每句调 whisperKit.transcribe（中文 + 标点风格 prompt）。串行消费，不阻塞下一句。
//   · 收尾（坑 #4 松开别丢尾句）：stop() 保持采纳闸门开到最后一个在途 delta 被追加之后——先 sleep ~0.3s
//     让尾音抵达 → 停 tap → 排空主队列 → **最后**才 recording=false → step + flush 兜底当前句 →
//     关识别流并 await 排空（含尾句）。绝不提前翻 recording=false，否则尾音被回调守卫吞掉。
//   · 隐私：全程内存 [Float]，绝不写任何音频文件。
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
    private let vad: EnergyVAD
    private var promptTokens: [Int] = []

    // 电平表：每秒打印 buffer 数 + RMS，确认确实有声音进来（采集自测用）。
    private var meterCount = 0
    private var meterSum: Float = 0
    private var meterStart = Date()

    // 注：sessionSamples 在整段会话内只 append（start() 才清空），consumed/uStart 用「相对会话起点的
    // 绝对索引」。hold 模式下会话只有几秒、内存无虞；toggle 模式的超长会话可能持续增长——Phase 2 再做
    // 滑窗 rebase（按 min(consumed,uStart) 裁前缀 + baseOffset 折算）来封顶内存。
    private var sessionSamples: [Float] = []   // 本次会话的 16kHz 单声道音频（内存）
    private var consumed = 0                    // 已喂过 VAD 的样本数
    private var collecting = false             // 是否正在收集一句
    private var uStart = 0                      // 当前句起点（含 lookback）
    private var recording = false
    private var stopping = false               // 防止 stop() 重入（endSession 与 quit 可能并发调用）

    // 识别队列（串行消费）
    private var utterContinuation: AsyncStream<[Float]>.Continuation?
    private var transcribeTask: Task<Void, Never>?

    init(config: Config,
         onResult: @escaping @MainActor (DictationResult) -> Void,
         onStatus: @escaping @MainActor (EngineStatus) -> Void) {
        self.config = config
        self.onResult = onResult
        self.onStatus = onStatus
        self.vad = EnergyVAD(sampleRate: AudioConstants.sampleRate,
                             minSilenceMs: config.minSilenceMs,
                             threshold: config.vadThreshold)
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

            // 标点风格引导 → prompt tokens（过滤掉 special token，只留文本 token）。
            if !config.initialPrompt.isEmpty, let tok = wk.tokenizer {
                let begin = tok.specialTokens.specialTokenBegin
                promptTokens = tok.encode(text: " " + config.initialPrompt).filter { $0 < begin }
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
        // 复位
        sessionSamples.removeAll(keepingCapacity: true)
        consumed = 0
        collecting = false
        uStart = 0
        vad.reset()
        meterCount = 0
        meterSum = 0
        meterStart = Date()

        // 识别串行任务
        let (stream, cont) = AsyncStream<[Float]>.makeStream(bufferingPolicy: .unbounded)
        utterContinuation = cont
        transcribeTask = Task { [weak self] in
            guard let self else { return }
            for await audio in stream {
                await self.transcribeAndEmit(audio)
            }
        }

        // 先置 recording=true，避免开头几帧被回调守卫丢掉；失败则回滚并抛错（由上层反馈到 UI）。
        recording = true
        do {
            try mic.start { [weak self] delta in
                DispatchQueue.main.async {
                    guard let self, self.recording else { return }
                    self.sessionSamples.append(contentsOf: delta)
                    self.meter(delta)
                    self.step()
                }
            }
        } catch {
            recording = false
            utterContinuation?.finish()
            utterContinuation = nil
            transcribeTask?.cancel()
            transcribeTask = nil
            throw error
        }
        onStatus(.listening)
    }

    /// 电平表：每秒打印 buffer 数 + RMS，确认有声音进来。
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
            Log.info("🎙️ buffers/s=\(meterCount) RMS=\(String(format: "%.4f", rms)) samples=\(sessionSamples.count)")
            meterCount = 0
            meterSum = 0
            meterStart = now
        }
    }

    /// 处理缓冲里新到的整帧：逐 512 喂 VAD，切句入识别队列。
    private func step() {
        let chunk = AudioConstants.chunk
        while consumed + chunk <= sessionSamples.count {
            let frame = sessionSamples[consumed ..< consumed + chunk]
            let ev = vad.process(frame)
            consumed += chunk
            switch ev {
            case .start(let s):
                collecting = true
                uStart = max(0, s - config.lookbackChunks * chunk)
            case .end(let e):
                if collecting {
                    collecting = false
                    emit(start: uStart, end: min(e, sessionSamples.count))
                }
            case .none:
                break
            }
        }
    }

    private func emit(start: Int, end: Int) {
        guard end > start, start >= 0, end <= sessionSamples.count else { return }
        let dur = Double(end - start) / Double(AudioConstants.sampleRate)
        if dur < config.minUtterSec { return }   // 过短丢弃（噪声/误触发）
        let slice = Array(sessionSamples[start ..< end])
        utterContinuation?.yield(slice)
    }

    /// flush：把当前正在收集的语音立即送识别（松开收尾用）。可多次调用，幂等。
    func flush() {
        step()   // 先吃掉残余整帧
        if collecting {
            collecting = false
            emit(start: uStart, end: sessionSamples.count)
        } else if vad.isTriggered {
            // VAD 仍在句中但尚未标记 collecting 的极端情形：兜底送出尾段。
            emit(start: uStart, end: sessionSamples.count)
        }
    }

    /// 优雅停止，**保证尾句不丢**（坑 #4）。
    /// 关键不变量：采纳闸门（录音回调里的 `guard recording`）必须**一直开到最后一个在途 delta 被追加之后**；
    /// 用「移除 tap」来停止新 delta，而不是提前翻 recording=false——否则尾音会被守卫吞掉。
    func stop() async {
        guard recording, !stopping else { return }
        stopping = true
        defer { stopping = false }

        // 1) 保持 recording=true：让最后 ~0.3s 的 tap 缓冲继续经 main.async 正常 append + step。
        try? await Task.sleep(for: .milliseconds(300))
        // 2) 关 tap：不再产生新的音频 delta（已捕获、已 dispatch 的回调仍会跑）。
        mic.stop()
        // 3) 排空已入队但尚未执行的录音回调 block（此刻 recording 仍为 true，会正常 append + step）。
        await drainMainQueue()
        // 4) 现在才关采纳闸门，处理残余 + 兜底当前句（尾句在此送入识别队列）。
        recording = false
        step()
        flush()
        // 5) 关识别流并等队列（含尾句）排空后才收工。
        utterContinuation?.finish()
        utterContinuation = nil
        await transcribeTask?.value
        transcribeTask = nil

        onStatus(.ready)
    }

    /// 等已入队的主队列 block（录音回调）全部跑完——它们 FIFO 排在本 block 之前，故先执行。
    private func drainMainQueue() async {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            DispatchQueue.main.async { cont.resume() }
        }
    }

    // MARK: - 识别

    private func transcribeAndEmit(_ audio: [Float]) async {
        guard let wk = whisperKit else { return }
        let dur = Double(audio.count) / Double(AudioConstants.sampleRate)
        var opts = DecodingOptions()
        opts.language = config.language
        opts.temperature = 0
        opts.usePrefillPrompt = true
        opts.promptTokens = promptTokens.isEmpty ? nil : promptTokens
        opts.detectLanguage = false
        opts.skipSpecialTokens = true
        opts.withoutTimestamps = true

        let t0 = Date()
        do {
            let results = try await wk.transcribe(audioArray: audio, decodeOptions: opts)
            let text = results.map(\.text).joined()
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let cost = Date().timeIntervalSince(t0)
            guard !text.isEmpty else { return }
            onResult(DictationResult(text: text, audioSec: dur, costSec: cost))
        } catch {
            Log.warn("识别失败: \(error.localizedDescription)")
        }
    }
}
