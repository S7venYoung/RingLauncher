import Foundation
import IOKit.hid
import OSLog

@MainActor
final class SurfaceDialManager: ObservableObject {
    static let shared = SurfaceDialManager()

    static let vendorID = 0x045E
    static let productID = 0x091B

    @Published private(set) var isConnected = false

    var onRotation: ((Int) -> Void)?
    var onButtonChanged: ((Bool) -> Void)?

    private let logger = Logger(
        subsystem: "com.s7venyoung.orbitlauncher",
        category: "SurfaceDial"
    )
    private var manager: IOHIDManager?
    private var running = false
    private var lastButtonPressed = false

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
        logger.notice("Surface Dial HID manager started result=\(result, privacy: .public)")
    }

    func stop() {
        guard running, let manager else { return }
        IOHIDManagerUnscheduleFromRunLoop(
            manager,
            CFRunLoopGetMain(),
            CFRunLoopMode.commonModes.rawValue
        )
        IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        self.manager = nil
        running = false
        isConnected = false
        lastButtonPressed = false
    }

    fileprivate func deviceAdded() {
        isConnected = true
        logger.notice("Surface Dial connected")
    }

    fileprivate func deviceRemoved() {
        isConnected = false
        lastButtonPressed = false
        logger.notice("Surface Dial disconnected")
    }

    fileprivate func process(reportID: UInt32, bytes: [UInt8]) {
        let payload: ArraySlice<UInt8>
        if bytes.first == 1, bytes.count >= 3 {
            payload = bytes.dropFirst()
        } else if reportID == 1, bytes.count >= 2 {
            payload = bytes[...]
        } else {
            logger.debug("Ignoring HID report id=\(reportID, privacy: .public) length=\(bytes.count, privacy: .public)")
            return
        }

        guard payload.count >= 2 else { return }
        let values = Array(payload)
        let pressed = values[0] & 1 == 1
        if pressed != lastButtonPressed {
            lastButtonPressed = pressed
            onButtonChanged?(pressed)
        }

        switch values[1] {
        case 0x01:
            onRotation?(1)
        case 0xFF:
            onRotation?(-1)
        default:
            break
        }
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
        manager.deviceAdded()
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
        manager.deviceRemoved()
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
