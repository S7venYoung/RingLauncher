import AppKit
import Carbon
import IOKit.hid
import OSLog
import ServiceManagement
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
    private let surfaceDial = SurfaceDialManager.shared

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        controller = RingPanelController()
        registerHotKey()
        configureSurfaceDial()
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
            self?.configureSurfaceDial()
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

    private func configureSurfaceDial() {
        surfaceDial.onRotation = { [weak self] direction in
            self?.controller?.handleSurfaceDialRotation(direction)
        }
        surfaceDial.onButtonChanged = { [weak self] pressed in
            self?.controller?.handleSurfaceDialButton(pressed: pressed)
        }
        if AppSettings.shared.surfaceDialEnabled {
            surfaceDial.start()
        } else {
            surfaceDial.stop()
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
    @Published var wheelStepSize: Int {
        didSet { UserDefaults.standard.set(wheelStepSize, forKey: Keys.wheelStepSize) }
    }
    @Published var wheelDebounceMilliseconds: Int {
        didSet { UserDefaults.standard.set(wheelDebounceMilliseconds, forKey: Keys.wheelDebounce) }
    }
    @Published var ringScale: Double {
        didSet { UserDefaults.standard.set(ringScale, forKey: Keys.ringScale) }
    }
    @Published var iconSize: Double {
        didSet { UserDefaults.standard.set(iconSize, forKey: Keys.iconSize) }
    }
    @Published var animationsEnabled: Bool {
        didSet { UserDefaults.standard.set(animationsEnabled, forKey: Keys.animations) }
    }
    @Published var soundEnabled: Bool {
        didSet { UserDefaults.standard.set(soundEnabled, forKey: Keys.sound) }
    }
    @Published var appearance: String {
        didSet { UserDefaults.standard.set(appearance, forKey: Keys.appearance) }
    }
    @Published var showItemNames: Bool {
        didSet { UserDefaults.standard.set(showItemNames, forKey: Keys.showItemNames) }
    }
    @Published var secondRingEnabled: Bool {
        didSet { UserDefaults.standard.set(secondRingEnabled, forKey: Keys.secondRingEnabled) }
    }
    @Published var surfaceDialEnabled: Bool {
        didSet {
            UserDefaults.standard.set(surfaceDialEnabled, forKey: Keys.surfaceDialEnabled)
            NotificationCenter.default.post(name: .orbitSettingsChanged, object: nil)
        }
    }
    @Published var surfaceDialStepsPerRotation: Int {
        didSet {
            UserDefaults.standard.set(
                surfaceDialStepsPerRotation,
                forKey: Keys.surfaceDialStepsPerRotation
            )
        }
    }
    @Published private(set) var launchAtLogin: Bool

    private enum Keys {
        static let hotKeyCode = "hotKeyCode"
        static let hotKeyModifiers = "hotKeyModifiers"
        static let wheelStepSize = "wheelStepSize"
        static let wheelDebounce = "wheelDebounceMilliseconds"
        static let ringScale = "ringScale"
        static let iconSize = "iconSize"
        static let animations = "animationsEnabled"
        static let sound = "soundEnabled"
        static let appearance = "appearance"
        static let showItemNames = "showItemNames"
        static let secondRingEnabled = "secondRingEnabled"
        static let surfaceDialEnabled = "surfaceDialEnabled"
        static let surfaceDialStepsPerRotation = "surfaceDialStepsPerRotation"
    }

    private init() {
        let defaults = UserDefaults.standard
        hotKeyCode = defaults.object(forKey: Keys.hotKeyCode) as? Int ?? kVK_Space
        hotKeyModifiers = defaults.object(forKey: Keys.hotKeyModifiers) as? Int ?? optionKey
        wheelStepSize = defaults.object(forKey: Keys.wheelStepSize) as? Int ?? 1
        wheelDebounceMilliseconds = defaults.object(forKey: Keys.wheelDebounce) as? Int ?? 60
        ringScale = defaults.object(forKey: Keys.ringScale) as? Double ?? 1
        iconSize = defaults.object(forKey: Keys.iconSize) as? Double ?? 56
        animationsEnabled = defaults.object(forKey: Keys.animations) as? Bool ?? true
        soundEnabled = defaults.object(forKey: Keys.sound) as? Bool ?? true
        appearance = defaults.string(forKey: Keys.appearance) ?? "system"
        showItemNames = defaults.object(forKey: Keys.showItemNames) as? Bool ?? true
        secondRingEnabled = defaults.object(forKey: Keys.secondRingEnabled) as? Bool ?? true
        surfaceDialEnabled = defaults.object(forKey: Keys.surfaceDialEnabled) as? Bool ?? true
        surfaceDialStepsPerRotation =
            defaults.object(forKey: Keys.surfaceDialStepsPerRotation) as? Int ?? 20
        launchAtLogin = SMAppService.mainApp.status == .enabled
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

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            launchAtLogin = enabled
        } catch {
            launchAtLogin = SMAppService.mainApp.status == .enabled
        }
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
    @ObservedObject private var surfaceDial = SurfaceDialManager.shared

    var body: some View {
        TabView {
            Form {
                Section("应用") {
                    Toggle(
                        "登录时启动",
                        isOn: Binding(
                            get: { settings.launchAtLogin },
                            set: { settings.setLaunchAtLogin($0) }
                        )
                    )
                    Text("第一环显示正在运行的应用；选择应用后进入快捷操作环。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("操作") {
                    Toggle("启用第二层快捷操作", isOn: $settings.secondRingEnabled)
                    Toggle("切换时播放音效", isOn: $settings.soundEnabled)
                    Toggle("启用过渡动画", isOn: $settings.animationsEnabled)
                    Text(
                        settings.secondRingEnabled
                            ? "确认应用后进入快捷操作环，默认选择“切换当前窗口”。"
                            : "确认应用后直接切换或打开该应用。"
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            .tabItem { Label("通用", systemImage: "gearshape") }

            Form {
                Section("圆环尺寸") {
                    HStack {
                        Text("面板")
                        Slider(value: $settings.ringScale, in: 0.75...1.15, step: 0.05)
                        Text(String(format: "%.2f×", settings.ringScale))
                            .monospacedDigit()
                            .frame(width: 52)
                    }
                    HStack {
                        Text("图标")
                        Slider(value: $settings.iconSize, in: 40...72, step: 2)
                        Text("\(Int(settings.iconSize)) pt")
                            .monospacedDigit()
                            .frame(width: 52)
                    }
                }

                Section("外观") {
                    Picker("配色", selection: $settings.appearance) {
                        Text("跟随系统").tag("system")
                        Text("浅色").tag("light")
                        Text("深色").tag("dark")
                    }
                    .pickerStyle(.segmented)
                    Toggle("显示应用与操作名称", isOn: $settings.showItemNames)
                }
            }
            .formStyle(.grouped)
            .tabItem { Label("外观", systemImage: "circle.lefthalf.filled") }

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
                        "每格切换：\(settings.wheelStepSize) 个项目",
                        value: $settings.wheelStepSize,
                        in: 1...3
                    )
                    HStack {
                        Text("最快连续切换间隔")
                        Slider(
                            value: Binding(
                                get: { Double(settings.wheelDebounceMilliseconds) },
                                set: { settings.wheelDebounceMilliseconds = Int($0) }
                            ),
                            in: 20...300,
                            step: 10
                        )
                        Text("\(settings.wheelDebounceMilliseconds) ms")
                            .monospacedDigit()
                            .frame(width: 64, alignment: .trailing)
                    }
                    Text("应用会识别每个格位的滚轮加速峰值。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("Surface Dial（实验性）") {
                    Toggle("启用原始 HID 支持", isOn: $settings.surfaceDialEnabled)
                    Stepper(
                        "每圈步数：\(settings.surfaceDialStepsPerRotation)",
                        value: $settings.surfaceDialStepsPerRotation,
                        in: 10...40,
                        step: 2
                    )
                    HStack {
                        Circle()
                            .fill(surfaceDial.isConnected ? Color.green : Color.secondary.opacity(0.45))
                            .frame(width: 8, height: 8)
                        Text(surfaceDial.isConnected ? "Surface Dial 已连接" : "等待 Surface Dial（045E:091B）")
                        Spacer()
                    }
                    Text("圆环隐藏时第一次旋转只负责呼出；继续旋转选择，按下立即确认。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section {
                    Text("Esc 返回上一环；回车或松开鼠标执行当前高亮项。")
                        .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            .tabItem { Label("输入", systemImage: "keyboard") }
        }
        .padding(12)
        .frame(width: 560, height: 390)
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
    private var lastWheelEventTime: TimeInterval = 0
    private var wheelBurstDirection = 0
    private var lastWheelMagnitude: CGFloat = 0
    private var wheelPeakMagnitude: CGFloat = 0
    private var wheelDetectorArmed = true
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

    func handleSurfaceDialRotation(_ direction: Int) {
        if !panel.isVisible {
            show()
            logger.notice("Surface Dial rotation opened ring")
            return
        }
        model.moveSelection(by: direction)
        logger.notice("Surface Dial rotation direction=\(direction, privacy: .public) selection=\(self.model.selectedIndex, privacy: .public)")
    }

    func handleSurfaceDialButton(pressed: Bool) {
        guard pressed else { return }
        if panel.isVisible {
            model.performSelected()
        } else {
            show()
        }
    }

    private func show() {
        NSApp.activate(ignoringOtherApps: true)
        model.reloadApps()
        model.goBack()
        model.resetSelection()
        model.presentationID = UUID()

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

            let now = Date.timeIntervalSinceReferenceDate
            let direction = delta > 0 ? 1 : -1
            let magnitude = abs(delta)
            let newSequence =
                now - lastWheelEventTime >= 0.12 ||
                direction != wheelBurstDirection

            if newSequence {
                lastWheelMagnitude = 0
                wheelPeakMagnitude = 0
                wheelDetectorArmed = true
                wheelBurstDirection = direction
            }
            lastWheelEventTime = now

            guard event.momentumPhase.isEmpty else { return true }

            wheelPeakMagnitude = max(wheelPeakMagnitude, magnitude)

            // Rearm after the current detent has fallen below roughly half of
            // its peak. A new rising edge then represents the next detent,
            // even when the wheel never becomes completely idle.
            if !wheelDetectorArmed,
               magnitude <= max(1, wheelPeakMagnitude * 0.48) {
                wheelDetectorArmed = true
                wheelPeakMagnitude = magnitude
            }

            let risingEdge =
                newSequence ||
                magnitude >= max(2, lastWheelMagnitude * 1.35)
            let minimumInterval =
                Double(AppSettings.shared.wheelDebounceMilliseconds) / 1_000

            if wheelDetectorArmed,
               risingEdge,
               now - lastWheelSelectionTime >= minimumInterval {
                let directionStep = direction > 0 ? -1 : 1
                let step = directionStep * AppSettings.shared.wheelStepSize
                model.moveSelection(by: step)
                lastWheelSelectionTime = now
                wheelDetectorArmed = false
                logger.notice(
                    "Wheel detent source=\(source, privacy: .public) delta=\(Double(delta), privacy: .public) intervalMs=\(self.settingsInterval, privacy: .public) step=\(step, privacy: .public) selection=\(self.model.selectedIndex, privacy: .public)"
                )
            }
            lastWheelMagnitude = magnitude
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
        lastWheelEventTime = 0
        wheelBurstDirection = 0
        lastWheelMagnitude = 0
        wheelPeakMagnitude = 0
        wheelDetectorArmed = true
        lastWheelSelectionTime = 0
    }

    private var settingsInterval: Int { AppSettings.shared.wheelDebounceMilliseconds }
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
    @Published var presentationID = UUID()
    var dismiss: (() -> Void)?

    var items: [RingItem] {
        if let selectedApp {
            return actions(for: selectedApp)
        }
        return apps.map { app in
            RingItem(id: app.id, title: app.name, icon: app.icon) { [weak self] in
                self?.selectApp(app)
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

    private func selectApp(_ app: RunningApp) {
        if AppSettings.shared.secondRingEnabled {
            selectedApp = app
            selectedIndex = 0
        } else {
            app.application.activate(options: [.activateAllWindows])
            dismiss?()
        }
    }

    func moveSelection(by step: Int) {
        guard !items.isEmpty else { return }
        selectedIndex = (selectedIndex + step + items.count) % items.count
        playSelectionSound()
    }

    func performSelected() {
        guard items.indices.contains(selectedIndex) else { return }
        items[selectedIndex].action()
    }

    func select(_ id: String) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        guard selectedIndex != index else { return }
        selectedIndex = index
        playSelectionSound()
    }

    func select(index: Int) {
        guard items.indices.contains(index), selectedIndex != index else { return }
        selectedIndex = index
        playSelectionSound()
    }

    private func playSelectionSound() {
        guard AppSettings.shared.soundEnabled else { return }
        NSSound(named: "Tink")?.play()
    }

    private func actions(for app: RunningApp) -> [RingItem] {
        let activate = RingItem(
            id: "\(app.id)-activate",
            title: "切换当前窗口",
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
    @ObservedObject private var settings = AppSettings.shared
    @State private var appeared = false

    private var diameter: CGFloat { 560 * settings.ringScale }
    private var itemRadius: CGFloat { 210 * settings.ringScale }
    private var innerDiameter: CGFloat { 174 * settings.ringScale }
    private var preferredScheme: ColorScheme? {
        switch settings.appearance {
        case "light": return .light
        case "dark": return .dark
        default: return nil
        }
    }

    var body: some View {
        ZStack {
            Color.black.opacity(0.001)
                .contentShape(Rectangle())
                .onTapGesture { model.dismiss?() }

            Circle()
                .fill(.ultraThinMaterial)
                .shadow(color: .black.opacity(0.28), radius: 30, y: 14)
                .frame(width: diameter, height: diameter)

            ForEach(Array(model.items.enumerated()), id: \.element.id) { index, _ in
                segment(index: index, count: model.items.count)
            }

            Circle()
                .fill(.ultraThickMaterial)
                .overlay(Circle().stroke(.white.opacity(0.32), lineWidth: 1))
                .shadow(color: .black.opacity(0.18), radius: 12, y: 4)
                .frame(width: innerDiameter, height: innerDiameter)
                .onTapGesture { model.escape() }

            VStack(spacing: 7) {
                Image(systemName: model.selectedApp == nil ? "circle.grid.3x3.fill" : "bolt.fill")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(.secondary)
                Text(model.centerTitle)
                    .font(.system(size: 17, weight: .semibold))
                    .multilineTextAlignment(.center)
                Text(model.selectedApp == nil ? "滚轮选择 · 回车确认" : "点击中心返回")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.tertiary)
            }

            ForEach(Array(model.items.enumerated()), id: \.element.id) { index, item in
                ringButton(item, index: index, count: model.items.count)
            }
        }
        .frame(width: 700, height: 700)
        .scaleEffect(appeared ? 1 : 0.82)
        .opacity(appeared ? 1 : 0)
        .preferredColorScheme(preferredScheme)
        .animation(
            settings.animationsEnabled ? .spring(response: 0.28, dampingFraction: 0.82) : nil,
            value: appeared
        )
        .animation(
            settings.animationsEnabled ? .easeOut(duration: 0.13) : nil,
            value: model.selectedIndex
        )
        .onAppear { reveal() }
        .onChange(of: model.presentationID) { _ in reveal() }
        .simultaneousGesture(radialSelectionGesture)
    }

    private func reveal() {
        appeared = false
        DispatchQueue.main.async {
            appeared = true
        }
    }

    private func segment(index: Int, count: Int) -> some View {
        let slice = 360 / Double(max(count, 1))
        let center = -90 + Double(index) * slice
        let selected = model.selectedIndex == index

        return RingSegment(
            startAngle: .degrees(center - slice / 2),
            endAngle: .degrees(center + slice / 2),
            innerRatio: innerDiameter / diameter
        )
        .fill(
            selected
                ? Color.accentColor.opacity(0.30)
                : Color.primary.opacity(index.isMultiple(of: 2) ? 0.035 : 0.018)
        )
        .overlay {
            RingSegment(
                startAngle: .degrees(center - slice / 2),
                endAngle: .degrees(center + slice / 2),
                innerRatio: innerDiameter / diameter
            )
            .stroke(.white.opacity(selected ? 0.55 : 0.16), lineWidth: selected ? 1.5 : 0.7)
        }
        .frame(width: diameter, height: diameter)
    }

    private func ringButton(_ item: RingItem, index: Int, count: Int) -> some View {
        let angle = Angle.degrees(Double(index) / Double(max(count, 1)) * 360 - 90)
        let x = cos(angle.radians) * itemRadius
        let y = sin(angle.radians) * itemRadius

        return Button(action: item.action) {
            VStack(spacing: 7) {
                ZStack {
                    Circle()
                        .fill(model.selectedIndex == index ? Color.white.opacity(0.22) : .clear)
                        .frame(width: settings.iconSize + 18, height: settings.iconSize + 18)
                    if let icon = item.icon {
                        Image(nsImage: icon)
                            .resizable()
                            .scaledToFit()
                            .frame(width: settings.iconSize, height: settings.iconSize)
                            .shadow(color: .black.opacity(0.22), radius: 5, y: 3)
                    } else {
                        Image(systemName: item.symbol ?? "circle")
                            .font(.system(size: settings.iconSize * 0.58, weight: .medium))
                            .frame(width: settings.iconSize, height: settings.iconSize)
                    }
                }
                if settings.showItemNames {
                    Text(item.title)
                        .font(.system(size: 14, weight: .medium))
                        .lineLimit(1)
                        .frame(width: 100)
                        .transition(.opacity.combined(with: .scale(scale: 0.9)))
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            if hovering { model.select(item.id) }
        }
        .offset(x: x, y: y)
    }

    private var radialSelectionGesture: some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .local)
            .onChanged { value in
                guard let index = radialIndex(at: value.location) else { return }
                model.select(index: index)
            }
            .onEnded { value in
                guard radialIndex(at: value.location) != nil else { return }
                model.performSelected()
            }
    }

    private func radialIndex(at location: CGPoint) -> Int? {
        let center = CGPoint(x: 350, y: 350)
        let dx = location.x - center.x
        let dy = location.y - center.y
        let radius = hypot(dx, dy)
        guard radius >= innerDiameter / 2, radius <= diameter / 2 else { return nil }
        guard !model.items.isEmpty else { return nil }

        var angle = Double(atan2(dy, dx)) + Double.pi / 2
        if angle < 0 { angle += 2 * Double.pi }
        let slice = 2 * Double.pi / Double(model.items.count)
        return min(Int(angle / slice), model.items.count - 1)
    }
}

struct RingSegment: Shape {
    let startAngle: Angle
    let endAngle: Angle
    let innerRatio: CGFloat

    func path(in rect: CGRect) -> Path {
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let outerRadius = min(rect.width, rect.height) / 2
        let innerRadius = outerRadius * innerRatio
        var path = Path()
        path.addArc(
            center: center,
            radius: outerRadius,
            startAngle: startAngle,
            endAngle: endAngle,
            clockwise: false
        )
        path.addArc(
            center: center,
            radius: innerRadius,
            startAngle: endAngle,
            endAngle: startAngle,
            clockwise: true
        )
        path.closeSubpath()
        return path
    }
}
