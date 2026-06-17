//
//  VAD.swift
//  Recorpaster
//
//  语音活动检测：把麦克风音频按停顿切成一句句。Phase 1 用**能量法**（无额外依赖），
//  状态机结构逐事件对齐 Python engine.py 的 _OnnxVADIterator（start/end 事件 + 静音挂起 +
//  迟滞）。嘈杂环境下 Silero ONNX 更稳，留作 Phase 2 升级（VAD 协议已抽好，可直接替换）。
//

import Foundation

/// VAD 事件，携带样本索引（相对于会话起点的累计样本数）。
enum VADEvent {
    case start(Int)   // 检测到一句开始（已含少量 speechPad 回看）
    case end(Int)     // 检测到一句结束
}

protocol VAD: AnyObject {
    func reset()
    /// 喂入一帧（约 512 样本），可能吐出一个边界事件。
    func process(_ chunk: ArraySlice<Float>) -> VADEvent?
}

/// 短时能量 VAD：自适应噪声基底 + 倍数门限 + 迟滞 + 静音挂起。
final class EnergyVAD: VAD {
    private let sampleRate: Int
    private let minSilenceSamples: Float
    private let speechPadSamples: Float
    private let speechFactor: Float        // 语音门限 = 噪声基底 × 此倍数
    private let minAbsEnergy: Float = 0.0009   // 绝对地板，避免纯静音里误触发

    // 状态
    private var noiseEMA: Float = 0.0009
    private var triggered = false
    private var tempEnd: Float = 0
    private var currentSample: Float = 0

    init(sampleRate: Int, minSilenceMs: Int, threshold: Float, speechPadMs: Int = 32) {
        self.sampleRate = sampleRate
        self.minSilenceSamples = Float(sampleRate) * Float(minSilenceMs) / 1000.0
        self.speechPadSamples = Float(sampleRate) * Float(speechPadMs) / 1000.0
        // 把 0…1 的 vadThreshold 映射成噪声倍数：0→1.5×（灵敏），1→5.5×（迟钝/抗噪）。
        self.speechFactor = 1.5 + max(0, min(1, threshold)) * 4.0
    }

    func reset() {
        noiseEMA = minAbsEnergy
        triggered = false
        tempEnd = 0
        currentSample = 0
    }

    func process(_ chunk: ArraySlice<Float>) -> VADEvent? {
        let n = Float(chunk.count)
        currentSample += n

        // 短时 RMS 能量
        var sum: Float = 0
        for v in chunk { sum += v * v }
        let energy = (chunk.isEmpty ? 0 : (sum / n).squareRoot())

        // 静音时更新噪声基底（缓慢跟随环境）
        if !triggered {
            noiseEMA = 0.95 * noiseEMA + 0.05 * energy
        }
        let speechThresh = max(minAbsEnergy, noiseEMA * speechFactor)
        let silenceThresh = speechThresh * 0.6   // 迟滞：松开门限更低，避免抖动

        // 语音恢复 → 取消挂起的“结束”
        if energy >= speechThresh && tempEnd != 0 {
            tempEnd = 0
        }
        // 静音→语音：一句开始
        if energy >= speechThresh && !triggered {
            triggered = true
            let start = max(0, currentSample - speechPadSamples - n)
            return .start(Int(start))
        }
        // 语音→静音持续够久：一句结束
        if energy < silenceThresh && triggered {
            if tempEnd == 0 { tempEnd = currentSample }
            if currentSample - tempEnd < minSilenceSamples { return nil }
            let end = tempEnd + speechPadSamples - n
            tempEnd = 0
            triggered = false
            return .end(Int(max(0, end)))
        }
        return nil
    }

    /// 当前是否正处在一句话当中（供引擎在松开/停止时决定要不要兜底送出尾句）。
    var isTriggered: Bool { triggered }
}
