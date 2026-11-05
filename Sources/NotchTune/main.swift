import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var player: NowPlayingManager!
    private var claude: ClaudeBridge!
    private var devices: DeviceMonitor!
    private var notch: NotchController!
    private var statusItem: NSStatusItem?
    private var settingsWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        Pref.registerDefaults()
        player = NowPlayingManager()
        claude = ClaudeBridge()
        devices = DeviceMonitor()
        notch = NotchController(player: player, claude: claude, devices: devices)
        updateStatusItem()
        NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateStatusItem() }
        }
    }

    /// Opening the app again (e.g. from Spotlight) shows Settings — handy if the menu bar icon is hidden.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        openSettings()
        return false
    }

    private func updateStatusItem() {
        let show = UserDefaults.standard.bool(forKey: Pref.showMenuBarIcon)
        if show, statusItem == nil {
            let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
            item.button?.image = NSImage(systemSymbolName: "music.note", accessibilityDescription: "NotchTune")
            let menu = NSMenu()
            menu.addItem(withTitle: "Settings…", action: #selector(openSettings), keyEquivalent: ",").target = self
            menu.addItem(.separator())
            menu.addItem(withTitle: "Quit NotchTune", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
            item.menu = menu
            statusItem = item
        } else if !show, let item = statusItem {
            NSStatusBar.system.removeStatusItem(item)
            statusItem = nil
        }
    }

    @objc func openSettings() {
        if settingsWindow == nil {
            let w = NSWindow(contentViewController: NSHostingController(
                rootView: SettingsView(chromeJavaScriptOff: player.chromeJavaScriptOff)))
            w.title = "NotchTune Settings"
            w.styleMask = [.titled, .closable, .resizable, .miniaturizable]
            // Fit the screen: never taller than the visible area.
            let maxH = (NSScreen.main?.visibleFrame.height ?? 800) - 40
            w.setContentSize(NSSize(width: 480, height: min(620, maxH)))
            w.contentMinSize = NSSize(width: 460, height: 360)
            w.isReleasedWhenClosed = false
            w.center()
            settingsWindow = w
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }
}

// Hook mode: launched by Claude Code as `NotchTune --hook <event>`; forwards and exits.
if CommandLine.arguments.count >= 3, CommandLine.arguments[1] == "--hook" {
    HookClient.run(event: CommandLine.arguments[2])
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}
