//
//  AppDelegate.swift
//  Recorpaster
//
//  设为 .accessory（菜单栏 App、无 Dock 图标），构建并启动总控。
//

import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var controller: AppController?
    private var selfTestMic: MicCapture?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)   // 菜单栏 App，无 Dock 图标，不抢前台

        // 开发自测：RECOR_MIC_SELFTEST=1 时只跑 2.5s 采集体检（打印 buffer 数/RMS/峰值）后退出，
        // 用来确认 tap 真的出数据、-10877 已解决。生产不设该变量则跳过。
        if ProcessInfo.processInfo.environment["RECOR_MIC_SELFTEST"] == "1" {
            runMicSelfTest()
            return
        }

        let controller = AppController()
        controller.start()
        self.controller = controller
        Log.info("Recorpaster 启动（accessory）。")
    }

    private func runMicSelfTest() {
        Log.info("MIC SELFTEST 开始（2.5s，靠环境底噪即可）…")
        let mic = MicCapture()
        selfTestMic = mic
        var buffers = 0, samples = 0
        var sumSq: Float = 0, maxAbs: Float = 0
        do {
            try mic.start { delta in
                DispatchQueue.main.async {
                    buffers += 1
                    samples += delta.count
                    for v in delta { sumSq += v * v; maxAbs = max(maxAbs, abs(v)) }
                }
            }
        } catch {
            Log.error("MIC SELFTEST 启动失败: \(error.localizedDescription)")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { NSApp.terminate(nil) }
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
            let rms = samples > 0 ? (sumSq / Float(samples)).squareRoot() : 0
            Log.info("MIC SELFTEST 结果: buffers=\(buffers) samples=\(samples) RMS=\(String(format: "%.5f", rms)) maxAbs=\(String(format: "%.4f", maxAbs))")
            mic.stop()
            NSApp.terminate(nil)
        }
    }
}
