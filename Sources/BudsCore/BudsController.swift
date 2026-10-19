import Foundation
import IOBluetooth
import Observation

/// Owns the connection, keeps `state` in sync with what the earbuds report, and exposes setters
/// that send a command and update the local state optimistically.
@MainActor
@Observable
public final class BudsController {
    public enum LinkStatus: Equatable, Sendable {
        case idle
        case searching
        case connecting(String)
        case connected(String)
        case waiting(String)          // paired but not reachable; waiting for the buds to come back
        case failed(String)

        public var isConnected: Bool { if case .connected = self { true } else { false } }
        public var label: String {
            switch self {
            case .idle: String(localized: "Idle")
            case .searching: String(localized: "Looking for Buds…")
            case .connecting(let n): String(localized: "Connecting to \(n)…")
            case .connected(let n): n
            case .waiting: String(localized: "Not connected to this Mac")
            case .failed(let e): String(localized: "Error: \(e)")
            }
        }
    }

    /// Progress of the user-initiated "Bring to Mac" action.
    public enum BringState: Equatable, Sendable {
        case idle
        case working(attempt: Int, of: Int)
        case cancelling
        case succeeded
        case failed(String)
        case cancelled

        public var isActive: Bool {
            switch self { case .working, .cancelling: true; default: false }
        }
        public var label: String? {
            switch self {
            case .idle: nil
            case .working(let a, let n): String(format: String(localized: "Bringing to Mac… %d/%d"), a, n)
            case .cancelling: String(localized: "Cancelling…")
            case .succeeded: String(localized: "Connected to this Mac")
            case .failed(let e): e
            case .cancelled: String(localized: "Cancelled")
            }
        }
    }

    public private(set) var status: LinkStatus = .idle
    public private(set) var bring: BringState = .idle
    public var state = BudsState()
    public private(set) var deviceName: String?
    public private(set) var hasESU = false
    public private(set) var lastError: String?

    /// User-chosen custom EQ bands. The firmware forgets them on power cycle and on every
    /// noise-control change, so the host re-sends them.
    public var customBands: [Int] {
        didSet { UserDefaults.standard.set(customBands, forKey: "customBands") }
    }

    /// Raw frame taps for the CLI / debug log.
    @ObservationIgnored public var onFrame: ((Frame) -> Void)?
    @ObservationIgnored public var onSent: ((Frame) -> Void)?
    @ObservationIgnored public var log: (String) -> Void = { _ in }

    /// True while the buds are connected at the baseband level (from IOBluetooth notifications).
    public private(set) var budsPresent = false

    @ObservationIgnored private let connection = BudsConnection()
    @ObservationIgnored private var address: String?
    @ObservationIgnored private var autoReconnect = true
    @ObservationIgnored private var pollTask: Task<Void, Never>?
    @ObservationIgnored private var connectNotification: IOBluetoothUserNotification?
    @ObservationIgnored private var disconnectNotification: IOBluetoothUserNotification?
    @ObservationIgnored private var observer: ConnectObserver?
    @ObservationIgnored private var connecting = false
    @ObservationIgnored private var rfcommRetries = 0
    @ObservationIgnored private var bringTask: Task<Bool, Never>?
    /// Bumped on every baseband disconnect; Bring uses it to see whether a page held.
    @ObservationIgnored private var basebandDrops = 0

    /// Bring to Mac tuning: attempts, pause between them, and how long the page must hold.
    static let bringAttempts = 4
    static let bringRetryDelay: Duration = .seconds(2)
    static let bringHold: Duration = .seconds(3)

    public init(address: String? = nil) {
        self.address = address
        customBands = (UserDefaults.standard.array(forKey: "customBands") as? [Int]) ?? Array(repeating: 0, count: 9)
        state.touchpadLocked = UserDefaults.standard.bool(forKey: "touchpadLocked")
        connection.onFrame = { [weak self] in self?.handle($0) }
        connection.onSent = { [weak self] in self?.onSent?($0) }
        connection.onClosed = { [weak self] in self?.linkClosed() }
    }

    // MARK: connection lifecycle
    //
    // Event driven, no polling: while the buds are away the app only waits for IOBluetooth's
    // connect notification. When they connect we open RFCOMM; when the device-level disconnect
    // notification fires we close it again and go quiet.

    /// Start watching for the paired Buds. IOBluetooth delivers a connect notification right away
    /// for devices that are already connected, so that single path covers both cases.
    /// (`IOBluetoothDevice.isConnected()` is not trustworthy here: on macOS 26 it returned false for
    /// connected Buds in a fresh process, so presence is tracked from notifications only.)
    public func start(autoReconnect: Bool = true) {
        self.autoReconnect = autoReconnect
        // Register before touching any IOBluetoothDevice: creating device objects first made the
        // initial "already connected" notification go missing in testing.
        watchForConnections()
        status = .waiting(deviceName ?? "Buds")
    }

    /// `page: true` forces a baseband connection (CLI / explicit user action).
    public func connect(page: Bool = true) async {
        guard !connecting, !connection.isOpen, bringTask == nil else { return }
        connecting = true
        defer { connecting = false }
        status = .searching
        guard let device = BudsConnection.findBuds(address: address) else {
            status = .failed(BudsError.noPairedBuds.localizedDescription)
            log("no paired Buds visible (\(IOBluetoothDevice.pairedDevices()?.count ?? 0) paired devices; Bluetooth permission?)")
            return
        }
        let name = device.name ?? device.addressString ?? "Buds"
        deviceName = name
        address = device.addressString
        if !budsPresent && !page {
            status = .waiting(name)
            log("\(name) not connected; waiting for connect event")
            return
        }
        status = .connecting(name)
        log("opening RFCOMM to \(name)")
        do {
            try await connection.connect(to: device, page: page)
            didConnect(device, name: name)
        } catch {
            lastError = error.localizedDescription
            log("connect failed: \(error.localizedDescription)")
            status = .failed(error.localizedDescription)
            retryWhileBasebandUp()
        }
    }

    private func didConnect(_ device: IOBluetoothDevice, name: String) {
        if bringTask == nil { bring = .idle }   // drop a stale Bring result after an automatic connect
        hasESU = false
        rfcommRetries = 0
        status = .connected(name)
        lastError = nil
        budsPresent = true
        if autoReconnect { watchForDisconnect(device) }
        log("connected \(name) [\(device.addressString ?? "")]")
        afterConnect()
    }

    // MARK: Bring to Mac
    //
    // The only place where the app pages the Buds on its own, and only because the user asked.
    // When the Buds prefer the phone they often accept the page and drop it again within a
    // second, so each attempt checks that the baseband link holds before opening RFCOMM.
    // The loop lives inside this one action; afterwards the automatic paths stay page-free.

    public var isBringing: Bool { bringTask != nil }

    /// Starts Bring to Mac, or cancels it when it is already running.
    public func toggleBring() {
        if bringTask != nil { cancelBring() } else { startBring() }
    }

    public func cancelBring() {
        guard let bringTask else { return }
        log("bring: cancel requested")
        bring = .cancelling
        bringTask.cancel()
    }

    /// Returns the running task; its value is true when RFCOMM ended up open.
    @discardableResult
    public func startBring() -> Task<Bool, Never> {
        if let bringTask { return bringTask }
        let task = Task { [weak self] () -> Bool in
            guard let self else { return false }
            let ok = await self.runBring()
            self.bringTask = nil
            if !ok { self.retryWhileBasebandUp() }   // non-paging fallback if the link is up anyway
            return ok
        }
        bringTask = task
        return task
    }

    private func runBring() async -> Bool {
        let total = Self.bringAttempts
        lastError = nil
        if connection.isOpen { bring = .succeeded; return true }
        guard let device = BudsConnection.findBuds(address: address) else {
            bring = .failed(BudsError.noPairedBuds.localizedDescription)
            return false
        }
        let name = device.name ?? device.addressString ?? "Buds"
        deviceName = name
        address = device.addressString
        var reason = String(localized: "The Buds did not stay connected. They may be in use on your phone.")

        for attempt in 1...total {
            if Task.isCancelled { break }
            bring = .working(attempt: attempt, of: total)
            log("bring: attempt \(attempt)/\(total)")
            let drops = basebandDrops

            // 1. Page. A timeout here is not fatal: the link may already be up.
            do {
                try await connection.page(device)
            } catch BudsError.timeout {
                log("bring: page callback timed out")
            } catch {
                log("bring: page failed: \(error.localizedDescription)")
                reason = error.localizedDescription
                if await pauseBeforeRetry(attempt) { continue } else { break }
            }
            if Task.isCancelled { break }

            // 2. Hold: the baseband must stay up (no disconnect notification) for a few seconds.
            try? await Task.sleep(for: Self.bringHold)
            if Task.isCancelled { break }
            guard basebandDrops == drops, budsPresent || device.isConnected() else {
                log("bring: link dropped during hold")
                if await pauseBeforeRetry(attempt) { continue } else { break }
            }

            // 3. RFCOMM (no page; the link is up).
            if connection.isOpen { bring = .succeeded; return true }
            status = .connecting(name)
            log("bring: opening RFCOMM to \(name)")
            do {
                try await connection.connect(to: device, page: false)
                didConnect(device, name: name)
                bring = .succeeded
                log("bring: done")
                return true
            } catch {
                log("bring: RFCOMM failed: \(error.localizedDescription)")
                reason = error.localizedDescription
                status = .waiting(name)
                if Task.isCancelled { break }
                if await pauseBeforeRetry(attempt) { continue } else { break }
            }
        }

        if Task.isCancelled {
            log("bring: cancelled")
            bring = .cancelled
        } else {
            log("bring: gave up")
            bring = .failed(reason)
        }
        if !connection.isOpen { status = .waiting(name) }
        return false
    }

    /// Sleeps between attempts. Returns false when there is no next attempt or it was cancelled.
    private func pauseBeforeRetry(_ attempt: Int) async -> Bool {
        guard attempt < Self.bringAttempts, !Task.isCancelled else { return false }
        try? await Task.sleep(for: Self.bringRetryDelay)
        return !Task.isCancelled
    }

    public func disconnect() {
        autoReconnect = false
        pollTask?.cancel()
        connection.disconnect()
        status = .idle
    }

    private func linkClosed() {
        log("rfcomm closed")
        if bring == .succeeded { bring = .idle }
        pollTask?.cancel()
        status = deviceName.map { .waiting($0) } ?? .idle
        retryWhileBasebandUp()
    }

    /// The SPP channel can drop while the buds stay connected (e.g. the phone grabbed it).
    /// Retry a couple of times in that case only; once the baseband link is gone we just wait
    /// for the connect notification. Retries never page: when the buds have moved to the phone,
    /// paging them would pull them back to the Mac.
    private func retryWhileBasebandUp() {
        guard autoReconnect, budsPresent, bringTask == nil, rfcommRetries < 3 else { return }
        rfcommRetries += 1
        let delay = Double(rfcommRetries) * 3
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard let self, self.budsPresent, self.bringTask == nil,
                  let device = BudsConnection.findBuds(address: self.address), device.isConnected()
            else { return }
            await self.connect(page: false)
        }
    }

    /// Baseband went away: close RFCOMM, dim the icon and stay idle until the next connect event.
    private func budsWentAway() {
        log("baseband disconnected")
        budsPresent = false
        basebandDrops += 1
        if bring == .succeeded { bring = .idle }
        pollTask?.cancel()
        connection.disconnect()
        disconnectNotification?.unregister()
        disconnectNotification = nil
        rfcommRetries = 0
        status = deviceName.map { .waiting($0) } ?? .idle
    }

    private func isOurBuds(_ device: IOBluetoothDevice) -> Bool {
        if let address { return address.caseInsensitiveCompare(device.addressString ?? "") == .orderedSame }
        return (device.name ?? "").localizedCaseInsensitiveContains("Buds")
    }

    private func watchForConnections() {
        guard connectNotification == nil else { return }
        let observer = ConnectObserver(
            connected: { [weak self] device in
                guard let self, self.isOurBuds(device) else { return }
                self.log("baseband connected: \(device.name ?? "")")
                self.budsPresent = true
                self.rfcommRetries = 0
                self.watchForDisconnect(device)
                // While Bring to Mac runs it opens RFCOMM itself after its hold check.
                guard !self.connection.isOpen, self.bringTask == nil else { return }
                Task {
                    try? await Task.sleep(for: .seconds(1.5))   // let A2DP/HFP settle first
                    await self.connect(page: false)     // never page from an event: see retryWhileBasebandUp
                }
            },
            disconnected: { [weak self] device in
                guard let self, self.isOurBuds(device) else { return }
                self.budsWentAway()
            })
        self.observer = observer
        connectNotification = IOBluetoothDevice.register(forConnectNotifications: observer,
                                                         selector: #selector(ConnectObserver.connected(_:device:)))
    }

    private func watchForDisconnect(_ device: IOBluetoothDevice) {
        guard autoReconnect, disconnectNotification == nil, let observer else { return }
        disconnectNotification = device.register(forDisconnectNotification: observer,
                                                 selector: #selector(ConnectObserver.disconnected(_:device:)))
    }

    private func afterConnect() {
        // The buds send an ESU on their own; nudge them if it does not arrive.
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(150))
            self?.send(.query(.debugSku))
            self?.send(.query(.cradleSerialNumber))
            self?.send(.query(.debugSerialNumber))
            try? await Task.sleep(for: .seconds(1))
            guard let self, !Task.isCancelled else { return }
            self.send(.query(.debugGetAllData))
        }
    }

    // MARK: incoming

    private func handle(_ frame: Frame) {
        onFrame?(frame)
        switch frame.msg {
        case .extendedStatusUpdated:
            let first = !hasESU
            state.applyESU(frame.payload)
            hasESU = true
            if first {
                send(.managerInfo)
                if state.eq == .custom { pushCustomEQ(select: true) }
            }
        case .statusUpdated:
            state.applyStatus(frame.payload)
        case .noiseControlsUpdate:
            if let m = frame.payload.first.flatMap(NoiseMode.init) { state.noiseMode = m }
            // Buds4 Pro drops the custom band table whenever the noise-control mode changes.
            if state.eq == .custom { pushCustomEQ(select: true) }
        case .ambientVolume:
            if let v = frame.payload.first { state.ambientLevel = Int(v) }
        case .touchUpdated:
            if let v = frame.payload.first { state.touchpadLocked = v == 1 }
        case .muteEarbudStatusUpdated:
            if frame.payload.count >= 2 { state.mutedL = frame.payload[0] == 1; state.mutedR = frame.payload[1] == 1 }
        case .findStop:
            state.ringing = false
        case .ack:
            handleAck(frame.payload)
        case .versionInfoLong, .debugGetAllData, .cradleSerialNumber, .debugSku, .debugSerialNumber:
            state.applyInfo(frame)
        default:
            break
        }
    }

    private func handleAck(_ p: [UInt8]) {
        guard let id = p.first, p.count >= 2 else { return }
        let v = p[1]
        switch MsgID(rawValue: id) {
        case .noiseControls:
            if let m = NoiseMode(rawValue: v) { state.noiseMode = m }
            if state.eq == .custom { pushCustomEQ(select: true) }
        case .ambientVolume: state.ambientLevel = Int(v)
        case .equalizer: if let e = EQPreset(rawValue: v) { state.eq = e }
        case .setSidetone: state.sidetone = v == 1
        case .setDetectConversations: state.detectConversations = v == 1
        case .setDetectConversationsDuration: state.conversationTimeout = ConversationTimeout(rawValue: min(v, 2)) ?? .s10
        case .muteEarbud where p.count >= 3: state.mutedL = p[1] == 1; state.mutedR = p[2] == 1
        default: break
        }
    }

    // MARK: outgoing

    @discardableResult
    public func send(_ command: Command) -> Bool {
        send(command.frame)
    }

    @discardableResult
    public func send(_ frame: Frame) -> Bool {
        do {
            try connection.send(frame)
            return true
        } catch {
            lastError = error.localizedDescription
            log("send \(frame.name) failed: \(error.localizedDescription)")
            return false
        }
    }

    /// Reads `status` too so SwiftUI views (the menu bar icon) observe changes; `connection` is not observable.
    public var isConnected: Bool { status.isConnected && connection.isOpen }

    // MARK: setters used by the UI (optimistic local update + send)

    public func setNoiseMode(_ m: NoiseMode) { state.noiseMode = m; send(.noiseMode(m)) }
    public func setAmbientLevel(_ v: Int) { state.ambientLevel = v; send(.ambientLevel(v)) }
    public func setANCLevel(_ v: Int) { state.ancLevel = v; send(.ancLevel(v)) }
    public func setBalance(_ v: Int) { state.balance = v; send(.balance(v)) }
    public func setSidetone(_ v: Bool) { state.sidetone = v; send(.sidetone(v)) }
    public func setDetectConversations(_ v: Bool) { state.detectConversations = v; send(.detectConversations(v)) }
    public func setConversationTimeout(_ t: ConversationTimeout) { state.conversationTimeout = t; send(.conversationTimeout(t)) }
    public func setNCWithOneEarbud(_ v: Bool) { state.ncWithOneEarbud = v; send(.ncWithOneEarbud(v)) }
    public func setGameMode(_ v: Bool) { state.gameMode = v; send(.gameMode(v)) }
    public func setSeamless(_ v: Bool) { state.seamlessConnection = v; send(.seamlessConnection(v)) }
    public func setCallPath(_ v: Bool) { state.callPathControl = v; send(.callPathControl(v)) }
    public func setExtraClearCall(_ v: Bool) { state.extraClearCall = v; send(.extraClearCall(v)) }
    public func setVoiceWakeUp(_ v: Bool) { state.voiceWakeUp = v; send(.voiceWakeUp(v)) }
    public func setSpeakSeamlessly(_ v: Bool) { state.speakSeamlessly = v; send(.speakSeamlessly(v)) }
    public func setAutoPause(_ v: Bool) { state.autoPauseResume = v; send(.autoPauseResume(v)) }
    public func setAdaptiveVolume(_ v: Bool) { state.adaptiveVolume = v; send(.adaptiveVolume(v)) }
    public func setSirenDetect(_ v: Bool) { state.sirenDetect = v; send(.sirenDetect(v)) }

    public func setAmbientCustom(on: Bool, left: Int, right: Int, tone: Int) {
        state.ambientCustomOn = on; state.ambientCustomL = left; state.ambientCustomR = right; state.ambientTone = tone
        send(.customizeAmbient(on: on, left: left, right: right, tone: tone))
    }

    public func setEQ(_ e: EQPreset) {
        state.eq = e
        if e == .custom { pushCustomEQ(select: true) } else { send(.equalizer(e)) }
    }

    public func setCustomBand(_ index: Int, _ gain: Int) {
        guard customBands.indices.contains(index) else { return }
        customBands[index] = gain
        if state.eq == .custom { pushCustomEQ(select: false) }
    }

    /// Custom EQ order: band table first, then select preset 7.
    public func pushCustomEQ(select: Bool) {
        send(.customEQ(customBands))
        if select { send(.equalizer(.custom)) }
    }

    public func setTouch(_ bit: BudsState.TouchBit, _ on: Bool) {
        state.setTouch(bit, on)
        send(.touchLock(locked: state.touchpadLocked, bits: state.touchLockBits))
    }

    public func setTouchpadLocked(_ locked: Bool) {
        state.touchpadLocked = locked
        UserDefaults.standard.set(locked, forKey: "touchpadLocked")
        send(.touchLock(locked: locked, bits: state.touchLockBits))
    }

    public func setTouchAction(left: TouchAction? = nil, right: TouchAction? = nil) {
        let l = left ?? state.touchActionL ?? .noiseControl
        let r = right ?? state.touchActionR ?? .noiseControl
        state.touchActionL = l; state.touchActionR = r
        send(.touchActions(left: l, right: r))
        if l == .noiseControl || r == .noiseControl { send(.noiseCycle(left: state.cycleL, right: state.cycleR)) }
    }

    /// Toggle one mode in a side's cycle. At least two modes must remain selected.
    public func setCycle(left: Bool, mode: CycleSet, on: Bool) {
        var set = left ? state.cycleL : state.cycleR
        if on { set.insert(mode) } else { set.remove(mode) }
        guard set.rawValue.nonzeroBitCount >= 2 else { return }
        if left { state.cycleL = set } else { state.cycleR = set }
        send(.noiseCycle(left: state.cycleL, right: state.cycleR))
    }

    public func findEarbuds(_ start: Bool) {
        state.ringing = start
        send(start ? .findStart : .findStop)
    }

    public func setMute(left: Bool, right: Bool) {
        state.mutedL = left; state.mutedR = right
        send(.muteEarbud(left: left, right: right))
    }

    public func refresh() {
        send(.query(.debugGetAllData))
    }
}

/// Objective-C target for IOBluetooth connect notifications.
@MainActor
private final class ConnectObserver: NSObject {
    let onConnect: (IOBluetoothDevice) -> Void
    let onDisconnect: (IOBluetoothDevice) -> Void
    init(connected: @escaping (IOBluetoothDevice) -> Void, disconnected: @escaping (IOBluetoothDevice) -> Void) {
        onConnect = connected
        onDisconnect = disconnected
    }

    @objc nonisolated func connected(_ note: IOBluetoothUserNotification, device: IOBluetoothDevice) {
        nonisolated(unsafe) let device = device
        MainActor.assumeIsolated { onConnect(device) }
    }

    @objc nonisolated func disconnected(_ note: IOBluetoothUserNotification, device: IOBluetoothDevice) {
        nonisolated(unsafe) let device = device
        MainActor.assumeIsolated { onDisconnect(device) }
    }
}
