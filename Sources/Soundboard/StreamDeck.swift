import Foundation
import IOKit.hid

struct DeckModel {
    let name: String
    let keyCount: Int
    let columns: Int
    let keySize: Int
    /// Capacitive buttons reported after the LCD keys (Neo: the two below the screen).
    let touchKeys: Int
    let screen: (width: Int, height: Int)?
}

let deckVendorID = 0x0fd9

/// Models that share the "gen 2" protocol (1024-byte JPEG image reports).
/// Only the Neo has been tested on real hardware.
let deckModels: [Int: DeckModel] = [
    0x009a: DeckModel(name: "Stream Deck Neo", keyCount: 8, columns: 4, keySize: 96, touchKeys: 2, screen: (248, 58)),
    0x006d: DeckModel(name: "Stream Deck", keyCount: 15, columns: 5, keySize: 72, touchKeys: 0, screen: nil),
    0x0080: DeckModel(name: "Stream Deck MK.2", keyCount: 15, columns: 5, keySize: 72, touchKeys: 0, screen: nil),
    0x00a5: DeckModel(name: "Stream Deck MK.2", keyCount: 15, columns: 5, keySize: 72, touchKeys: 0, screen: nil),
    0x006c: DeckModel(name: "Stream Deck XL", keyCount: 32, columns: 8, keySize: 96, touchKeys: 0, screen: nil),
    0x008f: DeckModel(name: "Stream Deck XL", keyCount: 32, columns: 8, keySize: 96, touchKeys: 0, screen: nil),
]

protocol StreamDeckDelegate: AnyObject {
    func deckDidConnect(_ deck: StreamDeck)
    func deckDidDisconnect(_ deck: StreamDeck)
    func deck(_ deck: StreamDeck, button: Int, pressed: Bool)
}

/// Watches USB for a supported Stream Deck and keeps one connected.
final class StreamDeckManager {
    weak var delegate: StreamDeckDelegate?
    private(set) var deck: StreamDeck?
    private let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))

    func start() {
        IOHIDManagerSetDeviceMatching(manager, [kIOHIDVendorIDKey: deckVendorID] as CFDictionary)
        let context = Unmanaged.passUnretained(self).toOpaque()
        IOHIDManagerRegisterDeviceMatchingCallback(manager, { context, _, _, device in
            Unmanaged<StreamDeckManager>.fromOpaque(context!).takeUnretainedValue().attached(device)
        }, context)
        IOHIDManagerRegisterDeviceRemovalCallback(manager, { context, _, _, device in
            Unmanaged<StreamDeckManager>.fromOpaque(context!).takeUnretainedValue().removed(device)
        }, context)
        // Common modes so keys keep working while the menu is open.
        IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
        // Devices are opened one by one in `attached`, so a busy device can be retried.
    }

    /// Plugged in but held exclusively by another app (such as the vendor's own software).
    private(set) var busyDevice: IOHIDDevice?
    private var retryTimer: Timer?

    private func attached(_ device: IOHIDDevice) {
        guard deck == nil,
              let pid = IOHIDDeviceGetProperty(device, kIOHIDProductIDKey as CFString) as? Int,
              let model = deckModels[pid]
        else { return }

        let result = IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeNone))
        guard result == kIOReturnSuccess else {
            if busyDevice == nil { NSLog("Soundboard: Stream Deck busy (0x%08x), will keep retrying", result) }
            busyDevice = device
            retryTimer?.invalidate()
            retryTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: false) { [weak self] _ in
                guard let self, let device = self.busyDevice else { return }
                self.attached(device)
            }
            return
        }
        busyDevice = nil
        retryTimer?.invalidate()

        let deck = StreamDeck(device: device, model: model)
        deck.onButton = { [weak self, weak deck] index, pressed in
            guard let self, let deck else { return }
            self.delegate?.deck(deck, button: index, pressed: pressed)
        }
        self.deck = deck
        delegate?.deckDidConnect(deck)
    }

    private func removed(_ device: IOHIDDevice) {
        if busyDevice === device {
            busyDevice = nil
            retryTimer?.invalidate()
        }
        guard let deck, deck.device === device else { return }
        self.deck = nil
        delegate?.deckDidDisconnect(deck)
    }
}

/// Talks the Stream Deck gen-2 HID protocol.
final class StreamDeck {
    let device: IOHIDDevice
    let model: DeckModel
    var onButton: ((Int, Bool) -> Void)?

    private static let imageReportLength = 1024
    private static let imageHeaderLength = 8
    private let io = DispatchQueue(label: "soundboard.streamdeck.io")
    private let reportBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 512)
    private var states: [Bool]
    private let debug = ProcessInfo.processInfo.environment["SOUNDBOARD_DEBUG"] != nil
    /// The newest screen image not yet sent; older ones are dropped if the device falls behind.
    private var pendingScreen: Data?
    private let screenLock = NSLock()
    private var screenStats = (frames: 0, seconds: 0.0)

    var buttonCount: Int { model.keyCount + model.touchKeys }

    init(device: IOHIDDevice, model: DeckModel) {
        self.device = device
        self.model = model
        states = Array(repeating: false, count: model.keyCount + model.touchKeys)
        IOHIDDeviceRegisterInputReportCallback(device, reportBuffer, 512, { context, _, _, _, _, report, length in
            Unmanaged<StreamDeck>.fromOpaque(context!).takeUnretainedValue().handle(report, Int(length))
        }, Unmanaged.passUnretained(self).toOpaque())
    }

    deinit {
        IOHIDDeviceRegisterInputReportCallback(device, reportBuffer, 512, nil, nil)
        reportBuffer.deallocate()
    }

    /// Report layout: [0x01, 0x00, count lo, count hi, key0, key1, …].
    private func handle(_ report: UnsafeMutablePointer<UInt8>, _ length: Int) {
        if debug {
            NSLog("Soundboard HID: %@", (0..<min(length, 16)).map { String(format: "%02x", report[$0]) }.joined(separator: " "))
        }
        guard length >= 4 + states.count, report[0] == 0x01 else { return }
        for i in 0..<states.count {
            let pressed = report[4 + i] != 0
            if pressed != states[i] {
                states[i] = pressed
                onButton?(i, pressed)
            }
        }
    }

    func setBrightness(_ percent: Int) {
        sendFeature([0x03, 0x08, UInt8(clamping: max(0, min(100, percent)))])
    }

    /// Resets the device, which clears the keys back to its built-in logo.
    func reset() {
        sendFeature([0x03, 0x02])
    }

    func setKeyImage(_ key: Int, jpeg: Data) {
        sendImage(command: 0x07, index: UInt8(key), jpeg)
    }

    func setScreenImage(_ jpeg: Data) {
        let queued = screenLock.withLock {
            defer { pendingScreen = jpeg }
            return pendingScreen != nil
        }
        if queued { return } // the write already queued will pick this one up
        io.async { [self] in
            guard let jpeg = screenLock.withLock({ defer { pendingScreen = nil }; return pendingScreen }) else { return }
            let start = Date()
            writeImage(command: 0x0b, index: 0, jpeg)
            if debug {
                screenStats.frames += 1
                screenStats.seconds += Date().timeIntervalSince(start)
                if screenStats.frames == 100 {
                    NSLog("Soundboard: screen write %.1f ms avg (%ld bytes)", screenStats.seconds * 10, jpeg.count)
                    screenStats = (0, 0)
                }
            }
        }
    }

    /// Blocks until queued writes have reached the device.
    func flush() {
        io.sync {}
    }

    private func sendFeature(_ bytes: [UInt8]) {
        let device = self.device
        io.async {
            var payload = bytes + [UInt8](repeating: 0, count: 32 - bytes.count)
            let result = IOHIDDeviceSetReport(device, kIOHIDReportTypeFeature, CFIndex(payload[0]), &payload, payload.count)
            if result != kIOReturnSuccess { NSLog("Soundboard: feature report failed: 0x%08x", result) }
        }
    }

    private func sendImage(command: UInt8, index: UInt8, _ data: Data) {
        io.async { self.writeImage(command: command, index: index, data) }
    }

    /// Sends one image as a run of output reports. Runs on `io`.
    private func writeImage(command: UInt8, index: UInt8, _ data: Data) {
        let bytes = [UInt8](data)
        let chunk = Self.imageReportLength - Self.imageHeaderLength
        var report = [UInt8](repeating: 0, count: Self.imageReportLength)
        var offset = 0
        var page = 0
        while offset < bytes.count {
            let length = min(chunk, bytes.count - offset)
            let isLast: UInt8 = offset + length == bytes.count ? 1 : 0
            report.withUnsafeMutableBufferPointer { buffer in
                buffer.update(repeating: 0)
                buffer[0] = 0x02
                buffer[1] = command
                buffer[2] = index
                buffer[3] = isLast
                buffer[4] = UInt8(length & 0xff)
                buffer[5] = UInt8(length >> 8)
                buffer[6] = UInt8(page & 0xff)
                buffer[7] = UInt8(page >> 8)
                for i in 0..<length { buffer[Self.imageHeaderLength + i] = bytes[offset + i] }
            }
            let result = IOHIDDeviceSetReport(device, kIOHIDReportTypeOutput, 0x02, report, report.count)
            if result != kIOReturnSuccess {
                NSLog("Soundboard: image report failed: 0x%08x", result)
                return
            }
            offset += length
            page += 1
        }
    }
}
