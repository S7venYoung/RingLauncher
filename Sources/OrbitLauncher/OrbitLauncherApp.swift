import AppKit
import Carbon
import SwiftUI

@main
struct OrbitLauncherApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra("OrbitLauncher", systemImage: "circle.hexagongrid") {
            Button("显示圆环  ⌥Space") {
                NotificationCenter.default.post(name: .toggleOrbitLauncher, object: nil)
            }
            Divider()
            Button("退出 OrbitLauncher") {
                NSApp.terminate(nil)
            }
        }

        Settings {
            VStack(alignment: .leading, spacing: 12) {
                Text("Orbit Launcher").font(.title2.bold())
                Text("按 ⌥Space 呼出圆环。")
                Text("Esc 返回上一层或关闭；再次按快捷键也可关闭。")
                    .foregroundStyle(.secondary)
            }
            .padding(24)
            .frame(width: 380)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var controller: RingPanelController?
    private var hotKey: GlobalHotKey?
    private var toggleObserver: NSObjectProtocol?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        controller = RingPanelController()
        hotKey = GlobalHotKey(keyCode: UInt32(kVK_Space), modifiers: UInt32(optionKey)) { [weak self] in
            self?.controller?.toggle()
        }
        toggleObserver = NotificationCenter.default.addObserver(
            forName: .toggleOrbitLauncher,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.controller?.toggle()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let toggleObserver {
            NotificationCenter.default.removeObserver(toggleObserver)
        }
    }
}

extension Notification.Name {
    static let toggleOrbitLauncher = Notification.Name("toggleOrbitLauncher")
}

final class GlobalHotKey {
    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    private let action: () -> Void

    init(keyCode: UInt32, modifiers: UInt32, action: @escaping () -> Void) {
        self.action = action

        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        InstallEventHandler(
            GetApplicationEventTarget(),
            { _, _, pointer in
                guard let pointer else { return noErr }
                let instance = Unmanaged<GlobalHotKey>.fromOpaque(pointer).takeUnretainedValue()
                instance.action()
                return noErr
            },
            1,
            &eventType,
            Unmanaged.passUnretained(self).toOpaque(),
            &handlerRef
        )

        var identifier = EventHotKeyID(signature: fourCC("ORBT"), id: 1)
        RegisterEventHotKey(
            keyCode,
            modifiers,
            identifier,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )
    }

    deinit {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        if let handlerRef { RemoveEventHandler(handlerRef) }
    }
}

private func fourCC(_ value: String) -> OSType {
    value.utf8.reduce(0) { ($0 << 8) + OSType($1) }
}

@MainActor
final class RingPanelController {
    private let model = RingModel()
    private let panel: NSPanel
    private var inputMonitor: Any?
    private var scrollAccumulator: CGFloat = 0

    init() {
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 700, height: 700),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .popUpMenu
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.hidesOnDeactivate = false
        panel.isMovable = false
        panel.contentView = NSHostingView(rootView: RingMenuView(model: model))

        model.dismiss = { [weak self] in self?.hide() }
    }

    func toggle() {
        panel.isVisible ? hide() : show()
    }

    private func show() {
        NSApp.activate(ignoringOtherApps: true)
        model.reloadApps()
        model.goBack()
        model.resetSelection()

        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first(where: { $0.frame.contains(mouse) }) ?? NSScreen.main
        guard let visibleFrame = screen?.visibleFrame else { return }
        let size = panel.frame.size
        let origin = NSPoint(
            x: min(max(mouse.x - size.width / 2, visibleFrame.minX), visibleFrame.maxX - size.width),
            y: min(max(mouse.y - size.height / 2, visibleFrame.minY), visibleFrame.maxY - size.height)
        )
        panel.setFrameOrigin(origin)
        panel.orderFrontRegardless()

        inputMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.keyDown, .scrollWheel]) { [weak self] event in
            DispatchQueue.main.async {
                self?.handle(event)
            }
        }
    }

    private func handle(_ event: NSEvent) {
        if event.type == .scrollWheel {
            scrollAccumulator += event.scrollingDeltaY
            guard abs(scrollAccumulator) >= 1 else { return }
            model.moveSelection(by: scrollAccumulator > 0 ? -1 : 1)
            scrollAccumulator = 0
            return
        }

        switch Int(event.keyCode) {
        case kVK_Escape:
            model.escape()
        case kVK_LeftArrow, kVK_UpArrow:
            model.moveSelection(by: -1)
        case kVK_RightArrow, kVK_DownArrow:
            model.moveSelection(by: 1)
        case kVK_Return, kVK_ANSI_KeypadEnter, kVK_Space:
            model.performSelected()
        default:
            break
        }
    }

    private func hide() {
        panel.orderOut(nil)
        if let inputMonitor {
            NSEvent.removeMonitor(inputMonitor)
            self.inputMonitor = nil
        }
    }
}

@MainActor
final class RingModel: ObservableObject {
    @Published var apps: [RunningApp] = []
    @Published var selectedApp: RunningApp?
    @Published var selectedIndex = 0
    var dismiss: (() -> Void)?

    var items: [RingItem] {
        if let selectedApp {
            return actions(for: selectedApp)
        }
        return apps.map { app in
            RingItem(id: app.id, title: app.name, icon: app.icon) { [weak self] in
                self?.selectedApp = app
            }
        }
    }

    var centerTitle: String {
        selectedApp.map { "\($0.name)\n快捷操作" } ?? "应用"
    }

    func reloadApps() {
        let frontmostPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        apps = NSWorkspace.shared.runningApplications
            .filter {
                $0.activationPolicy == .regular &&
                $0.processIdentifier != ProcessInfo.processInfo.processIdentifier
            }
            .sorted {
                if $0.processIdentifier == frontmostPID { return true }
                if $1.processIdentifier == frontmostPID { return false }
                return ($0.localizedName ?? "") < ($1.localizedName ?? "")
            }
            .prefix(10)
            .map(RunningApp.init)
    }

    func goBack() {
        selectedApp = nil
        selectedIndex = 0
    }

    func escape() {
        if selectedApp != nil { selectedApp = nil } else { dismiss?() }
        selectedIndex = 0
    }

    func resetSelection() {
        selectedIndex = 0
    }

    func moveSelection(by step: Int) {
        guard !items.isEmpty else { return }
        selectedIndex = (selectedIndex + step + items.count) % items.count
    }

    func performSelected() {
        guard items.indices.contains(selectedIndex) else { return }
        items[selectedIndex].action()
    }

    func select(_ id: String) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        selectedIndex = index
    }

    private func actions(for app: RunningApp) -> [RingItem] {
        let activate = RingItem(
            id: "\(app.id)-activate",
            title: "切换到",
            symbol: "arrow.up.forward.app"
        ) { [weak self] in
            app.application.activate(options: [.activateAllWindows])
            self?.dismiss?()
        }
        let hide = RingItem(
            id: "\(app.id)-hide",
            title: "隐藏",
            symbol: "eye.slash"
        ) { [weak self] in
            app.application.hide()
            self?.dismiss?()
        }
        let quit = RingItem(
            id: "\(app.id)-quit",
            title: "退出",
            symbol: "xmark.circle"
        ) { [weak self] in
            app.application.terminate()
            self?.dismiss?()
        }
        let windows = RingItem(
            id: "\(app.id)-windows",
            title: "所有窗口",
            symbol: "rectangle.stack"
        ) { [weak self] in
            app.application.activate(options: [.activateAllWindows])
            self?.dismiss?()
        }
        let back = RingItem(
            id: "\(app.id)-back",
            title: "返回",
            symbol: "arrow.uturn.backward"
        ) { [weak self] in self?.goBack() }
        return [activate, windows, hide, quit, back]
    }
}

struct RunningApp: Identifiable {
    let application: NSRunningApplication
    let id: String
    let name: String
    let icon: NSImage

    init(_ application: NSRunningApplication) {
        self.application = application
        id = application.bundleIdentifier ?? String(application.processIdentifier)
        name = application.localizedName ?? "未命名应用"
        icon = application.icon ?? NSImage(systemSymbolName: "app", accessibilityDescription: nil)!
    }
}

struct RingItem: Identifiable {
    let id: String
    let title: String
    let icon: NSImage?
    let symbol: String?
    let action: () -> Void

    init(id: String, title: String, icon: NSImage? = nil, symbol: String? = nil, action: @escaping () -> Void) {
        self.id = id
        self.title = title
        self.icon = icon
        self.symbol = symbol
        self.action = action
    }
}

struct RingMenuView: View {
    @ObservedObject var model: RingModel

    private let diameter: CGFloat = 560
    private let itemRadius: CGFloat = 210

    var body: some View {
        ZStack {
            Color.black.opacity(0.001)
                .contentShape(Rectangle())
                .onTapGesture { model.dismiss?() }

            Circle()
                .fill(.ultraThinMaterial)
                .overlay(Circle().stroke(.white.opacity(0.65), lineWidth: 1))
                .shadow(color: .black.opacity(0.22), radius: 28, y: 12)
                .frame(width: diameter, height: diameter)

            Circle()
                .fill(Color(nsColor: .windowBackgroundColor).opacity(0.84))
                .overlay(Circle().stroke(.primary.opacity(0.16), lineWidth: 1))
                .frame(width: 174, height: 174)
                .onTapGesture { model.escape() }

            Text(model.centerTitle)
                .font(.system(size: 18, weight: .semibold))
                .multilineTextAlignment(.center)
                .foregroundStyle(.primary)

            ForEach(Array(model.items.enumerated()), id: \.element.id) { index, item in
                ringButton(item, index: index, count: model.items.count)
            }
        }
        .frame(width: 700, height: 700)
    }

    private func ringButton(_ item: RingItem, index: Int, count: Int) -> some View {
        let angle = Angle.degrees(Double(index) / Double(max(count, 1)) * 360 - 90)
        let x = cos(angle.radians) * itemRadius
        let y = sin(angle.radians) * itemRadius

        return Button(action: item.action) {
            VStack(spacing: 7) {
                ZStack {
                    Circle()
                        .fill(model.selectedIndex == index ? Color.accentColor.opacity(0.24) : .clear)
                        .frame(width: 78, height: 78)
                    if let icon = item.icon {
                        Image(nsImage: icon)
                            .resizable()
                            .scaledToFit()
                            .frame(width: 58, height: 58)
                    } else {
                        Image(systemName: item.symbol ?? "circle")
                            .font(.system(size: 35, weight: .medium))
                            .frame(width: 58, height: 58)
                    }
                }
                Text(item.title)
                    .font(.system(size: 14, weight: .medium))
                    .lineLimit(1)
                    .frame(width: 100)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            if hovering { model.select(item.id) }
        }
        .offset(x: x, y: y)
    }
}
