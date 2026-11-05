import AppKit
import SwiftUI
import Combine

/// Borderless, transparent panel that sits on top of the menu bar around the notch.
final class NotchPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// Lets buttons respond on the very first click even though the app is never "active".
final class FirstClickHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

// MARK: - Shared layout (used by both hit-testing and drawing so they always agree)

enum NotchTab: Hashable { case music, claude }

enum NotchContent { case music, request(ClaudeRequest), sessions(Int), device(DeviceToast), empty }

enum WingItem: Hashable { case artwork, spark, sparkAlert, equalizer, alert, check, timer, toastIcon, toastStatus }

/// What sits on each side of the notch while it's closed: one item per side, like the Dynamic Island.
struct WingContent: Equatable {
    var left: WingItem?
    var right: WingItem?
    var isEmpty: Bool { left == nil && right == nil }

    /// Both sides share one width so the notch stays centered.
    func sideWidth(height h: CGFloat) -> CGFloat {
        guard !isEmpty else { return 0 }
        if left == .toastIcon { return 132 }
        // Extra room on each side while closed (Settings → Size & shape → Closed width).
        let extra = CGFloat(UserDefaults.standard.double(forKey: Pref.closedWidth))
        return (right == .timer ? 58 : h + 12) + extra
    }
}

@MainActor
enum NotchLayout {
    static var d: UserDefaults { .standard }

    static func availableTabs(player: NowPlayingManager, claude: ClaudeBridge) -> [NotchTab] {
        var tabs: [NotchTab] = []
        if player.track != nil { tabs.append(.music) }
        if d.bool(forKey: Pref.claudeEnabled), !claude.requests.isEmpty || !claude.visibleSessions.isEmpty {
            tabs.append(.claude)
        }
        return tabs
    }

    /// The tab actually shown: the one you picked if it has something, otherwise whatever does.
    static func activeTab(_ screen: NotchScreen, player: NowPlayingManager, claude: ClaudeBridge) -> NotchTab? {
        let tabs = availableTabs(player: player, claude: claude)
        return tabs.contains(screen.tab) ? screen.tab : tabs.first
    }

    static func content(_ screen: NotchScreen, player: NowPlayingManager, claude: ClaudeBridge,
                        devices: DeviceMonitor) -> NotchContent {
        // AirPods / charger cards take over briefly, unless Claude is asking for something.
        if let t = devices.toast, t.isRich, claude.requests.isEmpty { return .device(t) }
        switch activeTab(screen, player: player, claude: claude) {
        case .music: return .music
        case .claude:
            if let r = claude.requests.first, d.bool(forKey: Pref.claudeEnabled) { return .request(r) }
            return .sessions(claude.visibleSessions.count)
        case nil: return .empty
        }
    }

    /// Open size: your chosen size for music, or a size that fits the Claude content shown.
    static func expandedSize(_ content: NotchContent) -> CGSize {
        let w = d.double(forKey: Pref.expandedWidth), h = d.double(forKey: Pref.expandedHeight)
        switch content {
        case .music:
            return CGSize(width: w, height: h)
        case .empty:
            return CGSize(width: w, height: 170)
        case .device(let t):
            if case .airpods = t.kind { return CGSize(width: max(w, 440), height: 212) }
            return CGSize(width: max(w, 440), height: 140)
        case .sessions(let n):
            let rows = CGFloat(min(max(n, 1), 4))
            return CGSize(width: max(w, 460), height: max(130, 52 + rows * 54 + 8))
        case .request(let request):
            let height: CGFloat
            switch request.kind {
            case .permission(_, let detail): height = detail.count > 70 ? 236 : 206
            case .question(let qs, _): height = (qs.first?.options.count ?? 0) > 2 ? 262 : 216
            case .attention: height = 196
            }
            return CGSize(width: max(w, 480), height: height)
        }
    }

    static var maxExpandedSize: CGSize {
        let w = d.double(forKey: Pref.expandedWidth), h = d.double(forKey: Pref.expandedHeight)
        return CGSize(width: max(w, 480), height: max(h, 280))
    }

    /// Island geometry for displays without a notch.
    static let islandGap: CGFloat = 3
    static let islandCenter: CGFloat = 36

    static func wings(player: NowPlayingManager, claude: ClaudeBridge, devices: DeviceMonitor) -> WingContent {
        if devices.toast != nil { return WingContent(left: .toastIcon, right: .toastStatus) }
        let musicOn = d.bool(forKey: Pref.showLiveActivity) && player.track != nil && player.isPlaying
        let claudeOn = d.bool(forKey: Pref.claudeEnabled)
        let hasRequest = claudeOn && !claude.requests.isEmpty
        let activity = claudeOn && d.bool(forKey: Pref.showClaudeActivity) && (claude.isWorking || claude.recentlyFinished)
        let claudeVisible = hasRequest || activity
        var c = WingContent()
        if musicOn { c.left = .artwork } else if claudeVisible { c.left = .spark }
        if claudeVisible {
            if musicOn { c.right = hasRequest ? .sparkAlert : (claude.isWorking ? .spark : .check) }
            else { c.right = hasRequest ? .alert : (claude.isWorking ? .timer : .check) }
        } else if musicOn {
            c.right = .equalizer
        }
        return c
    }
}

// MARK: - One notch per display

@MainActor
final class NotchScreen: ObservableObject, Identifiable {
    let id: CGDirectDisplayID
    @Published var expanded = false
    @Published var notchSize = CGSize(width: 190, height: 32)
    @Published var hasPhysicalNotch = false
    @Published var tab: NotchTab = .music
    /// Opened automatically for a Claude request; stays open until it's handled.
    var pinned = false
    /// Island opened by a click or swipe; stays open until you click outside or swipe up.
    var userPinned = false
    /// Opened for an AirPods / charger card; closes again when the card goes away.
    var devicePinned = false
    var scrollAccum: CGFloat = 0
    /// Displays without a notch get a floating Dynamic Island instead (if enabled).
    var isIsland: Bool { !hasPhysicalNotch && UserDefaults.standard.bool(forKey: Pref.islandStyle) }
    /// The top of the shape sits this far below the top of the screen.
    var topGap: CGFloat { isIsland ? NotchLayout.islandGap : 0 }
    var onTap: (() -> Void)?
    var screen: NSScreen
    let panel: NotchPanel
    var pendingExpand: DispatchWorkItem?
    var pendingCollapse: DispatchWorkItem?

    init(screen: NSScreen, id: CGDirectDisplayID, root: (NotchScreen) -> AnyView) {
        self.id = id
        self.screen = screen
        panel = NotchPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                           backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .init(rawValue: NSWindow.Level.mainMenu.rawValue + 3)
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        panel.isMovable = false
        panel.ignoresMouseEvents = true
        panel.acceptsMouseMovedEvents = true
        panel.isReleasedWhenClosed = false
        panel.contentView = FirstClickHostingView(rootView: root(self))
        panel.orderFrontRegardless()
    }

    func layout(padding: CGFloat) {
        let f = screen.frame
        let size: CGSize
        if screen.safeAreaInsets.top > 0,
           let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea {
            size = CGSize(width: f.width - left.width - right.width, height: screen.safeAreaInsets.top)
        } else {
            let menuBar = f.maxY - screen.visibleFrame.maxY
            let island = UserDefaults.standard.bool(forKey: Pref.islandStyle)
            // Slim enough to stay inside the menu bar so it never covers the app below.
            let islandHeight = min(max((menuBar > 0 ? menuBar : 30) - 2 * NotchLayout.islandGap, 22), 30)
            size = island ? CGSize(width: NotchLayout.islandCenter, height: islandHeight)
                          : CGSize(width: 180, height: max(menuBar, 24))
        }
        let physical = screen.safeAreaInsets.top > 0
        if physical != hasPhysicalNotch { hasPhysicalNotch = physical }
        if size != notchSize { notchSize = size }

        let e = NotchLayout.maxExpandedSize
        let w = e.width + padding * 2, h = e.height + padding + NotchLayout.islandGap
        let frame = NSRect(x: f.midX - w / 2, y: f.maxY - h, width: w, height: h)
        if panel.frame != frame { panel.setFrame(frame, display: true) }
    }
}

// MARK: - Controller

@MainActor
final class NotchController: ObservableObject {
    let player: NowPlayingManager
    let claude: ClaudeBridge
    let devices: DeviceMonitor
    private(set) var screens: [NotchScreen] = []
    private var trackingTimer: Timer?
    private var monitors: [Any] = []
    private var observers: [NSObjectProtocol] = []
    private var bag: Set<AnyCancellable> = []
    private let windowPadding: CGFloat = 40 // room for the shadow

    init(player: NowPlayingManager, claude: ClaudeBridge, devices: DeviceMonitor) {
        self.player = player
        self.claude = claude
        self.devices = devices
        rebuildScreens()

        let nc = NotificationCenter.default
        observers.append(nc.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                        object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.rebuildScreens() }
        })
        observers.append(nc.addObserver(forName: UserDefaults.didChangeNotification,
                                        object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.rebuildScreens() }
        })

        // Mouse-moved monitors only need location, so no Accessibility permission is required.
        if let m = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged], handler: { [weak self] _ in
            MainActor.assumeIsolated { self?.mouseMoved() }
        }) { monitors.append(m) }
        if let m = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged], handler: { [weak self] e in
            MainActor.assumeIsolated { self?.mouseMoved() }
            return e
        }) { monitors.append(m) }

        // Island gestures: click outside closes it; two-finger swipe down opens, swipe up closes.
        if let m = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown], handler: { [weak self] _ in
            MainActor.assumeIsolated { self?.clickedOutside() }
        }) { monitors.append(m) }
        if let m = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel], handler: { [weak self] e in
            MainActor.assumeIsolated { self?.scrolled(e) }
            return e
        }) { monitors.append(m) }

        // Any shortcut or script can post this distributed notification to open/close the notch.
        observers.append(DistributedNotificationCenter.default().addObserver(
            forName: .init("local.notchtune.toggle"), object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let open = !self.screens.contains(where: \.expanded)
                for s in self.screens { s.pinned = open; self.setExpanded(open, on: s) }
            }
        })

        claude.onNewRequest = { [weak self] in self?.claudeNeedsAttention() }
        devices.$toast.receive(on: RunLoop.main).sink { [weak self] t in self?.deviceToastChanged(t) }.store(in: &bag)
        // Close pinned notches once every Claude request is handled.
        claude.$requests.receive(on: RunLoop.main).sink { [weak self] reqs in
            guard let self, reqs.isEmpty else { return }
            for s in self.screens where s.pinned {
                s.pinned = false
                if !self.expandedZone(s).contains(NSEvent.mouseLocation) { self.setExpanded(false, on: s) }
            }
        }.store(in: &bag)
    }

    // MARK: Screens

    private func wantedScreens() -> [NSScreen] {
        let all = NSScreen.screens
        switch UserDefaults.standard.string(forKey: Pref.displayMode) ?? "notch" {
        case "all": return all
        case "main": return [NSScreen.main ?? all.first].compactMap { $0 }
        default: return [all.first { $0.safeAreaInsets.top > 0 } ?? NSScreen.main ?? all.first].compactMap { $0 }
        }
    }

    private func rebuildScreens() {
        let wanted = wantedScreens()
        let ids = wanted.map(Self.displayID)
        for s in screens where !ids.contains(s.id) { s.panel.orderOut(nil); s.panel.close() }
        screens.removeAll { !ids.contains($0.id) }
        for (screen, id) in zip(wanted, ids) {
            if let existing = screens.first(where: { $0.id == id }) {
                existing.screen = screen
            } else {
                let s = NotchScreen(screen: screen, id: id) { [unowned self] s in
                    AnyView(NotchRootView(screen: s, player: self.player, claude: self.claude, devices: self.devices)
                        .environment(\.colorScheme, .dark))
                }
                s.onTap = { [weak self, weak s] in
                    guard let self, let s else { return }
                    s.userPinned = !s.expanded
                    self.setExpanded(!s.expanded, on: s)
                }
                screens.append(s)
            }
        }
        screens.forEach { $0.layout(padding: windowPadding) }
    }

    private static func displayID(_ s: NSScreen) -> CGDirectDisplayID {
        (s.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
    }

    // MARK: Hover logic

    private func collapsedHotZone(_ s: NotchScreen) -> CGRect {
        let wings = NotchLayout.wings(player: player, claude: claude, devices: devices)
        var w = s.notchSize.width + 2 * wings.sideWidth(height: s.notchSize.height)
        if s.isIsland, wings.isEmpty { w = 120 } // idle island pill
        let f = s.screen.frame
        let top = f.maxY - s.topGap
        return CGRect(x: f.midX - w / 2 - 6, y: top - s.notchSize.height - 4,
                      width: w + 12, height: s.notchSize.height + 6 + s.topGap)
    }

    private func expandedZone(_ s: NotchScreen) -> CGRect {
        let e = NotchLayout.expandedSize(NotchLayout.content(s, player: player, claude: claude, devices: devices)), f = s.screen.frame
        let top = f.maxY - s.topGap
        return CGRect(x: f.midX - e.width / 2, y: top - e.height, width: e.width, height: e.height + 2 + s.topGap)
            .insetBy(dx: -12, dy: -12)
    }

    // MARK: Island gestures

    private func clickedOutside() {
        let loc = NSEvent.mouseLocation
        for s in screens where s.isIsland && s.expanded && !s.pinned && !expandedZone(s).contains(loc) {
            setExpanded(false, on: s)
        }
    }

    private func scrolled(_ e: NSEvent) {
        guard let s = screens.first(where: { $0.panel === e.window }), s.isIsland else { return }
        if e.phase == .began { s.scrollAccum = 0 }
        // Positive = fingers moving down, regardless of the natural-scrolling setting.
        s.scrollAccum += e.isDirectionInvertedFromDevice ? e.scrollingDeltaY : -e.scrollingDeltaY
        guard e.phase == .ended || e.phase == .changed else { return }
        if !s.expanded, s.scrollAccum > 18 {
            s.scrollAccum = 0; s.userPinned = true; setExpanded(true, on: s)
        } else if s.expanded, !s.pinned, s.scrollAccum < -40 {
            s.scrollAccum = 0; setExpanded(false, on: s)
        }
    }

    private func mouseMoved() {
        let loc = NSEvent.mouseLocation
        let d = UserDefaults.standard
        for s in screens {
            if s.isIsland {
                // The island doesn't open on hover (unless enabled); it takes clicks and swipes instead.
                let showing = d.bool(forKey: Pref.alwaysShowExternal)
                    || !NotchLayout.wings(player: player, claude: claude, devices: devices).isEmpty
                let over = (s.expanded ? expandedZone(s) : collapsedHotZone(s)).contains(loc) && (s.expanded || showing)
                if !s.expanded { s.panel.ignoresMouseEvents = !over }
                if !d.bool(forKey: Pref.islandHover) || s.userPinned || s.pinned || s.devicePinned { continue }
            }
            if s.expanded {
                if s.pinned || s.userPinned || s.devicePinned || expandedZone(s).contains(loc) {
                    s.pendingCollapse?.cancel(); s.pendingCollapse = nil
                } else if s.pendingCollapse == nil {
                    let work = DispatchWorkItem { [weak self, weak s] in
                        MainActor.assumeIsolated { if let s { self?.setExpanded(false, on: s) } }
                    }
                    s.pendingCollapse = work
                    DispatchQueue.main.asyncAfter(deadline: .now() + d.double(forKey: Pref.collapseDelay), execute: work)
                }
            } else if collapsedHotZone(s).contains(loc) {
                guard s.pendingExpand == nil else { continue }
                let work = DispatchWorkItem { [weak self, weak s] in
                    MainActor.assumeIsolated {
                        guard let self, let s else { return }
                        s.pendingExpand = nil
                        if self.collapsedHotZone(s).contains(NSEvent.mouseLocation) { self.setExpanded(true, on: s) }
                    }
                }
                s.pendingExpand = work
                DispatchQueue.main.asyncAfter(deadline: .now() + d.double(forKey: Pref.hoverDelay), execute: work)
            } else {
                s.pendingExpand?.cancel(); s.pendingExpand = nil
            }
        }
    }

    private func deviceToastChanged(_ t: DeviceToast?) {
        if let t, t.isRich {
            for s in screens where !s.expanded || s.devicePinned {
                s.devicePinned = true
                setExpanded(true, on: s, haptic: s === screens.first)
            }
        } else {
            for s in screens where s.devicePinned {
                s.devicePinned = false
                if !s.pinned && !s.userPinned && !expandedZone(s).contains(NSEvent.mouseLocation) {
                    setExpanded(false, on: s)
                }
            }
        }
    }

    private func claudeNeedsAttention() {
        for s in screens { s.tab = .claude }
        guard UserDefaults.standard.bool(forKey: Pref.claudeAutoOpen) else { return }
        for s in screens {
            s.pinned = true
            setExpanded(true, on: s, haptic: s === screens.first)
        }
    }

    func setExpanded(_ value: Bool, on s: NotchScreen, haptic: Bool = true) {
        s.pendingExpand?.cancel(); s.pendingExpand = nil
        s.pendingCollapse?.cancel(); s.pendingCollapse = nil
        if !value { s.pinned = false; s.userPinned = false; s.devicePinned = false }
        guard value != s.expanded else { return }
        s.expanded = value
        s.panel.ignoresMouseEvents = !value && !(s.isIsland && collapsedHotZone(s).contains(NSEvent.mouseLocation))

        let anyOpen = screens.contains(where: \.expanded)
        player.fastPolling = anyOpen
        if value, haptic, UserDefaults.standard.bool(forKey: Pref.haptics) {
            NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
        }
        // While open, the mouse may be over our own non-key window where moved events
        // aren't always delivered, so also check the position on a light timer.
        if (anyOpen || screens.contains(where: \.isIsland)), trackingTimer == nil {
            trackingTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.mouseMoved() }
            }
        } else if !anyOpen && !screens.contains(where: \.isIsland) {
            trackingTimer?.invalidate(); trackingTimer = nil
        }
    }
}
