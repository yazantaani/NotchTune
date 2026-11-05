import SwiftUI

// MARK: - Design tokens

enum Theme {
    static let orange = Color(red: 0.86, green: 0.48, blue: 0.35)
    static let text = Color.white
    static let secondary = Color.white.opacity(0.62)
    static let tertiary = Color.white.opacity(0.38)
    static let fill = Color.white.opacity(0.07)
    static let fillHover = Color.white.opacity(0.13)
    static let stroke = Color.white.opacity(0.07)
    static let spring = Animation.spring(response: 0.42, dampingFraction: 0.8)
}

/// Notch silhouette: small outward curves at the top (blending into the screen edge)
/// and rounded corners at the bottom.
struct NotchShape: Shape {
    var topRadius: CGFloat
    var bottomRadius: CGFloat

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { .init(topRadius, bottomRadius) }
        set { topRadius = newValue.first; bottomRadius = newValue.second }
    }

    func path(in r: CGRect) -> Path {
        var p = Path()
        let t = topRadius, b = min(bottomRadius, r.height - t, (r.width - 2 * t) / 2)
        p.move(to: CGPoint(x: r.minX, y: r.minY))
        p.addQuadCurve(to: CGPoint(x: r.minX + t, y: r.minY + t), control: CGPoint(x: r.minX + t, y: r.minY))
        p.addLine(to: CGPoint(x: r.minX + t, y: r.maxY - b))
        p.addQuadCurve(to: CGPoint(x: r.minX + t + b, y: r.maxY), control: CGPoint(x: r.minX + t, y: r.maxY))
        p.addLine(to: CGPoint(x: r.maxX - t - b, y: r.maxY))
        p.addQuadCurve(to: CGPoint(x: r.maxX - t, y: r.maxY - b), control: CGPoint(x: r.maxX - t, y: r.maxY))
        p.addLine(to: CGPoint(x: r.maxX - t, y: r.minY + t))
        p.addQuadCurve(to: CGPoint(x: r.maxX, y: r.minY), control: CGPoint(x: r.maxX - t, y: r.minY))
        p.closeSubpath()
        return p
    }
}

// MARK: - Root

struct NotchRootView: View {
    @ObservedObject var screen: NotchScreen
    @ObservedObject var player: NowPlayingManager
    @ObservedObject var claude: ClaudeBridge
    @ObservedObject var devices: DeviceMonitor

    @AppStorage(Pref.islandStyle) private var islandStyle = true
    @State private var pressed = false
    @AppStorage(Pref.expandedWidth) private var expandedWidth = 480.0
    @AppStorage(Pref.expandedHeight) private var expandedHeight = 210.0
    @AppStorage(Pref.cornerRadius) private var cornerRadius = 26.0
    @AppStorage(Pref.accentStyle) private var accentStyle = "artwork"
    @AppStorage(Pref.alwaysShowExternal) private var alwaysShowExternal = false

    private var expanded: Bool { screen.expanded }
    private var content: NotchContent { NotchLayout.content(screen, player: player, claude: claude, devices: devices) }
    private var wings: WingContent {
        expanded ? WingContent() : NotchLayout.wings(player: player, claude: claude, devices: devices)
    }
    private var isIsland: Bool { !screen.hasPhysicalNotch && islandStyle }
    private var topRadius: CGFloat { isIsland ? 0 : (expanded ? 14 : 6) }
    private var accent: Color { Pref.accent(style: accentStyle, artwork: player.artworkColor) }

    private var contentKey: String {
        switch content {
        case .music: "music"
        case .request(let r): "request-\(r.id)"
        case .sessions: "sessions"
        case .device(let t): "device-\(t.id)"
        case .empty: "empty"
        }
    }

    private var shapeSize: CGSize {
        if expanded {
            let e = NotchLayout.expandedSize(content)
            return CGSize(width: e.width + 2 * topRadius, height: e.height)
        }
        if isIsland && wings.isEmpty { return CGSize(width: 120, height: screen.notchSize.height) }
        let side = wings.sideWidth(height: screen.notchSize.height)
        return CGSize(width: screen.notchSize.width + 2 * side + 2 * topRadius, height: screen.notchSize.height)
    }

    /// On screens without a notch, stay invisible until there is something to show (unless set otherwise).
    private var visible: Bool { screen.hasPhysicalNotch || alwaysShowExternal || expanded || !wings.isEmpty }

    /// Soft glow: album colors on the Music tab, Claude orange on the Claude tab.
    private var glow: Color? {
        guard expanded else { return nil }
        switch content {
        case .music: return accent
        case .request, .sessions: return Theme.orange
        case .device(let t):
            if case .charging(let plugged, _, _) = t.kind { return plugged ? .green : .white }
            return .white
        case .empty: return nil
        }
    }

    var body: some View {
        Group {
            if isIsland {
                shell(RoundedRectangle(cornerRadius: expanded ? max(cornerRadius, 30) : shapeSize.height / 2,
                                       style: .continuous))
                    .scaleEffect(pressed && !expanded ? 0.94 : 1, anchor: .top)
                    .padding(.top, NotchLayout.islandGap)
            } else {
                shell(NotchShape(topRadius: topRadius, bottomRadius: expanded ? cornerRadius : 10))
            }
        }
        .opacity(visible ? 1 : 0)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .animation(Theme.spring, value: expanded)
        .animation(Theme.spring, value: wings)
        .animation(Theme.spring, value: contentKey)
        .animation(.spring(response: 0.3, dampingFraction: 0.6), value: pressed)
    }

    // Opening: the width snaps out first, then the height drops down, so it unfolds from the top.
    // Closing: the height pulls up first, then the width tucks in.
    private var widthAnimation: Animation {
        expanded ? .spring(response: 0.3, dampingFraction: 0.86)
                 : .spring(response: 0.42, dampingFraction: 0.86).delay(0.06)
    }
    private var heightAnimation: Animation {
        expanded ? .spring(response: 0.46, dampingFraction: 0.76).delay(0.04)
                 : .spring(response: 0.32, dampingFraction: 0.9)
    }

    private func shell<S: Shape>(_ shape: S) -> some View {
        ZStack(alignment: .top) {
            shape
                .fill(.black)
                .overlay {
                    if let glow {
                        RadialGradient(colors: [glow.opacity(0.22), .clear], center: .bottomLeading,
                                       startRadius: 10, endRadius: shapeSize.width * 0.75)
                            .clipShape(shape)
                            .transition(.opacity)
                    }
                }
                .overlay {
                    // A hairline edge so the island reads as an object on light wallpapers.
                    if isIsland { shape.stroke(.white.opacity(expanded ? 0.08 : 0.05), lineWidth: 0.5) }
                }
                .animation(widthAnimation) { $0.frame(width: shapeSize.width) }
                .animation(heightAnimation) { $0.frame(height: shapeSize.height) }
                .shadow(color: .black.opacity(expanded ? 0.6 : (isIsland ? 0.35 : 0)), radius: expanded ? 18 : 8, y: expanded ? 6 : 2)

            Group {
                if expanded, case .device(let toast) = content {
                    DeviceCard(toast: toast, topInset: screen.notchSize.height)
                        .padding(.horizontal, isIsland ? 24 : topRadius + 22)
                        .transition(.asymmetric(
                            insertion: .opacity.combined(with: .offset(y: -14))
                                .animation(.spring(response: 0.42, dampingFraction: 0.85).delay(0.08)),
                            removal: .opacity.animation(.easeOut(duration: 0.12))))
                } else if expanded {
                    VStack(spacing: 0) {
                        Header(screen: screen, player: player, claude: claude, accent: accent,
                               height: screen.notchSize.height,
                               notchWidth: screen.hasPhysicalNotch ? screen.notchSize.width : 0)
                        Group {
                            switch content {
                            case .music:
                                ExpandedPlayer(player: player, accent: accent)
                            case .request(let request):
                                RequestCard(request: request, claude: claude, total: claude.requests.count)
                                    .id(request.id)
                            case .sessions:
                                ClaudeTab(claude: claude)
                            case .device, .empty:
                                EmptyPlayer(player: player)
                            }
                        }
                        .transition(.opacity.combined(with: .offset(y: -6)))
                    }
                    .padding(.horizontal, isIsland ? 24 : topRadius + 20)
                    .padding(.top, isIsland ? 4 : 0)
                    // Content slides down from under the top edge while the shape unfolds.
                    .transition(.asymmetric(
                        insertion: .opacity.combined(with: .offset(y: -14))
                            .animation(.spring(response: 0.42, dampingFraction: 0.85).delay(0.08)),
                        removal: .opacity.animation(.easeOut(duration: 0.12))))
                } else if !wings.isEmpty {
                    CollapsedWings(wings: wings, player: player, claude: claude, toast: devices.toast, accent: accent,
                                   notchWidth: screen.notchSize.width, height: screen.notchSize.height)
                        .padding(.horizontal, topRadius)
                        .transition(.opacity)
                }
            }
            // Lay content out at its final size right away (no animation)…
            .animation(nil) { $0.frame(width: shapeSize.width, height: shapeSize.height, alignment: .top) }
            // …then reveal it through the growing shape, top first.
            .animation(widthAnimation) { $0.frame(width: shapeSize.width) }
            .animation(heightAnimation) { $0.frame(height: shapeSize.height, alignment: .top) }
            .clipShape(shape)
        }
        .contentShape(shape)
        // Island gestures: click to open (with a little press-in), like tapping the Dynamic Island.
        .simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in if isIsland && !expanded && !pressed { pressed = true } }
                .onEnded { _ in pressed = false }
        )
        .onTapGesture { if isIsland && !expanded { screen.onTap?() } }
    }
}

// MARK: - Closed state

struct CollapsedWings: View {
    var wings: WingContent
    @ObservedObject var player: NowPlayingManager
    @ObservedObject var claude: ClaudeBridge
    var toast: DeviceToast?
    var accent: Color
    var notchWidth: CGFloat
    var height: CGFloat
    @AppStorage(Pref.showEqualizer) private var showEqualizer = true

    var body: some View {
        let side = wings.sideWidth(height: height)
        let icon = height < 30 ? height - 7 : height - 12 // the island is slimmer than the notch
        HStack(spacing: 0) {
            item(wings.left, icon: icon).frame(width: side)
            Spacer().frame(width: notchWidth)
            item(wings.right, icon: icon).frame(width: side)
        }
        .frame(height: height)
    }

    @ViewBuilder private func item(_ item: WingItem?, icon: CGFloat) -> some View {
        switch item {
        case .artwork:
            ArtworkView(image: player.artwork, size: icon, radius: 6)
        case .spark:
            ClaudeBuddy(mood: claude.mood, size: icon - 2, compact: true)
        case .sparkAlert:
            ClaudeBuddy(mood: .needsYou, size: icon - 2, compact: true)
        case .equalizer:
            if showEqualizer {
                EqualizerBars(playing: player.isPlaying, color: accent, height: icon * 0.75)
            } else {
                Image(systemName: "waveform").font(.system(size: 12, weight: .semibold)).foregroundStyle(accent)
            }
        case .alert:
            Circle().fill(Theme.orange).frame(width: 8, height: 8).modifier(Pulse())
        case .check:
            if wings.left == .spark {
                Image(systemName: "checkmark.circle.fill").font(.system(size: icon * 0.7)).foregroundStyle(.green)
            } else {
                ClaudeBuddy(mood: .done, size: icon - 2, compact: true)
            }
        case .timer:
            ElapsedText(since: claude.workingSince)
                .font(.system(size: 12, weight: .semibold, design: .rounded).monospacedDigit())
                .foregroundStyle(Theme.orange)
        case .toastIcon:
            if let toast { ToastLeading(toast: toast, height: height).id(toast.id) }
        case .toastStatus:
            if let toast { ToastTrailing(toast: toast, height: height).id(toast.id) }
        case nil:
            EmptyView()
        }
    }
}

// MARK: - Device pop-up (AirPods, accessories, charger)

struct ToastLeading: View {
    let toast: DeviceToast
    var height: CGFloat
    @State private var shown = false

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: toast.symbol)
                .font(.system(size: height * 0.5, weight: .medium))
                .foregroundStyle(toast.tint)
                .symbolEffect(.bounce, value: shown)
                .scaleEffect(shown ? 1 : 0.2)
                .opacity(shown ? 1 : 0)
            Text(toast.title)
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(toast.connected ? Theme.text : Theme.secondary)
                .lineLimit(1)
                .opacity(shown ? 1 : 0)
                .offset(x: shown ? 0 : -6)
        }
        .padding(.leading, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear { withAnimation(.spring(response: 0.5, dampingFraction: 0.55)) { shown = true } }
    }
}

struct ToastTrailing: View {
    let toast: DeviceToast
    var height: CGFloat
    @State private var shown = false

    var body: some View {
        HStack(spacing: 7) {
            if let level = toast.battery {
                Text("\(level)%")
                    .font(.system(size: 12.5, weight: .semibold, design: .rounded).monospacedDigit())
                    .foregroundStyle(ringColor(level))
                ZStack {
                    Circle().stroke(.white.opacity(0.15), lineWidth: 3)
                    Circle()
                        .trim(from: 0, to: shown ? CGFloat(level) / 100 : 0)
                        .stroke(ringColor(level), style: StrokeStyle(lineWidth: 3, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                }
                .frame(width: height * 0.5, height: height * 0.5)
            } else {
                Text(toast.status)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(toast.connected ? .green : Theme.tertiary)
                    .lineLimit(1)
            }
        }
        .padding(.trailing, 10)
        .frame(maxWidth: .infinity, alignment: .trailing)
        .opacity(shown ? 1 : 0)
        .onAppear { withAnimation(.easeOut(duration: 0.8).delay(0.1)) { shown = true } }
    }

    private func ringColor(_ level: Int) -> Color {
        if toast.tint == .green { return .green }
        return level <= 20 ? .red : .green
    }
}

struct Pulse: ViewModifier {
    @State private var on = false
    func body(content: Content) -> some View {
        content.scaleEffect(on ? 1 : 0.7).opacity(on ? 1 : 0.5)
            .onAppear { withAnimation(.easeInOut(duration: 0.8).repeatForever()) { on = true } }
    }
}

struct ElapsedText: View {
    var since: Date?
    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { ctx in
            Text(since.map { ProgressRow.format(ctx.date.timeIntervalSince($0)) } ?? "")
        }
    }
}

// MARK: - Open state: header beside the camera (tabs on the left, the other tab's status on the right)

struct Header: View {
    @ObservedObject var screen: NotchScreen
    @ObservedObject var player: NowPlayingManager
    @ObservedObject var claude: ClaudeBridge
    var accent: Color
    var height: CGFloat
    var notchWidth: CGFloat

    var body: some View {
        let tabs = NotchLayout.availableTabs(player: player, claude: claude)
        let active = NotchLayout.activeTab(screen, player: player, claude: claude)
        HStack(spacing: 6) {
            if tabs.count > 1 {
                TabSwitcher(selection: active, claude: claude) { tab in
                    withAnimation(Theme.spring) { screen.tab = tab }
                }
            } else if active == .claude {
                ClaudeBuddy(mood: claude.mood, size: 16)
                Text("Claude Code").font(.system(size: 11.5, weight: .semibold)).foregroundStyle(Theme.secondary)
            } else if let source = player.source {
                AppIcon(bundleID: source.bundleID, size: 15)
                Text(source.displayName).font(.system(size: 11.5, weight: .medium)).foregroundStyle(Theme.tertiary)
            }
            Spacer(minLength: notchWidth)
            trailing(active: active, showsTabs: tabs.count > 1)
        }
        .frame(height: height)
    }

    @ViewBuilder private func trailing(active: NotchTab?, showsTabs: Bool) -> some View {
        if active == .music, showsTabs, let source = player.source {
            HStack(spacing: 5) {
                AppIcon(bundleID: source.bundleID, size: 14)
                Text(source.displayName).font(.system(size: 11.5, weight: .medium)).foregroundStyle(Theme.tertiary)
            }
        } else if active == .claude, player.track != nil {
            // Peek at the music from the Claude tab; tap to switch back.
            Button { withAnimation(Theme.spring) { screen.tab = .music } } label: {
                HStack(spacing: 6) {
                    ArtworkView(image: player.artwork, size: 16, radius: 4)
                    EqualizerBars(playing: player.isPlaying, color: accent, height: 10)
                }
            }
            .buttonStyle(PressStyle())
            .help(player.track.map { "\($0.title) — \($0.artist)" } ?? "")
        } else if active == .claude {
            let n = claude.runningSessions.count
            Text(n == 0 ? "All done" : n == 1 ? "1 working" : "\(n) working")
                .font(.system(size: 11.5, weight: .medium)).foregroundStyle(n == 0 ? Theme.tertiary : Theme.orange)
        }
    }
}

/// Two-segment switch: Music | Claude. Icon-only so it fits beside the camera.
struct TabSwitcher: View {
    var selection: NotchTab?
    @ObservedObject var claude: ClaudeBridge
    var onSelect: (NotchTab) -> Void
    @Namespace private var ns

    var body: some View {
        HStack(spacing: 2) {
            segment(.music, help: "Music") {
                Image(systemName: "music.note").font(.system(size: 11, weight: .bold))
            }
            segment(.claude, help: "Claude Code") {
                ClaudeBuddy(mood: claude.mood, size: 13, compact: true)
                let n = claude.runningSessions.count
                if n > 1 {
                    Text("\(n)").font(.system(size: 10.5, weight: .bold, design: .rounded))
                }
                if !claude.requests.isEmpty {
                    Circle().fill(Theme.orange).frame(width: 5, height: 5)
                }
            }
        }
        .padding(2)
        .background(Capsule().fill(Theme.fill))
    }

    private func segment<Label: View>(_ tab: NotchTab, help: String, @ViewBuilder label: () -> Label) -> some View {
        Button { onSelect(tab) } label: {
            HStack(spacing: 3) { label() }
                .foregroundStyle(selection == tab ? Theme.text : Theme.tertiary)
                .frame(minWidth: 22, minHeight: 18)
                .padding(.horizontal, 7).padding(.vertical, 2)
                .background {
                    if selection == tab {
                        Capsule().fill(Theme.fillHover).matchedGeometryEffect(id: "tab", in: ns)
                    }
                }
                .contentShape(Capsule())
        }
        .buttonStyle(PressStyle())
        .help(help)
    }
}

struct AppIcon: View {
    var bundleID: String
    var size: CGFloat
    var body: some View {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                .resizable().frame(width: size, height: size)
        }
    }
}

// MARK: - Open state: music

struct ExpandedPlayer: View {
    @ObservedObject var player: NowPlayingManager
    var accent: Color
    @AppStorage(Pref.showAlbum) private var showAlbum = true
    @AppStorage(Pref.showEqualizer) private var showEqualizer = true
    @AppStorage(Pref.artworkSize) private var artworkSize = 76.0

    var body: some View {
        if let track = player.track {
            VStack(spacing: 0) {
                Spacer(minLength: 4)
                HStack(spacing: 14) {
                    ArtworkView(image: player.artwork, size: artworkSize, radius: 14)
                        .shadow(color: accent.opacity(0.35), radius: 12, y: 4)
                        .scaleEffect(player.isPlaying ? 1 : 0.94)
                        .animation(Theme.spring, value: player.isPlaying)
                        .onTapGesture { player.openPlayer() }
                        .help("Open \(player.source?.displayName ?? "player")")
                    VStack(alignment: .leading, spacing: 3) {
                        Text(track.title)
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(Theme.text)
                        Text(track.artist)
                            .font(.system(size: 13.5))
                            .foregroundStyle(Theme.secondary)
                        if showAlbum, !track.album.isEmpty {
                            Text(track.album)
                                .font(.system(size: 12))
                                .foregroundStyle(Theme.tertiary)
                        }
                    }
                    .lineLimit(1)
                    Spacer(minLength: 0)
                    if showEqualizer {
                        EqualizerBars(playing: player.isPlaying, color: accent, height: 18)
                            .padding(.trailing, 2)
                    }
                }
                Spacer(minLength: 10)
                if track.duration > 0 {
                    ProgressRow(player: player, accent: accent)
                }
                Controls(player: player)
                    .padding(.top, 2)
                    .padding(.bottom, 12)
            }
        }
    }
}

struct Controls: View {
    @ObservedObject var player: NowPlayingManager

    var body: some View {
        HStack(spacing: 28) {
            ControlButton(symbol: "backward.fill", size: 16) { player.previous() }
            PlayButton(playing: player.isPlaying) { player.playPause() }
            ControlButton(symbol: "forward.fill", size: 16) { player.next() }
        }
    }
}

struct PlayButton: View {
    var playing: Bool
    var action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: playing ? "pause.fill" : "play.fill")
                .font(.system(size: 17, weight: .bold))
                .foregroundStyle(.black)
                .contentTransition(.symbolEffect(.replace))
                .frame(width: 40, height: 40)
                .background(Circle().fill(.white))
                .contentShape(Circle())
        }
        .buttonStyle(PressStyle())
        .scaleEffect(hovering ? 1.06 : 1)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.15), value: hovering)
    }
}

struct ControlButton: View {
    var symbol: String
    var size: CGFloat
    var action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size, weight: .semibold))
                .foregroundStyle(.white.opacity(hovering ? 1 : 0.85))
                .frame(width: 36, height: 36)
                .background(Circle().fill(hovering ? Theme.fillHover : .clear))
                .contentShape(Circle())
        }
        .buttonStyle(PressStyle())
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.15), value: hovering)
    }
}

/// Subtle shrink on press, used by every button in the notch.
struct PressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.9 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

struct ProgressRow: View {
    @ObservedObject var player: NowPlayingManager
    var accent: Color
    @State private var dragFraction: Double?
    @State private var hovering = false

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.5)) { ctx in
            let duration = player.track?.duration ?? 0
            let pos = dragFraction.map { $0 * duration } ?? player.position(at: ctx.date)
            let fraction = duration > 0 ? min(max(pos / duration, 0), 1) : 0
            let active = hovering || dragFraction != nil
            VStack(spacing: 5) {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(.white.opacity(0.16))
                        Capsule().fill(active ? accent : .white.opacity(0.85))
                            .frame(width: max(0, geo.size.width * fraction))
                    }
                    .frame(height: active ? 6 : 4)
                    .overlay(alignment: .leading) {
                        Circle().fill(.white)
                            .frame(width: 11, height: 11)
                            .shadow(color: .black.opacity(0.4), radius: 2)
                            .offset(x: geo.size.width * fraction - 5.5)
                            .opacity(active ? 1 : 0)
                    }
                    .frame(maxHeight: .infinity)
                    .contentShape(Rectangle())
                    .onHover { hovering = $0 }
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { v in dragFraction = min(max(v.location.x / geo.size.width, 0), 1) }
                            .onEnded { _ in
                                if let f = dragFraction { player.seek(to: f * duration) }
                                dragFraction = nil
                            }
                    )
                    .animation(.easeOut(duration: 0.15), value: active)
                }
                .frame(height: 12)
                HStack {
                    Text(Self.format(pos))
                    Spacer()
                    Text("-" + Self.format(max(duration - pos, 0)))
                }
                .font(.system(size: 10.5, weight: .medium, design: .rounded).monospacedDigit())
                .foregroundStyle(Theme.tertiary)
            }
        }
    }

    static func format(_ s: Double) -> String {
        guard s.isFinite, s >= 0 else { return "0:00" }
        let t = Int(s)
        return t >= 3600 ? String(format: "%d:%02d:%02d", t / 3600, t / 60 % 60, t % 60)
                         : String(format: "%d:%02d", t / 60, t % 60)
    }
}

struct EmptyPlayer: View {
    @ObservedObject var player: NowPlayingManager

    var body: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "music.note")
                .font(.system(size: 22, weight: .medium))
                .foregroundStyle(Theme.tertiary)
            Text("Nothing playing")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Theme.secondary)
            HStack(spacing: 8) {
                ForEach(PlayerApp.allCases.filter(\.isInstalled)) { app in
                    Button { player.openPlayer(app) } label: {
                        HStack(spacing: 6) {
                            AppIcon(bundleID: app.bundleID, size: 16)
                            Text(app.displayName).font(.system(size: 12, weight: .medium))
                        }
                        .foregroundStyle(Theme.text)
                        .padding(.horizontal, 12).padding(.vertical, 6)
                        .background(Capsule().fill(Theme.fill))
                    }
                    .buttonStyle(PressStyle())
                }
            }
            Spacer()
        }
    }
}

struct ArtworkView: View {
    var image: NSImage?
    var size: CGFloat
    var radius: CGFloat

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
            } else {
                ZStack {
                    LinearGradient(colors: [.white.opacity(0.16), .white.opacity(0.05)], startPoint: .top, endPoint: .bottom)
                    Image(systemName: "music.note").font(.system(size: size * 0.4)).foregroundStyle(.white.opacity(0.5))
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).stroke(Theme.stroke, lineWidth: 0.5))
    }
}

/// Music bars animated by Core Animation (runs in the system's render server, so it costs the app
/// almost no CPU, unlike redrawing SwiftUI 30 times a second).
struct EqualizerBars: NSViewRepresentable {
    var playing: Bool
    var color: Color
    var height: CGFloat

    func makeNSView(context: Context) -> EqualizerNSView { EqualizerNSView() }

    func updateNSView(_ view: EqualizerNSView, context: Context) {
        view.configure(playing: playing, color: NSColor(color), height: height)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: EqualizerNSView, context: Context) -> CGSize? {
        CGSize(width: EqualizerNSView.width, height: height)
    }
}

final class EqualizerNSView: NSView {
    static let barWidth: CGFloat = 3, gap: CGFloat = 2.5, count = 4
    static var width: CGFloat { CGFloat(count) * barWidth + CGFloat(count - 1) * gap }
    private var bars: [CALayer] = []
    private var state: (Bool, NSColor, CGFloat)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        for _ in 0..<Self.count {
            let bar = CALayer()
            bar.cornerRadius = Self.barWidth / 2
            layer?.addSublayer(bar)
            bars.append(bar)
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: NSSize { NSSize(width: Self.width, height: state?.2 ?? 12) }

    func configure(playing: Bool, color: NSColor, height: CGFloat) {
        if let s = state, s.0 == playing, s.1 == color, s.2 == height { return }
        state = (playing, color, height)
        CATransaction.begin(); CATransaction.setDisableActions(true)
        let durations: [CFTimeInterval] = [0.42, 0.31, 0.53, 0.37]
        for (i, bar) in bars.enumerated() {
            bar.backgroundColor = color.cgColor
            bar.bounds = CGRect(x: 0, y: 0, width: Self.barWidth, height: height)
            bar.position = CGPoint(x: CGFloat(i) * (Self.barWidth + Self.gap) + Self.barWidth / 2, y: height / 2)
            bar.removeAllAnimations()
            if playing {
                bar.transform = CATransform3DIdentity
                let a = CABasicAnimation(keyPath: "transform.scale.y")
                a.fromValue = 0.25; a.toValue = 1.0
                a.duration = durations[i]
                a.autoreverses = true
                a.repeatCount = .infinity
                a.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                a.timeOffset = Double(i) * 0.17
                bar.add(a, forKey: "eq")
            } else {
                bar.transform = CATransform3DMakeScale(1, 0.22, 1)
            }
        }
        CATransaction.commit()
    }
}

// MARK: - Claude

struct ClaudeTab: View {
    @ObservedObject var claude: ClaudeBridge

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(spacing: 6) {
                ForEach(claude.visibleSessions) { SessionRow(session: $0) }
            }
            .padding(.top, 6)
        }
        .padding(.bottom, 10)
    }
}

struct SessionRow: View {
    let session: ClaudeSession
    @State private var hovering = false

    var body: some View {
        Button { ClaudeBridge.activate(host: session.host) } label: {
            HStack(spacing: 11) {
                ClaudeBuddy(mood: session.running ? .working : .done, size: 22)
                    .frame(width: 36, height: 36)
                    .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.orange.opacity(0.12)))
                VStack(alignment: .leading, spacing: 2) {
                    Text(session.project).font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.text)
                    Text(session.prompt ?? (session.running ? "Working…" : "Finished"))
                        .font(.system(size: 11.5)).foregroundStyle(Theme.tertiary)
                }
                .lineLimit(1)
                Spacer(minLength: 8)
                if session.running {
                    ElapsedText(since: session.startedAt)
                        .font(.system(size: 12, weight: .semibold, design: .rounded).monospacedDigit())
                        .foregroundStyle(Theme.orange)
                } else {
                    Label("Done", systemImage: "checkmark.circle.fill")
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(.green.opacity(0.9))
                }
                Image(systemName: "arrow.up.forward")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(Theme.tertiary)
                    .opacity(hovering ? 1 : 0)
            }
            .padding(.horizontal, 8).padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(hovering ? Theme.fillHover : Theme.fill))
            .contentShape(Rectangle())
        }
        .buttonStyle(PressStyle())
        .onHover { hovering = $0 }
        .help("Open in \(session.host == nil ? "Claude" : "its app")")
    }
}

struct RequestCard: View {
    let request: ClaudeRequest
    @ObservedObject var claude: ClaudeBridge
    var total: Int
    @State private var step = 0
    @State private var answers: [String: String] = [:]
    @State private var multi: Set<String> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                ClaudeBuddy(mood: .needsYou, size: 26)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.text)
                    Text(total > 1 ? "\(request.project)  ·  1 of \(total)" : request.project)
                        .font(.system(size: 11.5)).foregroundStyle(Theme.tertiary)
                }
                .lineLimit(1)
                Spacer()
                if case .permission(let tool, _) = request.kind { ToolChip(tool: tool) }
            }
            content
            Spacer(minLength: 0)
            footer
        }
        .padding(.top, 4)
        .padding(.bottom, 14)
    }

    private var question: ClaudeQuestion? {
        if case .question(let qs, _) = request.kind { return qs[min(step, qs.count - 1)] }
        return nil
    }

    private var title: String {
        switch request.kind {
        case .permission(let tool, _):
            switch tool {
            case "Bash": return "Run this command?"
            case "Edit", "Write", "MultiEdit", "NotebookEdit": return "Edit this file?"
            case "Read": return "Read this file?"
            case "WebFetch", "WebSearch": return "Go online?"
            default: return "Use \(tool)?"
            }
        case .question:
            return question.map { $0.header.isEmpty ? "Claude has a question" : $0.header } ?? ""
        case .attention(let t, _):
            return t
        }
    }

    @ViewBuilder private var content: some View {
        switch request.kind {
        case .permission(let tool, let detail):
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                if tool == "Bash" {
                    Text("$").foregroundStyle(Theme.orange)
                }
                Text(detail)
                    .foregroundStyle(.white.opacity(0.9))
                    .lineLimit(4)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .font(.system(size: 12, design: .monospaced))
            .padding(.horizontal, 12).padding(.vertical, 10)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.fill))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(Theme.stroke))
        case .question(let qs, _):
            let q = qs[min(step, qs.count - 1)]
            VStack(alignment: .leading, spacing: 8) {
                Text(q.question).font(.system(size: 13)).foregroundStyle(Theme.secondary).lineLimit(2)
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 6), GridItem(.flexible(), spacing: 6)], spacing: 6) {
                    ForEach(q.options, id: \.label) { opt in
                        OptionButton(label: opt.label, detail: opt.description, selected: multi.contains(opt.label)) {
                            choose(opt.label, in: q, total: qs.count)
                        }
                    }
                }
            }
        case .attention(_, let message):
            HStack(spacing: 10) {
                Image(systemName: "bell.badge.fill").foregroundStyle(Theme.orange)
                Text(message.isEmpty ? "Open Claude to continue." : message)
                    .font(.system(size: 13)).foregroundStyle(Theme.secondary).lineLimit(3)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.fill))
        }
    }

    @ViewBuilder private var footer: some View {
        HStack(spacing: 10) {
            Button { claude.open(request.id) } label: {
                Label("Open in Claude", systemImage: "arrow.up.forward.app")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Theme.secondary)
            }
            .buttonStyle(PressStyle())
            if let deadline = request.deadline {
                Countdown(start: request.created, end: deadline)
            }
            Spacer()
            switch request.kind {
            case .permission:
                ActionPill(label: "Deny", primary: false) { claude.answerPermission(request.id, .deny) }
                ActionPill(label: "Allow", primary: true) { claude.answerPermission(request.id, .allow) }
            case .question(let qs, _):
                if let q = question, q.multiSelect {
                    ActionPill(label: step == qs.count - 1 ? "Send" : "Next", primary: true) {
                        commitMulti(q, total: qs.count)
                    }
                    .disabled(multi.isEmpty)
                    .opacity(multi.isEmpty ? 0.5 : 1)
                }
            case .attention:
                ActionPill(label: "Dismiss", primary: false) { claude.dismiss(request.id) }
                ActionPill(label: "Open", primary: true) { claude.open(request.id) }
            }
        }
    }

    private func choose(_ label: String, in q: ClaudeQuestion, total: Int) {
        if q.multiSelect {
            if multi.contains(label) { multi.remove(label) } else { multi.insert(label) }
            return
        }
        answers[q.question] = label
        advance(total: total)
    }

    private func commitMulti(_ q: ClaudeQuestion, total: Int) {
        answers[q.question] = q.options.map(\.label).filter(multi.contains).joined(separator: ", ")
        multi = []
        advance(total: total)
    }

    private func advance(total: Int) {
        if step + 1 < total { withAnimation(Theme.spring) { step += 1 } }
        else { claude.answerQuestion(request.id, answers: answers) }
    }
}

struct ToolChip: View {
    var tool: String
    var body: some View {
        Label(tool, systemImage: symbol)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(Theme.orange)
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(Capsule().fill(Theme.orange.opacity(0.14)))
    }
    private var symbol: String {
        switch tool {
        case "Bash": "terminal.fill"
        case "Edit", "Write", "MultiEdit", "NotebookEdit": "pencil"
        case "Read": "doc.text"
        case "WebFetch", "WebSearch": "globe"
        default: tool.hasPrefix("mcp__") ? "puzzlepiece.extension.fill" : "wrench.and.screwdriver.fill"
        }
    }
}

struct ActionPill: View {
    var label: String
    var primary: Bool
    var action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(primary ? .white : Theme.text)
                .padding(.horizontal, 18).padding(.vertical, 7)
                .background(Capsule().fill(primary ? Theme.orange.opacity(hovering ? 1 : 0.9)
                                                   : (hovering ? Theme.fillHover : Theme.fill)))
                .overlay(Capsule().stroke(primary ? .clear : Theme.stroke))
                .contentShape(Capsule())
        }
        .buttonStyle(PressStyle())
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.15), value: hovering)
    }
}

struct OptionButton: View {
    var label: String
    var detail: String
    var selected: Bool
    var action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 1) {
                Text(label).font(.system(size: 12.5, weight: .semibold)).foregroundStyle(Theme.text)
                if !detail.isEmpty {
                    Text(detail).font(.system(size: 10.5)).foregroundStyle(selected ? .white.opacity(0.8) : Theme.tertiary)
                }
            }
            .lineLimit(1)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10).padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(selected ? Theme.orange.opacity(0.85) : (hovering ? Theme.fillHover : Theme.fill)))
            .contentShape(Rectangle())
        }
        .buttonStyle(PressStyle())
        .help(detail)
        .onHover { hovering = $0 }
    }
}

/// Thin bar that empties until Claude takes the decision back.
struct Countdown: View {
    var start: Date
    var end: Date
    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.25)) { ctx in
            let total = max(end.timeIntervalSince(start), 1)
            let left = max(end.timeIntervalSince(ctx.date), 0)
            HStack(spacing: 6) {
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.1))
                    Capsule().fill(Theme.orange.opacity(0.7)).frame(width: 36 * left / total)
                }
                .frame(width: 36, height: 3)
                Text("\(Int(left.rounded(.up)))s")
                    .font(.system(size: 10.5, weight: .medium, design: .rounded).monospacedDigit())
                    .foregroundStyle(Theme.tertiary)
            }
            .help("After this, Claude shows its own prompt instead")
        }
    }
}

// MARK: - The little Claude guy

enum BuddyMood: Equatable { case idle, working, needsYou, done }

extension ClaudeBridge {
    var mood: BuddyMood {
        if !requests.isEmpty { return .needsYou }
        if isWorking { return .working }
        if recentlyFinished { return .done }
        return .idle
    }
}

/// A small pixel-art orange buddy in the style of Claude Code's mascot, drawn in code.
/// Working: walks, hops and does backflips. Needs you: bounces and waves. Done: happy jumps.
struct ClaudeBuddy: View {
    var mood: BuddyMood
    var size: CGFloat
    /// Smaller jumps for tight spots like the closed notch.
    var compact = false

    private static let orange = Theme.orange
    private static let eye = Color(red: 0.12, green: 0.08, blue: 0.06)

    struct Pose {
        var dy: CGFloat = 0, rotation: Double = 0, sx: CGFloat = 1, sy: CGFloat = 1
        var step = 0          // 0 = all feet down, 1 / 2 = alternating feet lifted
        var leftArmUp = false, rightArmUp = false
        var blink = false
    }

    var body: some View {
        // Pixel art at 12 fps: looks right for a sprite and keeps CPU low (idle just blinks).
        TimelineView(.animation(minimumInterval: mood == .idle ? 1.0 / 4 : 1.0 / 12)) { ctx in
            let pose = Self.pose(mood, t: ctx.date.timeIntervalSinceReferenceDate, compact: compact)
            Canvas { gc, sz in Self.draw(pose, in: &gc, size: sz) }
                .scaleEffect(x: pose.sx, y: pose.sy, anchor: .bottom)
                .rotationEffect(.degrees(pose.rotation), anchor: UnitPoint(x: 0.5, y: 0.6))
                .offset(y: pose.dy * size)
        }
        .frame(width: size, height: size)
    }

    static func pose(_ mood: BuddyMood, t: Double, compact: Bool) -> Pose {
        var p = Pose()
        p.blink = t.truncatingRemainder(dividingBy: 3.7) < 0.14
        let jump: CGFloat = compact ? 0.2 : 0.42
        switch mood {
        case .idle:
            break
        case .working:
            let c = t.truncatingRemainder(dividingBy: 3.4)
            if c < 1.7 {                                     // walk in place
                p.step = Int(c / 0.14) % 2 + 1
                p.dy = -CGFloat(abs(sin(c * .pi / 0.28))) * 0.04
            } else if c < 2.5 {                              // backflip
                let q = (c - 1.7) / 0.8
                let e = q < 0.5 ? 2 * q * q : 1 - pow(-2 * q + 2, 2) / 2
                p.dy = -CGFloat(sin(.pi * q)) * jump
                p.rotation = -360 * e
                p.leftArmUp = true; p.rightArmUp = true
                p.step = 1
            } else if c < 2.7 {                              // land: squash
                let k = CGFloat(sin(.pi * (c - 2.5) / 0.2))
                p.sy = 1 - 0.2 * k; p.sx = 1 + 0.14 * k
            } else {                                         // two little hops
                let q = (c - 2.7) / 0.7
                p.dy = -CGFloat(abs(sin(q * 2 * .pi))) * jump * 0.3
            }
        case .needsYou:
            p.dy = -CGFloat(abs(sin(t * 7))) * 0.08
            let wave = Int(t / 0.22) % 2 == 0
            p.leftArmUp = wave; p.rightArmUp = !wave
        case .done:
            let c = t.truncatingRemainder(dividingBy: 1.6)
            if c < 0.5 {
                p.dy = -CGFloat(sin(.pi * c / 0.5)) * jump * 0.7
                p.leftArmUp = true; p.rightArmUp = true
            }
        }
        return p
    }

    /// 10 × 8 pixel sprite, drawn bottom-aligned so there's headroom for hops.
    static func draw(_ p: Pose, in gc: inout GraphicsContext, size: CGSize) {
        let px = size.width / 10
        let top = size.height - 8 * px
        func cell(_ x: Int, _ y: Int, _ color: Color) {
            gc.fill(Path(CGRect(x: CGFloat(x) * px, y: top + CGFloat(y) * px, width: px + 0.4, height: px + 0.4)),
                    with: .color(color))
        }
        // Body
        for y in 0...5 { for x in 1...8 { cell(x, y, orange) } }
        // Eyes (two pixels tall; half-closed when blinking)
        for x in [2, 7] {
            if !p.blink { cell(x, 1, eye) }
            cell(x, 2, eye)
        }
        // Arms: out to the sides, or raised
        for (x, up) in [(0, p.leftArmUp), (9, p.rightArmUp)] {
            if up { cell(x, 1, orange); cell(x, 2, orange) } else { cell(x, 3, orange); cell(x, 4, orange) }
        }
        // Legs: four little feet; alternate pairs lift while walking
        for (i, x) in [1, 3, 6, 8].enumerated() {
            cell(x, 6, orange)
            let lifted = (p.step == 1 && i % 2 == 0) || (p.step == 2 && i % 2 == 1)
            if !lifted { cell(x, 7, orange) }
        }
    }
}


// MARK: - Device cards (open notch)

struct DeviceCard: View {
    let toast: DeviceToast
    var topInset: CGFloat

    var body: some View {
        VStack(spacing: 0) {
            Spacer().frame(height: topInset)
            switch toast.kind {
            case .airpods(let left, let right, let caseLevel, let pro):
                AirPodsCard(toast: toast, left: left, right: right, caseLevel: caseLevel, pro: pro)
            case .charging(let plugged, let charging, let watts):
                ChargingCard(toast: toast, plugged: plugged, charging: charging, watts: watts)
            case .simple:
                EmptyView()
            }
            Spacer(minLength: 0)
        }
    }
}

struct AirPodsCard: View {
    let toast: DeviceToast
    var left: Int?, right: Int?, caseLevel: Int?
    var pro: Bool
    @State private var shown = false

    var body: some View {
        VStack(spacing: 14) {
            HStack(spacing: 12) {
                Image(systemName: toast.symbol)
                    .font(.system(size: 30, weight: .regular))
                    .foregroundStyle(.white)
                    .symbolEffect(.bounce, value: shown)
                    .scaleEffect(shown ? 1 : 0.3)
                VStack(alignment: .leading, spacing: 2) {
                    Text(toast.title).font(.system(size: 16, weight: .semibold)).foregroundStyle(Theme.text)
                    Text("Connected").font(.system(size: 12, weight: .medium)).foregroundStyle(.green)
                }
                Spacer()
            }
            .padding(.top, 8)
            HStack(spacing: 0) {
                BatteryGauge(symbol: pro ? "airpodpro.left" : "airpod.left", label: "Left", level: left)
                BatteryGauge(symbol: pro ? "airpodpro.right" : "airpod.right", label: "Right", level: right)
                BatteryGauge(symbol: pro ? "airpodspro.chargingcase.wireless.fill" : "airpods.chargingcase.fill",
                             label: "Case", level: caseLevel)
            }
        }
        .onAppear { withAnimation(.spring(response: 0.5, dampingFraction: 0.55)) { shown = true } }
    }
}

/// A ring that fills to the battery level, with the part's icon inside.
struct BatteryGauge: View {
    var symbol: String
    var label: String
    var level: Int?
    @State private var fill: CGFloat = 0

    var body: some View {
        VStack(spacing: 6) {
            ZStack {
                Circle().stroke(.white.opacity(0.12), lineWidth: 4)
                Circle()
                    .trim(from: 0, to: fill)
                    .stroke(color, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                Image(systemName: symbol)
                    .font(.system(size: 17))
                    .foregroundStyle(.white.opacity(level == nil ? 0.4 : 0.9))
            }
            .frame(width: 48, height: 48)
            Text(level.map { "\($0)%" } ?? "—")
                .font(.system(size: 13, weight: .semibold, design: .rounded).monospacedDigit())
                .foregroundStyle(level == nil ? Theme.tertiary : Theme.text)
                .contentTransition(.numericText())
            Text(label).font(.system(size: 10.5, weight: .medium)).foregroundStyle(Theme.tertiary)
        }
        .frame(maxWidth: .infinity)
        .onAppear { animate() }
        .onChange(of: level) { _, _ in animate() }
    }

    private var color: Color { (level ?? 100) <= 20 ? .red : .green }

    private func animate() {
        withAnimation(.easeOut(duration: 0.9).delay(0.15)) { fill = CGFloat(level ?? 0) / 100 }
    }
}

struct ChargingCard: View {
    let toast: DeviceToast
    var plugged: Bool, charging: Bool
    var watts: Int?

    var body: some View {
        HStack(spacing: 16) {
            MagSafeGraphic(plugged: plugged, charging: charging, percent: toast.battery ?? 0)
                .frame(width: 176, height: 54)
            VStack(alignment: .leading, spacing: 3) {
                Text(toast.title).font(.system(size: 16, weight: .semibold)).foregroundStyle(Theme.text)
                Text(subtitle).font(.system(size: 11.5, weight: .medium)).foregroundStyle(Theme.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            Text("\(toast.battery ?? 0)%")
                .font(.system(size: 26, weight: .bold, design: .rounded).monospacedDigit())
                .foregroundStyle(plugged ? .green : ((toast.battery ?? 100) <= 20 ? .red : Theme.text))
        }
        .padding(.top, 10)
    }

    private var subtitle: String {
        guard plugged else { return "Power disconnected" }
        let w = watts.map { " · \($0)W" } ?? ""
        return charging ? "MagSafe\(w)" : "MagSafe\(w) · Battery held"
    }
}

/// A MagSafe plug snapping magnetically onto the battery: the LED lights amber while charging
/// (green when the battery isn't charging), then the battery fills. Unplugging reverses it.
struct MagSafeGraphic: View {
    var plugged: Bool
    var charging: Bool
    var percent: Int
    @State private var attached = false
    @State private var fill: CGFloat = 0
    @State private var ledOn = false

    private var led: Color { charging ? Color(red: 1.0, green: 0.62, blue: 0.1) : .green }

    var body: some View {
        HStack(spacing: 0) {
            // Cable + plug
            HStack(spacing: 0) {
                Capsule()
                    .fill(LinearGradient(colors: [.white.opacity(0.25), .white.opacity(0.55)], startPoint: .leading, endPoint: .trailing))
                    .frame(width: 58, height: 6)
                ZStack {
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(LinearGradient(colors: [Color(white: 0.92), Color(white: 0.62)], startPoint: .top, endPoint: .bottom))
                    Circle()
                        .fill(ledOn ? led : Color(white: 0.4))
                        .frame(width: 5, height: 5)
                        .shadow(color: ledOn ? led : .clear, radius: 4)
                        .modifier(LEDPulse(active: ledOn && charging))
                }
                .frame(width: 30, height: 18)
            }
            .offset(x: attached ? 0 : -44)
            .opacity(attached ? 1 : 0)
            Spacer().frame(width: 6)
            // Battery
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(.white.opacity(0.4), lineWidth: 2)
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(LinearGradient(colors: [fillColor.opacity(0.75), fillColor], startPoint: .leading, endPoint: .trailing))
                    .frame(width: max(0, 66 * fill), height: 26)
                    .overlay { if attached && charging { Shimmer().clipShape(RoundedRectangle(cornerRadius: 5)) } }
                    .padding(.leading, 4)
                Image(systemName: "bolt.fill")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.4), radius: 2)
                    .frame(maxWidth: .infinity)
                    .scaleEffect(attached ? 1 : 0.2)
                    .opacity(attached ? 1 : 0)
            }
            .frame(width: 74, height: 34)
            RoundedRectangle(cornerRadius: 1.5).fill(.white.opacity(0.4)).frame(width: 4, height: 12).padding(.leading, 2)
        }
        .onAppear(perform: run)
    }

    private var fillColor: Color { percent <= 20 && !plugged ? .red : .green }

    private func run() {
        if plugged {
            fill = 0
            withAnimation(.spring(response: 0.45, dampingFraction: 0.55)) { attached = true }       // magnetic snap
            withAnimation(.easeIn(duration: 0.2).delay(0.35)) { ledOn = true }
            withAnimation(.easeOut(duration: 1.0).delay(0.45)) { fill = CGFloat(percent) / 100 }
        } else {
            attached = true; ledOn = true; fill = CGFloat(percent) / 100
            withAnimation(.easeIn(duration: 0.15).delay(0.3)) { ledOn = false }
            withAnimation(.spring(response: 0.5, dampingFraction: 0.8).delay(0.35)) { attached = false }
        }
    }
}

struct LEDPulse: ViewModifier {
    var active: Bool
    @State private var on = false
    func body(content: Content) -> some View {
        content.opacity(active && on ? 0.55 : 1)
            .onAppear { withAnimation(.easeInOut(duration: 0.9).repeatForever()) { on = true } }
    }
}

/// A soft light sweeping across the battery fill while charging.
struct Shimmer: View {
    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30)) { ctx in
            GeometryReader { geo in
                let t = ctx.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.6) / 1.6
                LinearGradient(colors: [.clear, .white.opacity(0.45), .clear], startPoint: .leading, endPoint: .trailing)
                    .frame(width: geo.size.width * 0.5)
                    .offset(x: (geo.size.width * 1.5) * t - geo.size.width * 0.5)
            }
        }
    }
}
