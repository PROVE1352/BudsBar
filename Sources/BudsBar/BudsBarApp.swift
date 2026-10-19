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

struct BudsBarApp: App {
    @State private var model = AppModel.shared

    var body: some Scene {
        // The icon is always there; it is dimmed while BudsBar has no settings channel.
        MenuBarExtra {
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
        if buds.isConnected {
            Image(systemName: "earbuds")
            if let l = s.batteryL, let r = s.batteryR { Text("\(min(l, r))%") }
        } else {
            // SwiftUI opacity is ignored in the status item, so draw a faded template image.
            Image(nsImage: Self.dimmedIcon)
        }
    }

    private static let dimmedIcon: NSImage = {
        let config = NSImage.SymbolConfiguration(pointSize: 14, weight: .regular)
        guard let symbol = NSImage(systemSymbolName: "earbuds", accessibilityDescription: "BudsBar")?
            .withSymbolConfiguration(config) else { return NSImage() }
        // Rendered once into a 2x bitmap (a drawing-handler image would redraw on every menu bar refresh).
        let size = symbol.size
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * 2), pixelsHigh: Int(size.height * 2),
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return symbol }
        rep.size = size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        symbol.draw(in: NSRect(origin: .zero, size: size), from: .zero, operation: .sourceOver, fraction: 0.35)
        NSGraphicsContext.restoreGraphicsState()
        let image = NSImage(size: size)
        image.addRepresentation(rep)
        image.isTemplate = true
        image.accessibilityDescription = String(localized: "BudsBar (not connected)")
        return image
    }()
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
