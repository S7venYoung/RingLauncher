import AppKit
import Foundation
import IOKit.hid
import OSLog

@MainActor
final class SurfaceDialManager: ObservableObject {
    static let shared = SurfaceDialManager()

    static let vendorID = 0x045E
    static let productID = 0x091B

    @Published private(set) var isConnected = false
    @Published private(set) var resolution = 360

    var onRotation: ((Int) -> Void)?
    var onButtonChanged: ((Bool) -> Void)?

    private let logger = Logger(
        subsystem: "com.s7venyoung.orbitlauncher",
        category: "SurfaceDial"
    )
    private var manager: IOHIDManager?
    private var device: IOHIDDevice?
    private var running = false
    private var hapticsEnabled = true
    private var preventSleepEnabled = true
    private var keepAliveInterval: TimeInterval = 15
    private var lastButtonPressed = false
    private var tickAccumulator = 0
    private var keepAliveTimer: DispatchSourceTimer?
    private var appNapActivity: NSObjectProtocol?
    private var wakeObserver: NSObjectProtocol?

    private init() {}

    func start() {
        guard !running else { return }
        running = true

        let manager = IOHIDManagerCreate(
            kCFAllocatorDefault,
            IOOptionBits(kIOHIDOptionsTypeNone)
        )
        self.manager = manager

        let matching: [String: Any] = [
            kIOHIDVendorIDKey as String: Self.vendorID,
            kIOHIDProductIDKey as String: Self.productID
        ]
        IOHIDManagerSetDeviceMatching(manager, matching as CFDictionary)

        let context = Unmanaged.passUnretained(self).toOpaque()
        IOHIDManagerRegisterDeviceMatchingCallback(manager, surfaceDialAdded, context)
        IOHIDManagerRegisterDeviceRemovalCallback(manager, surfaceDialRemoved, context)
        IOHIDManagerRegisterInputReportCallback(manager, surfaceDialReport, context)
        IOHIDManagerScheduleWithRunLoop(
            manager,
            CFRunLoopGetMain(),
            CFRunLoopMode.commonModes.rawValue
        )

        let result = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        observeSystemWake()
        logger.notice("Surface Dial HID manager started result=\(result, privacy: .public)")
    }

    func stop() {
        guard running, let manager else { return }
        stopKeepAlive()
        stopObservingSystemWake()
        IOHIDManagerUnscheduleFromRunLoop(
            manager,
            CFRunLoopGetMain(),
            CFRunLoopMode.commonModes.rawValue
        )
        IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        self.manager = nil
        device = nil
        running = false
        isConnected = false
        resolution = 360
        lastButtonPressed = false
        tickAccumulator = 0
    }

    func setHapticsEnabled(_ enabled: Bool) {
        hapticsEnabled = enabled
        guard let device else { return }
        configureHaptics(on: device)
    }

    func configureSleepPrevention(enabled: Bool, interval: Int) {
        preventSleepEnabled = enabled
        keepAliveInterval = TimeInterval(max(5, min(interval, 120)))
        guard running, device != nil else { return }
        if enabled {
            startKeepAlive()
        } else {
            stopKeepAlive()
        }
    }

    fileprivate func deviceAdded(_ device: IOHIDDevice) {
        self.device = device
        resolution = readResolution(from: device) ?? 360
        tickAccumulator = 0
        isConnected = true
        configureHaptics(on: device)
        if preventSleepEnabled {
            startKeepAlive()
        }
        logger.notice("Surface Dial connected resolution=\(self.resolution, privacy: .public) ticks/rev")
    }

    fileprivate func deviceRemoved(_ removedDevice: IOHIDDevice) {
        guard let device, CFEqual(device, removedDevice) else { return }
        stopKeepAlive()
        self.device = nil
        isConnected = false
        resolution = 360
        lastButtonPressed = false
        tickAccumulator = 0
        logger.notice("Surface Dial disconnected")
    }

    private func startKeepAlive() {
        stopKeepAlive()
        guard preventSleepEnabled else { return }
        appNapActivity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiatedAllowingIdleSystemSleep],
            reason: "保持 Surface Dial HID 通信活跃"
        )
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(
            deadline: .now() + keepAliveInterval,
            repeating: keepAliveInterval,
            leeway: .milliseconds(500)
        )
        timer.setEventHandler { [weak self] in
            self?.sendKeepAlive(reason: "timer")
        }
        keepAliveTimer = timer
        timer.resume()
        logger.notice(
            "Surface Dial keep-alive started interval=\(self.keepAliveInterval, privacy: .public)s"
        )
    }

    private func stopKeepAlive() {
        keepAliveTimer?.setEventHandler {}
        keepAliveTimer?.cancel()
        keepAliveTimer = nil
        if let appNapActivity {
            ProcessInfo.processInfo.endActivity(appNapActivity)
            self.appNapActivity = nil
        }
    }

    private func sendKeepAlive(reason: String) {
        guard running, isConnected, let device else { return }
        var readBuffer = [UInt8](repeating: 0, count: 64)
        var readLength = readBuffer.count
        let readResult = IOHIDDeviceGetReport(
            device,
            kIOHIDReportTypeFeature,
            CFIndex(1),
            &readBuffer,
            &readLength
        )
        let writeResult = configureHaptics(on: device, logSuccess: false)
        if readResult == kIOReturnSuccess || writeResult == kIOReturnSuccess {
            logger.debug(
                "Surface Dial keep-alive reason=\(reason, privacy: .public) read=\(readResult, privacy: .public) write=\(writeResult, privacy: .public)"
            )
        } else {
            logger.error(
                "Surface Dial keep-alive failed reason=\(reason, privacy: .public) read=\(readResult, privacy: .public) write=\(writeResult, privacy: .public)"
            )
        }
    }

    @discardableResult
    private func configureHaptics(
        on device: IOHIDDevice,
        logSuccess: Bool = true
    ) -> IOReturn {
        let steps = max(1, min(AppSettings.shared.surfaceDialStepsPerRotation, Int(UInt16.max)))
        // IOHIDDeviceSetReport requires the report ID both as its
        // reportID argument and as the first byte when the device uses
        // multiple reports. Surface Dial's haptic feature report is ID 1.
        var report: [UInt8] = [
            0x01,
            UInt8(steps & 0xFF),
            UInt8((steps >> 8) & 0xFF),
            0x00,
            hapticsEnabled ? 0x03 : 0x02,
            0x00,
            0x00,
            0x00
        ]
        let result = IOHIDDeviceSetReport(
            device,
            kIOHIDReportTypeFeature,
            CFIndex(1),
            &report,
            CFIndex(report.count)
        )
        if result == kIOReturnSuccess {
            if logSuccess {
                logger.notice(
                    "Surface Dial haptics configured enabled=\(self.hapticsEnabled, privacy: .public) steps/rev=\(steps, privacy: .public)"
                )
            }
        } else {
            logger.error(
                "Surface Dial haptics configuration failed result=\(result, privacy: .public)"
            )
        }
        return result
    }

    private func observeSystemWake() {
        guard wakeObserver == nil else { return }
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.tickAccumulator = 0
                self.sendKeepAlive(reason: "systemWake")
                if self.preventSleepEnabled {
                    self.startKeepAlive()
                }
            }
        }
    }

    private func stopObservingSystemWake() {
        if let wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver)
            self.wakeObserver = nil
        }
    }

    fileprivate func process(reportID: UInt32, bytes: [UInt8]) {
        // Depending on the IOKit callback, the report ID can be included in
        // the byte buffer or supplied only through reportID.
        let payload = bytes.first == 1 && bytes.count >= 4
            ? Array(bytes.dropFirst())
            : bytes
        guard reportID == 1 || bytes.first == 1, payload.count >= 3 else {
            logger.debug("Ignoring HID report id=\(reportID, privacy: .public) length=\(bytes.count, privacy: .public)")
            return
        }

        let pressed = payload[0] & 1 == 1
        if pressed != lastButtonPressed {
            lastButtonPressed = pressed
            onButtonChanged?(pressed)
        }

        let rawDelta = Int16(
            bitPattern: UInt16(payload[1]) | (UInt16(payload[2]) << 8)
        )
        guard rawDelta != 0 else { return }

        tickAccumulator += Int(rawDelta)
        let stepsPerRotation = max(1, AppSettings.shared.surfaceDialStepsPerRotation)
        let ticksPerStep = max(1, resolution / stepsPerRotation)
        let logicalSteps = tickAccumulator / ticksPerStep
        guard logicalSteps != 0 else { return }

        tickAccumulator -= logicalSteps * ticksPerStep
        let direction = logicalSteps > 0 ? 1 : -1
        for _ in 0..<abs(logicalSteps) {
            onRotation?(direction)
        }
        logger.notice(
            "Surface Dial delta=\(rawDelta, privacy: .public) logicalSteps=\(logicalSteps, privacy: .public) remainder=\(self.tickAccumulator, privacy: .public)"
        )
    }

    private func readResolution(from device: IOHIDDevice) -> Int? {
        let matching: [String: Any] = [
            kIOHIDElementUsagePageKey as String: 1,
            kIOHIDElementUsageKey as String: 0x48
        ]
        guard let elements = IOHIDDeviceCopyMatchingElements(
            device,
            matching as CFDictionary,
            IOOptionBits(kIOHIDOptionsTypeNone)
        ) as? [IOHIDElement] else {
            return nil
        }

        for element in elements where IOHIDElementGetType(element) == kIOHIDElementTypeFeature {
            var value = Unmanaged<IOHIDValue>.passRetained(
                IOHIDValueCreateWithIntegerValue(
                    kCFAllocatorDefault,
                    element,
                    0,
                    0
                )
            )
            guard IOHIDDeviceGetValue(device, element, &value) == kIOReturnSuccess else {
                value.release()
                continue
            }
            let candidate = Int(IOHIDValueGetIntegerValue(value.takeRetainedValue()))
            if candidate > 0 {
                return candidate
            }
        }
        return nil
    }
}

private func surfaceDialAdded(
    context: UnsafeMutableRawPointer?,
    result: IOReturn,
    sender: UnsafeMutableRawPointer?,
    device: IOHIDDevice
) {
    guard let context else { return }
    let manager = Unmanaged<SurfaceDialManager>.fromOpaque(context).takeUnretainedValue()
    DispatchQueue.main.async {
        manager.deviceAdded(device)
    }
}

private func surfaceDialRemoved(
    context: UnsafeMutableRawPointer?,
    result: IOReturn,
    sender: UnsafeMutableRawPointer?,
    device: IOHIDDevice
) {
    guard let context else { return }
    let manager = Unmanaged<SurfaceDialManager>.fromOpaque(context).takeUnretainedValue()
    DispatchQueue.main.async {
        manager.deviceRemoved(device)
    }
}

private func surfaceDialReport(
    context: UnsafeMutableRawPointer?,
    result: IOReturn,
    sender: UnsafeMutableRawPointer?,
    type: IOHIDReportType,
    reportID: UInt32,
    report: UnsafeMutablePointer<UInt8>,
    reportLength: CFIndex
) {
    guard let context, reportLength > 0 else { return }
    let bytes = Array(UnsafeBufferPointer(start: report, count: reportLength))
    let manager = Unmanaged<SurfaceDialManager>.fromOpaque(context).takeUnretainedValue()
    DispatchQueue.main.async {
        manager.process(reportID: reportID, bytes: bytes)
    }
}
