import BudsCore
import SwiftUI

struct ContentView: View {
    @Bindable var model: AppModel
    let buds: BudsController
    @AppStorage("page") private var page = Page.sound

    enum Page: String, CaseIterable, Identifiable {
        case sound = "Sound", touch = "Touch", misc = "More", find = "Find"
        var id: String { rawValue }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HeaderView(buds: buds)
            if buds.isConnected {
                Picker("", selection: $page) {
                    ForEach(Page.allCases) { Text(LocalizedStringKey($0.rawValue)).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()

                ScrollView {
                    Group {
                        switch page {
                        case .sound: SoundPage(buds: buds)
                        case .touch: TouchPage(buds: buds)
                        case .misc: MiscPage(model: model, buds: buds)
                        case .find: FindPage(buds: buds)
                        }
                    }
                    .padding(.trailing, 6)
                }
                .frame(height: 420)
            } else {
                DisconnectedView(buds: buds)
            }
            FooterView(model: model, buds: buds)
        }
        .padding(14)
        .frame(width: 360)
        .toggleStyle(RowToggleStyle())
        .controlSize(.small)
        .font(.callout)
    }
}

// MARK: - Header

private struct HeaderView: View {
    let buds: BudsController

    var body: some View {
        let s = buds.state
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "earbuds").font(.title3)
                VStack(alignment: .leading, spacing: 1) {
                    Text(buds.deviceName ?? "Galaxy Buds").font(.headline)
                    Text(buds.isConnected ? String(localized: "Connected") : buds.status.label)
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
            }
            if buds.isConnected {
                HStack(spacing: 8) {
                    BatteryTile(title: "Left", level: s.batteryL, charging: s.chargingL, detail: s.placementL.label)
                    BatteryTile(title: "Right", level: s.batteryR, charging: s.chargingR, detail: s.placementR.label)
                    BatteryTile(title: "Case", level: s.batteryCase.flatMap { $0 > 0 ? $0 : nil },
                                charging: s.chargingCase, detail: s.batteryCase == 0 ? String(localized: "No data") : "")
                }
            }
        }
    }
}

private struct BatteryTile: View {
    let title: LocalizedStringKey
    let level: Int?
    let charging: Bool
    let detail: String

    var body: some View {
        VStack(spacing: 2) {
            Text(title).font(.caption2).foregroundStyle(.secondary)
            HStack(spacing: 2) {
                Text(level.map { "\($0)%" } ?? "–").font(.system(.body, design: .rounded).monospacedDigit().bold())
                if charging { Image(systemName: "bolt.fill").font(.caption2).foregroundStyle(.green) }
            }
            Text(detail).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 6)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
    }
}

private struct DisconnectedView: View {
    let buds: BudsController

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("BudsBar opens the settings channel automatically when your Buds connect. Take them out of the case or connect them over Bluetooth.")
                .font(.callout).foregroundStyle(.secondary)
            if let e = buds.lastError { Text(e).font(.caption).foregroundStyle(.red) }
            Button("Connect now") { Task { await buds.connect(page: true) } }
        }
    }
}

private struct FooterView: View {
    @Bindable var model: AppModel
    let buds: BudsController

    var body: some View {
        Divider()
        HStack {
            if buds.isConnected {
                Button("Refresh") { buds.refresh() }
            }
            Spacer()
            Button("Quit") { NSApplication.shared.terminate(nil) }
        }
    }
}

// MARK: - Shared bits

struct Block<Content: View>: View {
    let title: LocalizedStringKey
    @ViewBuilder var content: Content

    init(_ title: LocalizedStringKey, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.subheadline.bold())
            content
        }
        .padding(.bottom, 10)
    }
}

/// A row for something the Buds4 Pro does not support (or we could not verify): shown disabled with the reason.
struct UnavailableRow: View {
    let title: LocalizedStringKey
    let reason: LocalizedStringKey

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Toggle(title, isOn: .constant(false)).disabled(true)
            Text(reason).font(.caption2).foregroundStyle(.secondary)
        }
    }
}

struct Note: View {
    let text: LocalizedStringKey
    init(_ text: LocalizedStringKey) { self.text = text }
    var body: some View { Text(text).font(.caption2).foregroundStyle(.secondary) }
}

/// Integer slider that only sends when the drag ends.
struct StepSlider: View {
    let title: LocalizedStringKey
    let range: ClosedRange<Int>
    let value: Int
    var format: (Int) -> String = { "\($0)" }
    let onCommit: (Int) -> Void
    @State private var draft: Double?

    var body: some View {
        HStack {
            Text(title).frame(width: 90, alignment: .leading)
            Slider(value: Binding(get: { draft ?? Double(value) }, set: { draft = $0.rounded() }),
                   in: Double(range.lowerBound)...Double(range.upperBound), step: 1) { editing in
                if !editing, let d = draft { onCommit(Int(d)); draft = nil }
            }
            Text(format(Int(draft ?? Double(value)))).monospacedDigit().frame(width: 44, alignment: .trailing)
        }
    }
}

extension BudsController {
    func binding<T>(_ get: @escaping (BudsState) -> T, _ set: @escaping (BudsController, T) -> Void) -> Binding<T> {
        Binding(get: { get(self.state) }, set: { set(self, $0) })
    }
}

/// Label on the left, switch on the right edge.
struct RowToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack {
            configuration.label
            Spacer(minLength: 8)
            Toggle("", isOn: configuration.$isOn).labelsHidden().toggleStyle(.switch)
        }
    }
}
