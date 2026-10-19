import Foundation
import IOBluetooth

public enum BudsError: LocalizedError {
    case noPairedBuds
    case notConnected
    case basebandFailed(IOReturn)
    case noServiceRecord
    case noChannel
    case openFailed(IOReturn)
    case timeout(String)
    case blocked(UInt8)

    public var errorDescription: String? {
        switch self {
        case .noPairedBuds: String(localized: "No paired Galaxy Buds found")
        case .notConnected: String(localized: "RFCOMM channel is not open")
        case .basebandFailed(let r): String(format: String(localized: "Bluetooth connection failed (0x%08X)"), r)
        case .noServiceRecord: String(localized: "No SPP service record (SDP)")
        case .noChannel: String(localized: "Could not get the RFCOMM channel number")
        case .openFailed(let r): String(format: String(localized: "Failed to open RFCOMM (0x%08X)"), r)
        case .timeout(let what): String(localized: "\(what) timed out")
        case .blocked(let id): String(format: String(localized: "0x%02X is blocked by the safety policy"), id)
        }
    }
}

/// RFCOMM link to the Buds' Samsung SPP service. All callbacks arrive on the main run loop.
@MainActor
public final class BudsConnection: NSObject {
    /// Samsung "SppNew" service (GEARMANAGER), used by Buds2 and later.
    public static let serviceUUID: [UInt8] = [0x2E, 0x73, 0xA4, 0xAD, 0x33, 0x2D, 0x41, 0xFC,
                                              0x90, 0xE2, 0x16, 0xBE, 0xF0, 0x65, 0x23, 0xF2]

    public var onFrame: ((Frame) -> Void)?
    public var onSent: ((Frame) -> Void)?
    public var onClosed: (() -> Void)?

    public private(set) var device: IOBluetoothDevice?
    private var channel: IOBluetoothRFCOMMChannel?
    private var parser = FrameParser()
    private var pending: CheckedContinuation<Void, Error>?
    private var waitGeneration = 0

    public var isOpen: Bool { channel?.isOpen() ?? false }

    /// Paired devices that look like Galaxy Buds, connected ones first.
    public static func pairedBuds() -> [IOBluetoothDevice] {
        let all = (IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice]) ?? []
        // pairedDevices() can list the same device twice and its objects report a stale
        // isConnected(), so re-resolve each unique address.
        var seen = Set<String>()
        return all
            .filter { ($0.name ?? "").localizedCaseInsensitiveContains("Buds") }
            .compactMap { $0.addressString }
            .filter { seen.insert($0.lowercased()).inserted }
            .compactMap { IOBluetoothDevice(addressString: $0) }
            .sorted { $0.isConnected() && !$1.isConnected() }
    }

    public static func findBuds(address: String? = nil) -> IOBluetoothDevice? {
        if let address { return IOBluetoothDevice(addressString: address) }
        return pairedBuds().first
    }

    /// Pages the Buds (baseband connect) without blocking the main thread. Only for explicit user
    /// actions: paging pulls the Buds away from whatever they are connected to (e.g. a phone).
    /// Returns once IOBluetooth reports the result; a missing callback (seen when the link is
    /// already up) ends in a timeout, which the caller treats as "unknown" rather than failure.
    public func page(_ device: IOBluetoothDevice, timeout: Double = 8) async throws {
        try await wait(timeout: timeout, what: String(localized: "Bluetooth connection")) {
            let r = device.openConnection(self)
            if r != kIOReturnSuccess { throw BudsError.basebandFailed(r) }
        }
    }

    /// Opens the SPP channel. With `page` the baseband link is (re)established first; that call
    /// returns immediately when the Buds are already connected.
    public func connect(to device: IOBluetoothDevice, page: Bool = true) async throws {
        disconnect()
        self.device = device
        parser = FrameParser()

        if page {
            // Returns at once when the link is already up (isConnected() can be stale, so always ask).
            let r = device.openConnection()
            if r != kIOReturnSuccess { throw BudsError.basebandFailed(r) }
        }

        let uuid = IOBluetoothSDPUUID(bytes: Self.serviceUUID, length: 16)
        if device.getServiceRecord(for: uuid) == nil {
            // UUID-filtered queries silently fail since Ventura, so query everything.
            try? await wait(timeout: 3, what: "SDP") {
                let r = device.performSDPQuery(self)
                if r != kIOReturnSuccess { throw BudsError.noServiceRecord }
            }
        }
        guard let record = device.getServiceRecord(for: uuid) else { throw BudsError.noServiceRecord }
        var channelID: BluetoothRFCOMMChannelID = 0
        guard record.getRFCOMMChannelID(&channelID) == kIOReturnSuccess else { throw BudsError.noChannel }

        try await wait(timeout: 8, what: String(localized: "Opening RFCOMM")) {
            var chan: IOBluetoothRFCOMMChannel?
            let r = device.openRFCOMMChannelAsync(&chan, withChannelID: channelID, delegate: self)
            if r != kIOReturnSuccess { throw BudsError.openFailed(r) }
            self.channel = chan
        }
    }

    public func disconnect() {
        if let pending { self.pending = nil; pending.resume(throwing: CancellationError()) }
        let chan = channel
        channel = nil
        chan?.setDelegate(nil)
        chan?.close()
    }

    public func send(_ frame: Frame) throws {
        guard SendPolicy.isAllowed(frame.id) else { throw BudsError.blocked(frame.id) }
        guard let channel, channel.isOpen() else { throw BudsError.notConnected }
        var bytes = frame.encoded()
        let mtu = max(Int(channel.getMTU()), 16)
        var offset = 0
        while offset < bytes.count {
            let n = min(mtu, bytes.count - offset)
            let r = bytes.withUnsafeMutableBytes { buf in
                channel.writeSync(buf.baseAddress!.advanced(by: offset), length: UInt16(n))
            }
            if r != kIOReturnSuccess { throw BudsError.openFailed(r) }
            offset += n
        }
        onSent?(frame)
    }

    public func send(_ command: Command) throws { try send(command.frame) }

    // MARK: async helpers

    /// Runs `start`, then suspends until a delegate callback calls `finish` or the timeout fires.
    private func wait(timeout: Double, what: String, _ start: @escaping () throws -> Void) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            pending = cont
            waitGeneration += 1
            let generation = waitGeneration
            do { try start() } catch { finish(error); return }
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(timeout))
                guard let self, self.waitGeneration == generation else { return }
                self.finish(BudsError.timeout(what))
            }
        }
    }

    private func finish(_ error: Error?) {
        guard let cont = pending else { return }
        pending = nil
        if let error { cont.resume(throwing: error) } else { cont.resume() }
    }
}

// MARK: - IOBluetooth delegates (delivered on the main thread)

extension BudsConnection: IOBluetoothRFCOMMChannelDelegate, IOBluetoothDeviceAsyncCallbacks {
    nonisolated public func rfcommChannelData(_ rfcommChannel: IOBluetoothRFCOMMChannel!,
                                              data dataPointer: UnsafeMutableRawPointer!, length dataLength: Int) {
        let bytes = [UInt8](UnsafeRawBufferPointer(start: dataPointer, count: dataLength))
        MainActor.assumeIsolated {
            for frame in parser.feed(bytes) { onFrame?(frame) }
        }
    }

    nonisolated public func rfcommChannelOpenComplete(_ opened: IOBluetoothRFCOMMChannel!, status error: IOReturn) {
        nonisolated(unsafe) let rfcommChannel = opened!
        MainActor.assumeIsolated {
            // macOS sometimes reports an error although the channel is usable; trust isOpen().
            if error == kIOReturnSuccess || rfcommChannel.isOpen() {
                channel = rfcommChannel
                finish(nil)
            } else {
                finish(BudsError.openFailed(error))
            }
        }
    }

    nonisolated public func rfcommChannelClosed(_ closed: IOBluetoothRFCOMMChannel!) {
        nonisolated(unsafe) let rfcommChannel = closed!
        MainActor.assumeIsolated {
            guard rfcommChannel === channel else { return }   // ignore stale / duplicate notices
            channel = nil
            finish(BudsError.notConnected)
            onClosed?()
        }
    }

    nonisolated public func connectionComplete(_ device: IOBluetoothDevice!, status: IOReturn) {
        MainActor.assumeIsolated {
            finish(status == kIOReturnSuccess ? nil : BudsError.basebandFailed(status))
        }
    }

    nonisolated public func sdpQueryComplete(_ device: IOBluetoothDevice!, status: IOReturn) {
        MainActor.assumeIsolated { finish(nil) }
    }

    nonisolated public func remoteNameRequestComplete(_ device: IOBluetoothDevice!, status: IOReturn) {}
}
