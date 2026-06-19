//
//  Settings.swift
//  Recorpaster
//
//  配置存储（读写 config.json，损坏→默认不崩，改动即存）+ 开机自启（SMAppService）。
//

import Foundation
import SwiftUI
import Combine
import ServiceManagement

@MainActor
final class ConfigStore: ObservableObject {
    /// 单一真相源。改动即存并回调 AppController 热生效（didSet 不在 init 时触发，故初次加载不误存）。
    @Published var config: Config {
        didSet {
            guard config != oldValue else { return }
            save()
            onChange?(oldValue, config)
        }
    }
    /// 配置变更回调（旧, 新）——AppController 据此对比、只对变了的项热生效。
    var onChange: ((Config, Config) -> Void)?

    private static let url: URL = FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Recorpaster/config.json")

    init() { config = ConfigStore.load() }

    /// 读 JSON；缺失/损坏 → 默认值，绝不崩。
    private static func load() -> Config {
        guard let data = try? Data(contentsOf: url) else { return .default }
        do {
            return try JSONDecoder().decode(Config.self, from: data)
        } catch {
            Log.warn("config.json 解析失败，用默认值：\(error)")
            return .default
        }
    }

    /// 改动即存（原子写；失败不崩）。
    private func save() {
        do {
            try FileManager.default.createDirectory(
                at: Self.url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
            try enc.encode(config).write(to: Self.url, options: .atomic)
        } catch {
            Log.error("config.json 写入失败：\(error)")
        }
    }
}

// MARK: - 开机自启（SMAppService.mainApp）

enum LoginItem {
    static var isEnabled: Bool {
        if #available(macOS 13.0, *) { return SMAppService.mainApp.status == .enabled }
        return false
    }
    static func set(_ on: Bool) {
        guard #available(macOS 13.0, *) else { return }
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            Log.error("开机自启\(on ? "注册" : "注销")失败：\(error)")
        }
    }
}
