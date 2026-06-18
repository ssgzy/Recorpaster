//
//  Log.swift
//  Recorpaster
//
//  打包后的 .app 无控制台，运行日志同时写到 ~/Library/Logs/Recorpaster.log（对应 Python 版
//  的 setup_logging / _Tee）。开发时也打到 Xcode 控制台。
//

import Foundation

// 日志线程安全（NSLock + FileHandle），全程 nonisolated，可从任意线程/actor 调用（音频线程、下载任务等）。
enum Log {
    nonisolated private static let fileHandle: FileHandle? = {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs", isDirectory: true)
        let url = dir.appendingPathComponent("Recorpaster.log")
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        let h = try? FileHandle(forWritingTo: url)
        _ = try? h?.seekToEnd()
        return h
    }()

    nonisolated private static let lock = NSLock()

    nonisolated static func line(_ message: String) {
        let stamp = ISO8601DateFormatter().string(from: Date())
        let text = "[\(stamp)] \(message)\n"
        print(message)
        lock.lock(); defer { lock.unlock() }
        if let data = text.data(using: .utf8) {
            fileHandle?.write(data)
        }
    }

    nonisolated static func info(_ m: String)  { line("ℹ️ \(m)") }
    nonisolated static func warn(_ m: String)  { line("⚠️ \(m)") }
    nonisolated static func error(_ m: String) { line("❌ \(m)") }
    nonisolated static func ok(_ m: String)    { line("✅ \(m)") }
}
