import CoreAudio
import SwiftUI

// Flat, hairline-bordered, system colors only: adapts to light/dark, no gradients, no heavy shadows.

// MARK: - Slider

/// Thin slider. With `maxValue > 1` it draws a 100% tick and colors the boost zone; `centered` fills from the middle (balance).
struct LevelSlider: View {
    @Binding var value: Double
    var maxValue = 1.0
    var centered = false
    var label: String

    var body: some View {
        GeometryReader { geo in
            let w = max(geo.size.width, 1)
            let x = w * CGFloat(value / maxValue)
            let unity = w * CGFloat(1 / maxValue)
            let mid = w / 2
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.10)).frame(height: 4)
                if centered {
                    Capsule().fill(Color.primary.opacity(0.7)).frame(width: abs(x - mid), height: 4).offset(x: min(x, mid))
                } else {
                    Capsule().fill(Color.primary.opacity(0.7)).frame(width: min(x, unity), height: 4)
                }
                if maxValue > 1 {
                    Capsule().fill(Color.orange.opacity(0.85)).frame(width: max(0, x - unity), height: 4).offset(x: unity)
                    Rectangle().fill(Color.primary.opacity(0.3)).frame(width: 1, height: 9).offset(x: unity)
                }
                Circle().fill(Color.white)
                    .overlay(Circle().stroke(Color.black.opacity(0.18), lineWidth: 0.5))
                    .frame(width: 12, height: 12)
                    .offset(x: x - 6)
            }
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { g in
                var v = min(max(Double(g.location.x / w), 0), 1) * maxValue
                if maxValue > 1, abs(v - 1) < 0.03 { v = 1 }                 // magnetic 100%
                if centered, abs(v - maxValue / 2) < 0.02 { v = maxValue / 2 }
                value = v
            })
        }
        .frame(height: 16)
        .accessibilityElement()
        .accessibilityLabel(label)
        .accessibilityValue("\(Int(value * 100)) percent")
        .accessibilityAdjustableAction { dir in
            value = min(max(value + (dir == .increment ? 0.05 : -0.05), 0), maxValue)
        }
    }
}

struct HoverRow: ViewModifier {
    @State private var hover = false
    func body(content: Content) -> some View {
        content
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(hover ? 0.05 : 0)))
            .onHover { hover = $0 }
            .animation(.easeOut(duration: 0.12), value: hover)
    }
}

extension View {
    func hoverRow() -> some View { modifier(HoverRow()) }
}

struct SectionTitle: View {
    let text: String
    var body: some View {
        Text(text.uppercased()).font(.system(size: 10, weight: .semibold)).tracking(0.6).foregroundStyle(.secondary)
    }
}

// MARK: - Root

struct ContentView: View {
    @ObservedObject var model: Model
    @ObservedObject var store: DeviceStore
    @State private var tab: Int

    init(model: Model, store: DeviceStore, tab: Int = 0) {
        self.model = model
        self.store = store
        _tab = State(initialValue: tab)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().opacity(0.6)
            Group { if tab == 0 { AppsView(model: model) } else { DevicesView(store: store) } }
                .padding(.horizontal, 8).padding(.vertical, 10)
            if let e = store.loginError {
                Text(e).font(.caption).foregroundStyle(.orange).padding(.horizontal, 16).padding(.bottom, 10)
            }
        }
        .frame(width: 340)
    }

    private var header: some View {
        HStack(spacing: 20) {
            tabButton("Apps", 0)
            tabButton("Devices", 1)
            Spacer()
            Menu {
                Toggle("Launch at login", isOn: Binding(get: { store.launchAtLogin }, set: { store.setLaunchAtLogin($0) }))
                Toggle("Only apps playing audio", isOn: $model.onlyPlaying)
                Divider()
                Button("Reset all volumes") { model.resetAll() }.disabled(model.gains.isEmpty)
                Divider()
                Button("Quit OpenSoundSource") { NSApp.terminate(nil) }.keyboardShortcut("q")
            } label: {
                Image(systemName: "ellipsis").font(.system(size: 13, weight: .semibold)).frame(width: 24, height: 24)
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        }
        .padding(.horizontal, 16).padding(.top, 12)
    }

    private func tabButton(_ title: String, _ index: Int) -> some View {
        Button { tab = index } label: {
            VStack(spacing: 6) {
                Text(title).font(.system(size: 13, weight: tab == index ? .semibold : .regular))
                    .foregroundStyle(tab == index ? Color.primary : .secondary)
                Rectangle().fill(tab == index ? Color.primary : .clear).frame(height: 1.5)
            }
            .fixedSize()
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(tab == index ? .isSelected : [])
    }
}

// MARK: - Apps

struct AppsView: View {
    @ObservedObject var model: Model

    var body: some View {
        VStack(spacing: 2) {
            if let name = model.failed {
                VStack(alignment: .leading, spacing: 6) {
                    Label("Can't control \(name)", systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 12, weight: .medium)).foregroundStyle(.orange)
                    Text("Allow OpenSoundSource to capture audio in System Settings, then try again.")
                        .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    Button("Open Privacy Settings") {
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AudioCapture")!)
                    }
                    .buttonStyle(.link).font(.system(size: 12))
                }
                .padding(12).frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 10).fill(Color.orange.opacity(0.08)))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.orange.opacity(0.25), lineWidth: 1))
                .padding(.horizontal, 8).padding(.bottom, 6)
            }

            if model.apps.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "waveform").font(.system(size: 20, weight: .light))
                    Text(model.onlyPlaying ? "Nothing is playing" : "No apps are using audio").font(.system(size: 13, weight: .medium))
                    Text("Apps show up here as soon as they make sound.").font(.system(size: 11))
                }
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, minHeight: 110)
            } else {
                ForEach(model.apps) { AppRowView(model: model, app: $0).transition(.opacity) }
            }
        }
        .animation(.easeOut(duration: 0.2), value: model.apps.map(\.id))
    }
}

struct AppRowView: View {
    @ObservedObject var model: Model
    let app: AppRow

    var body: some View {
        let g = model.gain(app.id)
        HStack(spacing: 12) {
            Image(nsImage: app.icon ?? NSImage()).resizable().frame(width: 30, height: 30)
            VStack(spacing: 3) {
                HStack {
                    Text(app.name).font(.system(size: 13, weight: .medium)).lineLimit(1)
                    Spacer()
                    // click the number to snap back to 100%
                    Button { model.setGain(app.id, 1) } label: {
                        Text("\(Int(g * 100))%").font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(g > 1 ? Color.orange : .secondary)
                    }
                    .buttonStyle(.plain).help("Reset to 100%")
                }
                LevelSlider(value: Binding(get: { Double(g) }, set: { model.setGain(app.id, Float($0)) }),
                            maxValue: 1.5, label: "Volume for \(app.name)")
            }
            Button { model.toggleMute(app.id) } label: {
                Image(systemName: g == 0 ? "speaker.slash.fill" : "speaker.wave.2.fill")
                    .font(.system(size: 12)).frame(width: 24, height: 24)
                    .foregroundStyle(g == 0 ? Color.primary : .secondary)
            }
            .buttonStyle(.plain).help(g == 0 ? "Unmute" : "Mute")
            .accessibilityLabel(g == 0 ? "Unmute \(app.name)" : "Mute \(app.name)")
        }
        .padding(8)
        .hoverRow()
    }
}

// MARK: - Devices

struct DevicesView: View {
    @ObservedObject var store: DeviceStore

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                DeviceSection(store: store, title: "Output", dir: .output, devices: store.outputs, current: store.defOut, controls: store.outControls)
                DeviceSection(store: store, title: "Input", dir: .input, devices: store.inputs, current: store.defIn, controls: store.inControls)
                if !store.bluetooth.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        SectionTitle(text: "Bluetooth").padding(.horizontal, 8)
                        ForEach(store.bluetooth) { row in
                            HStack(spacing: 10) {
                                Image(systemName: "headphones").frame(width: 20).foregroundStyle(.secondary)
                                Text(row.name).font(.system(size: 13)).lineLimit(1)
                                Spacer()
                                Button(row.connected ? "Disconnect" : "Connect") { store.toggleBluetooth(row) }
                                    .controlSize(.small)
                            }
                            .padding(8).hoverRow()
                        }
                    }
                }
                Button("AirPlay and more in Sound Settings") {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Sound-Settings.extension")!)
                }
                .buttonStyle(.link).font(.system(size: 11)).padding(.horizontal, 8)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxHeight: 420)
    }
}

struct DeviceSection: View {
    @ObservedObject var store: DeviceStore
    let title: String
    let dir: Direction
    let devices: [AudioDev]
    let current: AudioObjectID
    let controls: Controls

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            SectionTitle(text: title).padding(.horizontal, 8)
            ForEach(devices) { dev in
                let selected = dev.id == current
                Button { store.setDefault(dir, dev) } label: {
                    HStack(spacing: 10) {
                        Image(systemName: dev.symbol).frame(width: 20).foregroundStyle(selected ? Color.primary : .secondary)
                        Text(dev.name).font(.system(size: 13, weight: selected ? .medium : .regular)).lineLimit(1)
                        Spacer()
                        if selected { Image(systemName: "checkmark").font(.system(size: 11, weight: .semibold)) }
                    }
                    .padding(8).contentShape(Rectangle())
                }
                .buttonStyle(.plain).hoverRow()
                .accessibilityLabel("\(dev.name)\(selected ? ", selected" : "")")
            }
            controlsPanel.padding(.horizontal, 8).padding(.top, 4)
        }
    }

    // volume, mute and balance of the selected device
    private var controlsPanel: some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                Button { store.setMuted(dir, !(controls.muted ?? false)) } label: {
                    Image(systemName: dir == .input
                          ? (controls.muted == true ? "mic.slash.fill" : "mic.fill")
                          : (controls.muted == true ? "speaker.slash.fill" : "speaker.wave.2.fill"))
                        .font(.system(size: 12)).frame(width: 20)
                        .foregroundStyle(controls.muted == true ? Color.primary : .secondary)
                }
                .buttonStyle(.plain).disabled(controls.muted == nil)
                .help(controls.muted == true ? "Unmute" : "Mute")
                LevelSlider(value: Binding(get: { Double(controls.volume ?? 0) }, set: { store.setVolume(dir, Float($0)) }),
                            label: "\(title) volume")
                    .disabled(controls.volume == nil).opacity(controls.volume == nil ? 0.4 : 1)
                Text("\(Int((controls.volume ?? 0) * 100))%").font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary).frame(width: 36, alignment: .trailing)
            }
            if let b = controls.balance {
                HStack(spacing: 10) {
                    Text("L").font(.system(size: 10, weight: .semibold, design: .monospaced)).foregroundStyle(.secondary).frame(width: 20)
                    LevelSlider(value: Binding(get: { Double(b) }, set: { store.setBalance(Float($0)) }), centered: true, label: "Balance")
                    Text("R").font(.system(size: 10, weight: .semibold, design: .monospaced)).foregroundStyle(.secondary).frame(width: 36, alignment: .trailing)
                }
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.03)))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.primary.opacity(0.08), lineWidth: 1))
    }
}
