import BudsCore
import Foundation
import ServiceManagement

/// `BudsBar --cli <command>` — debugging front end that talks to the real earbuds.
@MainActor
enum CLI {
    static let usage = """
    usage: BudsBar --cli [-v] [--addr XX:XX:..] [--wait SEC] <command>

      status                       decoded state (ESU) + firmware
      esu                          raw ESU payload with offsets
      dump [SEC]                   print every received frame for SEC seconds (default 30)
      raw <hex…>                   send msgId + payload, e.g. `raw 78 01`; prints replies
      nc off|anc|ambient|adaptive  noise control mode   (alias: anc on|off)
      ambient <0-4>                ambient sound level
      anclevel <n>                 ANC level (NOISE_REDUCTION_LEVEL)
      eq off|bass|soft|dynamic|clear|treble|custom [g1 … g9]
      balance <0-32>               left/right balance, 16 = centre
      sidetone on|off
      conv on|off [5|10|15]        conversation detection (+ timeout)
      touch on|off                 touchpad lock (off = locked)
      touchbits <hex>              gesture allow bits (ESU[10]: 0 hold 1 triple 2 double 3 single 4 callDouble 5 callHold 6 swipe)
      hold <L> <R>                 pinch & hold action: 1 assistant 2 noise 3 volume 4 spotify
      cycle <Lhex> <Rhex>          noise-control cycle mask per side (1 amb 2 adapt 4 off 8 anc)
      game on|off
      onebud on|off                noise control with one earbud
      seamless|callpath|clearcall|wakeup|speakseamless|autopause|siren|adaptivevol on|off
      find stop                    (find start needs --yes-ring: rings the earbuds!)
      mute <0|1> <0|1>             mute left/right while finding
      fw                           firmware / serial info
      devices                      list paired Buds (no RFCOMM)
      login [on|off]               launch-at-login state (run from the installed .app)
      snapshot <dir>               render the panel pages to PNG (UI check)
      selftest                     offline frame/CRC test vectors (no Bluetooth)
    """

    private static var verbose = false
    private static var waitSeconds = 2.0

    static func run(_ argv: [String]) {
        var args = argv
        var address: String?
        var allowRing = false
        while let first = args.first, first.hasPrefix("-") {
            args.removeFirst()
            switch first {
            case "-v": verbose = true
            case "--addr": address = args.isEmpty ? nil : args.removeFirst()
            case "--wait": waitSeconds = args.isEmpty ? 2 : Double(args.removeFirst()) ?? 2
            case "--yes-ring": allowRing = true
            default: fail("unknown option \(first)")
            }
        }
        guard let command = args.first else { print(usage); exit(0) }
        let rest = Array(args.dropFirst())

        if command == "selftest" { exit(selfTest() ? 0 : 1) }
        if command == "help" { print(usage); exit(0) }
        if command == "login" {
            // Login item registration for the enclosing .app (run from the installed bundle).
            do {
                switch rest.first {
                case "on": try SMAppService.mainApp.register()
                case "off": try SMAppService.mainApp.unregister()
                default: break
                }
            } catch { fail("\(error.localizedDescription)") }
            print("login item: \(SMAppService.mainApp.status == .enabled ? "enabled" : "not enabled")")
            exit(0)
        }
        if command == "devices" {
            for d in BudsConnection.pairedBuds() {
                print("\(d.addressString ?? "?")  connected=\(d.isConnected())  \(d.name ?? "")")
            }
            exit(0)
        }
        if command == "find", rest.first == "start", !allowRing {
            fail("find start rings the earbuds loudly; add --yes-ring to really send it")
        }

        let buds = BudsController(address: address)
        let started = Date()
        func stamp() -> String { String(format: "%6.2f", Date().timeIntervalSince(started)) }
        let dumpAll = verbose || command == "dump" || command == "raw"
        buds.onFrame = { f in
            if dumpAll { print("\(stamp()) RX \(f.name.padding(toLength: 24, withPad: " ", startingAt: 0)) flags=\(String(format: "%04X", f.flags)) len=\(f.payload.count) | \(f.payload.hex)") }
        }
        buds.onSent = { f in
            if dumpAll { print("\(stamp()) TX \(f.name.padding(toLength: 24, withPad: " ", startingAt: 0)) | \(f.encoded().hex)") }
        }
        buds.log = { msg in if verbose { print("\(stamp()) -- \(msg)") } }

        Task { @MainActor in
            await buds.connect(page: true)
            guard buds.isConnected else { fail(buds.status.label) }
            // Wait for the first ESU so commands that depend on current state have it.
            for _ in 0..<30 where !buds.hasESU { try? await Task.sleep(for: .milliseconds(100)) }
            do {
                try await execute(command, rest, buds)
            } catch {
                fail("\(error)")
            }
            buds.disconnect()
            exit(0)
        }
    }

    private static func execute(_ command: String, _ a: [String], _ buds: BudsController) async throws {
        func on(_ i: Int = 0) throws -> Bool {
            guard i < a.count else { throw CLIError("expected on|off") }
            switch a[i].lowercased() {
            case "on", "1", "true": return true
            case "off", "0", "false": return false
            default: throw CLIError("expected on|off, got \(a[i])")
            }
        }
        func int(_ i: Int = 0) throws -> Int {
            guard i < a.count, let v = Int(a[i]) else { throw CLIError("expected a number") }
            return v
        }
        func hexByte(_ i: Int) throws -> UInt8 {
            guard i < a.count, let v = UInt8(a[i].replacingOccurrences(of: "0x", with: ""), radix: 16) else { throw CLIError("expected hex byte") }
            return v
        }
        func settle() async { try? await Task.sleep(for: .seconds(waitSeconds)) }

        switch command {
        case "status":
            buds.send(.query(.debugGetAllData))
            await settle()
            printStatus(buds.state)
        case "esu":
            printESU(buds.state.lastESU)
        case "fw":
            buds.send(.query(.debugGetAllData))
            await settle()
            printFirmware(buds.state.firmware)
        case "snapshot":
            guard let dir = a.first else { throw CLIError("snapshot <dir>") }
            buds.send(.query(.debugGetAllData))
            await settle()
            Snapshot.render(model: AppModel(cliController: buds), to: URL(fileURLWithPath: dir))
        case "dump":
            let secs = a.first.flatMap(Double.init) ?? 30
            try? await Task.sleep(for: .seconds(secs))
        case "raw":
            guard let bytes = [UInt8](hexString: a.joined(separator: " ")), let id = bytes.first else { throw CLIError("bad hex") }
            guard buds.send(Frame(id, Array(bytes.dropFirst()))) else { throw CLIError(buds.lastError ?? "send failed") }
            await settle()
        case "nc", "anc":
            let map: [String: NoiseMode] = ["off": .off, "anc": .anc, "on": .anc, "ambient": .ambient, "amb": .ambient, "adaptive": .adaptive]
            guard let m = a.first.flatMap({ map[$0.lowercased()] }) else { throw CLIError("nc off|anc|ambient|adaptive") }
            try sendAndReport(buds, .noiseMode(m)) { "noiseMode=\($0.noiseMode)" }
            await settle()
        case "ambient": buds.send(.ambientLevel(try int())); await settle()
        case "anclevel": buds.send(.ancLevel(try int())); await settle()
        case "balance": buds.send(.balance(try int())); await settle()
        case "sidetone": buds.send(.sidetone(try on())); await settle()
        case "conv":
            buds.send(.detectConversations(try on()))
            if a.count > 1, let t = ["5": ConversationTimeout.s5, "10": .s10, "15": .s15][a[1]] {
                buds.send(.conversationTimeout(t))
            }
            await settle()
        case "eq":
            let map: [String: EQPreset] = ["off": .off, "bass": .bassBoost, "soft": .soft, "dynamic": .dynamic, "clear": .clear, "treble": .trebleBoost, "custom": .custom]
            guard let e = a.first.flatMap({ map[$0.lowercased()] }) else { throw CLIError("eq preset?") }
            if e == .custom, a.count > 1 { buds.customBands = a.dropFirst().compactMap { Int($0) } }
            buds.setEQ(e)
            await settle()
        case "touch": buds.setTouchpadLocked(!(try on())); await settle()
        case "touchbits": buds.send(.touchLock(locked: buds.state.touchpadLocked, bits: try hexByte(0))); await settle()
        case "hold":
            guard let l = TouchAction(rawValue: UInt8(try int(0))), let r = TouchAction(rawValue: UInt8(try int(1))) else { throw CLIError("1-6") }
            buds.send(.touchActions(left: l, right: r)); await settle()
        case "cycle":
            buds.send(.noiseCycle(left: CycleSet(rawValue: try hexByte(0)), right: CycleSet(rawValue: try hexByte(1))))
            await settle()
        case "game": buds.send(.gameMode(try on())); await settle()
        case "onebud": buds.send(.ncWithOneEarbud(try on())); await settle()
        case "seamless": buds.send(.seamlessConnection(try on())); await settle()
        case "callpath": buds.send(.callPathControl(try on())); await settle()
        case "clearcall": buds.send(.extraClearCall(try on())); await settle()
        case "wakeup": buds.send(.voiceWakeUp(try on())); await settle()
        case "speakseamless": buds.send(.speakSeamlessly(try on())); await settle()
        case "autopause": buds.send(.autoPauseResume(try on())); await settle()
        case "adaptivevol": buds.send(.adaptiveVolume(try on())); await settle()
        case "siren": buds.send(.sirenDetect(try on())); await settle()
        case "find":
            switch a.first {
            case "start": buds.send(.findStart); try? await Task.sleep(for: .seconds(min(waitSeconds, 2))); buds.send(.findStop)
            case "stop": buds.send(.findStop)
            default: throw CLIError("find start|stop")
            }
            await settle()
        case "mute": buds.send(.muteEarbud(left: try int(0) != 0, right: try int(1) != 0)); await settle()
        default:
            throw CLIError("unknown command \(command)\n\(usage)")
        }
        if command != "status", command != "esu", command != "fw", command != "dump", verbose {
            printStatus(buds.state)
        }
    }

    private static func sendAndReport(_ buds: BudsController, _ c: Command, _ describe: (BudsState) -> String) throws {
        guard buds.send(c) else { throw CLIError(buds.lastError ?? "send failed") }
    }

    // MARK: output

    static func printStatus(_ s: BudsState) {
        func pct(_ v: Int?) -> String { v.map { "\($0)%" } ?? "-" }
        print("""
        battery      L \(pct(s.batteryL))\(s.chargingL ? "+" : "")  R \(pct(s.batteryR))\(s.chargingR ? "+" : "")  case \(pct(s.batteryCase))\(s.chargingCase ? "+" : "")
        placement    L \(s.placementL.label)  R \(s.placementR.label)  main=\(s.mainIsLeft ? "L" : "R") coupled=\(s.coupled)
        noise        \(s.noiseMode.label)  ambientLevel=\(s.ambientLevel)  esu[24]=\(s.ancLevel)  oneBud=\(s.ncWithOneEarbud)
        cycle        L \(cycleText(s.cycleL))  R \(cycleText(s.cycleR))
        eq           \(s.eq.label)  balance=\(s.balance)
        ambientCust  on=\(s.ambientCustomOn) L=\(s.ambientCustomL) R=\(s.ambientCustomR) tone=\(s.ambientTone)
        conversation \(s.detectConversations) timeout=\(s.conversationTimeout.label)
        touch        bits=\(String(format: "%02X", s.touchLockBits)) locked=\(s.touchpadLocked)  hold L=\(s.touchActionL?.label ?? "?") R=\(s.touchActionR?.label ?? "?")
        toggles      sidetone=\(s.sidetone) seamless=\(s.seamlessConnection) callPath=\(s.callPathControl) clearCall=\(s.extraClearCall) wakeUp=\(s.voiceWakeUp) speakSeamless=\(s.speakSeamlessly) autoPause=\(s.autoPauseResume) siren=\(s.sirenDetect)
        esu          rev=\(s.esuRevision.map(String.init) ?? "-") len=\(s.lastESU.count)
        """)
        printFirmware(s.firmware)
    }

    static func cycleText(_ c: CycleSet) -> String {
        CycleSet.all.filter { c.contains($0.0) }.map { $0.1.label }.joined(separator: "/") + String(format: " (0x%X)", c.rawValue)
    }

    static func printFirmware(_ f: FirmwareInfo) {
        print("firmware     L \(f.earbudsL ?? "-")  R \(f.earbudsR ?? "-")  case \(f.caseVersion ?? "-")  hw \(f.hardware ?? "-")")
        print("identity     sku L \(f.skuL ?? "-") R \(f.skuR ?? "-")  serial L \(f.serialL ?? "-") R \(f.serialR ?? "-") case \(f.caseSerial ?? "-")")
    }

    static func printESU(_ p: [UInt8]) {
        guard !p.isEmpty else { print("no ESU received"); return }
        print("ESU \(p.count) bytes: \(p.hex)")
        for row in stride(from: 0, to: p.count, by: 16) {
            let slice = p[row..<min(row + 16, p.count)]
            print(String(format: "  %02d: ", row) + Array(slice).hex)
        }
    }

    // MARK: self test

    static func selfTest() -> Bool {
        let vectors: [(Frame, String)] = [
            (Frame(.noiseControls, [0x01]), "FD 04 00 78 01 D1 91 DD"),
            (Frame(.findStop), "FD 03 00 A1 CB A5 DD"),
            (Frame(.managerInfo, [0x01, 0x01, 0x22]), "FD 06 00 88 01 01 22 DA 58 DD"),
            (Frame(.ambientVolume, [0x02]), "FD 04 00 84 02 1E F7 DD"),
            (Frame(.setTouchAndHoldNoiseControls, [0x0C, 0x0C]), "FD 05 00 79 0C 0C 78 C2 DD"),
        ]
        var ok = true
        for (frame, expected) in vectors {
            let got = frame.encoded().hex
            let pass = got == expected
            ok = ok && pass
            print("\(pass ? "PASS" : "FAIL") \(frame.name): \(got)\(pass ? "" : "  expected \(expected)")")
        }
        // Parser: two frames glued together, split at an odd boundary, with junk in front.
        var parser = FrameParser()
        let stream = [0x00, 0x13] + Frame(.noiseControls, [1]).encoded() + Frame(.findStop).encoded()
        let frames = parser.feed(Array(stream[0..<7])) + parser.feed(Array(stream[7...]))
        let parsePass = frames.map(\.id) == [0x78, 0xA1] && frames[0].payload == [1]
        ok = ok && parsePass
        print("\(parsePass ? "PASS" : "FAIL") parser reassembly (\(frames.count) frames)")
        return ok
    }

    static func fail(_ message: String) -> Never {
        FileHandle.standardError.write(Data("error: \(message)\n".utf8))
        exit(1)
    }
}

struct CLIError: Error, CustomStringConvertible {
    let description: String
    init(_ d: String) { description = d }
}
