import AppKit
import SwiftUI

class WindowManager: ObservableObject {
    static let shared = WindowManager()
    var window: NSPanel?
    var isVisible: Bool = false
    
    // 核心修复：增加这个变量来记录当前选中的功能名称
    var currentSelection: String = ""

    func show() {
        if window == nil {
            let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 400, height: 400),
                                styleMask: [.borderless, .nonactivatingPanel],
                                backing: .buffered, defer: false)
            panel.level = .mainMenu
            panel.backgroundColor = .clear
            panel.isOpaque = false
            // 确保这里加载的是你的圆环视图
            panel.contentView = NSHostingView(rootView: RingMenuView())
            self.window = panel
        }
        
        let mouse = NSEvent.mouseLocation
        // 居中显示在鼠标位置
        window?.setFrameOrigin(NSPoint(x: mouse.x - 200, y: mouse.y - 200))
        window?.makeKeyAndOrderFront(nil)
        isVisible = true
    }

    func hide() {
        window?.orderOut(nil)
        isVisible = false
    }
}
