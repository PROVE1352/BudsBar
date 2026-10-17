import Foundation

/// High-level setting commands and their wire encoding. Factory reset / firmware update / test-mode
/// commands are intentionally absent (and blocked in `SendPolicy`).
public enum Command: Sendable, Equatable {
    case noiseMode(NoiseMode)
    case ambientLevel(Int)
    case ancLevel(Int)
    case ncWithOneEarbud(Bool)
    case customizeAmbient(on: Bool, left: Int, right: Int, tone: Int)
    case sidetone(Bool)
    case detectConversations(Bool)
    case conversationTimeout(ConversationTimeout)
    case equalizer(EQPreset)
    case customEQ([Int])                       // 9 bands, −10…+10
    case balance(Int)                          // 0…32
    case touchLock(locked: Bool, bits: UInt8)  // gesture bits in ESU[10] layout
    case touchActions(left: TouchAction, right: TouchAction)
    case noiseCycle(left: CycleSet, right: CycleSet)
    case gameMode(Bool)                        // no ACK / no ESU change on Buds4 Pro
    case seamlessConnection(Bool)
    case callPathControl(Bool)
    case extraClearCall(Bool)
    case voiceWakeUp(Bool)
    case speakSeamlessly(Bool)
    case autoPauseResume(Bool)
    case adaptiveVolume(Bool)                  // no ACK on Buds4 Pro
    case sirenDetect(Bool)
    case findStart
    case findStop
    case muteEarbud(left: Bool, right: Bool)
    case managerInfo
    case query(MsgID)                          // empty-payload info request

    public var frame: Frame {
        func b(_ v: Bool) -> UInt8 { v ? 1 : 0 }
        func clamp(_ v: Int, _ lo: Int, _ hi: Int) -> UInt8 { UInt8(max(lo, min(hi, v))) }
        switch self {
        case .noiseMode(let m): return Frame(.noiseControls, [m.rawValue])
        case .ambientLevel(let v): return Frame(.ambientVolume, [clamp(v, 0, 4)])
        case .ancLevel(let v): return Frame(.noiseReductionLevel, [clamp(v, 0, 4)])
        case .ncWithOneEarbud(let v): return Frame(.setAncWithOneEarbud, [b(v)])
        case let .customizeAmbient(on, l, r, tone):
            return Frame(.customizeAmbientSound, [b(on), clamp(l, 0, 4), clamp(r, 0, 4), clamp(tone, 0, 4)])
        case .sidetone(let v): return Frame(.setSidetone, [b(v)])
        case .detectConversations(let v): return Frame(.setDetectConversations, [b(v)])
        case .conversationTimeout(let t): return Frame(.setDetectConversationsDuration, [t.rawValue])
        case .equalizer(let e): return Frame(.equalizer, [e.rawValue])
        case .customEQ(let gains):
            let bands = (gains + Array(repeating: 0, count: 9)).prefix(9).map { UInt8(bitPattern: Int8(max(-10, min(10, $0)))) }
            return Frame(.customEqualizeSend, [9] + bands)
        case .balance(let v): return Frame(.setHearingEnhancements, [clamp(v, 0, 32)])
        case let .touchLock(locked, bits):
            // [touchEnabled][tap][double][triple][hold][callDouble][callHold][swipe]
            // The 8th (swipe) byte is required on Buds4 Pro: a 7-byte payload leaves ESU bit 6 as is.
            func bit(_ n: Int) -> UInt8 { (bits >> n) & 1 }
            return Frame(.lockTouchpad, [locked ? 0 : 1, bit(3), bit(2), bit(1), bit(0), bit(4), bit(5), bit(6)])
        case let .touchActions(l, r): return Frame(.setTouchpadOption, [l.rawValue, r.rawValue])
        case let .noiseCycle(l, r): return Frame(.setTouchAndHoldNoiseControls, [l.rawValue, r.rawValue])
        case .gameMode(let v): return Frame(.gameMode, [b(v)])
        case .seamlessConnection(let v): return Frame(.setSeamlessConnection, [b(!v)])   // inverted
        case .callPathControl(let v): return Frame(.setCallPathControl, [b(!v)])         // inverted
        case .extraClearCall(let v): return Frame(.extraClearSoundCall, [b(v)])
        case .voiceWakeUp(let v): return Frame(.setVoiceWakeUp, [b(v)])
        case .speakSeamlessly(let v): return Frame(.setSpeakSeamlessly, [b(v)])
        case .autoPauseResume(let v): return Frame(.pauseMediaWhenOneBudRemoved, [b(v)])
        case .adaptiveVolume(let v): return Frame(.setAdaptiveVolume, [b(v)])
        case .sirenDetect(let v): return Frame(.sirenDetect, [b(v)])
        case .findStart: return Frame(.findOnWearingStart)
        case .findStop: return Frame(.findStop)
        case let .muteEarbud(l, r): return Frame(.muteEarbud, [b(l), b(r)])
        case .managerInfo: return Frame(.managerInfo, [0x01, 0x01, 0x22])
        case .query(let id): return Frame(id)
        }
    }
}
