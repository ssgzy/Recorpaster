//
//  RecorpasterApp.swift
//  Recorpaster
//
//  入口：无默认窗口（用空 Settings 场景），全部 UI 由 AppDelegate → AppController 驱动。
//

import SwiftUI

@main
struct RecorpasterApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        Settings {
            EmptyView()
        }
    }
}
