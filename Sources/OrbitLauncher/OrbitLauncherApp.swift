import AppKit
import Carbon
import IOKit.hid
import OSLog
import ServiceManagement
import SwiftUI
import UniformTypeIdentifiers

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
    private var activeDialSecondLayerProfileID: UUID?
    private var dialSecondLayerExpiresAt: TimeInterval = 0
    private var pendingDialSinglePress: DispatchWorkItem?
    private var pendingDialLongPress: DispatchWorkItem?
    private var dialButtonIsDown = false
    private var dialLongPressDidFire = false
    private let dialDoublePressInterval: TimeInterval = 0.32
    private let dialLongPressInterval: TimeInterval = 0.65
    private let dialSecondLayerTimeout: TimeInterval = 5
    private let dialLogger = Logger(
        subsystem: "com.s7venyoung.orbitlauncher",
        category: "DialDirectControl"
    )

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        requestAccessibilityPermissionIfNeeded()
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
        let settings = AppSettings.shared
        surfaceDial.onRotation = { [weak self] direction in
            guard let self else { return }
            if AppSettings.shared.surfaceDialControlMode == "direct" {
                self.performDialShortcut(
                    direction > 0 ? .clockwise : .counterClockwise
                )
            } else {
                self.controller?.handleSurfaceDialRotation(direction)
            }
        }
        surfaceDial.onButtonChanged = { [weak self] pressed in
            guard let self else { return }
            if AppSettings.shared.surfaceDialControlMode == "direct" {
                self.handleDirectDialButtonChanged(pressed)
            } else {
                self.cancelDirectDialButtonGestures()
                if pressed {
                    self.controller?.handleSurfaceDialButton(pressed: true)
                }
            }
        }
        surfaceDial.setHapticsEnabled(settings.surfaceDialHapticsEnabled)
        surfaceDial.configureSleepPrevention(
            enabled: settings.surfaceDialPreventSleepEnabled,
            interval: settings.surfaceDialKeepAliveSeconds
        )
        if settings.surfaceDialEnabled {
            surfaceDial.start()
        } else {
            surfaceDial.stop()
        }
    }

    private func handleDirectDialButtonChanged(_ pressed: Bool) {
        if pressed {
            dialButtonIsDown = true
            dialLongPressDidFire = false
            pendingDialLongPress?.cancel()

            let longPress = DispatchWorkItem { [weak self] in
                guard let self, self.dialButtonIsDown else { return }
                self.pendingDialSinglePress?.cancel()
                self.pendingDialSinglePress = nil
                self.pendingDialLongPress = nil
                self.dialLongPressDidFire = true
                self.performDialShortcut(.longPress)
            }
            pendingDialLongPress = longPress
            DispatchQueue.main.asyncAfter(
                deadline: .now() + dialLongPressInterval,
                execute: longPress
            )
            return
        }

        dialButtonIsDown = false
        pendingDialLongPress?.cancel()
        pendingDialLongPress = nil

        if dialLongPressDidFire {
            dialLongPressDidFire = false
            return
        }

        if let pendingDialSinglePress {
            pendingDialSinglePress.cancel()
            self.pendingDialSinglePress = nil
            performDialShortcut(.doublePress)
            return
        }

        let singlePress = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.pendingDialSinglePress = nil
            self.performDialShortcut(.press)
        }
        pendingDialSinglePress = singlePress
        DispatchQueue.main.asyncAfter(
            deadline: .now() + dialDoublePressInterval,
            execute: singlePress
        )
    }

    private func cancelDirectDialButtonGestures() {
        pendingDialSinglePress?.cancel()
        pendingDialSinglePress = nil
        pendingDialLongPress?.cancel()
        pendingDialLongPress = nil
        dialButtonIsDown = false
        dialLongPressDidFire = false
    }

    private func performDialShortcut(_ action: DialControlAction) {
        let frontmostApplication = NSWorkspace.shared.frontmostApplication
        let bundleIdentifier = frontmostApplication?.bundleIdentifier
        let profile = AppSettings.shared.dialProfile(for: bundleIdentifier)
        let now = Date.timeIntervalSinceReferenceDate
        let secondLayerIsActive =
            activeDialSecondLayerProfileID == profile.id
            && now < dialSecondLayerExpiresAt
        if !secondLayerIsActive {
            activeDialSecondLayerProfileID = nil
            dialSecondLayerExpiresAt = 0
        }

        let layer = secondLayerIsActive ? 2 : 1
        let shortcut = profile.shortcut(for: action, layer: layer)
        if shortcut.resolvedKind == "enterSecondLayer" {
            activeDialSecondLayerProfileID = profile.id
            dialSecondLayerExpiresAt = now + dialSecondLayerTimeout
            dialLogger.notice(
                "Direct Dial entered second layer profile=\(profile.name, privacy: .public)"
            )
            return
        }
        if shortcut.resolvedKind == "exitSecondLayer" {
            activeDialSecondLayerProfileID = nil
            dialSecondLayerExpiresAt = 0
            dialLogger.notice(
                "Direct Dial exited second layer profile=\(profile.name, privacy: .public)"
            )
            return
        }

        if secondLayerIsActive {
            dialSecondLayerExpiresAt = now + dialSecondLayerTimeout
        }
        switch shortcut.resolvedKind {
        case "none":
            break
        case "scrollUp":
            postScrollWheel(lines: shortcut.resolvedScrollLines)
        case "scrollDown":
            postScrollWheel(lines: -shortcut.resolvedScrollLines)
        case "volumeUp":
            postSystemDefinedKey(0)
        case "volumeDown":
            postSystemDefinedKey(1)
        case "brightnessUp":
            postSystemDefinedKey(2)
        case "brightnessDown":
            postSystemDefinedKey(3)
        case "mute":
            postSystemDefinedKey(7)
        case "playPause":
            postSystemDefinedKey(16)
        case "nextTrack":
            postSystemDefinedKey(17)
        case "previousTrack":
            postSystemDefinedKey(18)
        case "missionControl":
            postKeyboardShortcut(
                DialShortcut(keyCode: kVK_UpArrow, modifiers: controlKey)
            )
        case "appExpose":
            postKeyboardShortcut(
                DialShortcut(keyCode: kVK_DownArrow, modifiers: controlKey)
            )
        case "showDesktop":
            postKeyboardShortcut(
                DialShortcut(keyCode: kVK_F11, modifiers: 0)
            )
        case "lockScreen":
            postKeyboardShortcut(
                DialShortcut(
                    keyCode: kVK_ANSI_Q,
                    modifiers: controlKey | cmdKey
                )
            )
        case "screenshot":
            postKeyboardShortcut(
                DialShortcut(
                    keyCode: kVK_ANSI_5,
                    modifiers: shiftKey | cmdKey
                )
            )
        case "browserZoomIn":
            performExperimentalBrowserZoom(direction: 1)
        case "browserZoomOut":
            performExperimentalBrowserZoom(direction: -1)
        default:
            postKeyboardShortcut(shortcut)
        }
        dialLogger.notice(
            "Direct Dial action=\(action.rawValue, privacy: .public) layer=\(layer, privacy: .public) kind=\(shortcut.resolvedKind, privacy: .public) app=\(bundleIdentifier ?? "unknown", privacy: .public) profile=\(profile.name, privacy: .public)"
        )
    }
}

private func requestAccessibilityPermissionIfNeeded() {
    guard !AXIsProcessTrusted() else { return }
    let options = [
        kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true
    ] as CFDictionary
    AXIsProcessTrustedWithOptions(options)
}

extension Notification.Name {
    static let toggleOrbitLauncher = Notification.Name("toggleOrbitLauncher")
    static let orbitSettingsChanged = Notification.Name("orbitSettingsChanged")
}

struct LauncherApp: Codable, Identifiable, Hashable {
    let id: UUID
    var name: String
    var path: String
}

struct LauncherGroup: Codable, Identifiable, Hashable {
    let id: UUID
    var name: String
    var apps: [LauncherApp]
}

enum DialControlAction: String, Codable {
    case counterClockwise
    case clockwise
    case press
    case doublePress
    case longPress
}

struct DialShortcut: Codable, Hashable {
    var keyCode: Int
    var modifiers: Int
    var kind: String? = nil
    var scrollLines: Int? = nil

    var resolvedKind: String {
        kind ?? "shortcut"
    }

    var resolvedScrollLines: Int {
        max(1, scrollLines ?? 3)
    }
}

struct DialAppProfile: Codable, Identifiable, Hashable {
    let id: UUID
    var name: String
    var bundleIdentifier: String
    var rotationDegrees: Int? = nil
    var counterClockwise: DialShortcut
    var clockwise: DialShortcut
    var press: DialShortcut
    var doublePress: DialShortcut? = nil
    var longPress: DialShortcut? = nil
    var secondLayerCounterClockwise: DialShortcut? = nil
    var secondLayerClockwise: DialShortcut? = nil
    var secondLayerPress: DialShortcut? = nil
    var secondLayerDoublePress: DialShortcut? = nil
    var secondLayerLongPress: DialShortcut? = nil

    var hasSecondLayer: Bool {
        [press, doublePress, longPress].contains {
            $0?.resolvedKind == "enterSecondLayer"
        }
    }

    var resolvedRotationDegrees: Int {
        max(1, min(rotationDegrees ?? 18, 36))
    }

    func shortcut(
        for action: DialControlAction,
        layer: Int = 1
    ) -> DialShortcut {
        if layer == 2 {
            switch action {
            case .counterClockwise:
                return secondLayerCounterClockwise
                    ?? DialShortcut(
                        keyCode: kVK_ANSI_Minus,
                        modifiers: cmdKey
                    )
            case .clockwise:
                return secondLayerClockwise
                    ?? DialShortcut(
                        keyCode: kVK_ANSI_Equal,
                        modifiers: cmdKey
                    )
            case .press:
                return secondLayerPress
                    ?? DialShortcut(
                        keyCode: kVK_Escape,
                        modifiers: 0,
                        kind: "exitSecondLayer"
                    )
            case .doublePress:
                return secondLayerDoublePress
                    ?? DialShortcut(
                        keyCode: kVK_Space,
                        modifiers: 0,
                        kind: "none"
                    )
            case .longPress:
                return secondLayerLongPress
                    ?? DialShortcut(
                        keyCode: kVK_Space,
                        modifiers: 0,
                        kind: "none"
                    )
            }
        }

        switch action {
        case .counterClockwise:
            return counterClockwise
        case .clockwise:
            return clockwise
        case .press:
            return press
        case .doublePress:
            return doublePress
                ?? DialShortcut(
                    keyCode: kVK_Space,
                    modifiers: 0,
                    kind: "none"
                )
        case .longPress:
            return longPress
                ?? DialShortcut(
                    keyCode: kVK_Space,
                    modifiers: 0,
                    kind: "none"
                )
        }
    }
}

enum DialProfilePreset: String, CaseIterable, Identifiable {
    case system
    case browser
    case finder
    case codeEditor
    case xcode
    case photoshop
    case videoEditor
    case terminal
    case media
    case pdfReader

    var id: String { rawValue }

    var name: String {
        switch self {
        case .system: return "系统默认"
        case .browser: return "浏览器"
        case .finder: return "Finder"
        case .codeEditor: return "VS Code / Cursor"
        case .xcode: return "Xcode"
        case .photoshop: return "Photoshop"
        case .videoEditor: return "视频剪辑"
        case .terminal: return "Terminal / iTerm2"
        case .media: return "音乐与媒体"
        case .pdfReader: return "PDF 阅读"
        }
    }

    var summary: String {
        switch self {
        case .system: return "音量、播放、亮度与 Mission Control"
        case .browser: return "滚动、地址栏、刷新、缩放与前进后退"
        case .finder: return "滚动、快速查看、目录导航与新建文件夹"
        case .codeEditor: return "滚动、快速打开、命令面板与格式化"
        case .xcode: return "滚动、运行、停止、构建与测试"
        case .photoshop: return "画笔大小、工具切换、缩放与撤销"
        case .videoEditor: return "逐帧、播放、切割与时间线缩放"
        case .terminal: return "滚动、新标签、历史搜索与字体缩放"
        case .media: return "切歌、播放、静音与音量"
        case .pdfReader: return "滚动、搜索、缩放与适合页面"
        }
    }

    func makeProfile(
        id: UUID,
        name: String,
        bundleIdentifier: String
    ) -> DialAppProfile {
        let none = DialShortcut(keyCode: kVK_Space, modifiers: 0, kind: "none")
        let enterLayer = DialShortcut(
            keyCode: kVK_Space,
            modifiers: 0,
            kind: "enterSecondLayer"
        )
        let exitLayer = DialShortcut(
            keyCode: kVK_Escape,
            modifiers: 0,
            kind: "exitSecondLayer"
        )
        let scrollUp = DialShortcut(
            keyCode: kVK_UpArrow,
            modifiers: 0,
            kind: "scrollUp",
            scrollLines: 3
        )
        let scrollDown = DialShortcut(
            keyCode: kVK_DownArrow,
            modifiers: 0,
            kind: "scrollDown",
            scrollLines: 3
        )
        let zoomOut = DialShortcut(keyCode: kVK_ANSI_Minus, modifiers: cmdKey)
        let zoomIn = DialShortcut(keyCode: kVK_ANSI_Equal, modifiers: cmdKey)

        func shortcut(_ keyCode: Int, _ modifiers: Int = 0) -> DialShortcut {
            DialShortcut(keyCode: keyCode, modifiers: modifiers)
        }

        func action(_ kind: String) -> DialShortcut {
            DialShortcut(keyCode: kVK_Space, modifiers: 0, kind: kind)
        }

        switch self {
        case .system:
            return DialAppProfile(
                id: id, name: name, bundleIdentifier: bundleIdentifier,
                rotationDegrees: 9,
                counterClockwise: action("volumeDown"),
                clockwise: action("volumeUp"),
                press: action("playPause"),
                doublePress: action("mute"),
                longPress: enterLayer,
                secondLayerCounterClockwise: action("brightnessDown"),
                secondLayerClockwise: action("brightnessUp"),
                secondLayerPress: exitLayer,
                secondLayerDoublePress: action("missionControl"),
                secondLayerLongPress: action("screenshot")
            )
        case .browser:
            return DialAppProfile(
                id: id, name: name, bundleIdentifier: bundleIdentifier,
                rotationDegrees: 9,
                counterClockwise: scrollUp,
                clockwise: scrollDown,
                press: enterLayer,
                doublePress: shortcut(kVK_ANSI_L, cmdKey),
                longPress: shortcut(kVK_ANSI_R, cmdKey),
                secondLayerCounterClockwise: action("browserZoomOut"),
                secondLayerClockwise: action("browserZoomIn"),
                secondLayerPress: exitLayer,
                secondLayerDoublePress: shortcut(kVK_ANSI_LeftBracket, cmdKey),
                secondLayerLongPress: shortcut(kVK_ANSI_RightBracket, cmdKey)
            )
        case .finder:
            return DialAppProfile(
                id: id, name: name, bundleIdentifier: bundleIdentifier,
                rotationDegrees: 9,
                counterClockwise: scrollUp,
                clockwise: scrollDown,
                press: enterLayer,
                doublePress: shortcut(kVK_Space),
                longPress: shortcut(kVK_UpArrow, cmdKey),
                secondLayerCounterClockwise: shortcut(kVK_ANSI_LeftBracket, cmdKey),
                secondLayerClockwise: shortcut(kVK_ANSI_RightBracket, cmdKey),
                secondLayerPress: exitLayer,
                secondLayerDoublePress: shortcut(kVK_ANSI_N, cmdKey),
                secondLayerLongPress: shortcut(kVK_ANSI_N, shiftKey | cmdKey)
            )
        case .codeEditor:
            return DialAppProfile(
                id: id, name: name, bundleIdentifier: bundleIdentifier,
                rotationDegrees: 9,
                counterClockwise: scrollUp,
                clockwise: scrollDown,
                press: enterLayer,
                doublePress: shortcut(kVK_ANSI_P, cmdKey),
                longPress: shortcut(kVK_ANSI_P, shiftKey | cmdKey),
                secondLayerCounterClockwise: zoomOut,
                secondLayerClockwise: zoomIn,
                secondLayerPress: exitLayer,
                secondLayerDoublePress: shortcut(kVK_F12),
                secondLayerLongPress: shortcut(kVK_ANSI_F, shiftKey | optionKey)
            )
        case .xcode:
            return DialAppProfile(
                id: id, name: name, bundleIdentifier: bundleIdentifier,
                rotationDegrees: 9,
                counterClockwise: scrollUp,
                clockwise: scrollDown,
                press: enterLayer,
                doublePress: shortcut(kVK_ANSI_R, cmdKey),
                longPress: shortcut(kVK_ANSI_Period, cmdKey),
                secondLayerCounterClockwise: zoomOut,
                secondLayerClockwise: zoomIn,
                secondLayerPress: exitLayer,
                secondLayerDoublePress: shortcut(kVK_ANSI_B, cmdKey),
                secondLayerLongPress: shortcut(kVK_ANSI_U, cmdKey)
            )
        case .photoshop:
            return DialAppProfile(
                id: id, name: name, bundleIdentifier: bundleIdentifier,
                rotationDegrees: 1,
                counterClockwise: shortcut(kVK_ANSI_LeftBracket),
                clockwise: shortcut(kVK_ANSI_RightBracket),
                press: enterLayer,
                doublePress: shortcut(kVK_ANSI_B),
                longPress: shortcut(kVK_ANSI_E),
                secondLayerCounterClockwise: zoomOut,
                secondLayerClockwise: zoomIn,
                secondLayerPress: exitLayer,
                secondLayerDoublePress: shortcut(kVK_ANSI_Z, cmdKey),
                secondLayerLongPress: none
            )
        case .videoEditor:
            return DialAppProfile(
                id: id, name: name, bundleIdentifier: bundleIdentifier,
                rotationDegrees: 3,
                counterClockwise: shortcut(kVK_LeftArrow),
                clockwise: shortcut(kVK_RightArrow),
                press: shortcut(kVK_Space),
                doublePress: enterLayer,
                longPress: shortcut(kVK_ANSI_B, cmdKey),
                secondLayerCounterClockwise: zoomOut,
                secondLayerClockwise: zoomIn,
                secondLayerPress: exitLayer,
                secondLayerDoublePress: shortcut(kVK_ANSI_Z, shiftKey),
                secondLayerLongPress: shortcut(kVK_ANSI_K)
            )
        case .terminal:
            return DialAppProfile(
                id: id, name: name, bundleIdentifier: bundleIdentifier,
                rotationDegrees: 9,
                counterClockwise: scrollUp,
                clockwise: scrollDown,
                press: enterLayer,
                doublePress: shortcut(kVK_ANSI_T, cmdKey),
                longPress: shortcut(kVK_ANSI_L, cmdKey),
                secondLayerCounterClockwise: zoomOut,
                secondLayerClockwise: zoomIn,
                secondLayerPress: exitLayer,
                secondLayerDoublePress: shortcut(kVK_ANSI_R, controlKey),
                secondLayerLongPress: shortcut(kVK_ANSI_N, cmdKey)
            )
        case .media:
            return DialAppProfile(
                id: id, name: name, bundleIdentifier: bundleIdentifier,
                rotationDegrees: 18,
                counterClockwise: action("previousTrack"),
                clockwise: action("nextTrack"),
                press: action("playPause"),
                doublePress: action("mute"),
                longPress: enterLayer,
                secondLayerCounterClockwise: action("volumeDown"),
                secondLayerClockwise: action("volumeUp"),
                secondLayerPress: exitLayer,
                secondLayerDoublePress: none,
                secondLayerLongPress: none
            )
        case .pdfReader:
            return DialAppProfile(
                id: id, name: name, bundleIdentifier: bundleIdentifier,
                rotationDegrees: 9,
                counterClockwise: scrollUp,
                clockwise: scrollDown,
                press: enterLayer,
                doublePress: shortcut(kVK_ANSI_F, cmdKey),
                longPress: none,
                secondLayerCounterClockwise: zoomOut,
                secondLayerClockwise: zoomIn,
                secondLayerPress: exitLayer,
                secondLayerDoublePress: shortcut(kVK_ANSI_9, cmdKey),
                secondLayerLongPress: none
            )
        }
    }

    static func recommended(for bundleIdentifier: String) -> DialProfilePreset {
        let bundleID = bundleIdentifier.lowercased()
        if bundleID == "com.apple.finder" { return .finder }
        if bundleID == "com.apple.dt.xcode" { return .xcode }
        if bundleID.contains("photoshop") { return .photoshop }
        if bundleID == "com.apple.terminal" || bundleID.contains("iterm") {
            return .terminal
        }
        if bundleID == "com.apple.finalcut"
            || bundleID.contains("davinciresolve")
            || bundleID.contains("premierepro") {
            return .videoEditor
        }
        if bundleID == "com.apple.music"
            || bundleID == "com.spotify.client"
            || bundleID.contains("podcast") {
            return .media
        }
        if bundleID == "com.apple.preview"
            || bundleID.contains("pdfexpert")
            || bundleID.contains("skim-app") {
            return .pdfReader
        }
        if bundleID.contains("vscode")
            || bundleID.contains("cursor")
            || bundleID == "com.todesktop.230313mzl4w4u92"
            || bundleID.contains("sublimetext") {
            return .codeEditor
        }
        if bundleID.contains("safari")
            || bundleID.contains("chrome")
            || bundleID.contains("firefox")
            || bundleID.contains("edgemac")
            || bundleID.contains("arc")
            || bundleID == "company.thebrowser.browser" {
            return .browser
        }
        return .system
    }
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
    @Published var ringAutoDismissEnabled: Bool {
        didSet {
            UserDefaults.standard.set(
                ringAutoDismissEnabled,
                forKey: Keys.ringAutoDismissEnabled
            )
        }
    }
    @Published var ringAutoDismissSeconds: Int {
        didSet {
            UserDefaults.standard.set(
                ringAutoDismissSeconds,
                forKey: Keys.ringAutoDismissSeconds
            )
        }
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
            NotificationCenter.default.post(name: .orbitSettingsChanged, object: nil)
        }
    }
    @Published var surfaceDialHapticsEnabled: Bool {
        didSet {
            UserDefaults.standard.set(
                surfaceDialHapticsEnabled,
                forKey: Keys.surfaceDialHapticsEnabled
            )
            NotificationCenter.default.post(name: .orbitSettingsChanged, object: nil)
        }
    }
    @Published var surfaceDialPreventSleepEnabled: Bool {
        didSet {
            UserDefaults.standard.set(
                surfaceDialPreventSleepEnabled,
                forKey: Keys.surfaceDialPreventSleepEnabled
            )
            NotificationCenter.default.post(name: .orbitSettingsChanged, object: nil)
        }
    }
    @Published var surfaceDialKeepAliveSeconds: Int {
        didSet {
            UserDefaults.standard.set(
                surfaceDialKeepAliveSeconds,
                forKey: Keys.surfaceDialKeepAliveSeconds
            )
            NotificationCenter.default.post(name: .orbitSettingsChanged, object: nil)
        }
    }
    @Published var surfaceDialControlMode: String {
        didSet {
            UserDefaults.standard.set(surfaceDialControlMode, forKey: Keys.surfaceDialControlMode)
        }
    }
    @Published private(set) var dialProfiles: [DialAppProfile]
    @Published var selectedDialProfileID: String {
        didSet {
            UserDefaults.standard.set(selectedDialProfileID, forKey: Keys.selectedDialProfileID)
        }
    }
    @Published var operatingMode: String {
        didSet { UserDefaults.standard.set(operatingMode, forKey: Keys.operatingMode) }
    }
    @Published var secondaryActionKeyCode: Int {
        didSet { UserDefaults.standard.set(secondaryActionKeyCode, forKey: Keys.secondaryActionKeyCode) }
    }
    @Published var secondaryAction: String {
        didSet { UserDefaults.standard.set(secondaryAction, forKey: Keys.secondaryAction) }
    }
    @Published private(set) var launcherGroups: [LauncherGroup]
    @Published var activeLauncherGroupID: String {
        didSet { UserDefaults.standard.set(activeLauncherGroupID, forKey: Keys.activeLauncherGroupID) }
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
        static let ringAutoDismissEnabled = "ringAutoDismissEnabled"
        static let ringAutoDismissSeconds = "ringAutoDismissSeconds"
        static let surfaceDialEnabled = "surfaceDialEnabled"
        static let surfaceDialStepsPerRotation = "surfaceDialStepsPerRotation"
        static let surfaceDialHapticsEnabled = "surfaceDialHapticsEnabled"
        static let surfaceDialPreventSleepEnabled = "surfaceDialPreventSleepEnabled"
        static let surfaceDialKeepAliveSeconds = "surfaceDialKeepAliveSeconds"
        static let surfaceDialControlMode = "surfaceDialControlMode"
        static let dialProfiles = "dialProfiles"
        static let selectedDialProfileID = "selectedDialProfileID"
        static let operatingMode = "operatingMode"
        static let secondaryActionKeyCode = "secondaryActionKeyCode"
        static let secondaryAction = "secondaryAction"
        static let launcherGroups = "launcherGroups"
        static let activeLauncherGroupID = "activeLauncherGroupID"
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
        ringAutoDismissEnabled =
            defaults.object(forKey: Keys.ringAutoDismissEnabled) as? Bool ?? true
        ringAutoDismissSeconds =
            defaults.object(forKey: Keys.ringAutoDismissSeconds) as? Int ?? 5
        surfaceDialEnabled = defaults.object(forKey: Keys.surfaceDialEnabled) as? Bool ?? true
        surfaceDialStepsPerRotation =
            defaults.object(forKey: Keys.surfaceDialStepsPerRotation) as? Int ?? 20
        surfaceDialHapticsEnabled =
            defaults.object(forKey: Keys.surfaceDialHapticsEnabled) as? Bool ?? true
        surfaceDialPreventSleepEnabled =
            defaults.object(forKey: Keys.surfaceDialPreventSleepEnabled) as? Bool ?? true
        surfaceDialKeepAliveSeconds =
            defaults.object(forKey: Keys.surfaceDialKeepAliveSeconds) as? Int ?? 15
        surfaceDialControlMode =
            defaults.string(forKey: Keys.surfaceDialControlMode) ?? "ring"
        let savedDialProfiles: [DialAppProfile]
        if let data = defaults.data(forKey: Keys.dialProfiles),
           let profiles = try? JSONDecoder().decode([DialAppProfile].self, from: data),
           !profiles.isEmpty {
            savedDialProfiles = profiles
        } else {
            savedDialProfiles = [
                DialProfilePreset.system.makeProfile(
                    id: UUID(),
                    name: "默认配置",
                    bundleIdentifier: "*"
                )
            ]
        }
        dialProfiles = savedDialProfiles
        selectedDialProfileID =
            defaults.string(forKey: Keys.selectedDialProfileID)
            ?? savedDialProfiles[0].id.uuidString
        operatingMode = defaults.string(forKey: Keys.operatingMode) ?? "switcher"
        secondaryActionKeyCode =
            defaults.object(forKey: Keys.secondaryActionKeyCode) as? Int ?? kVK_ANSI_Q
        secondaryAction = defaults.string(forKey: Keys.secondaryAction) ?? "closeWindow"
        let savedLauncherGroups: [LauncherGroup]
        if let data = defaults.data(forKey: Keys.launcherGroups),
           let groups = try? JSONDecoder().decode([LauncherGroup].self, from: data),
           !groups.isEmpty {
            savedLauncherGroups = groups
        } else {
            savedLauncherGroups = [
                LauncherGroup(id: UUID(), name: "常用应用", apps: [])
            ]
        }
        launcherGroups = savedLauncherGroups
        activeLauncherGroupID =
            defaults.string(forKey: Keys.activeLauncherGroupID) ?? savedLauncherGroups[0].id.uuidString
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

    var selectedDialProfile: DialAppProfile? {
        dialProfiles.first { $0.id.uuidString == selectedDialProfileID }
            ?? dialProfiles.first
    }

    func dialProfile(for bundleIdentifier: String?) -> DialAppProfile {
        if let bundleIdentifier,
           let profile = dialProfiles.first(where: {
               $0.bundleIdentifier.caseInsensitiveCompare(bundleIdentifier) == .orderedSame
           }) {
            return profile
        }
        return dialProfiles.first(where: { $0.bundleIdentifier == "*" })
            ?? dialProfiles[0]
    }

    func dialShortcut(
        for action: DialControlAction,
        layer: Int = 1
    ) -> DialShortcut {
        selectedDialProfile?.shortcut(for: action, layer: layer)
            ?? DialShortcut(keyCode: kVK_Space, modifiers: 0)
    }

    func updateDialShortcut(
        _ action: DialControlAction,
        layer: Int = 1,
        keyCode: Int? = nil,
        modifiers: Int? = nil,
        kind: String? = nil,
        scrollLines: Int? = nil
    ) {
        guard let index = dialProfiles.firstIndex(where: {
            $0.id.uuidString == selectedDialProfileID
        }) else { return }
        var shortcut = dialProfiles[index].shortcut(for: action, layer: layer)
        if let keyCode {
            shortcut.keyCode = keyCode
        }
        if let modifiers {
            shortcut.modifiers = modifiers
        }
        if let kind {
            shortcut.kind = kind
        }
        if let scrollLines {
            shortcut.scrollLines = max(1, scrollLines)
        }
        if layer == 2 {
            switch action {
            case .counterClockwise:
                dialProfiles[index].secondLayerCounterClockwise = shortcut
            case .clockwise:
                dialProfiles[index].secondLayerClockwise = shortcut
            case .press:
                dialProfiles[index].secondLayerPress = shortcut
            case .doublePress:
                dialProfiles[index].secondLayerDoublePress = shortcut
            case .longPress:
                dialProfiles[index].secondLayerLongPress = shortcut
            }
        } else {
            switch action {
            case .counterClockwise:
                dialProfiles[index].counterClockwise = shortcut
            case .clockwise:
                dialProfiles[index].clockwise = shortcut
            case .press:
                dialProfiles[index].press = shortcut
            case .doublePress:
                dialProfiles[index].doublePress = shortcut
            case .longPress:
                dialProfiles[index].longPress = shortcut
            }
        }
        saveDialProfiles()
    }

    func updateSelectedDialRotationDegrees(_ degrees: Int) {
        guard let index = dialProfiles.firstIndex(where: {
            $0.id.uuidString == selectedDialProfileID
        }) else { return }
        dialProfiles[index].rotationDegrees = max(1, min(degrees, 36))
        saveDialProfiles()
        NotificationCenter.default.post(name: .orbitSettingsChanged, object: nil)
    }

    func addDialApplicationProfile() {
        let panel = NSOpenPanel()
        panel.title = "选择要配置 Surface Dial 的应用"
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.application]
        guard panel.runModal() == .OK,
              let url = panel.url,
              let bundleIdentifier = Bundle(url: url)?.bundleIdentifier else {
            return
        }

        if let existing = dialProfiles.first(where: {
            $0.bundleIdentifier.caseInsensitiveCompare(bundleIdentifier) == .orderedSame
        }) {
            selectedDialProfileID = existing.id.uuidString
            return
        }

        let preset = DialProfilePreset.recommended(for: bundleIdentifier)
        let profile = preset.makeProfile(
            id: UUID(),
            name: FileManager.default.displayName(atPath: url.path)
                .replacingOccurrences(of: ".app", with: ""),
            bundleIdentifier: bundleIdentifier
        )
        dialProfiles.append(profile)
        selectedDialProfileID = profile.id.uuidString
        saveDialProfiles()
    }

    func applyDialPreset(_ preset: DialProfilePreset) {
        guard let index = dialProfiles.firstIndex(where: {
            $0.id.uuidString == selectedDialProfileID
        }) else { return }
        let current = dialProfiles[index]
        dialProfiles[index] = preset.makeProfile(
            id: current.id,
            name: current.name,
            bundleIdentifier: current.bundleIdentifier
        )
        saveDialProfiles()
        NotificationCenter.default.post(name: .orbitSettingsChanged, object: nil)
    }

    func removeSelectedDialProfile() {
        guard let index = dialProfiles.firstIndex(where: {
            $0.id.uuidString == selectedDialProfileID
        }), dialProfiles[index].bundleIdentifier != "*" else {
            return
        }
        dialProfiles.remove(at: index)
        selectedDialProfileID =
            dialProfiles.first(where: { $0.bundleIdentifier == "*" })?.id.uuidString
            ?? dialProfiles[0].id.uuidString
        saveDialProfiles()
    }

    private func saveDialProfiles() {
        if let data = try? JSONEncoder().encode(dialProfiles) {
            UserDefaults.standard.set(data, forKey: Keys.dialProfiles)
        }
    }

    var activeLauncherGroup: LauncherGroup? {
        launcherGroups.first { $0.id.uuidString == activeLauncherGroupID }
            ?? launcherGroups.first
    }

    func addLauncherGroup() {
        let group = LauncherGroup(
            id: UUID(),
            name: "应用组 \(launcherGroups.count + 1)",
            apps: []
        )
        launcherGroups.append(group)
        activeLauncherGroupID = group.id.uuidString
        saveLauncherGroups()
    }

    func renameActiveLauncherGroup(_ name: String) {
        guard let index = activeLauncherGroupIndex else { return }
        launcherGroups[index].name = name
        saveLauncherGroups()
    }

    func deleteActiveLauncherGroup() {
        guard launcherGroups.count > 1, let index = activeLauncherGroupIndex else { return }
        launcherGroups.remove(at: index)
        activeLauncherGroupID = launcherGroups[0].id.uuidString
        saveLauncherGroups()
    }

    func addApplicationsToActiveGroup() {
        guard let index = activeLauncherGroupIndex else { return }
        let panel = NSOpenPanel()
        panel.title = "选择要加入圆环的应用"
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.application]
        guard panel.runModal() == .OK else { return }

        let existingPaths = Set(launcherGroups[index].apps.map(\.path))
        let newApps = panel.urls
            .filter { !existingPaths.contains($0.path) }
            .map {
                LauncherApp(
                    id: UUID(),
                    name: FileManager.default.displayName(atPath: $0.path)
                        .replacingOccurrences(of: ".app", with: ""),
                    path: $0.path
                )
            }
        launcherGroups[index].apps.append(contentsOf: newApps)
        saveLauncherGroups()
    }

    func removeApplicationFromActiveGroup(_ appID: UUID) {
        guard let index = activeLauncherGroupIndex else { return }
        launcherGroups[index].apps.removeAll { $0.id == appID }
        saveLauncherGroups()
    }

    private var activeLauncherGroupIndex: Int? {
        launcherGroups.firstIndex { $0.id.uuidString == activeLauncherGroupID }
            ?? launcherGroups.indices.first
    }

    private func saveLauncherGroups() {
        if let data = try? JSONEncoder().encode(launcherGroups) {
            UserDefaults.standard.set(data, forKey: Keys.launcherGroups)
        }
    }
}

struct HotKeyModifier: Identifiable {
    let value: Int
    let label: String
    var id: Int { value }

    static let directOptions: [HotKeyModifier] = [
        .init(value: 0, label: "无")
    ] + options

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
        .init(code: kVK_ANSI_0, label: "0"), .init(code: kVK_ANSI_1, label: "1"),
        .init(code: kVK_ANSI_2, label: "2"), .init(code: kVK_ANSI_3, label: "3"),
        .init(code: kVK_ANSI_4, label: "4"), .init(code: kVK_ANSI_5, label: "5"),
        .init(code: kVK_ANSI_6, label: "6"), .init(code: kVK_ANSI_7, label: "7"),
        .init(code: kVK_ANSI_8, label: "8"), .init(code: kVK_ANSI_9, label: "9"),
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
        .init(code: kVK_F11, label: "F11"), .init(code: kVK_F12, label: "F12"),
        .init(code: kVK_ANSI_Minus, label: "−"),
        .init(code: kVK_ANSI_Equal, label: "="),
        .init(code: kVK_ANSI_LeftBracket, label: "["),
        .init(code: kVK_ANSI_RightBracket, label: "]"),
        .init(code: kVK_ANSI_Backslash, label: "\\"),
        .init(code: kVK_ANSI_Semicolon, label: ";"),
        .init(code: kVK_ANSI_Quote, label: "'"),
        .init(code: kVK_ANSI_Comma, label: ","),
        .init(code: kVK_ANSI_Period, label: "."),
        .init(code: kVK_ANSI_Slash, label: "/"),
        .init(code: kVK_ANSI_Grave, label: "`"),
        .init(code: kVK_LeftArrow, label: "←"), .init(code: kVK_RightArrow, label: "→"),
        .init(code: kVK_UpArrow, label: "↑"), .init(code: kVK_DownArrow, label: "↓"),
        .init(code: kVK_Home, label: "Home"), .init(code: kVK_End, label: "End"),
        .init(code: kVK_PageUp, label: "Page Up"), .init(code: kVK_PageDown, label: "Page Down"),
        .init(code: kVK_Return, label: "Return"), .init(code: kVK_Tab, label: "Tab"),
        .init(code: kVK_Escape, label: "Esc"), .init(code: kVK_Delete, label: "Delete"),
        .init(code: kVK_ForwardDelete, label: "Forward Delete")
    ]
}

struct SettingsView: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject private var surfaceDial = SurfaceDialManager.shared

    var body: some View {
        TabView {
            Form {
                Section("应用") {
                    Picker("工作模式", selection: $settings.operatingMode) {
                        Text("应用切换器").tag("switcher")
                        Text("环形启动器").tag("launcher")
                    }
                    .pickerStyle(.segmented)
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
                    Toggle("圆环无操作时自动隐藏", isOn: $settings.ringAutoDismissEnabled)
                    Stepper(
                        "自动隐藏时间：\(settings.ringAutoDismissSeconds) 秒",
                        value: $settings.ringAutoDismissSeconds,
                        in: 1...60
                    )
                    .disabled(!settings.ringAutoDismissEnabled)
                    Toggle("切换时播放音效", isOn: $settings.soundEnabled)
                    Toggle("启用过渡动画", isOn: $settings.animationsEnabled)
                    Text(
                        settings.secondRingEnabled
                            ? "确认应用后进入快捷操作环，默认选择“切换当前窗口”。"
                            : "确认应用后直接切换或打开该应用。"
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    Text("应用切换器和环形启动器呼出后会开始计时；旋转、滚轮、键盘、鼠标选择或进入下一环都会重新计时。")
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
                        "转动：\(settings.wheelStepSize) 格切换一次",
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

                Section("应用切换器辅助操作") {
                    HStack {
                        Picker("辅助按键", selection: $settings.secondaryActionKeyCode) {
                            ForEach(HotKeyKey.options) { key in
                                Text(key.label).tag(key.code)
                            }
                        }
                        Picker("按下后", selection: $settings.secondaryAction) {
                            Text("关闭当前窗口").tag("closeWindow")
                            Text("彻底退出应用").tag("quit")
                        }
                    }
                    Text("高亮应用时按辅助键执行；支持 Space、A–Z、F1–F12 和 Delete。关闭窗口需要辅助功能权限。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("Surface Dial（实验性）") {
                    Toggle("启用原始 HID 支持", isOn: $settings.surfaceDialEnabled)
                    Picker("操作模式", selection: $settings.surfaceDialControlMode) {
                        Text("环形切换").tag("ring")
                        Text("直接控制").tag("direct")
                    }
                    .pickerStyle(.segmented)
                    .disabled(!settings.surfaceDialEnabled)
                    Toggle("启用触觉反馈", isOn: $settings.surfaceDialHapticsEnabled)
                        .disabled(!settings.surfaceDialEnabled)
                    Toggle(
                        "主动阻止 Dial 休眠（实验性）",
                        isOn: $settings.surfaceDialPreventSleepEnabled
                    )
                    .disabled(!settings.surfaceDialEnabled)
                    Stepper(
                        "保活间隔：\(settings.surfaceDialKeepAliveSeconds) 秒",
                        value: $settings.surfaceDialKeepAliveSeconds,
                        in: 5...60,
                        step: 5
                    )
                    .disabled(
                        !settings.surfaceDialEnabled
                            || !settings.surfaceDialPreventSleepEnabled
                    )
                    Stepper(
                        "圆环精度：\(String(format: "%.1f", 360.0 / Double(settings.surfaceDialStepsPerRotation)))°/格（\(settings.surfaceDialStepsPerRotation) 格/圈）",
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
                    Text(
                        settings.surfaceDialControlMode == "direct"
                            ? "直接控制会根据当前前台应用发送配置的快捷键，不显示圆环。"
                            : "圆环隐藏时第一次旋转只负责呼出；继续旋转选择，按下立即确认。"
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    Text("触觉反馈开启后，Dial 会按每圈步数产生对应的物理刻度震动。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("主动保活会定期读写静默 HID 报告，并避免应用被 App Nap 暂停；不会阻止 Mac 正常睡眠，但会缩短 Dial 电池续航。建议先使用 15 秒。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if settings.surfaceDialControlMode == "direct" {
                    Section("Dial 直接控制") {
                        Picker("应用配置", selection: $settings.selectedDialProfileID) {
                            ForEach(settings.dialProfiles) { profile in
                                Text(profile.name).tag(profile.id.uuidString)
                            }
                        }

                        HStack {
                            Button("添加应用…") {
                                settings.addDialApplicationProfile()
                            }
                            Menu("套用模板…") {
                                ForEach(DialProfilePreset.allCases) { preset in
                                    Button("\(preset.name) — \(preset.summary)") {
                                        settings.applyDialPreset(preset)
                                    }
                                }
                            }
                            Button("删除当前配置", role: .destructive) {
                                settings.removeSelectedDialProfile()
                            }
                            .disabled(
                                settings.selectedDialProfile?.bundleIdentifier == "*"
                            )
                            Spacer()
                        }

                        Text("添加应用时会自动匹配模板；手动套用模板会替换当前应用的第一层和第二层操作。")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        if let profile = settings.selectedDialProfile {
                            LabeledContent("应用标识") {
                                Text(profile.bundleIdentifier)
                                    .font(.system(.caption, design: .monospaced))
                                    .foregroundStyle(.secondary)
                            }
                            Stepper(
                                "旋转精度：\(profile.resolvedRotationDegrees)°/格（约 \(max(1, Int((360.0 / Double(profile.resolvedRotationDegrees)).rounded()))) 格/圈）",
                                value: Binding(
                                    get: {
                                        settings.selectedDialProfile?.resolvedRotationDegrees ?? 18
                                    },
                                    set: { settings.updateSelectedDialRotationDegrees($0) }
                                ),
                                in: 1...36
                            )
                        }

                        DialShortcutRow(
                            title: "逆时针",
                            action: .counterClockwise,
                            settings: settings
                        )
                        DialShortcutRow(
                            title: "顺时针",
                            action: .clockwise,
                            settings: settings
                        )
                        DialShortcutRow(
                            title: "单击",
                            action: .press,
                            settings: settings
                        )
                        DialShortcutRow(
                            title: "双击",
                            action: .doublePress,
                            settings: settings
                        )
                        DialShortcutRow(
                            title: "长按",
                            action: .longPress,
                            settings: settings
                        )

                        if settings.selectedDialProfile?.hasSecondLayer == true {
                            Divider()
                            Text("第二层")
                                .font(.headline)
                            DialShortcutRow(
                                title: "逆时针",
                                action: .counterClockwise,
                                layer: 2,
                                settings: settings
                            )
                            DialShortcutRow(
                                title: "顺时针",
                                action: .clockwise,
                                layer: 2,
                                settings: settings
                            )
                            DialShortcutRow(
                                title: "单击",
                                action: .press,
                                layer: 2,
                                settings: settings
                            )
                            DialShortcutRow(
                                title: "双击",
                                action: .doublePress,
                                layer: 2,
                                settings: settings
                            )
                            DialShortcutRow(
                                title: "长按",
                                action: .longPress,
                                layer: 2,
                                settings: settings
                            )
                            Text("第二层连续 5 秒无操作会自动返回第一层。第二层可以由单击、双击或长按进入。")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        Text("双击间隔约 320 ms；长按约 650 ms。没有专属配置的应用使用“默认配置”。发送快捷键需要辅助功能权限。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text("浏览器连续缩放会在 Safari 或 Chrome 页面内以约 4% 的小步进平滑缩放；Safari 需要开启“开发 → 允许来自 Apple 事件的 JavaScript”，首次使用还会请求自动化权限。执行失败会自动回退到 ⌘+/⌘−。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Section {
                    Text("Esc 返回上一环；回车或松开鼠标执行当前高亮项。")
                        .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            .tabItem { Label("输入", systemImage: "keyboard") }

            Form {
                Section("应用组") {
                    Picker("当前组", selection: $settings.activeLauncherGroupID) {
                        ForEach(settings.launcherGroups) { group in
                            Text(group.name).tag(group.id.uuidString)
                        }
                    }
                    TextField(
                        "组名",
                        text: Binding(
                            get: { settings.activeLauncherGroup?.name ?? "" },
                            set: { settings.renameActiveLauncherGroup($0) }
                        )
                    )
                    HStack {
                        Button("新增组") { settings.addLauncherGroup() }
                        Button("删除当前组", role: .destructive) {
                            settings.deleteActiveLauncherGroup()
                        }
                        .disabled(settings.launcherGroups.count <= 1)
                        Spacer()
                        Button("添加应用…") {
                            settings.addApplicationsToActiveGroup()
                        }
                    }
                }

                Section("组内应用") {
                    if let apps = settings.activeLauncherGroup?.apps, !apps.isEmpty {
                        ForEach(apps) { app in
                            HStack {
                                Image(nsImage: NSWorkspace.shared.icon(forFile: app.path))
                                    .resizable()
                                    .frame(width: 28, height: 28)
                                Text(app.name)
                                Spacer()
                                Button {
                                    settings.removeApplicationFromActiveGroup(app.id)
                                } label: {
                                    Image(systemName: "minus.circle")
                                }
                                .buttonStyle(.borderless)
                            }
                        }
                    } else {
                        Text("此应用组为空，请点击“添加应用…”选择 .app。")
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .formStyle(.grouped)
            .tabItem { Label("启动器", systemImage: "square.grid.2x2") }
        }
        .padding(12)
        .frame(width: 600, height: 440)
    }
}

struct DialShortcutRow: View {
    let title: String
    let action: DialControlAction
    var layer: Int = 1
    @ObservedObject var settings: AppSettings

    var body: some View {
        let shortcut = settings.dialShortcut(for: action, layer: layer)
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title)
                    .frame(width: 64, alignment: .leading)
                Picker(
                    "动作类型",
                    selection: Binding(
                        get: { settings.dialShortcut(for: action, layer: layer).resolvedKind },
                        set: { settings.updateDialShortcut(action, layer: layer, kind: $0) }
                    )
                ) {
                    Text("无操作").tag("none")
                    Text("快捷键").tag("shortcut")
                    Text("向上滚动").tag("scrollUp")
                    Text("向下滚动").tag("scrollDown")
                    Text("增大音量").tag("volumeUp")
                    Text("减小音量").tag("volumeDown")
                    Text("静音/取消静音").tag("mute")
                    Text("播放/暂停").tag("playPause")
                    Text("下一首").tag("nextTrack")
                    Text("上一首").tag("previousTrack")
                    Text("提高亮度").tag("brightnessUp")
                    Text("降低亮度").tag("brightnessDown")
                    Text("Mission Control").tag("missionControl")
                    Text("当前应用窗口").tag("appExpose")
                    Text("显示桌面").tag("showDesktop")
                    Text("锁定屏幕").tag("lockScreen")
                    Text("截图工具").tag("screenshot")
                    Text("浏览器连续放大（实验性）").tag("browserZoomIn")
                    Text("浏览器连续缩小（实验性）").tag("browserZoomOut")
                    if layer == 1 {
                        Text("进入第二层").tag("enterSecondLayer")
                    } else {
                        Text("返回第一层").tag("exitSecondLayer")
                    }
                }
                .labelsHidden()
                Spacer()
                Text(actionLabel(shortcut))
                    .font(.system(.caption, design: .monospaced).bold())
            }

            if shortcut.resolvedKind == "shortcut" {
                HStack {
                    Spacer()
                        .frame(width: 64)
                    Picker(
                        "修饰键",
                        selection: Binding(
                            get: { settings.dialShortcut(for: action, layer: layer).modifiers },
                            set: { settings.updateDialShortcut(action, layer: layer, modifiers: $0) }
                        )
                    ) {
                        ForEach(HotKeyModifier.directOptions) { option in
                            Text(option.label).tag(option.value)
                        }
                    }
                    .labelsHidden()
                    Picker(
                        "按键",
                        selection: Binding(
                            get: { settings.dialShortcut(for: action, layer: layer).keyCode },
                            set: { settings.updateDialShortcut(action, layer: layer, keyCode: $0) }
                        )
                    ) {
                        ForEach(HotKeyKey.options) { key in
                            Text(key.label).tag(key.code)
                        }
                    }
                    .labelsHidden()
                }
            } else if shortcut.resolvedKind == "scrollUp"
                        || shortcut.resolvedKind == "scrollDown" {
                Stepper(
                    "每格滚动：\(shortcut.resolvedScrollLines) 行",
                    value: Binding(
                        get: { settings.dialShortcut(for: action, layer: layer).resolvedScrollLines },
                        set: { settings.updateDialShortcut(action, layer: layer, scrollLines: $0) }
                    ),
                    in: 1...12
                )
                .padding(.leading, 64)
            }
        }
    }

    private func actionLabel(_ shortcut: DialShortcut) -> String {
        switch shortcut.resolvedKind {
        case "none":
            return "无操作"
        case "scrollUp":
            return "滚轮 ↑"
        case "scrollDown":
            return "滚轮 ↓"
        case "volumeUp":
            return "音量 +"
        case "volumeDown":
            return "音量 −"
        case "mute":
            return "静音"
        case "playPause":
            return "播放/暂停"
        case "nextTrack":
            return "下一首"
        case "previousTrack":
            return "上一首"
        case "brightnessUp":
            return "亮度 +"
        case "brightnessDown":
            return "亮度 −"
        case "missionControl":
            return "调度中心"
        case "appExpose":
            return "应用窗口"
        case "showDesktop":
            return "桌面"
        case "lockScreen":
            return "锁屏"
        case "screenshot":
            return "截图"
        case "browserZoomIn":
            return "浏览器缩放 +"
        case "browserZoomOut":
            return "浏览器缩放 −"
        case "enterSecondLayer":
            return "进入第二层"
        case "exitSecondLayer":
            return "返回第一层"
        default:
            let modifier = HotKeyModifier.directOptions.first {
                $0.value == shortcut.modifiers
            }?.label ?? ""
            let key = HotKeyKey.options.first {
                $0.code == shortcut.keyCode
            }?.label ?? "?"
            return modifier + key
        }
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
    private var wheelDetentProgress = 0
    private var lastWheelSelectionTime: TimeInterval = 0
    private var inactivityDismissWorkItem: DispatchWorkItem?

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
        model.activity = { [weak self] in self?.resetInactivityTimer() }
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
        logger.notice(
            "Surface Dial rotation direction=\(direction, privacy: .public) selection=\(self.model.selectedIndex, privacy: .public)"
        )
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
        // AppKit may order out a transient panel without calling hide().
        // Remove any stale monitors before adding a new pair so one physical
        // wheel event is never handled by multiple retained callbacks.
        removeInputMonitors()
        resetWheelDetector()

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
        resetInactivityTimer()
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
            resetInactivityTimer()

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

            if wheelDetectorArmed, risingEdge {
                let directionStep = direction > 0 ? -1 : 1
                if wheelDetentProgress != 0,
                   (wheelDetentProgress > 0) != (directionStep > 0) {
                    wheelDetentProgress = 0
                }
                wheelDetentProgress += directionStep
                wheelDetectorArmed = false

                let detentsPerSelection = AppSettings.shared.wheelStepSize
                if abs(wheelDetentProgress) >= detentsPerSelection,
                   now - lastWheelSelectionTime >= minimumInterval {
                    let step = wheelDetentProgress > 0 ? 1 : -1
                    model.moveSelection(by: step)
                    wheelDetentProgress = 0
                    lastWheelSelectionTime = now
                    logger.notice(
                        "Wheel detent source=\(source, privacy: .public) delta=\(Double(delta), privacy: .public) intervalMs=\(self.settingsInterval, privacy: .public) detents=\(detentsPerSelection, privacy: .public) step=\(step, privacy: .public) selection=\(self.model.selectedIndex, privacy: .public)"
                    )
                }
            }
            lastWheelMagnitude = magnitude
            return true
        }

        resetInactivityTimer()

        switch Int(event.keyCode) {
        case kVK_Escape:
            model.escape()
            return true
        case AppSettings.shared.secondaryActionKeyCode:
            model.performSecondaryAction()
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
        inactivityDismissWorkItem?.cancel()
        inactivityDismissWorkItem = nil
        panel.orderOut(nil)
        removeInputMonitors()
        resetWheelDetector()
    }

    private func removeInputMonitors() {
        if let globalInputMonitor {
            NSEvent.removeMonitor(globalInputMonitor)
            self.globalInputMonitor = nil
        }
        if let localInputMonitor {
            NSEvent.removeMonitor(localInputMonitor)
            self.localInputMonitor = nil
        }
    }

    private func resetWheelDetector() {
        lastWheelEventTime = 0
        wheelBurstDirection = 0
        lastWheelMagnitude = 0
        wheelPeakMagnitude = 0
        wheelDetectorArmed = true
        wheelDetentProgress = 0
        lastWheelSelectionTime = 0
    }

    private func resetInactivityTimer() {
        inactivityDismissWorkItem?.cancel()
        inactivityDismissWorkItem = nil
        guard panel.isVisible,
              AppSettings.shared.ringAutoDismissEnabled else {
            return
        }

        let seconds = max(1, AppSettings.shared.ringAutoDismissSeconds)
        let workItem = DispatchWorkItem { [weak self] in
            guard let self, self.panel.isVisible else { return }
            self.logger.notice(
                "Ring hidden after inactivity timeout seconds=\(seconds, privacy: .public)"
            )
            self.hide()
        }
        inactivityDismissWorkItem = workItem
        DispatchQueue.main.asyncAfter(
            deadline: .now() + .seconds(seconds),
            execute: workItem
        )
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
    var activity: (() -> Void)?

    var items: [RingItem] {
        if let selectedApp {
            return actions(for: selectedApp)
        }
        if AppSettings.shared.operatingMode == "launcher" {
            return launcherItems()
        }
        return apps.map { app in
            RingItem(id: app.id, title: app.name, icon: app.icon) { [weak self] in
                self?.selectApp(app)
            }
        }
    }

    var centerTitle: String {
        if let selectedApp {
            return "\(selectedApp.name)\n快捷操作"
        }
        if AppSettings.shared.operatingMode == "launcher" {
            return AppSettings.shared.activeLauncherGroup?.name ?? "启动器"
        }
        return "应用"
    }

    func reloadApps() {
        if AppSettings.shared.operatingMode == "launcher" {
            apps = []
            return
        }
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
        activity?()
        selectedApp = nil
        selectedIndex = 0
    }

    func escape() {
        activity?()
        if selectedApp != nil { selectedApp = nil } else { dismiss?() }
        selectedIndex = 0
    }

    func resetSelection() {
        activity?()
        selectedIndex = 0
    }

    private func selectApp(_ app: RunningApp) {
        if AppSettings.shared.secondRingEnabled {
            selectedApp = app
            selectedIndex = 0
        } else {
            activateAndRestoreWindows(app.application)
            dismiss?()
        }
    }

    func moveSelection(by step: Int) {
        activity?()
        guard !items.isEmpty else { return }
        selectedIndex = (selectedIndex + step + items.count) % items.count
        playSelectionSound()
    }

    func performSelected() {
        activity?()
        guard items.indices.contains(selectedIndex) else { return }
        items[selectedIndex].action()
    }

    func performSecondaryAction() {
        activity?()
        guard AppSettings.shared.operatingMode == "switcher",
              selectedApp == nil,
              apps.indices.contains(selectedIndex) else {
            return
        }
        let app = apps[selectedIndex]
        if AppSettings.shared.secondaryAction == "quit" {
            app.application.terminate()
            dismiss?()
        } else {
            app.application.activate(options: [.activateAllWindows])
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) { [weak self] in
                if !closeFocusedWindow(of: app.application.processIdentifier) {
                    postCommandW()
                }
                self?.dismiss?()
            }
        }
    }

    func select(_ id: String) {
        activity?()
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        guard selectedIndex != index else { return }
        selectedIndex = index
        playSelectionSound()
    }

    func select(index: Int) {
        activity?()
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
            activateAndRestoreWindows(app.application)
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
            activateAndRestoreWindows(app.application)
            self?.dismiss?()
        }
        let back = RingItem(
            id: "\(app.id)-back",
            title: "返回",
            symbol: "arrow.uturn.backward"
        ) { [weak self] in self?.goBack() }
        return [activate, windows, hide, quit, back]
    }

    private func launcherItems() -> [RingItem] {
        let group = AppSettings.shared.activeLauncherGroup
        return (group?.apps ?? []).map { app in
            RingItem(
                id: app.id.uuidString,
                title: app.name,
                icon: NSWorkspace.shared.icon(forFile: app.path)
            ) { [weak self] in
                let url = URL(fileURLWithPath: app.path)
                let configuration = NSWorkspace.OpenConfiguration()
                NSWorkspace.shared.openApplication(
                    at: url,
                    configuration: configuration,
                    completionHandler: nil
                )
                self?.dismiss?()
            }
        }
    }
}

private func postSystemDefinedKey(_ keyType: Int) {
    let keyDownValue = 0xA
    let keyUpValue = 0xB
    let keyDown = NSEvent.otherEvent(
        with: .systemDefined,
        location: .zero,
        modifierFlags: NSEvent.ModifierFlags(rawValue: UInt(keyDownValue << 8)),
        timestamp: 0,
        windowNumber: 0,
        context: nil,
        subtype: 8,
        data1: (keyType << 16) | (keyDownValue << 8),
        data2: -1
    )
    let keyUp = NSEvent.otherEvent(
        with: .systemDefined,
        location: .zero,
        modifierFlags: NSEvent.ModifierFlags(rawValue: UInt(keyUpValue << 8)),
        timestamp: 0,
        windowNumber: 0,
        context: nil,
        subtype: 8,
        data1: (keyType << 16) | (keyUpValue << 8),
        data2: -1
    )
    keyDown?.cgEvent?.post(tap: .cghidEventTap)
    keyUp?.cgEvent?.post(tap: .cghidEventTap)
}

private func postScrollWheel(lines: Int) {
    // CGEvent's wheel delta represents the physical wheel direction. Convert the
    // user-facing page direction so it stays correct with Natural Scrolling on
    // or off.
    let naturalScrolling = UserDefaults.standard.object(
        forKey: "com.apple.swipescrolldirection"
    ) as? Bool ?? true
    let wheelLines = naturalScrolling ? -lines : lines
    guard let source = CGEventSource(stateID: .hidSystemState),
          let event = CGEvent(
              scrollWheelEvent2Source: source,
              units: .line,
              wheelCount: 1,
              wheel1: Int32(wheelLines),
              wheel2: 0,
              wheel3: 0
          ) else {
        return
    }
    event.post(tap: .cghidEventTap)
}

private func postKeyboardShortcut(_ shortcut: DialShortcut) {
    guard let source = CGEventSource(stateID: .hidSystemState),
          let keyDown = CGEvent(
            keyboardEventSource: source,
            virtualKey: CGKeyCode(shortcut.keyCode),
            keyDown: true
          ),
          let keyUp = CGEvent(
            keyboardEventSource: source,
            virtualKey: CGKeyCode(shortcut.keyCode),
            keyDown: false
          ) else {
        return
    }

    var flags: CGEventFlags = []
    if shortcut.modifiers & cmdKey != 0 {
        flags.insert(.maskCommand)
    }
    if shortcut.modifiers & optionKey != 0 {
        flags.insert(.maskAlternate)
    }
    if shortcut.modifiers & controlKey != 0 {
        flags.insert(.maskControl)
    }
    if shortcut.modifiers & shiftKey != 0 {
        flags.insert(.maskShift)
    }
    keyDown.flags = flags
    keyUp.flags = flags
    keyDown.post(tap: .cghidEventTap)
    keyUp.post(tap: .cghidEventTap)
}

private let browserZoomLogger = Logger(
    subsystem: "com.s7venyoung.orbitlauncher",
    category: "BrowserZoom"
)

@MainActor
private func performExperimentalBrowserZoom(direction: Int) {
    let fallback = DialShortcut(
        keyCode: direction > 0 ? kVK_ANSI_Equal : kVK_ANSI_Minus,
        modifiers: cmdKey
    )
    guard let application = NSWorkspace.shared.frontmostApplication,
          let bundleIdentifier = application.bundleIdentifier?.lowercased() else {
        postKeyboardShortcut(fallback)
        return
    }

    let delta = direction > 0 ? 0.04 : -0.04
    let javaScript = """
    (function() {
      const root = document.documentElement;
      const current = parseFloat(getComputedStyle(root).zoom) || 1;
      const base = Number.isFinite(window.__ringLauncherZoomTarget)
        ? window.__ringLauncherZoomTarget : current;
      window.__ringLauncherZoomTarget = Math.max(0.5, Math.min(3.0, base + \(delta)));
      if (window.__ringLauncherZoomAnimating) return window.__ringLauncherZoomTarget;
      window.__ringLauncherZoomAnimating = true;
      function animateZoom() {
        const value = parseFloat(getComputedStyle(root).zoom) || 1;
        const target = window.__ringLauncherZoomTarget;
        const next = value + (target - value) * 0.38;
        if (Math.abs(target - next) < 0.002) {
          root.style.zoom = String(target);
          window.__ringLauncherZoomAnimating = false;
          return;
        }
        root.style.zoom = String(next);
        requestAnimationFrame(animateZoom);
      }
      requestAnimationFrame(animateZoom);
      return window.__ringLauncherZoomTarget;
    })();
    """
    let escapedJavaScript = javaScript
        .replacingOccurrences(of: "\\", with: "\\\\")
        .replacingOccurrences(of: "\"", with: "\\\"")
        .replacingOccurrences(of: "\n", with: " ")

    let source: String
    if bundleIdentifier.contains("safari") {
        source = "tell application \"Safari\" to do JavaScript \"\(escapedJavaScript)\" in current tab of front window"
    } else if bundleIdentifier == "com.microsoft.edgemac" {
        source = "tell application \"Microsoft Edge\" to execute active tab of front window javascript \"\(escapedJavaScript)\""
    } else if bundleIdentifier.contains("chrome") {
        source = "tell application \"Google Chrome\" to execute active tab of front window javascript \"\(escapedJavaScript)\""
    } else {
        postKeyboardShortcut(fallback)
        return
    }

    var error: NSDictionary?
    guard let script = NSAppleScript(source: source) else {
        postKeyboardShortcut(fallback)
        return
    }
    script.executeAndReturnError(&error)
    if let error {
        browserZoomLogger.error(
            "Experimental browser zoom failed app=\(bundleIdentifier, privacy: .public) error=\(error.description, privacy: .public); using shortcut fallback"
        )
        postKeyboardShortcut(fallback)
    } else {
        browserZoomLogger.debug(
            "Experimental browser zoom direction=\(direction, privacy: .public) app=\(bundleIdentifier, privacy: .public)"
        )
    }
}

private func postCommandW() {
    guard let source = CGEventSource(stateID: .hidSystemState),
          let keyDown = CGEvent(
            keyboardEventSource: source,
            virtualKey: CGKeyCode(kVK_ANSI_W),
            keyDown: true
          ),
          let keyUp = CGEvent(
            keyboardEventSource: source,
            virtualKey: CGKeyCode(kVK_ANSI_W),
            keyDown: false
          ) else {
        return
    }
    keyDown.flags = .maskCommand
    keyUp.flags = .maskCommand
    keyDown.post(tap: .cghidEventTap)
    keyUp.post(tap: .cghidEventTap)
}

private func activateAndRestoreWindows(_ application: NSRunningApplication) {
    application.unhide()
    application.activate(options: [.activateAllWindows])

    let processIdentifier = application.processIdentifier
    restoreMinimizedWindows(of: processIdentifier)
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
        restoreMinimizedWindows(of: processIdentifier)
    }
}

private func restoreMinimizedWindows(of processIdentifier: pid_t) {
    let applicationElement = AXUIElementCreateApplication(processIdentifier)
    var windowsValue: CFTypeRef?
    guard AXUIElementCopyAttributeValue(
        applicationElement,
        kAXWindowsAttribute as CFString,
        &windowsValue
    ) == .success,
    let windowsValue,
    CFGetTypeID(windowsValue) == CFArrayGetTypeID() else {
        return
    }

    let windows = unsafeBitCast(windowsValue, to: CFArray.self)
    var windowToRaise: AXUIElement?
    for index in 0..<CFArrayGetCount(windows) {
        let window = unsafeBitCast(
            CFArrayGetValueAtIndex(windows, index),
            to: AXUIElement.self
        )
        if windowToRaise == nil {
            windowToRaise = window
        }

        var minimizedValue: CFTypeRef?
        if AXUIElementCopyAttributeValue(
            window,
            kAXMinimizedAttribute as CFString,
            &minimizedValue
        ) == .success,
        let minimized = minimizedValue as? Bool,
        minimized {
            AXUIElementSetAttributeValue(
                window,
                kAXMinimizedAttribute as CFString,
                kCFBooleanFalse
            )
            windowToRaise = window
        }
    }

    guard let windowToRaise else { return }
    AXUIElementSetAttributeValue(
        windowToRaise,
        kAXMainAttribute as CFString,
        kCFBooleanTrue
    )
    AXUIElementSetAttributeValue(
        windowToRaise,
        kAXFocusedAttribute as CFString,
        kCFBooleanTrue
    )
    AXUIElementPerformAction(windowToRaise, kAXRaiseAction as CFString)
}

private func closeFocusedWindow(of processIdentifier: pid_t) -> Bool {
    let applicationElement = AXUIElementCreateApplication(processIdentifier)
    var focusedWindowValue: CFTypeRef?
    let focusedWindowResult = AXUIElementCopyAttributeValue(
        applicationElement,
        kAXFocusedWindowAttribute as CFString,
        &focusedWindowValue
    )
    guard focusedWindowResult == .success,
          let focusedWindowValue,
          CFGetTypeID(focusedWindowValue) == AXUIElementGetTypeID() else {
        return false
    }
    let focusedWindow = unsafeBitCast(focusedWindowValue, to: AXUIElement.self)

    var closeButtonValue: CFTypeRef?
    let closeButtonResult = AXUIElementCopyAttributeValue(
        focusedWindow,
        kAXCloseButtonAttribute as CFString,
        &closeButtonValue
    )
    guard closeButtonResult == .success,
          let closeButtonValue,
          CFGetTypeID(closeButtonValue) == AXUIElementGetTypeID() else {
        return false
    }
    let closeButton = unsafeBitCast(closeButtonValue, to: AXUIElement.self)

    return AXUIElementPerformAction(
        closeButton,
        kAXPressAction as CFString
    ) == .success
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

        return Button {
            model.activity?()
            item.action()
        } label: {
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
