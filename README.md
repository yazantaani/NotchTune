# NotchTune

A small, private notch app for macOS. Hover the notch (or click the Dynamic Island on an external display) and it opens.

- **Music** — Apple Music, Spotify and Google Chrome (YouTube, YouTube Music, Spotify Web, SoundCloud, …): artwork, seekable progress, play/pause/skip. Reacts instantly to play/pause.
- **Claude Code** — an animated pixel Claude buddy while prompts run, every running session listed, permission requests with Allow / Deny, Claude's questions answerable from the notch, and "Claude is waiting" alerts.
- **Devices** — AirPods card with left / right / case battery, MagSafe charging animation, Bluetooth and USB accessory pop-ups.
- **Any display** — the notch on a MacBook, a Dynamic Island on external screens (click or swipe down to open, click outside or swipe up to close).
- **Customizable** — sizes, colors, delays, what's shown, and more in Settings (menu bar ♪ icon).

Requires macOS 14 or later. About 1–2% CPU while active.

## Install

**Build it yourself (recommended — you run exactly the code you can read):**

1. Install Apple's command line tools once: `xcode-select --install`
2. Then:
   ```bash
   git clone https://github.com/yazantaani/NotchTune.git
   cd NotchTune
   ./build.sh
   cp -R NotchTune.app /Applications/
   open /Applications/NotchTune.app
   ```

**Or download the ready-made app** from the Releases page, unzip it, move it to Applications, then right-click it → **Open** → **Open** the first time (it isn't signed with an Apple Developer ID, so macOS asks once).

## One-time setup

- **Music / Spotify / Chrome**: macOS asks "NotchTune wants to control …" → OK.
- **Chrome**: Chrome menu → View → Developer → *Allow JavaScript from Apple Events*.
- **Bluetooth**: allow it when asked (for AirPods pop-ups).
- **Claude Code**: Settings → Claude Code → **Connect**. Adds hooks to `~/.claude/settings.json` (a backup is saved as `settings.json.notchtune-backup`). Disconnect removes only NotchTune's entries.
- **Launch at login**: Settings → App (works from /Applications).

## Privacy

No dependencies, no analytics, nothing sent anywhere. It uses only public macOS interfaces: AppleScript for Music/Spotify/Chrome, Core Audio to notice when sound starts, IOKit for chargers/USB, IOBluetooth for accessories. Network use is limited to downloading cover art. In Chrome it only reads the page's audio/video element and standard media info.

The Claude Code link is a local, owner-only socket (`~/Library/Application Support/NotchTune/claude.sock`). If NotchTune isn't running, or you don't answer in time, Claude Code behaves exactly as usual.

## Code map

| File | What it does |
|---|---|
| `NotchView.swift` | Everything you see: notch/island shapes, player, tabs, Claude buddy, cards |
| `NotchController.swift` | Windows per display, hover/click/swipe handling, layout |
| `NowPlaying.swift` | Music, Spotify and Chrome reading/controls; instant updates |
| `ClaudeBridge.swift` | Claude Code hooks, sessions, permission/question answers |
| `DeviceMonitor.swift` | AirPods, Bluetooth, USB and charger pop-ups |
| `Settings.swift` | All options |
