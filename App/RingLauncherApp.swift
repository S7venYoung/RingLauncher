import SwiftUI

@main
struct RingLauncherApp: App {
    // 保持对 WindowManager 的引用
    let windowManager = WindowManager.shared

    var body: some Scene {
        Settings {
            Text("设置界面 - 你可以在这里配置快捷键")
                .frame(width: 300, height: 200)
        }
    }
}