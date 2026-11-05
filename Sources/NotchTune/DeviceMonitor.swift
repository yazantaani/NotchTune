import AppKit
import SwiftUI
import IOBluetooth
import IOKit
import IOKit.ps
import CoreAudio
import os

private let log = Logger(subsystem: "local.notchtune", category: "devices")

/// A short pop-up shown in the notch, like the iPhone's AirPods / charging animation.
struct DeviceToast: Identifiable, Equatable {
    enum Kind: Equatable {
        case simple
        /// AirPods: opens the notch with left, right and case battery.
        case airpods(left: Int?, right: Int?, caseLevel: Int?, pro: Bool)
        /// Charger: opens the notch with the MagSafe animation.
        case charging(plugged: Bool, charging: Bool, watts: Int?)
    }

    let id = UUID()
    var symbol: String
    var title: String
    var status: String
    var battery: Int?          // 0–100 when known
    var tint: Color = .white
    var connected = true
    var kind: Kind = .simple

    /// Rich pop-ups open the notch; simple ones stay in the closed notch's sides.
    var isRich: Bool { kind != .simple }
}

struct BatteryLevels { var left: Int?, right: Int?, caseLevel: Int?, main: Int? }

/// Watches for Bluetooth accessories, USB devices and the charger, using only public macOS APIs.
/// Nothing leaves the Mac.
@MainActor
final class DeviceMonitor: NSObject, ObservableObject {
    @Published private(set) var toast: DeviceToast?

    private var hideWork: DispatchWorkItem?
    private var started = Date()
    private var btConnect: IOBluetoothUserNotification?
    private var usbPort: IONotificationPortRef?
    private var usbIterator: io_iterator_t = 0
    private var powerSource: CFRunLoopSource?
    private var lastOnAC: Bool?
    private var lastOutputID: AudioObjectID = 0
    private var recent: [String: Date] = [:]   // de-duplicates the same device announced twice

    override init() {
        super.init()
        startBluetooth()
        startAudioRoute()
        startUSB()
        startPower()
        DistributedNotificationCenter.default().addObserver(
            forName: Self.previewNotification, object: nil, queue: .main
        ) { [weak self] note in
            let which = note.userInfo?["kind"] as? String ?? "airpods"
            MainActor.assumeIsolated { self?.preview(which) }
        }
    }

    static let previewNotification = Notification.Name("local.notchtune.preview-device")

    /// Sample pop-ups so you can see the animations without plugging anything in.
    func preview(_ which: String) {
        switch which {
        case "charger":
            let state = Self.powerState()
            show(chargingToast(plugged: true, percent: state?.percent ?? 80, charging: true), duration: 4.5)
        case "accessory":
            show(DeviceToast(symbol: "keyboard", title: "Magic Keyboard", status: "Connected", battery: 100))
        default:
            show(DeviceToast(symbol: "airpodspro", title: "AirPods Pro", status: "Connected", battery: 82,
                             kind: .airpods(left: 82, right: 85, caseLevel: 64, pro: true)), duration: 6)
        }
    }

    func show(_ t: DeviceToast, duration: TimeInterval = 3.5) {
        toast = t
        hideWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { if self?.toast?.id == t.id { self?.toast = nil } }
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: work)
    }

    /// True if this device was already announced in the last few seconds (two detectors can fire).
    private func isDuplicate(_ name: String) -> Bool {
        let key = name.lowercased()
        defer { recent[key] = Date() }
        return recent[key].map { Date().timeIntervalSince($0) < 6 } ?? false
    }

    private var quietPeriod: Bool { Date().timeIntervalSince(started) < 3 } // ignore what's already plugged in at launch

    // MARK: Bluetooth

    /// Devices already connected when NotchTune started. macOS reports them as "connected" right
    /// after we start listening (sometimes several seconds later), which isn't a real connection.
    private var connectedAtLaunch: Set<String> = []

    private func startBluetooth() {
        guard UserDefaults.standard.bool(forKey: Pref.showAccessories) else { return }
        let paired = (IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice]) ?? []
        connectedAtLaunch = Set(paired.filter { $0.isConnected() }.compactMap(\.addressString))
        btConnect = IOBluetoothDevice.register(forConnectNotifications: self, selector: #selector(btConnected(_:device:)))
    }

    @objc private func btConnected(_ note: IOBluetoothUserNotification, device: IOBluetoothDevice) {
        device.register(forDisconnectNotification: self, selector: #selector(btDisconnected(_:device:)))
        log.info("Bluetooth connected: \(device.name ?? "?", privacy: .public)")
        if let address = device.addressString, connectedAtLaunch.remove(address) != nil { return }
        guard !quietPeriod, UserDefaults.standard.bool(forKey: Pref.showAccessories),
              !isDuplicate(Self.shortName(device.name)) else { return }
        announceHeadphones(name: device.name ?? "Accessory", device: device)
    }

    /// AirPods get the big card with every battery; other headphones get the small pop-up.
    private func headphonesToast(name: String, device: IOBluetoothDevice?) -> DeviceToast {
        let lower = name.lowercased()
        let symbol = Self.symbol(name: name, device: device)
        if lower.contains("airpods"), !lower.contains("max") {
            return DeviceToast(symbol: symbol, title: Self.shortName(name), status: "Connected",
                               kind: .airpods(left: nil, right: nil, caseLevel: nil, pro: lower.contains("pro")))
        }
        return DeviceToast(symbol: symbol, title: Self.shortName(name), status: "Connected",
                           battery: device.flatMap(Self.battery(of:)))
    }

    private func announceHeadphones(name: String, device: IOBluetoothDevice?) {
        let t = headphonesToast(name: name, device: device)
        show(t, duration: t.isRich ? 6 : 3.5)
        fillBattery(for: t, name: name)
        // Case and buds report a moment after connecting; ask again shortly.
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            MainActor.assumeIsolated { self?.fillBattery(for: t, name: name) }
        }
    }

    // MARK: Audio output (AirPods taking over the sound)

    /// AirPods often stay paired in the background and only switch the audio over when you put
    /// them in, without a new Bluetooth connection. Watching the default output catches that.
    private func startAudioRoute() {
        lastOutputID = Self.defaultOutput()
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &addr, .main) { [weak self] _, _ in
            MainActor.assumeIsolated { self?.outputChanged() }
        }
    }

    private func outputChanged() {
        let id = Self.defaultOutput()
        guard id != 0, id != lastOutputID else { return }
        lastOutputID = id
        let name = Self.stringProperty(id, kAudioObjectPropertyName) ?? "Headphones"
        let transport = Self.uint32Property(id, kAudioDevicePropertyTransportType)
        log.info("Audio output → \(name, privacy: .public) transport=\(transport)")
        guard transport == kAudioDeviceTransportTypeBluetooth || transport == kAudioDeviceTransportTypeBluetoothLE,
              !quietPeriod, UserDefaults.standard.bool(forKey: Pref.showAccessories),
              !isDuplicate(Self.shortName(name)) else { return }
        announceHeadphones(name: name, device: nil)
    }

    private static func defaultOutput() -> AudioObjectID {
        uint32Property(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultOutputDevice)
    }

    private static func uint32Property(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> UInt32 {
        var addr = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &value) == noErr ? value : 0
    }

    private static func stringProperty(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var addr = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &value) == noErr else { return nil }
        return value?.takeRetainedValue() as String?
    }

    // MARK: Battery from the system Bluetooth report

    /// Reads battery levels from `system_profiler` (the same data as System Information),
    /// then updates the pop-up if it's still showing.
    private func fillBattery(for toast: DeviceToast, name: String) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let levels = Self.profilerBattery(named: name) else { return }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, var t = self.toast, t.id == toast.id else { return }
                    if case .airpods(let l, let r, let c, let pro) = t.kind {
                        t.kind = .airpods(left: levels.left ?? l, right: levels.right ?? r,
                                          caseLevel: levels.caseLevel ?? c, pro: pro)
                    }
                    t.battery = [levels.left, levels.right].compactMap { $0 }.min() ?? levels.main ?? t.battery
                    self.toast = t
                }
            }
        }
    }

    nonisolated private static func profilerBattery(named name: String) -> BatteryLevels? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/system_profiler")
        p.arguments = ["SPBluetoothDataType", "-json"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let controllers = root["SPBluetoothDataType"] as? [[String: Any]] else { return nil }
        let wanted = shortName(name).lowercased()
        for c in controllers {
            for group in (c["device_connected"] as? [[String: Any]] ?? []) {
                for (devName, info) in group {
                    guard shortName(devName).lowercased() == wanted, let info = info as? [String: Any] else { continue }
                    func level(_ key: String) -> Int? {
                        (info[key] as? String).flatMap { Int($0.replacingOccurrences(of: "%", with: "")) }
                    }
                    return BatteryLevels(left: level("device_batteryLevelLeft"), right: level("device_batteryLevelRight"),
                                         caseLevel: level("device_batteryLevelCase"), main: level("device_batteryLevelMain"))
                }
            }
        }
        return nil
    }

    @objc private func btDisconnected(_ note: IOBluetoothUserNotification, device: IOBluetoothDevice) {
        note.unregister()
        guard UserDefaults.standard.bool(forKey: Pref.showAccessories) else { return }
        show(DeviceToast(symbol: Self.symbol(name: device.name ?? "", device: device), title: Self.shortName(device.name),
                         status: "Disconnected", tint: .white.opacity(0.6), connected: false), duration: 2.5)
    }

    nonisolated private static func shortName(_ raw: String?) -> String {
        let name = raw ?? "Accessory"
        // "Alex's AirPods Pro" → "AirPods Pro"
        if let r = name.range(of: "’s ") ?? name.range(of: "'s ") { return String(name[r.upperBound...]) }
        return name
    }

    private static func symbol(name: String, device d: IOBluetoothDevice?) -> String {
        let n = name.lowercased()
        if n.contains("airpods max") { return "airpodsmax" }
        if n.contains("airpods pro") { return "airpodspro" }
        if n.contains("airpods") { return "airpods" }
        if n.contains("beats") { return "beats.headphones" }
        if n.contains("keyboard") { return "keyboard" }
        if n.contains("trackpad") { return "rectangle.and.hand.point.up.left.filled" }
        if n.contains("mouse") { return "magicmouse" }
        if n.contains("controller") || n.contains("dualsense") || n.contains("xbox") { return "gamecontroller" }
        if n.contains("watch") { return "applewatch" }
        if n.contains("iphone") { return "iphone" }
        guard let d else { return "headphones" }
        switch d.deviceClassMajor {
        case 0x04: return d.deviceClassMinor == 0x05 || d.deviceClassMinor == 0x0A ? "hifispeaker" : "headphones"
        case 0x05:
            if d.deviceClassMinor & 0x10 != 0 { return "keyboard" }
            if d.deviceClassMinor & 0x20 != 0 { return "computermouse" }
            return "gamecontroller"
        case 0x02: return "iphone"
        default: return "dot.radiowaves.left.and.right"
        }
    }

    /// AirPods and other Apple accessories expose battery levels on IOBluetoothDevice
    /// (read-only, undocumented keys; missing on other devices → nil).
    private static func battery(of d: IOBluetoothDevice) -> Int? {
        func read(_ key: String) -> Int? {
            guard d.responds(to: NSSelectorFromString(key)),
                  let v = d.value(forKey: key) as? Int, v > 0, v <= 100 else { return nil }
            return v
        }
        if let single = read("batteryPercentSingle") { return single }
        let buds = [read("batteryPercentLeft"), read("batteryPercentRight")].compactMap { $0 }
        if let low = buds.min() { return low }
        return read("batteryPercentCombined")
    }

    // MARK: USB

    private func startUSB() {
        let port = IONotificationPortCreate(kIOMainPortDefault)
        IONotificationPortSetDispatchQueue(port, .main)
        usbPort = port
        let callback: IOServiceMatchingCallback = { refcon, iterator in
            guard let refcon else { return }
            let me = Unmanaged<DeviceMonitor>.fromOpaque(refcon).takeUnretainedValue()
            MainActor.assumeIsolated { me.drainUSB(iterator, announce: true) }
        }
        IOServiceAddMatchingNotification(port, kIOFirstMatchNotification, IOServiceMatching("IOUSBHostDevice"),
                                         callback, Unmanaged.passUnretained(self).toOpaque(), &usbIterator)
        drainUSB(usbIterator, announce: false) // arm the notification; these are already connected
    }

    private func drainUSB(_ iterator: io_iterator_t, announce: Bool) {
        var names: [String] = []
        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }
            guard let name = IORegistryEntryCreateCFProperty(service, "USB Product Name" as CFString,
                                                             kCFAllocatorDefault, 0)?.takeRetainedValue() as? String,
                  !name.isEmpty, !name.localizedCaseInsensitiveContains("hub") else { continue }
            names.append(name)
        }
        guard announce, !quietPeriod, let name = names.first,
              UserDefaults.standard.bool(forKey: Pref.showAccessories) else { return }
        show(DeviceToast(symbol: Self.usbSymbol(name), title: name,
                         status: names.count > 1 ? "+\(names.count - 1) more connected" : "Connected"))
    }

    private static func usbSymbol(_ name: String) -> String {
        let n = name.lowercased()
        if n.contains("keyboard") { return "keyboard" }
        if n.contains("mouse") { return "computermouse" }
        if n.contains("iphone") { return "iphone" }
        if n.contains("ipad") { return "ipad" }
        if ["disk", "drive", "ssd", "flash", "storage", "card"].contains(where: n.contains) { return "externaldrive.fill" }
        if n.contains("camera") || n.contains("webcam") { return "web.camera" }
        if ["audio", "headset", "dac", "microphone", "mic"].contains(where: n.contains) { return "headphones" }
        if n.contains("display") || n.contains("monitor") { return "display" }
        return "cable.connector"
    }

    // MARK: Charger

    private func startPower() {
        lastOnAC = Self.powerState()?.onAC
        let ctx = Unmanaged.passUnretained(self).toOpaque()
        guard let src = IOPSNotificationCreateRunLoopSource({ ctx in
            guard let ctx else { return }
            let me = Unmanaged<DeviceMonitor>.fromOpaque(ctx).takeUnretainedValue()
            MainActor.assumeIsolated { me.powerChanged() }
        }, ctx)?.takeRetainedValue() else { return }
        CFRunLoopAddSource(CFRunLoopGetMain(), src, .defaultMode)
        powerSource = src
    }

    private func powerChanged() {
        guard let state = Self.powerState(), state.onAC != lastOnAC else { return }
        lastOnAC = state.onAC
        guard UserDefaults.standard.bool(forKey: Pref.showCharging), state.hasBattery else { return }
        show(chargingToast(plugged: state.onAC, percent: state.percent, charging: state.charging),
             duration: state.onAC ? 4.5 : 3)
    }

    private func chargingToast(plugged: Bool, percent: Int, charging: Bool) -> DeviceToast {
        let watts = plugged ? Self.adapterWatts() : nil
        return DeviceToast(symbol: plugged ? "bolt.fill" : Self.batterySymbol(percent),
                           title: plugged ? (charging ? "Charging" : "Connected") : "On battery",
                           status: plugged ? (charging ? "MagSafe" : "Not charging — battery held") : "Power disconnected",
                           battery: percent, tint: plugged ? .green : (percent <= 20 ? .red : .white),
                           connected: plugged, kind: .charging(plugged: plugged, charging: charging, watts: watts))
    }

    private static func adapterWatts() -> Int? {
        (IOPSCopyExternalPowerAdapterDetails()?.takeRetainedValue() as? [String: Any])?["Watts"] as? Int
    }

    private static func batterySymbol(_ p: Int) -> String {
        switch p {
        case ..<13: "battery.0percent"
        case ..<38: "battery.25percent"
        case ..<63: "battery.50percent"
        case ..<88: "battery.75percent"
        default: "battery.100percent"
        }
    }

    private static func powerState() -> (onAC: Bool, percent: Int, hasBattery: Bool, charging: Bool)? {
        let info = IOPSCopyPowerSourcesInfo().takeRetainedValue()
        let onAC = (IOPSGetProvidingPowerSourceType(info).takeUnretainedValue() as String) == kIOPMACPowerKey
        let list = IOPSCopyPowerSourcesList(info).takeRetainedValue() as Array
        for ps in list {
            guard let desc = IOPSGetPowerSourceDescription(info, ps)?.takeUnretainedValue() as? [String: Any],
                  desc[kIOPSTypeKey] as? String == kIOPSInternalBatteryType else { continue }
            let cur = desc[kIOPSCurrentCapacityKey] as? Int ?? 0
            let max = desc[kIOPSMaxCapacityKey] as? Int ?? 100
            return (onAC, max > 0 ? cur * 100 / max : cur, true, desc[kIOPSIsChargingKey] as? Bool ?? false)
        }
        return (onAC, 0, false, false)
    }
}
