import Foundation

public enum NoiseMode: UInt8, Sendable, CaseIterable, Identifiable {
    case off = 0, anc = 1, ambient = 2, adaptive = 3
    public var id: UInt8 { rawValue }
    public var label: String {
        switch self {
        case .off: String(localized: "Off")
        case .anc: "ANC"
        case .ambient: String(localized: "Ambient")
        case .adaptive: String(localized: "Adaptive")
        }
    }
}

public enum EQPreset: UInt8, Sendable, CaseIterable, Identifiable {
    case off = 0, bassBoost = 1, soft = 2, dynamic = 3, clear = 4, trebleBoost = 5, custom = 7
    public var id: UInt8 { rawValue }
    public var label: String {
        switch self {
        case .off: String(localized: "Off")
        case .bassBoost: String(localized: "Bass boost")
        case .soft: String(localized: "Soft")
        case .dynamic: String(localized: "Dynamic")
        case .clear: String(localized: "Clear")
        case .trebleBoost: String(localized: "Treble boost")
        case .custom: String(localized: "Custom")
        }
    }
}

/// Pinch-and-hold (long press) action per earbud (`SET_TOUCHPAD_OPTION`, ESU[11]).
public enum TouchAction: UInt8, Sendable, CaseIterable, Identifiable {
    case voiceAssistant = 1, noiseControl = 2, volume = 3, spotify = 4, customLeft = 5, customRight = 6
    public var id: UInt8 { rawValue }
    public var label: String {
        switch self {
        case .voiceAssistant: String(localized: "Voice assistant")
        case .noiseControl: String(localized: "Switch noise control")
        case .volume: String(localized: "Volume")
        case .spotify: "Spotify"
        case .customLeft: String(localized: "App action (L)")
        case .customRight: String(localized: "App action (R)")
        }
    }
}

public enum Placement: UInt8, Sendable {
    case disconnected = 0, wearing = 1, idle = 2, inCaseOpen = 3, inCaseClosed = 4
    public var label: String {
        switch self {
        case .disconnected: String(localized: "Disconnected")
        case .wearing: String(localized: "In ear")
        case .idle: String(localized: "Out of ear")
        case .inCaseOpen: String(localized: "In case (open)")
        case .inCaseClosed: String(localized: "In case (closed)")
        }
    }
}

/// One side of the noise-control cycle mask (ESU[21] nibble / SET_TOUCH_AND_HOLD_NOISE_CONTROLS byte).
/// Layout: bit0 ambient, bit1 adaptive, bit2 off, bit3 ANC; left side is the high nibble of ESU[21]
/// and the first payload byte. On a Buds4 Pro the bytes round-trip verbatim (ACK `79 L R`, ESU[21] = L<<4|R)
/// and the factory value 0xB (bit 3 set) only makes sense in this layout.
public struct CycleSet: OptionSet, Sendable, Hashable {
    public let rawValue: UInt8
    public init(rawValue: UInt8) { self.rawValue = rawValue & 0x0F }
    public static let ambient = CycleSet(rawValue: 0x01)
    public static let adaptive = CycleSet(rawValue: 0x02)
    public static let off = CycleSet(rawValue: 0x04)
    public static let anc = CycleSet(rawValue: 0x08)

    public static let all: [(CycleSet, NoiseMode)] = [(.off, .off), (.anc, .anc), (.ambient, .ambient), (.adaptive, .adaptive)]
}

public enum ConversationTimeout: UInt8, Sendable, CaseIterable, Identifiable {
    case s5 = 0, s10 = 1, s15 = 2
    public var id: UInt8 { rawValue }
    public var label: String { [String(localized: "5 s"), String(localized: "10 s"), String(localized: "15 s")][Int(rawValue)] }
}

public struct FirmwareInfo: Sendable, Equatable {
    public var earbudsL: String?
    public var earbudsR: String?
    public var caseVersion: String?
    public var caseSerial: String?
    public var skuL: String?
    public var skuR: String?
    public var serialL: String?
    public var serialR: String?
    public var hardware: String?
    public init() {}
}
