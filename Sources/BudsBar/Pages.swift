import BudsCore
import SwiftUI

// MARK: - Sound

struct SoundPage: View {
    let buds: BudsController
    private let bandLabels = ["63", "125", "250", "500", "1k", "2k", "4k", "8k", "16k"]

    var body: some View {
        let s = buds.state
        VStack(alignment: .leading, spacing: 4) {
            Block("Noise control") {
                Picker("", selection: buds.binding(\.noiseMode) { $0.setNoiseMode($1) }) {
                    ForEach(NoiseMode.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden()
                StepSlider(title: "Ambient level", range: 0...4, value: s.ambientLevel, format: { String(localized: "Level \($0 + 1)") }) {
                    buds.setAmbientLevel($0)
                }
                StepSlider(title: "ANC level", range: 0...4, value: s.ancLevel) { buds.setANCLevel($0) }
                Note("ANC level: the buds store 0–4, audible effect not verified")
                Toggle("Noise control with one earbud", isOn: buds.binding(\.ncWithOneEarbud) { $0.setNCWithOneEarbud($1) })
            }

            Block("Conversation detection") {
                Toggle("Switch to ambient when I talk", isOn: buds.binding(\.detectConversations) { $0.setDetectConversations($1) })
                Picker("Return after", selection: buds.binding(\.conversationTimeout) { $0.setConversationTimeout($1) }) {
                    ForEach(ConversationTimeout.allCases) { Text($0.label).tag($0) }
                }
                .disabled(!s.detectConversations)
                Note("The buds acknowledge the timeout but do not report it back, so the last value set here is shown")
            }

            Block("Ambient sound customization") {
                Toggle("Separate left/right levels", isOn: Binding(get: { s.ambientCustomOn }, set: {
                    buds.setAmbientCustom(on: $0, left: s.ambientCustomL, right: s.ambientCustomR, tone: s.ambientTone)
                }))
                if s.ambientCustomOn {
                    StepSlider(title: "Left", range: 0...4, value: s.ambientCustomL) {
                        buds.setAmbientCustom(on: true, left: $0, right: s.ambientCustomR, tone: s.ambientTone)
                    }
                    StepSlider(title: "Right", range: 0...4, value: s.ambientCustomR) {
                        buds.setAmbientCustom(on: true, left: s.ambientCustomL, right: $0, tone: s.ambientTone)
                    }
                }
                StepSlider(title: "Tone", range: 0...4, value: s.ambientTone) {
                    buds.setAmbientCustom(on: s.ambientCustomOn, left: s.ambientCustomL, right: s.ambientCustomR, tone: $0)
                }
            }

            Block("Equalizer") {
                Picker("Preset", selection: buds.binding(\.eq) { $0.setEQ($1) }) {
                    ForEach(EQPreset.allCases) { Text($0.label).tag($0) }
                }
                if s.eq == .custom {
                    HStack(alignment: .bottom, spacing: 4) {
                        ForEach(0..<9, id: \.self) { i in
                            BandSlider(label: bandLabels[i], value: buds.customBands[i]) { buds.setCustomBand(i, $0) }
                        }
                    }
                    Note("Custom bands are stored on this Mac and re-sent whenever the noise control mode changes")
                }
                StepSlider(title: "L/R balance", range: 0...32, value: s.balance, format: balanceText) { buds.setBalance($0) }
            }
        }
    }

    private func balanceText(_ v: Int) -> String {
        v == 16 ? "Center" : v < 16 ? "L\(16 - v)" : "R\(v - 16)"
    }
}

/// Vertical −10…+10 slider for one EQ band.
private struct BandSlider: View {
    let label: String
    let value: Int
    let onCommit: (Int) -> Void
    @State private var draft: Double?

    var body: some View {
        VStack(spacing: 2) {
            Text("\(Int(draft ?? Double(value)))").font(.caption2.monospacedDigit())
            Slider(value: Binding(get: { draft ?? Double(value) }, set: { draft = $0.rounded() }), in: -10...10, step: 1) { editing in
                if !editing, let d = draft { onCommit(Int(d)); draft = nil }
            }
            .rotationEffect(.degrees(-90))
            .frame(width: 90, height: 24)
            .frame(width: 30, height: 90)
            Text(label).font(.system(size: 9)).foregroundStyle(.secondary)
        }
    }
}

// MARK: - Touch

struct TouchPage: View {
    let buds: BudsController

    var body: some View {
        let s = buds.state
        VStack(alignment: .leading, spacing: 4) {
            Block("Touch lock") {
                Toggle("Lock all touch controls", isOn: buds.binding(\.touchpadLocked) { $0.setTouchpadLocked($1) })
                Note("Acknowledged by the buds but not reported back, so the last value set here is shown (actual locking not verified)")
                ForEach([BudsState.TouchBit.single, .double, .triple, .hold, .swipe, .callDouble, .callHold], id: \.self) { bit in
                    Toggle(bit.label, isOn: Binding(get: { s.touch(bit) }, set: { buds.setTouch(bit, $0) }))
                        .disabled(s.touchpadLocked)
                }
            }

            Block("Pinch & hold action") {
                actionPicker("Left", left: true, s.touchActionL)
                actionPicker("Right", left: false, s.touchActionR)
                UnavailableRow(title: "Double pinch & hold", reason: "No known command to change it (ESU[51] is read-only)")
            }

            Block("Noise control cycle") {
                HStack(alignment: .top, spacing: 20) {
                    cycleColumn("Left", left: true, set: s.cycleL, active: s.touchActionL == .noiseControl)
                    cycleColumn("Right", left: false, set: s.cycleR, active: s.touchActionR == .noiseControl)
                }
                Note("Applies to the side whose pinch & hold is set to noise control. Pick at least two.")
            }
        }
    }

    private func actionPicker(_ title: LocalizedStringKey, left: Bool, _ value: TouchAction?) -> some View {
        Picker(title, selection: Binding(get: { value ?? .noiseControl }, set: {
            if left { buds.setTouchAction(left: $0) } else { buds.setTouchAction(right: $0) }
        })) {
            ForEach(TouchAction.allCases) { Text($0.label).tag($0) }
        }
    }

    private func cycleColumn(_ title: LocalizedStringKey, left: Bool, set: CycleSet, active: Bool) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            ForEach(CycleSet.all, id: \.1) { flag, mode in
                Toggle(mode.label, isOn: Binding(get: { set.contains(flag) }, set: { buds.setCycle(left: left, mode: flag, on: $0) }))
                    .toggleStyle(.checkbox)
            }
        }
        .disabled(!active)
    }
}

// MARK: - Misc

struct MiscPage: View {
    @Bindable var model: AppModel
    let buds: BudsController

    var body: some View {
        let s = buds.state
        VStack(alignment: .leading, spacing: 4) {
            Block("Wearing & calls") {
                Toggle("Pause when an earbud is removed (wear detection)", isOn: buds.binding(\.autoPauseResume) { $0.setAutoPause($1) })
                Toggle("Hear my voice during calls (sidetone)", isOn: buds.binding(\.sidetone) { $0.setSidetone($1) })
                Toggle("Route calls to the buds when worn (call path control)", isOn: buds.binding(\.callPathControl) { $0.setCallPath($1) })
                Toggle("Extra clear call sound", isOn: buds.binding(\.extraClearCall) { $0.setExtraClearCall($1) })
                UnavailableRow(title: "Auto-answer calls", reason: "No such command found in the protocol")
            }

            Block("Connection & voice") {
                Toggle("Seamless connection (auto switch between Samsung devices)", isOn: buds.binding(\.seamlessConnection) { $0.setSeamless($1) })
                Toggle("Speak seamlessly", isOn: buds.binding(\.speakSeamlessly) { $0.setSpeakSeamlessly($1) })
                Toggle("Siren detection", isOn: buds.binding(\.sirenDetect) { $0.setSirenDetect($1) })
                Toggle("Bixby voice wake-up", isOn: buds.binding(\.voiceWakeUp) { $0.setVoiceWakeUp($1) })
                Note("Wake-up is not reported back, so the last value set here is shown")
            }

            Block("Not supported") {
                UnavailableRow(title: "Game mode", reason: "The buds neither acknowledge nor apply GAME_MODE (0x87)")
                UnavailableRow(title: "Adaptive volume", reason: "No response to SET_ADAPTIVE_VOLUME (0xC5)")
            }

            Block("App") {
                Toggle("Launch at login", isOn: $model.launchAtLogin)
            }

            Block("Firmware") {
                let f = s.firmware
                info("Earbuds", [f.earbudsL, f.earbudsR].compactMap { $0 }.uniqued().joined(separator: " / "))
                info("Case", f.caseVersion ?? "–")
                info("Model", f.skuL ?? "–")
                info("Serial", [f.serialL, f.serialR].compactMap { $0 }.joined(separator: " / "))
            }
        }
    }

    private func info(_ k: LocalizedStringKey, _ v: String) -> some View {
        HStack {
            Text(k).foregroundStyle(.secondary).frame(width: 60, alignment: .leading)
            Text(v.isEmpty ? "–" : v).textSelection(.enabled)
        }
        .font(.caption)
    }
}

// MARK: - Find

struct FindPage: View {
    let buds: BudsController

    var body: some View {
        let s = buds.state
        VStack(alignment: .leading, spacing: 4) {
            Block("Find my earbuds") {
                Note("The earbuds will beep loudly. Take them out of your ears first.")
                HStack {
                    Button(s.ringing ? "Ringing…" : "Ring") { buds.findEarbuds(true) }.disabled(s.ringing)
                    Button("Stop") { buds.findEarbuds(false) }
                }
                Toggle("Mute left", isOn: Binding(get: { s.mutedL }, set: { buds.setMute(left: $0, right: s.mutedR) }))
                Toggle("Mute right", isOn: Binding(get: { s.mutedR }, set: { buds.setMute(left: s.mutedL, right: $0) }))
            }
        }
        .onDisappear { if s.ringing { buds.findEarbuds(false) } }
    }
}

private extension Array where Element: Hashable {
    func uniqued() -> [Element] { var seen = Set<Element>(); return filter { seen.insert($0).inserted } }
}
