import AppKit
import BudsCore
import SwiftUI

/// `--cli snapshot <dir>`: renders every panel page to PNG (offscreen window) for visual checks.
@MainActor
enum Snapshot {
    static func render(model: AppModel, to dir: URL) {
        _ = NSApplication.shared
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for page in ContentView.Page.allCases {
            UserDefaults.standard.set(page.rawValue, forKey: "page")
            let host = NSHostingView(rootView: ContentView(model: model, buds: model.buds)
                .background(Color(nsColor: .windowBackgroundColor)))
            let size = host.fittingSize
            let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless],
                                  backing: .buffered, defer: false)
            window.contentView = host
            host.frame = NSRect(origin: .zero, size: size)
            host.layoutSubtreeIfNeeded()
            guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { continue }
            host.cacheDisplay(in: host.bounds, to: rep)
            let url = dir.appendingPathComponent("page-\(page.rawValue.lowercased()).png")
            try? rep.representation(using: .png, properties: [:])?.write(to: url)
            print("wrote \(url.path)")
        }
    }
}
