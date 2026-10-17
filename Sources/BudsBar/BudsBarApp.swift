import AppKit
import BudsCore
import ServiceManagement
import SwiftUI

/// App-wide model: the controller plus app-level preferences.
@MainActor
@Observable
final class AppModel {
    static let shared = AppModel()

    let buds: BudsController
    /// Set when the user re-launches the app while the icon is hidden; shows it until quit.
    var forceShowIcon = false
    var alwaysShowIcon = UserDefaults.standard.bool(forKey: "alwaysShowIcon") {
        didSet { UserDefaults.standard.set(alwaysShowIcon, forKey: "alwaysShowIcon") }
    }

    var iconVisible: Bool { buds.budsPresent || alwaysShowIcon || forceShowIcon }

    var launchAtLogin: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            do {
                if newValue { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            } catch {
                Log.write("login item: \(error.localizedDescription)")
            }
        }
    }

    /// Wraps an already-connected controller (CLI snapshot); no login item, no notifications.
    init(cliController: BudsController) {
        buds = cliController
    }

    private init() {
        // Optional pin to one device: `defaults write <bundle id> deviceAddress xx-xx-xx-xx-xx-xx`.
        buds = BudsController(address: UserDefaults.standard.string(forKey: "deviceAddress"))
        buds.log = { Log.write($0) }
        buds.onFrame = { frame in
            if frame.msg == .extendedStatusUpdated { Log.write("ESU \(frame.payload.hex)") }
        }
        // Register as a login item once; the user can turn it off in the panel.
        if !UserDefaults.standard.bool(forKey: "didOfferLoginItem") {
            UserDefaults.standard.set(true, forKey: "didOfferLoginItem")
            launchAtLogin = true
        }
        Log.write("BudsBar \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "") started; watching for Buds")
        // Register IOBluetooth notifications once the app has finished launching.
        DispatchQueue.main.async { [buds] in buds.start() }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        MainActor.assumeIsolated { AppModel.shared.forceShowIcon = true }
        return false
    }
}

struct BudsBarApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var model = AppModel.shared

    var body: some Scene {
        MenuBarExtra(isInserted: Binding(get: { model.iconVisible }, set: { _ in })) {
            ContentView(model: model, buds: model.buds)
        } label: {
            MenuBarLabel(buds: model.buds)
        }
        .menuBarExtraStyle(.window)
    }
}

private struct MenuBarLabel: View {
    let buds: BudsController

    var body: some View {
        let s = buds.state
        if buds.isConnected, let l = s.batteryL, let r = s.batteryR {
            Image(systemName: "earbuds")
            Text("\(min(l, r))%")
        } else {
            Image(systemName: "earbuds")
        }
    }
}

/// Minimal append-only log at ~/Library/Logs/BudsBar.log.
enum Log {
    private static let url = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/BudsBar.log")

    static func write(_ message: String) {
        let line = "\(Date().formatted(.iso8601)) \(message)\n"
        guard let data = line.data(using: .utf8) else { return }
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(data)
            try? handle.close()
        } else {
            try? data.write(to: url)
        }
    }
}
