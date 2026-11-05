import SwiftUI
import ServiceManagement

/// All user-customizable settings live here (stored in UserDefaults).
enum Pref {
    static let hoverDelay = "hoverDelay"
    static let collapseDelay = "collapseDelay"
    static let expandedWidth = "expandedWidth"
    static let expandedHeight = "expandedHeight"
    static let cornerRadius = "cornerRadius"
    static let showLiveActivity = "showLiveActivity"
    static let showEqualizer = "showEqualizer"
    static let showAlbum = "showAlbum"
    static let accentStyle = "accentStyle"
    static let preferredPlayer = "preferredPlayer"
    static let haptics = "haptics"
    static let showMenuBarIcon = "showMenuBarIcon"
    static let artworkSize = "artworkSize"
    static let chromeEnabled = "chromeEnabled"
    static let displayMode = "displayMode"          // "notch" | "all" | "main"
    static let alwaysShowExternal = "alwaysShowExternal"
    static let claudeEnabled = "claudeEnabled"
    static let showClaudeActivity = "showClaudeActivity"
    static let claudeAutoOpen = "claudeAutoOpen"
    static let claudeWaitSeconds = "claudeWaitSeconds"
    static let claudeIdleAlerts = "claudeIdleAlerts"
    static let islandStyle = "islandStyle"
    static let islandHover = "islandHover"
    static let showAccessories = "showAccessories"
    static let showCharging = "showCharging"
    static let closedWidth = "closedWidth"

    static let all = [hoverDelay, collapseDelay, expandedWidth, expandedHeight, cornerRadius, showLiveActivity,
                      showEqualizer, showAlbum, accentStyle, preferredPlayer, haptics, showMenuBarIcon, artworkSize,
                      chromeEnabled, displayMode, alwaysShowExternal, claudeEnabled, showClaudeActivity,
                      claudeAutoOpen, claudeWaitSeconds, claudeIdleAlerts,
                      islandStyle, islandHover, showAccessories, showCharging, closedWidth]

    static func registerDefaults() {
        UserDefaults.standard.register(defaults: [
            hoverDelay: 0.15,
            collapseDelay: 0.25,
            expandedWidth: 480.0,
            expandedHeight: 210.0,
            cornerRadius: 26.0,
            showLiveActivity: true,
            showEqualizer: true,
            showAlbum: true,
            accentStyle: "artwork",
            preferredPlayer: "auto",
            haptics: true,
            showMenuBarIcon: true,
            artworkSize: 76.0,
            chromeEnabled: true,
            displayMode: "notch",
            alwaysShowExternal: false,
            claudeEnabled: true,
            showClaudeActivity: true,
            claudeAutoOpen: true,
            claudeWaitSeconds: 45.0,
            claudeIdleAlerts: true,
            islandStyle: true,
            islandHover: false,
            showAccessories: true,
            showCharging: true,
            closedWidth: 30.0,
        ])
    }

    static func accent(style: String, artwork: Color?) -> Color {
        switch style {
        case "white": return .white
        case "green": return Color(red: 0.12, green: 0.84, blue: 0.38)
        case "pink": return Color(red: 1.0, green: 0.27, blue: 0.47)
        case "blue": return Color(red: 0.25, green: 0.6, blue: 1.0)
        case "purple": return Color(red: 0.7, green: 0.45, blue: 1.0)
        default: return artwork ?? .white
        }
    }
}

struct SettingsView: View {
    @AppStorage(Pref.hoverDelay) private var hoverDelay = 0.15
    @AppStorage(Pref.collapseDelay) private var collapseDelay = 0.25
    @AppStorage(Pref.expandedWidth) private var expandedWidth = 480.0
    @AppStorage(Pref.expandedHeight) private var expandedHeight = 210.0
    @AppStorage(Pref.cornerRadius) private var cornerRadius = 26.0
    @AppStorage(Pref.artworkSize) private var artworkSize = 76.0
    @AppStorage(Pref.showLiveActivity) private var showLiveActivity = true
    @AppStorage(Pref.showEqualizer) private var showEqualizer = true
    @AppStorage(Pref.showAlbum) private var showAlbum = true
    @AppStorage(Pref.accentStyle) private var accentStyle = "artwork"
    @AppStorage(Pref.preferredPlayer) private var preferredPlayer = "auto"
    @AppStorage(Pref.haptics) private var haptics = true
    @AppStorage(Pref.showMenuBarIcon) private var showMenuBarIcon = true
    @AppStorage(Pref.chromeEnabled) private var chromeEnabled = true
    @AppStorage(Pref.displayMode) private var displayMode = "notch"
    @AppStorage(Pref.alwaysShowExternal) private var alwaysShowExternal = false
    @AppStorage(Pref.claudeEnabled) private var claudeEnabled = true
    @AppStorage(Pref.showClaudeActivity) private var showClaudeActivity = true
    @AppStorage(Pref.claudeAutoOpen) private var claudeAutoOpen = true
    @AppStorage(Pref.claudeWaitSeconds) private var claudeWaitSeconds = 45.0
    @AppStorage(Pref.claudeIdleAlerts) private var claudeIdleAlerts = true
    @AppStorage(Pref.islandStyle) private var islandStyle = true
    @AppStorage(Pref.islandHover) private var islandHover = false
    @AppStorage(Pref.showAccessories) private var showAccessories = true
    @AppStorage(Pref.showCharging) private var showCharging = true
    @AppStorage(Pref.closedWidth) private var closedWidth = 30.0
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var hookStatus = HookInstaller.status
    @State private var hookError: String?
    var chromeJavaScriptOff = false

    var body: some View {
        Form {
            Section("Music") {
                Picker("Player", selection: $preferredPlayer) {
                    Text("Automatic (whatever is playing)").tag("auto")
                    Text("Apple Music only").tag("music")
                    Text("Spotify only").tag("spotify")
                    Text("Google Chrome only").tag("chrome")
                }
                Toggle("Include music playing in Google Chrome", isOn: $chromeEnabled)
                if chromeEnabled {
                    Text(chromeJavaScriptOff
                         ? "⚠️ Chrome is blocking it. In Chrome: View → Developer → Allow JavaScript from Apple Events."
                         : "Needs Chrome → View → Developer → Allow JavaScript from Apple Events (one time).")
                        .font(.caption).foregroundStyle(chromeJavaScriptOff ? .orange : .secondary)
                }
                Toggle("Show song in the notch while closed", isOn: $showLiveActivity)
                Toggle("Show equalizer animation", isOn: $showEqualizer)
                Toggle("Show album name", isOn: $showAlbum)
                Picker("Accent color", selection: $accentStyle) {
                    Text("From album artwork").tag("artwork")
                    Text("White").tag("white")
                    Text("Green").tag("green")
                    Text("Pink").tag("pink")
                    Text("Blue").tag("blue")
                    Text("Purple").tag("purple")
                }
            }
            Section("Claude Code") {
                Toggle("Show Claude Code in the notch", isOn: $claudeEnabled)
                LabeledContent("Connection") {
                    HStack {
                        Text(hookStatus.currentPath ? "Connected" : hookStatus.installed ? "Points to another copy" : "Not connected")
                            .foregroundStyle(hookStatus.currentPath ? .green : .secondary)
                        Button(hookStatus.currentPath ? "Reconnect" : "Connect") { run(HookInstaller.install) }
                        if hookStatus.installed { Button("Disconnect") { run(HookInstaller.uninstall) } }
                    }
                }
                Text("Connect adds NotchTune hooks to ~/.claude/settings.json (a backup is saved next to it). New Claude sessions pick them up.")
                    .font(.caption).foregroundStyle(.secondary)
                if let hookError { Text(hookError).font(.caption).foregroundStyle(.red) }
                Toggle("Show the animated Claude icon while a prompt runs", isOn: $showClaudeActivity)
                Toggle("Open the notch for permission requests and questions", isOn: $claudeAutoOpen)
                Toggle("Tell me when Claude is waiting for my reply", isOn: $claudeIdleAlerts)
                slider("Wait for my answer", $claudeWaitSeconds, 10...300, step: 5, unit: "s")
                Text("If you don't answer in the notch in time, Claude shows its normal prompt.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Displays") {
                Picker("Show on", selection: $displayMode) {
                    Text("Built-in display (with notch)").tag("notch")
                    Text("All displays").tag("all")
                    Text("Main display only").tag("main")
                }
                Toggle("Dynamic Island style on displays without a notch", isOn: $islandStyle)
                if islandStyle {
                    Text("Click the island or swipe down on it with two fingers to open. Click outside or swipe up to close.")
                        .font(.caption).foregroundStyle(.secondary)
                    Toggle("Also open the island on hover", isOn: $islandHover)
                }
                Toggle(islandStyle ? "Always show the island" : "Always show a notch on displays without one",
                       isOn: $alwaysShowExternal)
                Text("Otherwise it appears only while music, Claude or a device pop-up is active.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Devices") {
                Toggle("Show AirPods, Bluetooth and USB accessories when they connect", isOn: $showAccessories)
                Toggle("Show when the charger is plugged in or out", isOn: $showCharging)
                Text("Bluetooth changes apply after restarting NotchTune.").font(.caption).foregroundStyle(.secondary)
                LabeledContent("Preview") {
                    HStack {
                        ForEach([("AirPods", "airpods"), ("Charger", "charger"), ("Accessory", "accessory")], id: \.1) { label, kind in
                            Button(label) {
                                DistributedNotificationCenter.default().postNotificationName(
                                    DeviceMonitor.previewNotification, object: nil, userInfo: ["kind": kind],
                                    deliverImmediately: true)
                            }
                        }
                    }
                }
            }
            Section("Behavior") {
                slider("Open after hovering", $hoverDelay, 0...1, step: 0.05, unit: "s")
                slider("Close after leaving", $collapseDelay, 0...1.5, step: 0.05, unit: "s")
                Toggle("Haptic feedback when opening", isOn: $haptics)
            }
            Section("Size & shape") {
                slider("Closed width", $closedWidth, 0...80, step: 2, unit: "pt")
                slider("Open width", $expandedWidth, 380...700, step: 10, unit: "pt")
                slider("Height", $expandedHeight, 160...260, step: 5, unit: "pt")
                slider("Corner radius", $cornerRadius, 10...40, step: 1, unit: "pt")
                slider("Artwork size", $artworkSize, 50...110, step: 2, unit: "pt")
            }
            Section("App") {
                Toggle("Launch at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, on in
                        do {
                            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                        } catch {
                            launchAtLogin = SMAppService.mainApp.status == .enabled
                        }
                    }
                Toggle("Show menu bar icon", isOn: $showMenuBarIcon)
                if !showMenuBarIcon {
                    Text("To get back here, open NotchTune again from Finder or Spotlight.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Button("Reset all settings") {
                    Pref.all.forEach(UserDefaults.standard.removeObject(forKey:))
                }
            }
        }
        .formStyle(.grouped)
        // Scrolls instead of growing past the screen; drag the window edge to make it taller.
        .frame(minWidth: 460, idealWidth: 480, minHeight: 360, idealHeight: 620)
    }

    private func run(_ action: () throws -> Void) {
        do { try action(); hookError = nil } catch { hookError = error.localizedDescription }
        hookStatus = HookInstaller.status
    }

    private func slider(_ title: String, _ value: Binding<Double>, _ range: ClosedRange<Double>,
                        step: Double, unit: String) -> some View {
        LabeledContent(title) {
            HStack {
                Slider(value: value, in: range, step: step).frame(width: 180)
                Text(unit == "s" ? String(format: "%.2fs", value.wrappedValue) : "\(Int(value.wrappedValue))\(unit)")
                    .monospacedDigit().foregroundStyle(.secondary).frame(width: 50, alignment: .trailing)
            }
        }
    }
}
