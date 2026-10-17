import Foundation

/// Everything BudsBar knows about the earbuds, updated from incoming frames.
public struct BudsState: Sendable, Equatable {
    // Power & placement
    public var batteryL: Int?
    public var batteryR: Int?
    public var batteryCase: Int?
    public var placementL: Placement = .disconnected
    public var placementR: Placement = .disconnected
    public var chargingL = false
    public var chargingR = false
    public var chargingCase = false
    public var coupled = false
    public var mainIsLeft = false

    // Sound
    public var noiseMode: NoiseMode = .off
    public var ambientLevel = 0            // 0…4
    public var ancLevel = 0                // ESU[24]
    public var eq: EQPreset = .off
    public var balance = 16                // 0…32, 16 = centre
    public var ambientCustomOn = false
    public var ambientCustomL = 0
    public var ambientCustomR = 0
    public var ambientTone = 2
    public var sidetone = false
    public var gameMode: Bool?             // not reported in ESU; known only after we set it

    // Noise-control cycle (pinch & hold)
    public var cycleL: CycleSet = []
    public var cycleR: CycleSet = []
    public var ncWithOneEarbud = false

    // Conversation detection
    public var detectConversations = false
    public var conversationTimeout: ConversationTimeout = .s10

    // Touch
    public var touchLockBits: UInt8 = 0xFF
    /// Master touch lock. Buds4 Pro accepts it (ACK) but does not mirror it in ESU[10] bit 7,
    /// so it is tracked from our own commands and TOUCH_UPDATED (0x91).
    public var touchpadLocked = false
    public var touchActionL: TouchAction?
    public var touchActionR: TouchAction?

    // Misc toggles
    public var voiceWakeUp = false
    public var seamlessConnection = false
    public var speakSeamlessly = false
    public var callPathControl = false
    public var extraClearCall = false
    public var autoPauseResume = false
    public var adaptiveVolume = false      // ESU index unknown on Buds4 Pro; not decoded
    public var sirenDetect = false
    public var spatialAudio = false

    // Find my earbuds
    public var mutedL = false
    public var mutedR = false
    public var ringing = false

    // Meta
    public var esuRevision: Int?
    public var lastESU: [UInt8] = []
    public var firmware = FirmwareInfo()

    public init() {}

    // MARK: touch lock bits (ESU[10])

    public enum TouchBit: Int, CaseIterable, Sendable {
        case hold = 0, triple = 1, double = 2, single = 3, callDouble = 4, callHold = 5, swipe = 6, enabled = 7
        public var label: String {
            switch self {
            case .hold: String(localized: "Pinch & hold")
            case .triple: String(localized: "Triple pinch")
            case .double: String(localized: "Double pinch")
            case .single: String(localized: "Single pinch")
            case .callDouble: String(localized: "Double pinch during calls")
            case .callHold: String(localized: "Pinch & hold during calls")
            case .swipe: String(localized: "Swipe (volume)")
            case .enabled: String(localized: "Touch enabled")
            }
        }
    }

    public func touch(_ bit: TouchBit) -> Bool { touchLockBits & (1 << bit.rawValue) != 0 }
    public mutating func setTouch(_ bit: TouchBit, _ on: Bool) {
        if on { touchLockBits |= 1 << bit.rawValue } else { touchLockBits &= ~(1 << bit.rawValue) }
    }

    // MARK: decoding

    /// STATUS_UPDATED (0x60).
    public mutating func applyStatus(_ p: [UInt8]) {
        guard p.count >= 7 else { return }
        batteryL = Int(p[1]); batteryR = Int(p[2])
        coupled = p[3] == 1
        mainIsLeft = p[4] == 1
        applyPlacement(p[5])
        batteryCase = Int(p[6])
        if p.count > 7 { applyCharging(p[7]) }
    }

    /// EXTENDED_STATUS_UPDATED (0x61). Base layout from the Buds3 Pro decoder; offsets marked
    /// "Buds4 Pro" were re-located by toggling each setting on a real SM-R640 (FW R640XXU0AZD2, ESU rev 4,
    /// 62-byte payload) and diffing the ESU.
    public mutating func applyESU(_ p: [UInt8]) {
        lastESU = p
        func b(_ i: Int) -> UInt8? { i < p.count ? p[i] : nil }
        func flag(_ i: Int) -> Bool? { b(i).map { $0 == 1 } }

        esuRevision = b(0).map(Int.init)
        if let v = b(2) { batteryL = Int(v) }
        if let v = b(3) { batteryR = Int(v) }
        if let v = flag(4) { coupled = v }
        if let v = b(5) { mainIsLeft = v == 1 }
        if let v = b(6) { applyPlacement(v) }
        if let v = b(7) { batteryCase = Int(v) }
        if let v = b(9), let e = EQPreset(rawValue: v) { eq = e }
        if let v = b(10) { touchLockBits = v }
        if let v = b(11) {
            touchActionL = TouchAction(rawValue: v >> 4)
            touchActionR = TouchAction(rawValue: v & 0x0F)
        }
        if let v = b(12), let m = NoiseMode(rawValue: v) { noiseMode = m }
        if let v = flag(13) { voiceWakeUp = v }                   // not updated by SET_VOICE_WAKE_UP on Buds4 Pro
        if let v = b(19) { seamlessConnection = v == 0 }        // inverted
        if let v = b(21) { cycleL = CycleSet(rawValue: v >> 4); cycleR = CycleSet(rawValue: v & 0x0F) }
        if let v = flag(22) { speakSeamlessly = v }
        if let v = b(23) { ambientLevel = Int(v) }
        if let v = b(24) { ancLevel = Int(v) }
        if let v = b(25) { balance = Int(v) }
        if let v = flag(26) { detectConversations = v }
        if let v = b(27) { conversationTimeout = ConversationTimeout(rawValue: min(v, 2)) ?? .s10 }
        if let v = flag(28) { ncWithOneEarbud = v }
        if let v = flag(29) { ambientCustomOn = v }
        if let v = b(30) { ambientCustomL = Int(v >> 4); ambientCustomR = Int(v & 0x0F) }
        if let v = b(36) { ambientTone = Int(v) }                 // Buds4 Pro: 36, not 31
        if let v = flag(33) { sidetone = v }
        if let v = b(34) { callPathControl = v == 0 }           // inverted
        if let v = b(35) { spatialAudio = v != 0 }
        if let v = b(43) { applyCharging(v) }                     // assumed +1 shift like 44/46 (unverified)
        if let v = flag(44) { extraClearCall = v }                // Buds4 Pro: 44, not 43
        if let v = flag(46) { autoPauseResume = v }               // Buds4 Pro: 46, not 45
        if let v = flag(52) { sirenDetect = v }                   // verified
    }

    private mutating func applyPlacement(_ v: UInt8) {
        placementL = Placement(rawValue: v >> 4) ?? .disconnected
        placementR = Placement(rawValue: v & 0x0F) ?? .disconnected
    }

    private mutating func applyCharging(_ v: UInt8) {
        chargingL = v & 0x10 != 0
        chargingR = v & 0x04 != 0
        chargingCase = v & 0x01 != 0
    }

    /// Firmware / identity responses.
    public mutating func applyInfo(_ frame: Frame) {
        let p = frame.payload
        func ascii(_ r: Range<Int>) -> String? {
            guard r.lowerBound < p.count else { return nil }
            let bytes = p[r.lowerBound..<min(r.upperBound, p.count)].filter { $0 >= 0x20 && $0 < 0x7F }
            return bytes.isEmpty ? nil : String(decoding: bytes, as: UTF8.self)
        }
        switch frame.msg {
        case .versionInfoLong:
            // [rev][?][20B left SW][20B right SW]…  (observed on Buds4 Pro; sent unsolicited)
            firmware.earbudsL = ascii(2..<22)
            firmware.earbudsR = ascii(22..<42)
        case .debugGetAllData:
            if p.count > 1 { firmware.hardware = "rev\(p[1] >> 4).\(p[1] & 0x0F)" }
            if let sw = ascii(2..<22) { firmware.earbudsL = firmware.earbudsL ?? sw }
        case .cradleSerialNumber:
            // Null-separated ASCII fields: case SW version, case serial.
            let parts = p.split(separator: 0).map { String(decoding: $0.filter { $0 >= 0x20 && $0 < 0x7F }, as: UTF8.self) }.filter { !$0.isEmpty }
            firmware.caseVersion = parts.first
            firmware.caseSerial = parts.count > 1 ? parts[1] : nil
        case .debugSku:
            firmware.skuL = ascii(0..<14); firmware.skuR = ascii(14..<28)
        case .debugSerialNumber:
            firmware.serialL = ascii(0..<11); firmware.serialR = ascii(11..<22)
        default: break
        }
    }
}
