import AppKit
import SwiftUI

class WindowManager: ObservableObject {
    static let shared = WindowManager()
    var window: NSPanel?

    func show() {
        if window == nil {
            let panel = NSPanel(
                contentRect: .zero,
                styleMask: [.nonactivatingPanel, .fullSizeContentView],
                backing: .buffered, defer: false)
            
            panel.isFloatingPanel = true
            panel.level = .mainMenu
            panel.backgroundColor = .clear
            panel.isOpaque = false
            panel.hasShadow = false
            
            let contentView = RingMenuView()
            panel.contentView = NSHostingView(rootView: contentView)
            self.window = panel
        }
        
        // 将窗口中心对准当前鼠标位置
        let mouseLocation = NSEvent.mouseLocation
        let windowSize = CGSize(width: 400, height: 400)
        let rect = NSRect(
            x: mouseLocation.x - windowSize.width / 2,
            y: mouseLocation.y - windowSize.height / 2,
            width: windowSize.width,
            height: windowSize.height
        )
        
        window?.setFrame(rect, display: true)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func hide() {
        window?.orderOut(nil)
    }
}