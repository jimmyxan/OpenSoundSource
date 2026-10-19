import AppKit
import CoreAudio
import SwiftUI

// MARK: - CoreAudio helpers

func prop<T>(_ obj: AudioObjectID, _ sel: AudioObjectPropertySelector, _ qual: [UInt8] = [], as: T.Type) -> T? {
    var addr = AudioObjectPropertyAddress(mSelector: sel, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    var size = UInt32(MemoryLayout<T>.size)
    let p = UnsafeMutablePointer<T>.allocate(capacity: 1)
    defer { p.deallocate() }
    let st = qual.withUnsafeBytes {
        AudioObjectGetPropertyData(obj, &addr, UInt32($0.count), $0.baseAddress, &size, p)
    }
    return st == noErr ? p.pointee : nil
}

func processObject(pid: pid_t) -> AudioObjectID? {
    withUnsafeBytes(of: pid) { b in
        prop(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyTranslatePIDToProcessObject, Array(b), as: AudioObjectID.self)
    }.flatMap { $0 == kAudioObjectUnknown ? nil : $0 }
}

/// Every process CoreAudio knows about, as (audio object, pid).
func audioProcesses() -> [(obj: AudioObjectID, pid: pid_t, playing: Bool)] {
    let sys = AudioObjectID(kAudioObjectSystemObject)
    var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyProcessObjectList, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(sys, &addr, 0, nil, &size) == noErr else { return [] }
    var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
    guard AudioObjectGetPropertyData(sys, &addr, 0, nil, &size, &ids) == noErr else { return [] }
    return ids.compactMap { o in
        prop(o, kAudioProcessPropertyPID, as: pid_t.self).map {
            (o, $0, (prop(o, kAudioProcessPropertyIsRunningOutput, as: UInt32.self) ?? 0) != 0)
        }
    }
}

func executablePath(_ pid: pid_t) -> String? {
    var buf = [CChar](repeating: 0, count: 4096)
    return proc_pidpath(pid, &buf, UInt32(buf.count)) > 0 ? String(cString: buf) : nil
}

func defaultOutputUID() -> String? {
    guard let dev = prop(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultOutputDevice, as: AudioObjectID.self),
          let uid = prop(dev, kAudioDevicePropertyDeviceUID, as: CFString?.self).flatMap({ $0 }) else { return nil }
    return uid as String
}

// MARK: - Limiter

/// Soft-knee limiter: identity up to `knee`, then tanh rolls off smoothly toward +/-1.0 so boosted audio never clips.
/// ponytail: stateless waveshaper, not an envelope limiter; adds mild harmonics at heavy boost. Look-ahead limiter if it matters.
@inline(__always)
func softLimit(_ x: Float, knee: Float = 0.8) -> Float {
    let a = abs(x)
    if a <= knee { return x }
    return (x < 0 ? -1 : 1) * (knee + (1 - knee) * tanhf((a - knee) / (1 - knee)))
}

// MARK: - Per-app tap: mutes the app's own output and replays it scaled by `gain`

final class AppTap {
    var gain: Float
    let pids: Set<pid_t>
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?

    /// `pids` = the app's main process plus every helper process that plays audio (Teams, Chrome, Electron...).
    init?(pids: Set<pid_t>, gain: Float) {
        self.gain = gain
        self.pids = pids
        let objs = pids.compactMap { processObject(pid: $0) }
        guard !objs.isEmpty, let outUID = defaultOutputUID() else { return nil }

        let desc = CATapDescription(stereoMixdownOfProcesses: objs)
        desc.uuid = UUID()
        desc.muteBehavior = .mutedWhenTapped
        guard AudioHardwareCreateProcessTap(desc, &tapID) == noErr else { return nil }

        let agg: [String: Any] = [
            kAudioAggregateDeviceNameKey: "OpenSoundSource-\(UUID().uuidString.prefix(8))",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: outUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outUID]],
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapUIDKey: desc.uuid.uuidString, kAudioSubTapDriftCompensationKey: true]],
        ]
        guard AudioHardwareCreateAggregateDevice(agg as CFDictionary, &aggID) == noErr else { stop(); return nil }

        // ponytail: assumes float32 interleaved stereo tap; query kAudioTapPropertyFormat if exotic devices matter
        let ok = AudioDeviceCreateIOProcIDWithBlock(&procID, aggID, nil) { [unowned self] _, inData, _, outData, _ in
            let ins = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inData))
            let outs = UnsafeMutableAudioBufferListPointer(outData)
            for (i, ob) in outs.enumerated() {
                guard let dst = ob.mData?.assumingMemoryBound(to: Float.self) else { continue }
                let dstN = Int(ob.mDataByteSize) / 4
                guard i < ins.count, let src = ins[i].mData?.assumingMemoryBound(to: Float.self) else {
                    memset(dst, 0, Int(ob.mDataByteSize)); continue
                }
                let n = min(dstN, Int(ins[i].mDataByteSize) / 4)
                let g = self.gain
                if g <= 1 { for k in 0..<n { dst[k] = src[k] * g } }          // cut: plain gain, bit-exact at 100%
                else { for k in 0..<n { dst[k] = softLimit(src[k] * g) } }  // boost: limited
                if n < dstN { memset(dst + n, 0, (dstN - n) * 4) }
            }
        }
        guard ok == noErr, AudioDeviceStart(aggID, procID) == noErr else { stop(); return nil }
    }

    func stop() {
        if let p = procID { AudioDeviceStop(aggID, p); AudioDeviceDestroyIOProcID(aggID, p); procID = nil }
        if aggID != kAudioObjectUnknown { AudioHardwareDestroyAggregateDevice(aggID); aggID = AudioObjectID(kAudioObjectUnknown) }
        if tapID != kAudioObjectUnknown { AudioHardwareDestroyProcessTap(tapID); tapID = AudioObjectID(kAudioObjectUnknown) }
    }
    deinit { stop() }
}

// MARK: - Model + UI

struct AppRow: Identifiable {
    let id: pid_t
    let name: String
    let icon: NSImage?
}

@MainActor
final class Model: ObservableObject {
    @Published var apps: [AppRow] = []
    @Published var gains: [pid_t: Float] = [:]
    /// Show only apps that are emitting sound right now (apps with an active volume change stay visible).
    @Published var onlyPlaying = UserDefaults.standard.object(forKey: "onlyPlaying") as? Bool ?? true {
        didSet { UserDefaults.standard.set(onlyPlaying, forKey: "onlyPlaying"); refresh() }
    }
    @Published var failed: String?                      // app name we could not tap (usually missing permission)
    private var taps: [pid_t: AppTap] = [:]
    private var groups: [pid_t: Set<pid_t>] = [:]          // owner app pid -> its audio-producing pids
    private var premute: [pid_t: Float] = [:]

    init() {
        let nc = NSWorkspace.shared.notificationCenter
        for n in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            nc.addObserver(forName: n, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh() }
            }
        }
        refresh()
    }

    var hasTaps: Bool { !taps.isEmpty }

    func gain(_ pid: pid_t) -> Float { gains[pid] ?? 1 }

    func refresh() {
        let regular = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }
        let me = ProcessInfo.processInfo.processIdentifier
        var g: [pid_t: Set<pid_t>] = [:]
        var playing: Set<pid_t> = []
        for proc in audioProcesses() where proc.pid != me {
            let path = executablePath(proc.pid) ?? ""
            // the process is either an app itself, or a helper living inside an app bundle
            let owner = regular.first { $0.processIdentifier == proc.pid }
                ?? regular.filter { $0.bundleURL.map { path.hasPrefix($0.path + "/") } ?? false }
                          .max { ($0.bundleURL?.path.count ?? 0) < ($1.bundleURL?.path.count ?? 0) }
            if let o = owner {
                g[o.processIdentifier, default: []].insert(proc.pid)
                if proc.playing { playing.insert(o.processIdentifier) }
            }
        }
        groups = g

        let new = regular.filter { g[$0.processIdentifier] != nil && (!onlyPlaying || playing.contains($0.processIdentifier) || taps[$0.processIdentifier] != nil) }
            .map { AppRow(id: $0.processIdentifier, name: $0.localizedName ?? "?", icon: $0.icon) }
            .sorted { $0.name < $1.name }
        // app quit: drop its tap so nothing stays muted. helpers changed (e.g. a call started): rebuild the tap.
        for (pid, tap) in taps {
            guard let now = g[pid] else { taps[pid] = nil; gains[pid] = nil; premute[pid] = nil; continue }
            if now != tap.pids { taps[pid] = AppTap(pids: now, gain: tap.gain) }
        }
        if new.map(\.id) != apps.map(\.id) { apps = new }
    }

    func setGain(_ pid: pid_t, _ g: Float) {
        if abs(g - 1) < 0.01 { taps[pid] = nil; gains[pid] = nil; return }   // unity: remove tap, zero overhead
        if let t = taps[pid] { t.gain = g } else if let t = AppTap(pids: groups[pid] ?? [pid], gain: g) { taps[pid] = t } else {
            failed = apps.first { $0.id == pid }?.name ?? "this app"
            return
        }
        failed = nil
        gains[pid] = g
    }

    func toggleMute(_ pid: pid_t) {
        if gain(pid) > 0 { premute[pid] = gain(pid); setGain(pid, 0) } else { setGain(pid, premute[pid] ?? 1) }
    }

    /// Default output changed: recreate every tap so it replays to the new device.
    func rebuildTaps() {
        for (pid, t) in taps { taps[pid] = AppTap(pids: t.pids, gain: t.gain) }
    }

    func resetAll() { taps.removeAll(); gains.removeAll(); premute.removeAll(); failed = nil }
}

final class Delegate: NSObject, NSApplicationDelegate {
    let model = MainActor.assumeIsolated { Model() }
    let store = MainActor.assumeIsolated { DeviceStore() }
    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    let popover = NSPopover()

    private var ticks = 0

    /// Popover open: refresh everything every second. Closed: only keep active taps in sync (every 3 s); idle: do nothing.
    /// App launch/quit and device changes are still caught instantly by notifications and CoreAudio listeners.
    @objc func tick() {
        ticks += 1
        MainActor.assumeIsolated {
            if popover.isShown { model.refresh(); store.refresh(bluetooth: true) }
            else if model.hasTaps, ticks % 3 == 0 { model.refresh() }
        }
    }

    func applicationDidFinishLaunching(_: Notification) {
        let t = Timer.scheduledTimer(timeInterval: 1, target: self, selector: #selector(tick), userInfo: nil, repeats: true)
        t.tolerance = 0.5          // lets macOS coalesce wakeups
        item.button?.image = Delegate.menuBarIcon()
        item.button?.target = self
        item.button?.action = #selector(toggle)
        popover.behavior = .transient
        let host = NSHostingController(rootView: ContentView(model: model, store: store))
        host.sizingOptions = [.preferredContentSize]          // popover follows the content height when the tab changes
        popover.contentViewController = host
        MainActor.assumeIsolated { store.onDefaultOutputChange = { [model] in model.rebuildTaps() } }
    }

    /// Three mixer faders with knobs at different heights. Template image: macOS tints it for light/dark.
    static func menuBarIcon() -> NSImage {
        let img = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in
            NSColor.black.set()
            for (x, knobY) in [(4.0, 12.0), (9.0, 6.5), (14.0, 10.0)] {
                let track = NSBezierPath()
                track.lineWidth = 1.6
                track.lineCapStyle = .round
                track.move(to: NSPoint(x: x, y: 2.5))
                track.line(to: NSPoint(x: x, y: 15.5))
                track.stroke()
                NSBezierPath(ovalIn: NSRect(x: x - 2.6, y: knobY - 2.6, width: 5.2, height: 5.2)).fill()
            }
            return true
        }
        img.isTemplate = true
        img.accessibilityDescription = "OpenSoundSource"
        return img
    }

    @objc func toggle() {
        guard let b = item.button else { return }
        if popover.isShown { popover.performClose(nil); return }
        MainActor.assumeIsolated { model.refresh(); store.refresh(bluetooth: true) }
        popover.show(relativeTo: b.bounds, of: b, preferredEdge: .minY)
    }
}

if CommandLine.arguments.contains("--selftest") {
    assert(softLimit(0.5) == 0.5 && softLimit(-0.8) == -0.8)                 // below knee untouched
    assert(softLimit(0.9) > 0.8 && softLimit(0.9) < 1)                       // above knee compressed
    assert(softLimit(10) <= 1 && softLimit(-10) >= -1)                       // never exceeds full scale
    assert(softLimit(-0.95) == -softLimit(0.95))                             // symmetric
    var prev: Float = 0
    for i in 0...1000 { let y = softLimit(Float(i) / 100); assert(y >= prev); prev = y }   // monotonic
    print("selftest ok"); exit(0)
}

// --snapshot <dir>: render the popover to PNG (light and dark, both tabs) with made-up demo data, for the README.
// The popover itself cannot be screen-captured, and demo data keeps real device names out of public screenshots.
if let i = CommandLine.arguments.firstIndex(of: "--snapshot"), i + 1 < CommandLine.arguments.count {
    let dir = CommandLine.arguments[i + 1]
    _ = NSApplication.shared
    MainActor.assumeIsolated {
        let model = Model(), store = DeviceStore()
        func icon(_ path: String) -> NSImage { NSWorkspace.shared.icon(forFile: path) }
        model.apps = [
            AppRow(id: 1, name: "Music", icon: icon("/System/Applications/Music.app")),
            AppRow(id: 2, name: "Safari", icon: icon("/System/Volumes/Preboot/Cryptexes/App/System/Applications/Safari.app")),
            AppRow(id: 3, name: "Podcasts", icon: icon("/System/Applications/Podcasts.app")),
            AppRow(id: 4, name: "FaceTime", icon: icon("/System/Applications/FaceTime.app")),
        ]
        model.gains = [2: 0.62, 3: 1.3, 4: 0]
        let speakers = AudioDev(id: 1, uid: "a", name: "MacBook Pro Speakers", transport: kAudioDeviceTransportTypeBuiltIn)
        let airpods = AudioDev(id: 2, uid: "b", name: "AirPods Pro", transport: kAudioDeviceTransportTypeBluetooth)
        let mic = AudioDev(id: 4, uid: "d", name: "MacBook Pro Microphone", transport: kAudioDeviceTransportTypeBuiltIn)
        store.outputs = [speakers, airpods]; store.defOut = 1
        store.inputs = [mic]; store.defIn = 4
        store.outControls = Controls(volume: 0.6, muted: false, balance: 0.5)
        store.inControls = Controls(volume: 0.8, muted: false, balance: nil)
        store.bluetooth = [BTRow(id: "a", name: "AirPods Pro", connected: false)]

        for (mode, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            for (n, tab) in [("apps", 0), ("devices", 1)] {
                let backdrop = mode == "dark" ? Color(white: 0.1) : Color(white: 0.91)
                let panel = mode == "dark" ? Color(white: 0.16) : Color(white: 0.97)
                let view = ContentView(model: model, store: store, tab: tab)
                    .background(panel)
                    .clipShape(RoundedRectangle(cornerRadius: 14))
                    .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.primary.opacity(0.12), lineWidth: 1))
                    .padding(28)
                    .background(backdrop)
                let host = NSHostingView(rootView: view)
                host.appearance = NSAppearance(named: appearance)
                host.frame = NSRect(origin: .zero, size: host.fittingSize)
                host.layoutSubtreeIfNeeded()
                if let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                    host.cacheDisplay(in: host.bounds, to: rep)
                    try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "\(dir)/\(n)-\(mode).png"))
                }
            }
        }
    }
    exit(0)
}

let app = NSApplication.shared
let delegate = Delegate()
app.delegate = delegate
app.run()
