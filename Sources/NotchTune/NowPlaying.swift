import AppKit
import SwiftUI
import CoreAudio
import os

private let playerLog = Logger(subsystem: "local.notchtune", category: "player")

/// Players we know how to talk to. Both expose a public AppleScript dictionary,
/// so no private Apple frameworks are used.
enum PlayerApp: String, CaseIterable, Identifiable {
    case music, spotify, chrome

    var id: String { rawValue }
    var bundleID: String {
        switch self {
        case .music: "com.apple.Music"
        case .spotify: "com.spotify.client"
        case .chrome: "com.google.Chrome"
        }
    }
    var displayName: String {
        switch self {
        case .music: "Music"
        case .spotify: "Spotify"
        case .chrome: "Chrome"
        }
    }
    var symbol: String {
        switch self {
        case .music: "music.note"
        case .spotify: "dot.radiowaves.left.and.right"
        case .chrome: "globe"
        }
    }
    /// Fired by the player itself whenever the track or play state changes (Chrome has none).
    var changeNotification: Notification.Name? {
        switch self {
        case .music: .init("com.apple.Music.playerInfo")
        case .spotify: .init("com.spotify.client.PlaybackStateChanged")
        case .chrome: nil
        }
    }
    var isRunning: Bool {
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).contains { !$0.isTerminated }
    }
    var isInstalled: Bool { NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) != nil }
}

struct Track: Equatable {
    var title: String
    var artist: String
    var album: String
    var duration: Double
    var key: String { "\(title)|\(artist)|\(album)" }
}

struct ChromeTab: Equatable { let window: String; let tab: String }

struct PlayerSnapshot {
    let app: PlayerApp
    let playing: Bool
    let track: Track?
    let position: Double
    var artworkURL: URL? = nil
    var chromeTab: ChromeTab? = nil
    /// When the position was read. Reading many Chrome tabs can take a moment, so the
    /// progress bar is anchored to this instant rather than to when the result arrived.
    var capturedAt = Date()
}

/// JavaScript run inside Chrome tabs. Uses no double quotes or backslashes so it can be
/// embedded in AppleScript as-is. It only reads the page's <video>/<audio> element and
/// the standard Media Session metadata; nothing is sent anywhere.
enum ChromeJS {
    /// Picks the audible media element on the page (ignores muted autoplay previews; allows live streams).
    /// TI() reads the time shown in YouTube Music's player bar: its hidden player keeps counting
    /// across songs (gapless playback), so the element's own time isn't the song's time there.
    static let pick = "var E=function(){var a=Array.prototype.slice.call(document.querySelectorAll('video,audio')).filter(function(e){return (e.duration>0||!e.paused)&&!e.muted&&e.volume>0;});return a.filter(function(e){return !e.paused;})[0]||a[0];};var S=function(){return navigator.mediaSession?navigator.mediaSession.playbackState:'none';};var TI=function(){var t=document.querySelector('ytmusic-player-bar .time-info');if(!t)return null;var m=t.textContent.split('/');if(m.length<2)return null;var f=function(x){return x.trim().split(':').reduce(function(a,b){return a*60+(parseInt(b,10)||0);},0);};return [f(m[0]),f(m[1])];};"

    /// Uses the page's media element when it can see it, otherwise the site's Media Session
    /// (many music sites play through a hidden player that isn't part of the page).
    static let read = "(function(){" + pick + "var el=E();var md=navigator.mediaSession&&navigator.mediaSession.metadata;var st=S();if(el&&el.paused&&st==='playing'){el=null;}if(!el&&!(md&&st!=='none'))return '';var art='';if(md&&md.artwork&&md.artwork.length){art=md.artwork[md.artwork.length-1].src;}var tt=TI();var d=tt?tt[1]:(el&&isFinite(el.duration)?el.duration:0);var c=tt?tt[0]:(el?el.currentTime:0);return JSON.stringify({p:el?!el.paused:st==='playing',t:(md&&md.title)||document.title,a:(md&&md.artist)||location.hostname,l:(md&&md.album)||'',d:d,c:c,i:art});})()"

    static let playPause = "(function(){" + pick + "var e=E();if(e&&!(e.paused&&S()==='playing')){if(e.paused){e.play();}else{e.pause();}return;}var b=document.querySelector('[data-testid=control-button-playpause], #play-pause-button, .playControl, button[aria-label*=Pause i], button[aria-label*=Play i]');if(b){b.click();}})()"

    /// Seeks relative to the shown song time on YouTube Music, absolute elsewhere.
    static func seek(_ s: Int) -> String { "(function(){" + pick + "var e=E();if(!e)return;var tt=TI();if(tt){e.currentTime=e.currentTime+(\(s)-tt[0]);}else{e.currentTime=\(s);}})()" }

    // Site buttons for YouTube, YouTube Music, Spotify Web, SoundCloud, then generic.
    static let next = "(function(){var b=document.querySelector('.ytp-next-button, ytmusic-player-bar .next-button, [data-testid=control-button-skip-forward], .skipControl__next, button[aria-label*=Next i]');if(b){b.click();}})()"

    static let previous = "(function(){" + pick + "var b=document.querySelector('ytmusic-player-bar .previous-button, [data-testid=control-button-skip-back], .skipControl__previous, button[aria-label*=Previous i]');if(b){b.click();}else{var e=E();if(e){e.currentTime=0;}}})()"
}

/// Tells us the instant any app starts or stops playing sound (Core Audio process objects),
/// so the notch reacts immediately instead of waiting for the next poll.
@MainActor
final class AudioActivityWatcher {
    private var watched: Set<AudioObjectID> = []
    private let onChange: () -> Void
    private static let system = AudioObjectID(kAudioObjectSystemObject)

    init(onChange: @escaping () -> Void) {
        self.onChange = onChange
        var addr = Self.address(kAudioHardwarePropertyProcessObjectList)
        AudioObjectAddPropertyListenerBlock(Self.system, &addr, .main) { [weak self] _, _ in
            MainActor.assumeIsolated { self?.syncProcesses() }
        }
        syncProcesses()
    }

    /// Whether an app whose bundle ID starts with `prefix` is outputting sound right now.
    func isPlaying(bundlePrefix prefix: String) -> Bool {
        processes().contains { id in
            Self.uint32(id, kAudioProcessPropertyIsRunningOutput) != 0
                && (Self.bundleID(id)?.hasPrefix(prefix) ?? false)
        }
    }

    private func syncProcesses() {
        let ids = Set(processes())
        for id in ids.subtracting(watched) {
            var addr = Self.address(kAudioProcessPropertyIsRunningOutput)
            AudioObjectAddPropertyListenerBlock(id, &addr, .main) { [weak self] _, _ in
                MainActor.assumeIsolated { self?.onChange() }
            }
        }
        watched = ids
    }

    private func processes() -> [AudioObjectID] {
        var addr = Self.address(kAudioHardwarePropertyProcessObjectList)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(Self.system, &addr, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(Self.system, &addr, 0, nil, &size, &ids) == noErr else { return [] }
        return ids
    }

    private static func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                   mElement: kAudioObjectPropertyElementMain)
    }

    private static func uint32(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> UInt32 {
        var addr = address(selector)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &value) == noErr ? value : 0
    }

    private static func bundleID(_ id: AudioObjectID) -> String? {
        var addr = address(kAudioProcessPropertyBundleID)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &value) == noErr else { return nil }
        return value?.takeRetainedValue() as String?
    }
}

/// Runs AppleScript on one serial queue (NSAppleScript is not thread-safe).
/// Never talks to a player that isn't already running, so it can't launch one by accident.
final class ScriptRunner: @unchecked Sendable {
    let queue = DispatchQueue(label: "notchtune.applescript", qos: .userInitiated)
    private var cache: [String: NSAppleScript] = [:]
    // Chrome bookkeeping (only touched on `queue`).
    private var lastChromeTab: ChromeTab?
    private var lastError: String?
    private(set) var chromeJavaScriptOff = false

    func run(_ source: String) -> NSAppleEventDescriptor? {
        dispatchPrecondition(condition: .onQueue(queue))
        let script: NSAppleScript
        if let cached = cache[source] {
            script = cached
        } else {
            guard let s = NSAppleScript(source: source) else { return nil }
            cache[source] = s
            script = s
        }
        var error: NSDictionary?
        let result = script.executeAndReturnError(&error)
        lastError = error?[NSAppleScript.errorMessage] as? String
        return error == nil ? result : nil
    }

    func snapshot(of app: PlayerApp, chromeAudible: Bool = true) -> PlayerSnapshot? {
        guard app.isRunning else { return nil }
        if app == .chrome { return chromeSnapshot(audible: chromeAudible) }
        // Spotify reports duration in ms, Music in seconds.
        let duration = app == .spotify ? "((duration of t) / 1000)" : "(duration of t)"
        let source = """
        tell application id "\(app.bundleID)"
            try
                set st to (player state as text)
                if st is "stopped" then return {st}
                set t to current track
                return {st, (name of t), (artist of t), (album of t), \(duration), player position}
            on error
                return {"stopped"}
            end try
        end tell
        """
        guard let d = run(source), d.numberOfItems >= 1 else { return nil }
        let state = d.atIndex(1)?.stringValue ?? "stopped"
        guard state != "stopped", d.numberOfItems >= 6 else {
            return PlayerSnapshot(app: app, playing: false, track: nil, position: 0)
        }
        let track = Track(
            title: d.atIndex(2)?.stringValue ?? "",
            artist: d.atIndex(3)?.stringValue ?? "",
            album: d.atIndex(4)?.stringValue ?? "",
            duration: d.atIndex(5)?.doubleValue ?? 0
        )
        return PlayerSnapshot(app: app, playing: state == "playing", track: track,
                              position: d.atIndex(6)?.doubleValue ?? 0)
    }

    // MARK: Chrome

    /// Sites checked first when looking for the tab that's playing.
    private static let mediaHosts = ["music.youtube.com", "youtube.com", "open.spotify.com", "soundcloud.com",
                                     "deezer.com", "tidal.com", "anghami.com", "music.apple.com", "twitch.tv",
                                     "bandcamp.com", "mixcloud.com", "pandora.com", "netflix.com", "vimeo.com"]

    /// `audible` = Chrome is outputting sound right now (from Core Audio).
    /// Silent Chrome → only re-check the tab we know about (cheap). Audible → find the playing tab,
    /// checking music sites first and stopping at the first hit.
    private func chromeSnapshot(audible: Bool) -> PlayerSnapshot? {
        if let tab = lastChromeTab {
            if let snap = readTab(tab) {
                if snap.playing || !audible { return snap }
            } else {
                lastChromeTab = nil // tab closed or media gone
            }
        }
        guard audible else { return nil }
        for tab in chromeTabs() {
            if let snap = readTab(tab), snap.playing {
                lastChromeTab = tab
                return snap
            }
        }
        return lastChromeTab.flatMap(readTab)
    }

    /// Just the tab we already know about — one tiny call, used for the fast check.
    func readKnownChromeTab() -> (snap: PlayerSnapshot?, hadTab: Bool) {
        guard PlayerApp.chrome.isRunning, let tab = lastChromeTab else { return (nil, false) }
        let snap = readTab(tab)
        if snap == nil { lastChromeTab = nil }
        return (snap, true)
    }

    private func readTab(_ tab: ChromeTab) -> PlayerSnapshot? {
        let d = run("tell application id \"com.google.Chrome\" to execute (tab id \(tab.tab) of window id \(tab.window)) javascript \"\(ChromeJS.read)\"")
        if d == nil, lastError?.contains("JavaScript") == true { chromeJavaScriptOff = true }
        if d != nil { chromeJavaScriptOff = false }
        return Self.parseChrome(d?.stringValue, tab: tab)
    }

    /// All web tabs in one cheap call, music sites first.
    private func chromeTabs() -> [ChromeTab] {
        guard let list = run("""
        tell application id "com.google.Chrome"
            set out to {}
            repeat with w in windows
                set wid to (id of w) as text
                repeat with t in tabs of w
                    set end of out to {wid, (id of t) as text, (URL of t)}
                end repeat
            end repeat
            return out
        end tell
        """), list.numberOfItems > 0 else { return [] }
        var media: [ChromeTab] = [], other: [ChromeTab] = []
        for i in 1...list.numberOfItems {
            guard let item = list.atIndex(i), item.numberOfItems == 3,
                  let w = item.atIndex(1)?.stringValue, let t = item.atIndex(2)?.stringValue,
                  let url = item.atIndex(3)?.stringValue, url.hasPrefix("http") else { continue }
            let host = URL(string: url)?.host ?? ""
            let tab = ChromeTab(window: w, tab: t)
            if Self.mediaHosts.contains(where: { host == $0 || host.hasSuffix("." + $0) }) { media.append(tab) } else { other.append(tab) }
        }
        return media + other
    }

    private static func parseChrome(_ json: String?, tab: ChromeTab) -> PlayerSnapshot? {
        guard let json, let data = json.data(using: .utf8),
              let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let track = Track(title: o["t"] as? String ?? "", artist: o["a"] as? String ?? "",
                          album: o["l"] as? String ?? "", duration: o["d"] as? Double ?? 0)
        let art = (o["i"] as? String).flatMap { $0.isEmpty ? nil : URL(string: $0) }
        return PlayerSnapshot(app: .chrome, playing: o["p"] as? Bool ?? false, track: track,
                              position: o["c"] as? Double ?? 0, artworkURL: art, chromeTab: tab)
    }

    func chromeRun(_ js: String) {
        guard PlayerApp.chrome.isRunning, let tab = lastChromeTab else { return }
        _ = run("tell application id \"com.google.Chrome\" to execute (tab id \(tab.tab) of window id \(tab.window)) javascript \"\(js)\"")
    }

    func artwork(of app: PlayerApp) -> (data: Data?, url: URL?) {
        guard app.isRunning else { return (nil, nil) }
        switch app {
        case .music:
            let d = run("""
            tell application id "com.apple.Music"
                try
                    return raw data of artwork 1 of current track
                end try
            end tell
            """)
            return (d?.data, nil)
        case .spotify:
            let d = run("""
            tell application id "com.spotify.client"
                try
                    return artwork url of current track
                end try
            end tell
            """)
            return (nil, d?.stringValue.flatMap(URL.init(string:)))
        case .chrome:
            return (nil, nil) // comes with the snapshot
        }
    }

    func send(_ command: String, to app: PlayerApp) {
        guard app.isRunning else { return }
        _ = run("tell application id \"\(app.bundleID)\" to \(command)")
    }
}

@MainActor
final class NowPlayingManager: ObservableObject {
    @Published private(set) var track: Track?
    @Published private(set) var isPlaying = false
    @Published private(set) var source: PlayerApp?
    @Published private(set) var artwork: NSImage?
    @Published private(set) var artworkColor: Color?
    /// Chrome's "Allow JavaScript from Apple Events" is off, so web players can't be read.
    @Published private(set) var chromeJavaScriptOff = false

    // Position is interpolated locally between polls so the progress bar is smooth.
    private var anchorPosition: Double = 0
    private var anchorDate = Date()

    private let runner = ScriptRunner()
    private var timer: Timer?
    private var artworkKey: String?
    private var refreshRunning = false
    private var refreshQueued = false
    private var audio: AudioActivityWatcher?

    /// Poll faster while the notch is open (for an accurate progress bar).
    var fastPolling = false {
        didSet { if fastPolling != oldValue { timer?.invalidate(); timer = nil; schedule(); refresh() } }
    }

    init() {
        for app in PlayerApp.allCases {
            guard let name = app.changeNotification else { continue }
            DistributedNotificationCenter.default().addObserver(
                forName: name, object: nil, queue: .main
            ) { [weak self] note in
                // Spotify posts "Stopped" while quitting; querying it then could relaunch it.
                let state = note.userInfo?["Player State"] as? String
                MainActor.assumeIsolated {
                    if state == "Stopped" { self?.clear(app) } else { self?.refresh(after: 0.1) }
                }
            }
        }
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            let bundleID = (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.bundleIdentifier
            MainActor.assumeIsolated {
                if let app = PlayerApp.allCases.first(where: { $0.bundleID == bundleID }) { self?.clear(app) }
            }
        }
        // Any app starting/stopping sound → look right away (this is what makes it instant).
        audio = AudioActivityWatcher { [weak self] in self?.refresh(after: 0.05) }
        refresh()
        schedule()
    }

    func position(at date: Date = Date()) -> Double {
        guard let track else { return 0 }
        let p = isPlaying ? anchorPosition + date.timeIntervalSince(anchorDate) : anchorPosition
        return min(max(p, 0), max(track.duration, 0))
    }

    // MARK: Controls

    func playPause() {
        guard let source else { return }
        anchorPosition = position(); anchorDate = Date()
        isPlaying.toggle()
        source == .chrome ? chrome(ChromeJS.playPause) : command("playpause", source)
    }

    func next() {
        guard let source else { return }
        source == .chrome ? chrome(ChromeJS.next) : command("next track", source)
    }

    func previous() {
        guard let source else { return }
        source == .chrome ? chrome(ChromeJS.previous) : command("previous track", source)
    }

    func seek(to seconds: Double) {
        guard let source else { return }
        anchorPosition = seconds; anchorDate = Date()
        objectWillChange.send()
        let s = Int(seconds.rounded())
        source == .chrome ? chrome(ChromeJS.seek(s)) : command("set player position to \(s)", source)
    }

    private func chrome(_ js: String) {
        runner.queue.async { [runner] in runner.chromeRun(js) }
        refresh(after: 0.4)
    }

    func openPlayer(_ app: PlayerApp? = nil) {
        guard let app = app ?? source,
              let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: app.bundleID) else { return }
        NSWorkspace.shared.openApplication(at: url, configuration: .init())
    }

    private func command(_ cmd: String, _ app: PlayerApp) {
        runner.queue.async { [runner] in runner.send(cmd, to: app) }
        refresh(after: 0.25)
    }

    // MARK: Polling

    private var timerInterval: TimeInterval = 0

    // Fast check: Chrome can't announce play/pause, so for a few minutes after Chrome music was
    // active, re-read just that one tab 5× a second. Changes then show within ~0.2 s.
    private var quickTimer: Timer?
    private var quickRunning = false
    private var chromeHotUntil = Date.distantPast

    private func updateQuickTimer() {
        let hot = source == .chrome && Date() < chromeHotUntil
        if hot, quickTimer == nil {
            let t = Timer(timeInterval: 0.2, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.quickCheck() }
            }
            t.tolerance = 0.05
            RunLoop.main.add(t, forMode: .common)
            quickTimer = t
        } else if !hot, let t = quickTimer {
            t.invalidate(); quickTimer = nil
        }
    }

    private func quickCheck() {
        guard !quickRunning, !refreshRunning else { return }
        quickRunning = true
        runner.queue.async { [runner, weak self] in
            let result = runner.readKnownChromeTab()
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.quickRunning = false
                    if let snap = result.snap {
                        self.apply(snap)
                    } else if result.hadTab {
                        self.refresh() // tab closed or media gone → full look
                    }
                    self.updateQuickTimer()
                }
            }
        }
    }

    /// Changes arrive as events; the timer is just a light safety net. It runs every second while the
    /// notch is open (progress bar) or a Chrome song plays (Chrome keeps its audio open for a few
    /// seconds after a pause, so this catches pauses right away). Otherwise every 6 s.
    private func schedule() {
        let interval: TimeInterval = fastPolling ? 1.0 : 6.0
        guard interval != timerInterval || timer == nil else { return }
        timerInterval = interval
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    /// Reads the players. If a read is already running, one more is queued right after it
    /// (never dropped), so the latest change always shows up.
    func refresh(after delay: TimeInterval = 0) {
        if refreshRunning { refreshQueued = true; return }
        refreshRunning = true
        let preferred = UserDefaults.standard.string(forKey: Pref.preferredPlayer) ?? "auto"
        let useChrome = UserDefaults.standard.bool(forKey: Pref.chromeEnabled)
        let chromeAudible = audio?.isPlaying(bundlePrefix: PlayerApp.chrome.bundleID) ?? true
        let lastSource = source
        runner.queue.asyncAfter(deadline: .now() + delay) { [runner, weak self] in
            let candidates = PlayerApp.allCases.filter {
                ($0 != .chrome || useChrome) && (preferred == "auto" || $0.rawValue == preferred)
            }
            let snaps = candidates.compactMap { runner.snapshot(of: $0, chromeAudible: chromeAudible) }
            let jsOff = useChrome && runner.chromeJavaScriptOff
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.refreshRunning = false
                    if self.refreshQueued { self.refreshQueued = false; self.refresh() }
                    if self.chromeJavaScriptOff != jsOff { self.chromeJavaScriptOff = jsOff }
                    self.apply(Self.pick(snaps, preferred: preferred, last: lastSource))
                }
            }
        }
    }

    /// A playing player wins; otherwise keep showing the most relevant paused one.
    private static func pick(_ snaps: [PlayerSnapshot], preferred: String, last: PlayerApp?) -> PlayerSnapshot? {
        let withTrack = snaps.filter { $0.track != nil }
        let playing = withTrack.filter(\.playing)
        if playing.count == 1 { return playing[0] }
        let pool = playing.isEmpty ? withTrack : playing
        return pool.first { $0.app == last } ?? pool.first
    }

    private func apply(_ snap: PlayerSnapshot?) {
        guard let snap, let newTrack = snap.track else {
            if track != nil || source != nil { reset() }
            return
        }
        let trackChanged = newTrack != track || snap.app != source
        let playChanged = isPlaying != snap.playing
        if trackChanged { track = newTrack; source = snap.app }
        if playChanged { isPlaying = snap.playing }
        // Re-anchor only when something really moved, so the bar doesn't jitter and the notch
        // doesn't redraw on every fast check.
        let drift = abs(position(at: snap.capturedAt) - snap.position)
        if trackChanged || playChanged || (snap.playing ? drift > 1.6 : abs(anchorPosition - snap.position) > 0.25) {
            anchorPosition = snap.position
            anchorDate = snap.capturedAt
            objectWillChange.send()
            playerLog.debug("snap \(snap.app.rawValue, privacy: .public) playing=\(snap.playing) pos=\(snap.position, format: .fixed(precision: 1)) dur=\(newTrack.duration, format: .fixed(precision: 1)) title=\(newTrack.title, privacy: .public)")
        }
        if snap.app == .chrome {
            if snap.playing { chromeHotUntil = Date().addingTimeInterval(180) }
            updateQuickTimer()
        }
        schedule()
        let key = "\(snap.app.rawValue)|\(newTrack.key)"
        if key != artworkKey { artworkKey = key; loadArtwork(for: snap.app, key: key, url: snap.artworkURL) }
    }

    private func clear(_ app: PlayerApp) {
        if source == app { reset() }
        refresh(after: 0.5)
    }

    private func reset() {
        defer { schedule(); updateQuickTimer() }
        track = nil; source = nil; isPlaying = false
        artwork = nil; artworkColor = nil; artworkKey = nil
    }

    private func loadArtwork(for app: PlayerApp, key: String, url: URL?) {
        runner.queue.async { [runner, weak self] in
            var result = runner.artwork(of: app)
            if let url { result.url = url }
            if let data = result.data {
                let image = NSImage(data: data)
                DispatchQueue.main.async { MainActor.assumeIsolated { self?.setArtwork(image, key: key) } }
            } else if let url = result.url {
                URLSession.shared.dataTask(with: url) { data, _, _ in
                    let image = data.flatMap(NSImage.init(data:))
                    DispatchQueue.main.async { MainActor.assumeIsolated { self?.setArtwork(image, key: key) } }
                }.resume()
            } else {
                DispatchQueue.main.async { MainActor.assumeIsolated { self?.setArtwork(nil, key: key) } }
            }
        }
    }

    private func setArtwork(_ image: NSImage?, key: String) {
        guard key == artworkKey else { return } // a newer track arrived meanwhile
        artwork = image
        artworkColor = image.flatMap(Self.vibrantColor(of:))
    }

    /// Average color of the cover, brightened so it reads well on black.
    private static func vibrantColor(of image: NSImage) -> Color? {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        var pixel = [UInt8](repeating: 0, count: 4)
        guard let ctx = CGContext(data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.interpolationQuality = .medium
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        let ns = NSColor(red: CGFloat(pixel[0]) / 255, green: CGFloat(pixel[1]) / 255,
                         blue: CGFloat(pixel[2]) / 255, alpha: 1)
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        ns.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
        return Color(hue: h, saturation: min(s * 1.3, 0.85), brightness: max(b, 0.85))
    }
}
