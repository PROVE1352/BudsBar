/// Message IDs used by BudsBar (subset of GalaxyBudsClient `MsgIds`).
public enum MsgID: UInt8, Sendable, CaseIterable {
    // Info / debug queries
    case debugSku = 0x22
    case debugGetAllData = 0x26
    case debugSerialNumber = 0x29
    case versionInfoLong = 0x68
    case cradleSerialNumber = 0xCD
    case getFmmConfig = 0xAD

    // Generic replies
    case ack = 0x42
    case resp = 0x51
    case statusAlert = 0x57

    // Status
    case statusUpdated = 0x60
    case extendedStatusUpdated = 0x61
    case connectionUpdated = 0x62
    case multipointInfo = 0x76
    case noiseControlsUpdate = 0x77
    case touchUpdated = 0x91
    case touchpadOtherOption = 0x93
    case voiceWakeUpEvent = 0x9A
    case fitTestResult = 0x9E
    case muteEarbudStatusUpdated = 0xA3
    case overheat = 0xCA
    case spatialAudioData = 0xC2
    case debugEvent = 0xF2
    case debugErrorCode = 0xF1

    // Settings
    case extraClearSoundCall = 0x48
    case customEqualizeRecv = 0x69
    case pauseMediaWhenOneBudRemoved = 0x6C
    case ambientDuringCallNoti = 0x6D
    case setCallPathControl = 0x6E
    case setAncWithOneEarbud = 0x6F
    case noiseControls = 0x78
    case setTouchAndHoldNoiseControls = 0x79
    case setDetectConversations = 0x7A
    case setDetectConversationsDuration = 0x7B
    case setSpeakSeamlessly = 0x7D
    case customizeAmbientSound = 0x82
    case noiseReductionLevel = 0x83
    case ambientVolume = 0x84
    case adjustSoundSync = 0x85
    case equalizer = 0x86
    case gameMode = 0x87
    case managerInfo = 0x88
    case customEqualizeSend = 0x89
    case setInBandRingtone = 0x8A
    case setSidetone = 0x8B
    case setHearingEnhancements = 0x8F
    case lockTouchpad = 0x90
    case setTouchpadOption = 0x92
    case outsideDoubleTap = 0x95
    case setVoiceWakeUp = 0x97
    case voiceWakeUpLanguage = 0x99
    case checkFit = 0x9D
    case findStart = 0xA0
    case findStop = 0xA1
    case muteEarbud = 0xA2
    case findOnWearingStart = 0xA6
    case setSeamlessConnection = 0xAF
    case setAdaptiveVolume = 0xC5
    case sirenDetect = 0xDE
}

/// IDs that BudsBar refuses to transmit, including via `--cli raw`: factory reset, reboot/power,
/// firmware update (FOTA), factory/test modes, pairing mode, coredump/log control, property writes.
public enum SendPolicy {
    public static let blocked: Set<UInt8> = {
        var set: Set<UInt8> = [
            16, 17, 18, 19, 21, 22, 23,     // mode change / hidden factory commands
            32, 39, 42,                     // debug mode, "disconnects device", sensor logging
            67,                             // WRITE_PROPERTY (alt mode)
            74, 75,                         // aging / act test
            80, 82, 83, 86,                 // RESET, REBOOT, POWEROFF, RF test mode
            114,                            // PAIRING_MODE
            141,                            // TAP_TEST_MODE
            169, 170, 171, 172,             // coupling helper, SELF_TEST, SET_FMM_CONFIG
            207,                            // RESET_BATTERY_SOC_CYCLE
        ]
        set.formUnion(48...61)              // coredump / trace / log session
        set.formUnion(176...191)            // FOTA family
        return set
    }()

    public static func isAllowed(_ id: UInt8) -> Bool { !blocked.contains(id) }
}
