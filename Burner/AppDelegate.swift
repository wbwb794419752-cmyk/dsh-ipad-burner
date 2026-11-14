//
//  AppDelegate.swift
//  Burner
//
//  只做三件事：启动即禁止锁屏、回到前台再禁一次、不注册任何音频会话。
//

import UIKit

final class AppDelegate: NSObject, UIApplicationDelegate {

    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        // 原生 API：进程级禁止自动锁屏，无需改系统设置、无需 Wake Lock
        // 注意：这里只在启动时设一次；用户点「停止」后由 BurnerEngine 负责关掉，
        // 所以不要在 applicationDidBecomeActive 里无脑重设。
        application.isIdleTimerDisabled = true
        return true
    }

    func applicationWillTerminate(_ application: UIApplication) {
        // 退出前把亮度恢复的活交给系统；这里只清标志，避免下次冷启动残留
        application.isIdleTimerDisabled = false
    }
}
