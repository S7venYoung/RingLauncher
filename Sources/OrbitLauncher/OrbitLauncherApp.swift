import AppKit
import Carbon
import OSLog
import SwiftUI

@main
struct OrbitLauncherApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var settings = AppSettings.shared

    var body: some Scene {
        MenuBarExtra("OrbitLauncher", systemImage: "circle.hexagongrid") {
            Button("显示圆环  \(settings.shortcutText)") {
                NotificationCenter.default.post(name: .toggleOrbitLauncher, object: nil)
            }
            Divider()
            if #available(macOS 14.0, *) {
                SettingsLink {
                    Text("设置…")
                }
            } else {
                Button("设置…") {
                    NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
                }
            }
            Divider()
            Button("退出 OrbitLauncher") {
                NSApp.terminate(nil)
            }
        }

        Settings {
            SettingsView(settings: settings)
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var controller: RingPanelController?
    private var hotKey: GlobalHotKey?
    private var toggleObserver: NSObjectProtocol?
    private var settingsObserver: NSObjectProtocol?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        controller = RingPanelController()
        registerHotKey()
        toggleObserver = NotificationCenter.default.addObserver(
            forName: .toggleOrbitLauncher,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.controller?.toggle()
        }
        settingsObserver = NotificationCenter.default.addObserver(
            forName: .orbitSettingsChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.registerHotKey()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let toggleObserver {
            NotificationCenter.default.removeObserver(toggleObserver)
        }
        if let settingsObserver {
            NotificationCenter.default.removeObserver(settingsObserver)
        }
    }

    private func registerHotKey() {
        let settings = AppSettings.shared
        hotKey = GlobalHotKey(
            keyCode: UInt32(settings.hotKeyCode),
            modifiers: UInt32(settings.hotKeyModifiers)
        ) { [weak self] in
            DispatchQueue.main.async {
                self?.controller?.toggle()
            }
        }
    }
}

extension Notification.Name {
    static let toggleOrbitLauncher = Notification.Name("toggleOrbitLauncher")
    static let orbitSettingsChanged = Notification.Name("orbitSettingsChanged")
}

@MainActor
final class AppSettings: ObservableObject {
    static let shared = AppSettings()

    @Published var hotKeyCode: Int {
        didSet { saveShortcut() }
    }
    @Published var hotKeyModifiers: Int {
        didSet { saveShortcut() }
    }
    @Published var wheelPulsesPerStep: Int {
        didSet { UserDefaults.standard.set(wheelPulsesPerStep, forKey: Keys.wheelPulses) }
    }
    @Published var wheelDebounceMilliseconds: Int {
        didSet { UserDefaults.standard.set(wheelDebounceMilliseconds, forKey: Keys.wheelDebounce) }
    }

    private enum Keys {
        static let hotKeyCode = "hotKeyCode"
        static let hotKeyModifiers = "hotKeyModifiers"
        static let wheelPulses = "wheelPulsesPerStep"
        static let wheelDebounce = "wheelDebounceMilliseconds"
    }

    private init() {
        let defaults = UserDefaults.standard
        hotKeyCode = defaults.object(forKey: Keys.hotKeyCode) as? Int ?? kVK_Space
        hotKeyModifiers = defaults.object(forKey: Keys.hotKeyModifiers) as? Int ?? optionKey
        wheelPulsesPerStep = defaults.object(forKey: Keys.wheelPulses) as? Int ?? 4
        wheelDebounceMilliseconds = defaults.object(forKey: Keys.wheelDebounce) as? Int ?? 180
    }

    var shortcutText: String {
        let modifier = HotKeyModifier.options.first(where: { $0.value == hotKeyModifiers })?.label ?? "⌥"
        let key = HotKeyKey.options.first(where: { $0.code == hotKeyCode })?.label ?? "Space"
        return modifier + key
    }

    private func saveShortcut() {
        UserDefaults.standard.set(hotKeyCode, forKey: Keys.hotKeyCode)
        UserDefaults.standard.set(hotKeyModifiers, forKey: Keys.hotKeyModifiers)
        NotificationCenter.default.post(name: .orbitSettingsChanged, object: nil)
    }
}

struct HotKeyModifier: Identifiable {
    let value: Int
    let label: String
    var id: Int { value }

    static let options: [HotKeyModifier] = [
        .init(value: optionKey, label: "⌥"),
        .init(value: cmdKey, label: "⌘"),
        .init(value: controlKey, label: "⌃"),
        .init(value: shiftKey, label: "⇧"),
        .init(value: optionKey | cmdKey, label: "⌥⌘"),
        .init(value: controlKey | optionKey, label: "⌃⌥"),
        .init(value: controlKey | cmdKey, label: "⌃⌘"),
        .init(value: shiftKey | optionKey, label: "⇧⌥"),
        .init(value: shiftKey | cmdKey, label: "⇧⌘")
    ]
}

struct HotKeyKey: Identifiable {
    let code: Int
    let label: String
    var id: Int { code }

    static let options: [HotKeyKey] = [
        .init(code: kVK_Space, label: "Space"),
        .init(code: kVK_ANSI_A, label: "A"), .init(code: kVK_ANSI_B, label: "B"),
        .init(code: kVK_ANSI_C, label: "C"), .init(code: kVK_ANSI_D, label: "D"),
        .init(code: kVK_ANSI_E, label: "E"), .init(code: kVK_ANSI_F, label: "F"),
        .init(code: kVK_ANSI_G, label: "G"), .init(code: kVK_ANSI_H, label: "H"),
        .init(code: kVK_ANSI_I, label: "I"), .init(code: kVK_ANSI_J, label: "J"),
        .init(code: kVK_ANSI_K, label: "K"), .init(code: kVK_ANSI_L, label: "L"),
        .init(code: kVK_ANSI_M, label: "M"), .init(code: kVK_ANSI_N, label: "N"),
        .init(code: kVK_ANSI_O, label: "O"), .init(code: kVK_ANSI_P, label: "P"),
        .init(code: kVK_ANSI_Q, label: "Q"), .init(code: kVK_ANSI_R, label: "R"),
        .init(code: kVK_ANSI_S, label: "S"), .init(code: kVK_ANSI_T, label: "T"),
        .init(code: kVK_ANSI_U, label: "U"), .init(code: kVK_ANSI_V, label: "V"),
        .init(code: kVK_ANSI_W, label: "W"), .init(code: kVK_ANSI_X, label: "X"),
        .init(code: kVK_ANSI_Y, label: "Y"), .init(code: kVK_ANSI_Z, label: "Z"),
        .init(code: kVK_F1, label: "F1"), .init(code: kVK_F2, label: "F2"),
        .init(code: kVK_F3, label: "F3"), .init(code: kVK_F4, label: "F4"),
        .init(code: kVK_F5, label: "F5"), .init(code: kVK_F6, label: "F6"),
        .init(code: kVK_F7, label: "F7"), .init(code: kVK_F8, label: "F8"),
        .init(code: kVK_F9, label: "F9"), .init(code: kVK_F10, label: "F10"),
        .init(code: kVK_F11, label: "F11"), .init(code: kVK_F12, label: "F12")
    ]
}

struct SettingsView: View {
    @ObservedObject var settings: AppSettings

    var body: some View {
        Form {
            Section("启动快捷键") {
                HStack {
                    Picker("修饰键", selection: $settings.hotKeyModifiers) {
                        ForEach(HotKeyModifier.options) { option in
                            Text(option.label).tag(option.value)
                        }
                    }
                    Picker("主键", selection: $settings.hotKeyCode) {
                        ForEach(HotKeyKey.options) { key in
                            Text(key.label).tag(key.code)
                        }
                    }
                    Text(settings.shortcutText)
                        .font(.system(.body, design: .monospaced).bold())
                        .frame(minWidth: 70)
                }
            }

            Section("编码器与滚轮") {
                Stepper(
                    "每切换一项：\(settings.wheelPulsesPerStep) 个滚轮脉冲",
                    value: $settings.wheelPulsesPerStep,
                    in: 1...30
                )
                HStack {
                    Text("防抖间隔")
                    Slider(
                        value: Binding(
                            get: { Double(settings.wheelDebounceMilliseconds) },
                            set: { settings.wheelDebounceMilliseconds = Int($0) }
                        ),
                        in: 0...600,
                        step: 20
                    )
                    Text("\(settings.wheelDebounceMilliseconds) ms")
                        .monospacedDigit()
                        .frame(width: 64, alignment: .trailing)
                }
                Text("一格跳过多个项目时，提高脉冲数或防抖间隔。推荐从 4 个脉冲、180 ms 开始。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Text("按 Esc 返回上一环或关闭；按回车执行当前高亮项。")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding(16)
        .frame(width: 520, height: 340)
    }
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
    private let logger = Logger(
        subsystem: "com.s7venyoung.orbitlauncher",
        category: "Input"
    )
    private let model = RingModel()
    private let panel: RingPanel
    private var globalInputMonitor: Any?
    private var localInputMonitor: Any?
    private var scrollAccumulator: CGFloat = 0
    private var lastWheelSelectionTime: TimeInterval = 0

    init() {
        panel = RingPanel(
            contentRect: NSRect(x: 0, y: 0, width: 700, height: 700),
            styleMask: [.borderless],
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
        panel.makeKeyAndOrderFront(nil)
        logger.notice("Ring shown; keyWindow=\(self.panel.isKeyWindow, privacy: .public)")

        let eventMask: NSEvent.EventTypeMask = [.keyDown, .scrollWheel]

        globalInputMonitor = NSEvent.addGlobalMonitorForEvents(matching: eventMask) { [weak self] event in
            DispatchQueue.main.async {
                self?.handle(event, source: "global")
            }
        }

        localInputMonitor = NSEvent.addLocalMonitorForEvents(matching: eventMask) { [weak self] event in
            guard let self, self.panel.isVisible else { return event }
            if self.handle(event, source: "local") {
                return nil
            }
            return event
        }
    }

    @discardableResult
    private func handle(_ event: NSEvent, source: String) -> Bool {
        if event.type == .scrollWheel {
            let vertical = event.scrollingDeltaY
            let horizontal = event.scrollingDeltaX
            let delta = abs(vertical) >= abs(horizontal) ? vertical : horizontal
            guard delta != 0 else { return false }

            let normalizedDelta: CGFloat
            if event.hasPreciseScrollingDeltas {
                normalizedDelta = delta
            } else {
                normalizedDelta = delta > 0 ? 1 : -1
            }

            scrollAccumulator += normalizedDelta
            let threshold = CGFloat(AppSettings.shared.wheelPulsesPerStep)
            guard abs(scrollAccumulator) >= threshold else { return true }

            let now = Date.timeIntervalSinceReferenceDate
            let debounce = Double(AppSettings.shared.wheelDebounceMilliseconds) / 1_000
            guard now - lastWheelSelectionTime >= debounce else {
                scrollAccumulator = 0
                return true
            }

            let step = scrollAccumulator > 0 ? -1 : 1
            model.moveSelection(by: step)
            lastWheelSelectionTime = now
            logger.notice(
                "Wheel source=\(source, privacy: .public) delta=\(Double(delta), privacy: .public) pulses=\(self.settingsPulseCount, privacy: .public) debounceMs=\(self.settingsDebounce, privacy: .public) step=\(step, privacy: .public) selection=\(self.model.selectedIndex, privacy: .public)"
            )
            scrollAccumulator = 0
            return true
        }

        switch Int(event.keyCode) {
        case kVK_Escape:
            model.escape()
            return true
        case kVK_LeftArrow, kVK_UpArrow:
            model.moveSelection(by: -1)
            return true
        case kVK_RightArrow, kVK_DownArrow:
            model.moveSelection(by: 1)
            return true
        case kVK_Return, kVK_ANSI_KeypadEnter, kVK_Space:
            model.performSelected()
            return true
        default:
            return false
        }
    }

    private func hide() {
        panel.orderOut(nil)
        if let globalInputMonitor {
            NSEvent.removeMonitor(globalInputMonitor)
            self.globalInputMonitor = nil
        }
        if let localInputMonitor {
            NSEvent.removeMonitor(localInputMonitor)
            self.localInputMonitor = nil
        }
        scrollAccumulator = 0
        lastWheelSelectionTime = 0
    }

    private var settingsPulseCount: Int { AppSettings.shared.wheelPulsesPerStep }
    private var settingsDebounce: Int { AppSettings.shared.wheelDebounceMilliseconds }
}

final class RingPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
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
