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

import AVFoundation

nonisolated final class MicCapture {
    private let engine = AVAudioEngine()
    private let targetFormat: AVAudioFormat
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
        self.onSamples = onSamples

        let input = engine.inputNode
        let hwFormat = input.inputFormat(forBus: 0)   // 硬件原生格式（常见 48kHz）
        // 无效格式（sampleRate/通道为 0）说明没有可用输入或未真正授权 —— 明确报错，别装 tap。
        guard hwFormat.sampleRate > 0, hwFormat.channelCount > 0 else {
            throw err(-1, "输入设备格式无效（sampleRate=\(hwFormat.sampleRate), channels=\(hwFormat.channelCount)）——可能没有可用麦克风或未授权")
        }
        guard let converter = AVAudioConverter(from: hwFormat, to: targetFormat) else {
            throw err(-2, "无法创建 AVAudioConverter（\(hwFormat.sampleRate)Hz/\(hwFormat.channelCount)ch → 16kHz/mono）")
        }
        self.converter = converter

        // 用硬件原生格式装 tap（关键修复点）。
        input.installTap(onBus: 0, bufferSize: 4096, format: hwFormat) { [weak self] buffer, _ in
            self?.handle(buffer)
        }

        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            self.converter = nil
            self.onSamples = nil
            throw err(-3, "AVAudioEngine.start() 失败: \(error.localizedDescription)")
        }
        running = true
        Log.info("🎙️ 采集启动：硬件 \(Int(hwFormat.sampleRate))Hz/\(hwFormat.channelCount)ch → 16kHz/mono")
    }

    func stop() {
        guard running else { return }
        running = false
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        onSamples = nil
        converter = nil
    }

    // 把硬件格式 buffer 转成 16kHz mono Float32，吐增量样本。
    private func handle(_ inBuffer: AVAudioPCMBuffer) {
        guard let converter, inBuffer.frameLength > 0 else { return }
        let ratio = targetFormat.sampleRate / inBuffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(inBuffer.frameLength) * ratio) + 16
        guard let outBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else { return }

        var fed = false
        var convError: NSError?
        let status = converter.convert(to: outBuffer, error: &convError) { _, inStatus in
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
        onSamples?(samples)
    }

    private func err(_ code: Int, _ msg: String) -> NSError {
        NSError(domain: "Recorpaster.MicCapture", code: code,
                userInfo: [NSLocalizedDescriptionKey: msg])
    }
}
