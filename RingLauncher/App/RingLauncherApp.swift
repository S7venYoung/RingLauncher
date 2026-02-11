import SwiftUI
import AppKit

@main
struct RingLauncherApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    var body: some Scene {
        Settings { EmptyView() }
    }
}

class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // 1. 在右上角创建一个菜单栏图标
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem?.button {
            // 使用系统自带的圆形图标
            button.image = NSImage(systemSymbolName: "circle.circle", accessibilityDescription: "RingLauncher")
        }
        
        // 2. 创建下拉菜单
        let menu = NSMenu()
        // 增加一个“手动显示”按钮，用来测试窗口逻辑是否正常
        menu.addItem(NSMenuItem(title: "手动显示 (Show)", action: #selector(manualShow), keyEquivalent: "s"))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "退出 (Quit)", action: #selector(quitApp), keyEquivalent: "q"))
        statusItem?.menu = menu

        // 3. 核心：监听全局按键 (Option 键)
        // 注意：这行代码必须有“辅助功能”权限才能生效！
        NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { event in
            if event.modifierFlags.contains(.option) {
                print("按下 Option，尝试显示窗口")
                WindowManager.shared.show()
            } else {
                print("松开 Option，隐藏窗口")
                WindowManager.shared.hide()
            }
        }
    }

    @objc func manualShow() {
        // 手动点击菜单栏显示，用于排除按键监听问题
        WindowManager.shared.show()
    }

    @objc func quitApp() {
        NSApplication.shared.terminate(nil)
    }
}
