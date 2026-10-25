import AudioToolbox
import CoreAudio
@preconcurrency import IOBluetooth
import ServiceManagement
import SwiftUI

// MARK: - CoreAudio device helpers

enum Direction {
    case output, input
    var scope: AudioObjectPropertyScope { self == .output ? kAudioObjectPropertyScopeOutput : kAudioObjectPropertyScopeInput }
    var defaultSelector: AudioObjectPropertySelector {
        self == .output ? kAudioHardwarePropertyDefaultOutputDevice : kAudioHardwarePropertyDefaultInputDevice
    }
}

private let system = AudioObjectID(kAudioObjectSystemObject)

private func address(_ sel: AudioObjectPropertySelector, _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(mSelector: sel, mScope: scope, mElement: kAudioObjectPropertyElementMain)
}

private func get<T>(_ obj: AudioObjectID, _ sel: AudioObjectPropertySelector, _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal, as: T.Type) -> T? {
    var a = address(sel, scope)
    var size = UInt32(MemoryLayout<T>.size)
    let p = UnsafeMutablePointer<T>.allocate(capacity: 1)
    defer { p.deallocate() }
    return AudioObjectGetPropertyData(obj, &a, 0, nil, &size, p) == noErr ? p.pointee : nil
}

@discardableResult
private func set<T>(_ obj: AudioObjectID, _ sel: AudioObjectPropertySelector, _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal, _ value: T) -> Bool {
    var a = address(sel, scope)
    var v = value
    return AudioObjectSetPropertyData(obj, &a, 0, nil, UInt32(MemoryLayout<T>.size), &v) == noErr
}

private func settable(_ obj: AudioObjectID, _ sel: AudioObjectPropertySelector, _ scope: AudioObjectPropertyScope) -> Bool {
    var a = address(sel, scope)
    var b: DarwinBoolean = false
    return AudioObjectIsPropertySettable(obj, &a, &b) == noErr && b.boolValue
}

struct AudioDev: Identifiable, Equatable {
    let id: AudioObjectID
    let uid: String
    let name: String
    let transport: UInt32

    var symbol: String {
        switch transport {
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE: return "headphones"
        case kAudioDeviceTransportTypeAirPlay: return "airplayaudio"
        case kAudioDeviceTransportTypeUSB: return "cable.connector"
        case kAudioDeviceTransportTypeBuiltIn: return "laptopcomputer"
        case kAudioDeviceTransportTypeHDMI, kAudioDeviceTransportTypeDisplayPort: return "display"
        default: return "speaker.wave.2"
        }
    }
}

func audioDevices(_ d: Direction) -> [AudioDev] {
    var a = address(kAudioHardwarePropertyDevices)
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(system, &a, 0, nil, &size) == noErr else { return [] }
    var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
    guard AudioObjectGetPropertyData(system, &a, 0, nil, &size, &ids) == noErr else { return [] }
    return ids.compactMap { id in
        var sa = address(kAudioDevicePropertyStreams, d.scope)
        var ssize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &sa, 0, nil, &ssize) == noErr, ssize > 0,       // has streams in this direction
              let name = get(id, kAudioObjectPropertyName, as: CFString?.self).flatMap({ $0 }),
              let uid = get(id, kAudioDevicePropertyDeviceUID, as: CFString?.self).flatMap({ $0 }) else { return nil }
        return AudioDev(id: id, uid: uid as String, name: name as String,
                        transport: get(id, kAudioDevicePropertyTransportType, as: UInt32.self) ?? 0)
    }
}

/// nil = the device does not expose that control (or it is fixed), so the UI disables it.
struct Controls: Equatable {
    var volume: Float?
    var muted: Bool?
    var balance: Float?          // 0 = left, 0.5 = center, 1 = right
}

func readControls(_ id: AudioObjectID, _ d: Direction) -> Controls {
    var c = Controls()
    let vol = kAudioHardwareServiceDeviceProperty_VirtualMainVolume
    let bal = kAudioHardwareServiceDeviceProperty_VirtualMainBalance
    if settable(id, vol, d.scope) { c.volume = get(id, vol, d.scope, as: Float32.self) }
    if settable(id, kAudioDevicePropertyMute, d.scope) { c.muted = get(id, kAudioDevicePropertyMute, d.scope, as: UInt32.self).map { $0 != 0 } }
    if d == .output, settable(id, bal, d.scope) { c.balance = get(id, bal, d.scope, as: Float32.self) }
    return c
}

// MARK: - Store

struct BTRow: Identifiable {
    let id: String          // Bluetooth address
    let name: String
    let connected: Bool
}

@MainActor
final class DeviceStore: ObservableObject {
    @Published var outputs: [AudioDev] = []
    @Published var inputs: [AudioDev] = []
    @Published var defOut = AudioObjectID(kAudioObjectUnknown)
    @Published var defIn = AudioObjectID(kAudioObjectUnknown)
    @Published var outControls = Controls()
    @Published var inControls = Controls()
    @Published var bluetooth: [BTRow] = []
    @Published var launchAtLogin = SMAppService.mainApp.status == .enabled
    @Published var loginError: String?

    /// Fired when the system default output changes (headphones plugged, Bluetooth connected...), so taps can follow it.
    var onDefaultOutputChange: (() -> Void)?

    init() {
        // react immediately to device list / default device changes; the 1 s timer in the UI covers volume changes made elsewhere
        for sel in [kAudioHardwarePropertyDevices, kAudioHardwarePropertyDefaultOutputDevice, kAudioHardwarePropertyDefaultInputDevice] {
            var a = address(sel)
            AudioObjectAddPropertyListenerBlock(system, &a, .main) { [weak self] _, _ in
                MainActor.assumeIsolated { self?.refresh() }
            }
        }
        refresh(bluetooth: true)
    }

    func id(_ d: Direction) -> AudioObjectID { d == .output ? defOut : defIn }
    func controls(_ d: Direction) -> Controls { d == .output ? outControls : inControls }

    func refresh(bluetooth: Bool = false) {
        let newOut = get(system, kAudioHardwarePropertyDefaultOutputDevice, as: AudioObjectID.self) ?? 0
        let newIn = get(system, kAudioHardwarePropertyDefaultInputDevice, as: AudioObjectID.self) ?? 0
        // hide virtual/aggregate drivers (Background Music, Teams Audio...) unless one is currently selected
        func visible(_ d: AudioDev, _ cur: AudioObjectID) -> Bool {
            d.id == cur || (d.transport != kAudioDeviceTransportTypeVirtual && d.transport != kAudioDeviceTransportTypeAggregate)
        }
        let o = audioDevices(.output).filter { visible($0, newOut) }, i = audioDevices(.input).filter { visible($0, newIn) }
        if o != outputs { outputs = o }
        if i != inputs { inputs = i }
        let outChanged = newOut != defOut && defOut != 0
        if newOut != defOut { defOut = newOut }
        if newIn != defIn { defIn = newIn }
        let oc = readControls(defOut, .output), ic = readControls(defIn, .input)
        if oc != outControls { outControls = oc }
        if ic != inControls { inControls = ic }
        if bluetooth { refreshBluetooth() }          // IOBluetooth is a synchronous XPC call: only while the popover is open
        if outChanged { onDefaultOutputChange?() }
    }

    func setDefault(_ d: Direction, _ dev: AudioDev) {
        set(system, d.defaultSelector, kAudioObjectPropertyScopeGlobal, dev.id)
        refresh()
    }

    func setVolume(_ d: Direction, _ v: Float) {
        set(id(d), kAudioHardwareServiceDeviceProperty_VirtualMainVolume, d.scope, v)
        // input gain at 0% is not silence on many mics (and apps like Discord re-amplify it): 0% also mutes
        if d == .input, controls(d).muted != nil {
            set(id(d), kAudioDevicePropertyMute, d.scope, UInt32(v == 0 ? 1 : 0))
        }
        refresh()
    }

    func setMuted(_ d: Direction, _ m: Bool) {
        set(id(d), kAudioDevicePropertyMute, d.scope, UInt32(m ? 1 : 0))
        refresh()
    }

    func setBalance(_ b: Float) {
        set(defOut, kAudioHardwareServiceDeviceProperty_VirtualMainBalance, kAudioObjectPropertyScopeOutput, b)
        refresh()
    }

    // Bluetooth: public IOBluetooth can connect paired audio devices. Once connected they appear in the CoreAudio lists above.
    func refreshBluetooth() {
        let paired = (IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice]) ?? []
        let rows = paired.filter { $0.deviceClassMajor == 4 }          // 4 = Audio/Video
            .map { BTRow(id: $0.addressString ?? "", name: $0.name ?? "Bluetooth device", connected: $0.isConnected()) }
        if rows.map(\.id) != bluetooth.map(\.id) || rows.map(\.connected) != bluetooth.map(\.connected) { bluetooth = rows }
    }

    func toggleBluetooth(_ row: BTRow) {
        guard let dev = IOBluetoothDevice(addressString: row.id) else { return }
        DispatchQueue.global().async {
            _ = dev.isConnected() ? dev.closeConnection() : dev.openConnection()      // blocking calls, so off the main thread
            Task { @MainActor in self.refresh() }
        }
    }

    // Launch at login
    func setLaunchAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            loginError = nil
        } catch {
            loginError = "Could not change login item: \(error.localizedDescription)"
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }
}
