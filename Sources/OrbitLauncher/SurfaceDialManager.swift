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
    private var lastButtonPressed = false
    private var tickAccumulator = 0
    private var lastReportTime: TimeInterval = 0
    private var wakeObserver: NSObjectProtocol?
    private var reconnectWorkItem: DispatchWorkItem?
    private let idleWakeThreshold: TimeInterval = 15

    private init() {}

    func start() {
        guard !running else { return }
        running = true
        installWakeObserver()
        openHIDManager()
    }

    func stop() {
        guard running else { return }
        running = false
        reconnectWorkItem?.cancel()
        reconnectWorkItem = nil
        if let wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver)
            self.wakeObserver = nil
        }
        closeHIDManager()
        resetDeviceState()
    }

    func setHapticsEnabled(_ enabled: Bool) {
        hapticsEnabled = enabled
        guard let device else { return }
        configureHaptics(on: device)
    }

    fileprivate func deviceAdded(_ device: IOHIDDevice) {
        reconnectWorkItem?.cancel()
        reconnectWorkItem = nil
        self.device = device
        resolution = readResolution(from: device) ?? 360
        tickAccumulator = 0
        lastReportTime = Date.timeIntervalSinceReferenceDate
        isConnected = true
        configureHaptics(on: device)
        logger.notice(
            "Surface Dial connected resolution=\(self.resolution, privacy: .public) ticks/rev"
        )
    }

    fileprivate func deviceRemoved(_ removedDevice: IOHIDDevice) {
        guard let device, CFEqual(device, removedDevice) else { return }
        resetDeviceState()
        logger.notice("Surface Dial disconnected; scheduling HID recovery")
        scheduleReconnect(after: 1.2)
    }

    fileprivate func reportFailed(_ result: IOReturn) {
        logger.error(
            "Surface Dial input report failed result=\(result, privacy: .public); scheduling HID recovery"
        )
        scheduleReconnect(after: 0.8)
    }

    private func openHIDManager() {
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
        logger.notice("Surface Dial HID manager started result=\(result, privacy: .public)")
        if result != kIOReturnSuccess {
            scheduleReconnect(after: 1.5)
        }
    }

    private func closeHIDManager() {
        guard let manager else { return }
        IOHIDManagerUnscheduleFromRunLoop(
            manager,
            CFRunLoopGetMain(),
            CFRunLoopMode.commonModes.rawValue
        )
        IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        self.manager = nil
    }

    private func installWakeObserver() {
        guard wakeObserver == nil else { return }
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.recoverAfterSystemWake()
            }
        }
    }

    private func recoverAfterSystemWake() {
        guard running else { return }
        tickAccumulator = 0
        lastButtonPressed = false
        lastReportTime = 0
        logger.notice("Mac woke from sleep; rebuilding Surface Dial HID session")
        scheduleReconnect(after: 0.8)
    }

    private func scheduleReconnect(after delay: TimeInterval) {
        guard running else { return }
        reconnectWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            Task { @MainActor in
                self?.restartHIDSession()
            }
        }
        reconnectWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
    }

    private func restartHIDSession() {
        guard running else { return }
        reconnectWorkItem = nil
        closeHIDManager()
        resetDeviceState()
        openHIDManager()
    }

    private func resetDeviceState() {
        device = nil
        isConnected = false
        resolution = 360
        lastButtonPressed = false
        tickAccumulator = 0
        lastReportTime = 0
    }

    private func configureHaptics(on device: IOHIDDevice) {
        let steps = max(1, min(AppSettings.shared.surfaceDialStepsPerRotation, Int(UInt16.max)))
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
            logger.notice(
                "Surface Dial haptics configured enabled=\(self.hapticsEnabled, privacy: .public) steps/rev=\(steps, privacy: .public)"
            )
        } else {
            logger.error(
                "Surface Dial haptics configuration failed result=\(result, privacy: .public)"
            )
        }
    }

    fileprivate func process(reportID: UInt32, bytes: [UInt8]) {
        let payload = bytes.first == 1 && bytes.count >= 4
            ? Array(bytes.dropFirst())
            : bytes
        guard reportID == 1 || bytes.first == 1, payload.count >= 3 else {
            logger.debug(
                "Ignoring HID report id=\(reportID, privacy: .public) length=\(bytes.count, privacy: .public)"
            )
            return
        }

        let now = Date.timeIntervalSinceReferenceDate
        let wokeFromIdle =
            lastReportTime > 0 &&
            now - lastReportTime >= idleWakeThreshold
        lastReportTime = now

        if wokeFromIdle {
            tickAccumulator = 0
            lastButtonPressed = false
            if let device {
                configureHaptics(on: device)
            }
            logger.notice("Surface Dial woke from idle; state and haptics restored")
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
    guard let context else { return }
    let manager = Unmanaged<SurfaceDialManager>.fromOpaque(context).takeUnretainedValue()
    guard result == kIOReturnSuccess, reportLength > 0 else {
        DispatchQueue.main.async {
            manager.reportFailed(result)
        }
        return
    }
    let bytes = Array(UnsafeBufferPointer(start: report, count: reportLength))
    DispatchQueue.main.async {
        manager.process(reportID: reportID, bytes: bytes)
    }
}
