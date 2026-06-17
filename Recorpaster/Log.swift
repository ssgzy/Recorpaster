//
//  Log.swift
//  Recorpaster
//
//  打包后的 .app 无控制台，运行日志同时写到 ~/Library/Logs/Recorpaster.log（对应 Python 版
//  的 setup_logging / _Tee）。开发时也打到 Xcode 控制台。
//

import Foundation

enum Log {
    nonisolated(unsafe) private static let fileHandle: FileHandle? = {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs", isDirectory: true)
        let url = dir.appendingPathComponent("Recorpaster.log")
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        let h = try? FileHandle(forWritingTo: url)
        try? h?.seekToEnd()
        return h
    }()

    private static let lock = NSLock()

    static func line(_ message: String) {
        let stamp = ISO8601DateFormatter().string(from: Date())
        let text = "[\(stamp)] \(message)\n"
        print(message)
        lock.lock(); defer { lock.unlock() }
        if let data = text.data(using: .utf8) {
            fileHandle?.write(data)
        }
    }

    static func info(_ m: String)  { line("ℹ️ \(m)") }
    static func warn(_ m: String)  { line("⚠️ \(m)") }
    static func error(_ m: String) { line("❌ \(m)") }
    static func ok(_ m: String)    { line("✅ \(m)") }
}
