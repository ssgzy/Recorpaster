//
//  MicCapture.swift
//  Recorpaster
//
//  自管 AVAudioEngine 麦克风采集。替代 WhisperKit AudioProcessor 的采集——后者在本机逐帧重采样
//  抛 -10877(kAudioUnitErr_InvalidElement) 并**静默丢弃**每个 buffer（只 Logging.error 不抛），
//  导致浮窗显示「聆听中」却一个样本都没录进来。
//
//  关键：tap 必须用**硬件原生格式** `inputNode.inputFormat(forBus:0)` 安装（绝不硬编码 16kHz，
//  否则 -10877），再用 AVAudioConverter 把每个 buffer 转成 16kHz / mono / Float32 才喂模型。
//  installTap / engine.start() 全包 do/catch，抛错带确切位置；采集失败显式抛出由上层反馈到 UI。
//

@preconcurrency import AVFoundation   // 抑制 AVFAudio 的 Sendable 互操作告警（buffer 仅在音频线程内用）

nonisolated final class MicCapture {
    private let engine = AVAudioEngine()
    private let targetFormat: AVAudioFormat
    // converter / onSamples / running 被两端访问：start/stop 在主线程，handle 在音频渲染线程。
    // 用 lock 串行化对这三者的读写，消除「stop() 置 nil 时 handle() 正在读」的跨线程竞争。
    private let lock = NSLock()
    private var converter: AVAudioConverter?
    private var onSamples: (([Float]) -> Void)?
    private var running = false

    init() {
        // 16kHz / 单声道 / 非交错 Float32 —— WhisperKit 期望的输入格式。
        targetFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                     sampleRate: Double(AudioConstants.sampleRate),
                                     channels: 1, interleaved: false)!
    }

    /// 启动采集。onSamples 在音频线程被调用，参数是**已转成 16kHz mono Float32 的增量样本**。
    /// 失败抛错（NSError，带可读原因），由上层反馈到浮窗。
    func start(onSamples: @escaping ([Float]) -> Void) throws {
        guard !running else { return }

        let input = engine.inputNode
        let hwFormat = input.inputFormat(forBus: 0)   // 硬件原生格式（常见 48kHz）
        // 无效格式（sampleRate/通道为 0）说明没有可用输入或未真正授权 —— 明确报错，别装 tap。
        guard hwFormat.sampleRate > 0, hwFormat.channelCount > 0 else {
            throw err(-1, "输入设备格式无效（sampleRate=\(hwFormat.sampleRate), channels=\(hwFormat.channelCount)）——可能没有可用麦克风或未授权")
        }
        guard let conv = AVAudioConverter(from: hwFormat, to: targetFormat) else {
            throw err(-2, "无法创建 AVAudioConverter（\(hwFormat.sampleRate)Hz/\(hwFormat.channelCount)ch → 16kHz/mono）")
        }

        // 先在锁内备好状态，再装 tap：保证回调一来就能安全读到 converter/onSamples/running。
        lock.lock()
        self.converter = conv
        self.onSamples = onSamples
        running = true
        lock.unlock()

        // 用硬件原生格式装 tap（关键修复点）。
        input.installTap(onBus: 0, bufferSize: 4096, format: hwFormat) { [weak self] buffer, _ in
            self?.handle(buffer)
        }

        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            lock.lock(); running = false; self.converter = nil; self.onSamples = nil; lock.unlock()
            throw err(-3, "AVAudioEngine.start() 失败: \(error.localizedDescription)")
        }
        Log.info("🎙️ 采集启动：硬件 \(Int(hwFormat.sampleRate))Hz/\(hwFormat.channelCount)ch → 16kHz/mono")
    }

    func stop() {
        // 先在锁内翻 running=false 并清引用 → 此后任何 handle() 回调都早退；再拆 tap/停引擎。
        lock.lock()
        let wasRunning = running
        running = false
        onSamples = nil
        converter = nil
        lock.unlock()
        guard wasRunning else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
    }

    // 把硬件格式 buffer 转成 16kHz mono Float32，吐增量样本。在音频渲染线程执行。
    private func handle(_ inBuffer: AVAudioPCMBuffer) {
        // 锁内只取本地强引用（纳秒级临界区）；转换与回调在锁外做，避免在渲染线程长时间持锁。
        lock.lock()
        let active = running
        let conv = converter
        let sink = onSamples
        lock.unlock()
        guard active, let conv, let sink, inBuffer.frameLength > 0 else { return }

        let ratio = targetFormat.sampleRate / inBuffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(inBuffer.frameLength) * ratio) + 16
        guard let outBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else { return }

        var fed = false
        var convError: NSError?
        let status = conv.convert(to: outBuffer, error: &convError) { _, inStatus in
            if fed { inStatus.pointee = .noDataNow; return nil }
            fed = true
            inStatus.pointee = .haveData
            return inBuffer
        }
        if let convError {
            Log.warn("重采样失败: \(convError.localizedDescription)")
            return
        }
        guard status != .error, outBuffer.frameLength > 0, let ch = outBuffer.floatChannelData else { return }
        let samples = Array(UnsafeBufferPointer(start: ch[0], count: Int(outBuffer.frameLength)))
        sink(samples)
    }

    private func err(_ code: Int, _ msg: String) -> NSError {
        NSError(domain: "Recorpaster.MicCapture", code: code,
                userInfo: [NSLocalizedDescriptionKey: msg])
    }
}

// MARK: - 🔬 调试音频工具（dump / 读取 WAV）
//
//  用于定位「transcribe 拿到音频却返回空」：
//   · writeWAV：把**喂给 transcribe 的那段 buffer 原样**写成 16kHz/mono/Float32 WAV，人工试听
//     —— 声音清楚=音频没问题、锅在解码；静音/噪音/变速尖叫=转换器坏了。
//   · read16kMono：读任意 WAV → 16kHz mono Float32，喂给 WhisperKit 绕开麦克风+转换器，隔离 WhisperKit 用法。
enum DebugAudio {
    /// 把 16kHz mono Float32 样本原样写成 WAV（afplay /tmp/recor_debug.wav 可试听）。
    static func writeWAV(_ samples: [Float], to path: String) {
        let url = URL(fileURLWithPath: path)
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: Double(AudioConstants.sampleRate),
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false,
            AVLinearPCMIsBigEndianKey: false,
        ]
        guard let fmt = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                      sampleRate: Double(AudioConstants.sampleRate),
                                      channels: 1, interleaved: false),
              let buf = AVAudioPCMBuffer(pcmFormat: fmt,
                                         frameCapacity: AVAudioFrameCount(max(1, samples.count))) else {
            Log.error("DebugAudio.writeWAV: 无法创建缓冲")
            return
        }
        buf.frameLength = AVAudioFrameCount(samples.count)
        if let ch = buf.floatChannelData {
            samples.withUnsafeBufferPointer { src in
                if let base = src.baseAddress { ch[0].update(from: base, count: samples.count) }
            }
        }
        do {
            try? FileManager.default.removeItem(at: url)
            let file = try AVAudioFile(forWriting: url, settings: settings,
                                       commonFormat: .pcmFormatFloat32, interleaved: false)
            try file.write(from: buf)
            Log.ok("🔬 DebugAudio.writeWAV: 已写 \(samples.count) samples → \(path)（afplay 可试听）")
        } catch {
            Log.error("DebugAudio.writeWAV 失败: \(error)")
        }
    }

    /// 读任意音频文件 → 16kHz mono Float32 样本（必要时重采样/降混）。
    static func read16kMono(_ path: String) -> [Float]? {
        let url = URL(fileURLWithPath: path)
        guard let file = try? AVAudioFile(forReading: url) else {
            Log.error("DebugAudio.read16kMono: 打不开 \(path)"); return nil
        }
        let inFormat = file.processingFormat
        let frames = AVAudioFrameCount(file.length)
        guard frames > 0, let inBuf = AVAudioPCMBuffer(pcmFormat: inFormat, frameCapacity: frames) else {
            Log.error("DebugAudio.read16kMono: 空文件或缓冲创建失败"); return nil
        }
        do { try file.read(into: inBuf) } catch { Log.error("read16kMono 读失败: \(error)"); return nil }

        guard let target = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                         sampleRate: Double(AudioConstants.sampleRate),
                                         channels: 1, interleaved: false) else { return nil }
        // 已是 16k/mono/float32：直接取
        if inFormat.sampleRate == target.sampleRate, inFormat.channelCount == 1,
           inFormat.commonFormat == .pcmFormatFloat32, let ch = inBuf.floatChannelData {
            return Array(UnsafeBufferPointer(start: ch[0], count: Int(inBuf.frameLength)))
        }
        // 否则一次性转换
        guard let conv = AVAudioConverter(from: inFormat, to: target) else {
            Log.error("read16kMono: 无法创建转换器 \(inFormat) → 16k/mono"); return nil
        }
        let ratio = target.sampleRate / inFormat.sampleRate
        let cap = AVAudioFrameCount(Double(inBuf.frameLength) * ratio) + 1024
        guard let outBuf = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: cap) else { return nil }
        var fed = false
        var convError: NSError?
        _ = conv.convert(to: outBuf, error: &convError) { _, st in
            if fed { st.pointee = .noDataNow; return nil }
            fed = true; st.pointee = .haveData; return inBuf
        }
        if let convError { Log.error("read16kMono 转换失败: \(convError)"); return nil }
        guard let ch = outBuf.floatChannelData else { return nil }
        return Array(UnsafeBufferPointer(start: ch[0], count: Int(outBuf.frameLength)))
    }
}
