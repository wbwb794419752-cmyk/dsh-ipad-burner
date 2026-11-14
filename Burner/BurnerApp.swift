//
//  BurnerApp.swift
//  Burner
//
//  SwiftUI 入口。App 启动即自动开始烤机（专用 App，不需要启动门）。
//

import SwiftUI

@main
struct BurnerApp: App {

    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var engine = BurnerEngine()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            ContentView(engine: engine)
                .statusBarHidden(true)
                .persistentSystemOverlays(.hidden)   // 顺带把 Home 指示条压暗
                .preferredColorScheme(.light)
                .onChange(of: scenePhase) { _, phase in
                    switch phase {
                    case .active:
                        engine.handleForeground()
                    case .inactive:
                        break
                    case .background:
                        engine.handleBackground()
                    @unknown default:
                        break
                    }
                }
        }
    }
}
