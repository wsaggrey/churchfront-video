import SwiftUI
import AppKit
import CueATEM

// MARK: - Full switcher page

/// Every switcher control, for experienced operators. Kept out of the Operator view.
struct SwitcherWindow: View {
    @EnvironmentObject var booth: Booth
    @EnvironmentObject var atem: ATEMClient
    @State private var me = 0

    var body: some View {
        Page {
            PageHeader(title: "Full switcher", purpose: "Every control on the switcher. What you press here goes to air like the hardware panel.") {
                if !atem.state.product.isEmpty { Text(atem.state.product).font(.sans(12)).foregroundStyle(T.inkMuted) }
                if atem.state.meCount > 1 {
                    Segments(items: (0..<atem.state.meCount).map { ("M/E \($0 + 1)", $0) }, selection: $me)
                }
            }
            SurfaceView(me: me)
        }
        .onAppear { me = booth.me }
    }
}

// MARK: - Setup page

/// The parts of Setup, as tabs across the top of the page.
enum SetupPage: String, CaseIterable, Identifiable {
    case switcher, sources, keys, cameras, tracking, assistant, file
    var id: String { rawValue }
    var title: String {
        switch self {
        case .switcher: return "Switcher"
        case .sources: return "Sources"
        case .keys: return "Key buttons"
        case .cameras: return "Cameras"
        case .tracking: return "Tracking"
        case .assistant: return "AI assistant"
        case .file: return "Setup file"
        }
    }
    var purpose: String {
        switch self {
        case .switcher: return "Where the ATEM is, and which mix the operator runs."
        case .sources: return "The tiles the operator can put on Next, left to right."
        case .keys: return "On and off buttons under Fade and Cut, such as lower thirds."
        case .cameras: return "The PTZ cameras, the switcher input each one feeds, and their saved shots."
        case .tracking: return "How auto tracking follows a person."
        case .assistant: return "Let Claude set up and run Churchfront Video for you, in plain words."
        case .file: return "Everything in Setup is saved in one file that people and Claude can edit."
        }
    }
    var help: String? {
        switch self {
        case .switcher: return nil
        case .sources: return "Keys 1 to 9 and 0 pick the tiles in this order. Leave the name blank to use the camera's name or the switcher's. Until any are added, the row shows every camera. For graphics or lyrics, choose the NDI source showing the same picture (in Churchfront Screens, add an NDI output to that screen) so the tile and the Next and Live monitors show it."
        case .keys: return "Upstream keys cut on and off; DSKs fade at their own rate. Choose an NDI preview with alpha (in Churchfront Screens, send the lower thirds screen to NDI with alpha) to see the key laid over the Next and Live pictures."
        case .cameras: return "Canon (HTTP) works with no camera settings, reports where the camera points, and shows the presets saved on the camera. Most other cameras speak VISCA over IP (UDP 52381); PTZOptics also takes VISCA over TCP (5678). Set the switcher input each camera is plugged into, so putting it on Next lets the operator move it."
        case .tracking: return "Track (under the joystick) makes a Canon camera follow a person, using its preview picture. It frames them as a shoulders-up, waist-up or full-length follow shot: eyes near the upper third, headroom to suit the shot, lead room on the side they face or walk toward, and gentle eased moves. Zooming by hand keeps tracking and holds the new size. Moving the joystick, a shot or a preset hands the camera back."
        case .assistant: return "Connecting adds Churchfront Video to the Claude desktop app on this Mac. Claude can then find your switcher and cameras on the network, set them up with you, and run the switcher when you ask. It checks with you before changing anything live. Claude for Mac is free from claude.ai/download."
        case .file: return "The file is plain JSON. You, the system owner or Claude can edit it directly; Churchfront Video picks up changes within a second. A copy of the last setup that loaded cleanly is kept beside it."
        }
    }
}

struct SetupTab: View {
    @EnvironmentObject var booth: Booth
    @EnvironmentObject var atem: ATEMClient
    @EnvironmentObject var ptz: PTZController
    @EnvironmentObject var store: ConfigStore
    @AppStorage("setupPage") private var pageRaw = SetupPage.switcher.rawValue
    @State private var host = ""

    private var page: SetupPage { SetupPage(rawValue: pageRaw) ?? .switcher }

    var body: some View {
        Page {
            PageHeader(title: "Setup", purpose: page.purpose, help: page.help)
            Segments(items: SetupPage.allCases.map { ($0.title, $0.rawValue) }, selection: $pageRaw)
            switch page {
            case .switcher: switcher
            case .sources: sources
            case .keys: keyButtons
            case .cameras: cameras
            case .tracking: tracking
            case .assistant: AssistantSetup()
            case .file: configFile
            }
        }
        .onAppear { host = store.config.atemHost }
        .onChange(of: store.config.atemHost) { _, h in host = h }
    }

    private func labeled<C: View>(_ label: String, @ViewBuilder _ content: () -> C) -> some View {
        HStack(alignment: .center, spacing: T.s3) {
            Text(label).font(.sans(12, .semibold)).foregroundStyle(T.inkMuted).frame(width: 130, alignment: .leading)
            content()
            Spacer(minLength: 0)
        }
    }

    // MARK: Switcher

    var switcher: some View {
        Card(title: "ATEM switcher") {
            labeled("Address") {
                TextField("IP address", text: $host).textFieldStyle(CueFieldStyle()).frame(width: 200)
                    .onSubmit { store.update { $0.atemHost = host.trimmingCharacters(in: .whitespaces) } }
                Button("Connect") { store.update { $0.atemHost = host.trimmingCharacters(in: .whitespaces) } }
                    .buttonStyle(CueButton(kind: .primary))
                LinkPill()
            }
            labeled("Model") {
                Text(atem.state.product.isEmpty ? "Unknown until connected" : "\(atem.state.product), protocol \(atem.state.version)")
                    .font(.sans(13)).foregroundStyle(atem.state.product.isEmpty ? T.inkSubtle : T.ink)
            }
            if atem.state.meCount > 1 {
                labeled("The operator runs") {
                    Segments(items: (1...atem.state.meCount).map { ("M/E \($0)", $0) },
                             selection: Binding(get: { store.config.me }, set: { v in store.update { $0.me = v } }))
                    Text("Live on it now: \(store.label(atem.state.program[store.config.me - 1], atem.state))")
                        .font(.sans(12)).foregroundStyle(T.inkMuted)
                }
            }
        }
        .frame(maxWidth: 760, alignment: .leading)
    }

    // MARK: Sources

    var sources: some View {
        let chosen = store.config.sources
        let available = atem.state.busSources.filter { s in !chosen.contains { $0.input == s.id } }
        return Card {
            HStack(spacing: T.s3) {
                Col("Key", 30); Col("Switcher input", 200); Col("Name on screen", 200); Col("Picture")
                Spacer()
            }
            if chosen.isEmpty {
                Text("Nothing added yet, so the row shows every camera.").font(.sans(13)).foregroundStyle(T.inkMuted)
            }
            ForEach(Array(chosen.enumerated()), id: \.element.input) { i, s in
                HStack(spacing: T.s3) {
                    Text(i < 10 ? "\((i + 1) % 10)" : "").font(.sans(13, .bold)).foregroundStyle(T.inkSubtle).frame(width: 30, alignment: .leading)
                    Text(atem.state.inputs[s.input]?.long ?? "Input \(s.input)").font(.sans(13)).lineLimit(1).frame(width: 200, alignment: .leading)
                    TextField(store.label(s.input, atem.state), text: Binding(
                        get: { s.label ?? "" },
                        set: { v in store.update { c in
                            if let j = c.sources.firstIndex(where: { $0.input == s.input }) { c.sources[j].label = v.isEmpty ? nil : v }
                        } }
                    ))
                    .textFieldStyle(CueFieldStyle()).frame(width: 200)
                    if ptz.cameras.contains(where: { $0.atemInput == s.input && $0.proto == .canonXC && !$0.host.isEmpty }) {
                        Label("The camera's own picture", systemImage: "video").font(.sans(12)).foregroundStyle(T.inkSubtle)
                    } else {
                        // A VISCA camera (an NDI HX camera such as a Fomako or PTZOptics) has no
                        // picture of its own here: its NDI stream is the picture for its input.
                        let isCamera = ptz.cameras.contains { $0.atemInput == s.input }
                        NDIPicker(selection: s.ndi, none: isCamera ? "No picture (pick the camera's NDI stream)" : "No picture") { v in store.update { c in
                            if let j = c.sources.firstIndex(where: { $0.input == s.input }) { c.sources[j].ndi = v }
                        } }
                        .frame(width: 280)
                        .help(isCamera
                              ? "This camera's NDI stream, as it announces itself on the network. Its tile, the Next and Live pictures, auto tracking and snapshots all use it."
                              : "An NDI source showing what this input carries, such as a Churchfront Screens screen sent to NDI, for its tile and the Next and Live pictures.")
                    }
                    Spacer(minLength: 0)
                    IconButton(icon: "chevron.up", help: "Move earlier in the row") { move(s.input, by: -1) }.disabled(i == 0)
                    IconButton(icon: "chevron.down", help: "Move later in the row") { move(s.input, by: 1) }.disabled(i == chosen.count - 1)
                    IconButton(icon: "trash", help: "Take this tile out of the row") { store.update { $0.sources.removeAll { $0.input == s.input } } }
                }
            }
            MenuField(text: "Add a source", width: 180, icon: "plus") {
                ForEach(available) { s in
                    Button("\(s.long) (\(s.short))") { store.update { $0.sources.append(VolunteerSource(input: s.id)) } }
                }
            }
            .disabled(available.isEmpty)
        }
    }

    // MARK: Key buttons

    var keyButtons: some View {
        let s = atem.state
        func name(_ i: Int?) -> String { i.map { s.inputs[$0]?.long ?? "input \($0)" } ?? "?" }
        return Card {
            HStack(spacing: T.s3) {
                Col("Button label", 180); Col("Key", 110); Col("Fill and key sources", 260); Col("Preview picture")
                Spacer()
            }
            if store.config.keys.isEmpty {
                Text("No key buttons yet.").font(.sans(13)).foregroundStyle(T.inkMuted)
            }
            ForEach(store.config.keys) { k in
                HStack(spacing: T.s3) {
                    TextField("Label", text: Binding(get: { k.label }, set: { v in store.update { c in
                        if let i = c.keys.firstIndex(of: k) { c.keys[i].label = v }
                    } }))
                    .textFieldStyle(CueFieldStyle()).frame(width: 180)
                    Text(k.target).font(.sans(13)).frame(width: 110, alignment: .leading)
                    Text(k.dsk.map { "\(name(s.dskFill[$0 - 1])) / \(name(s.dskCut[$0 - 1]))" }
                         ?? "\(name(s.keyFill[(k.me ?? 1) - 1]?[(k.keyer ?? 1) - 1])) / \(name(s.keyCut[(k.me ?? 1) - 1]?[(k.keyer ?? 1) - 1]))")
                        .font(.sans(12)).foregroundStyle(T.inkMuted).lineLimit(1).frame(width: 260, alignment: .leading)
                    NDIPicker(selection: k.ndi, none: "No preview") { v in store.update { c in
                        if let i = c.keys.firstIndex(of: k) { c.keys[i].ndi = v }
                    } }
                    .frame(width: 280)
                    .help("An NDI source with alpha showing this key, such as Churchfront Screens' lower thirds sent to NDI with alpha. It's laid over the Next and Live pictures when the key is on them.")
                    Spacer(minLength: 0)
                    IconButton(icon: "trash", help: "Remove this button") { store.update { $0.keys.removeAll { $0 == k } } }
                }
            }
            MenuField(text: "Add a key button", width: 180, icon: "plus") {
                ForEach(s.keyFill.keys.sorted(), id: \.self) { me in
                    ForEach((s.keyFill[me] ?? [:]).keys.sorted(), id: \.self) { k in
                        Button("M/E \(me + 1) Key \(k + 1): \(name(s.keyFill[me]?[k]))") {
                            store.update { $0.keys.append(KeyButton(label: "Key \(k + 1)", me: me + 1, keyer: k + 1)) }
                        }
                    }
                }
                ForEach(s.dskFill.keys.sorted(), id: \.self) { d in
                    Button("DSK \(d + 1): \(name(s.dskFill[d]))") {
                        store.update { $0.keys.append(KeyButton(label: "DSK \(d + 1)", dsk: d + 1)) }
                    }
                }
            }
        }
    }

    func move(_ input: Int, by d: Int) {
        store.update { c in
            guard let i = c.sources.firstIndex(where: { $0.input == input }) else { return }
            let j = i + d
            guard c.sources.indices.contains(j) else { return }
            c.sources.swapAt(i, j)
        }
    }

    // MARK: Cameras

    var cameras: some View {
        VStack(alignment: .leading, spacing: T.s4) {
            Card {
                HStack(spacing: T.s2) {
                    Col("", 10); Col("Name", 120); Col("Address", 140); Col("Control", 170); Col("Port", 64); Col("Switcher input", 170); Col("Presets", 130)
                    Spacer()
                }
                if ptz.cameras.isEmpty {
                    Text("No cameras yet.").font(.sans(13)).foregroundStyle(T.inkMuted)
                }
                ForEach($ptz.cameras) { $c in
                    VStack(alignment: .leading, spacing: T.s2) {
                        CameraRow(camera: $c) { ptz.cameras.removeAll { $0.id == c.id } }
                        if ptz.canSaveShots(c) { ShotEditor(camera: $c).padding(.leading, 18) }
                    }
                    if c.id != ptz.cameras.last?.id { Rectangle().fill(T.line).frame(height: 1) }
                }
                Button {
                    var c = PTZCamera()
                    c.name = "Cam \(ptz.cameras.count + 1)"
                    c.proto = .canonXC; c.port = 80
                    ptz.cameras.append(c)
                } label: { Label("Add a camera", systemImage: "plus") }
                .buttonStyle(CueButton())
            }
            Card(title: "Camera admin login",
                 help: "Only needed to delete or change presets stored on Canon cameras themselves. Saved in this Mac's Keychain, not in the setup file. One login for every Canon camera. VISCA and NDI cameras (Fomako, PTZOptics, BirdDog) need no login here; their web page's login isn't used. macOS may ask for this Mac's password the first time Churchfront Video uses it after an update.") {
                CameraLoginRow()
            }
            .frame(maxWidth: 760, alignment: .leading)
        }
    }

    // MARK: Tracking

    var tracking: some View {
        Card(title: "Auto tracking") {
            labeled("Follow speed") {
                Slider(value: Binding(get: { store.config.trackSpeed }, set: { v in store.update { $0.trackSpeed = (v * 10).rounded() / 10 } }),
                       in: 0.5...4).frame(width: 240)
                Text(String(format: "%.1f×", store.config.trackSpeed)).font(.system(size: 12, design: .monospaced)).foregroundStyle(T.inkMuted)
                    .frame(width: 40, alignment: .leading)
                Text("Lower if the camera overshoots, higher if it falls behind.").font(.sans(12)).foregroundStyle(T.inkSubtle)
            }
            labeled("Tilt") {
                Toggle("", isOn: Binding(get: { store.config.trackTilt }, set: { v in store.update { $0.trackTilt = v } }))
                    .toggleStyle(.switch).controlSize(.small).labelsHidden()
                Text("Tilt to follow as well as pan. Off: pan only.").font(.sans(12)).foregroundStyle(T.inkSubtle)
            }
            labeled("Zoom") {
                Toggle("", isOn: Binding(get: { store.config.trackZoom }, set: { v in store.update { $0.trackZoom = v } }))
                    .toggleStyle(.switch).controlSize(.small).labelsHidden()
                Text("Zoom to hold the shot size as people move nearer or farther.").font(.sans(12)).foregroundStyle(T.inkSubtle)
            }
        }
        .frame(maxWidth: 760, alignment: .leading)
    }

    // MARK: Setup file

    var configFile: some View {
        Card(title: "Setup file") {
            Text(store.url.path).font(.system(size: 12, design: .monospaced)).textSelection(.enabled)
            HStack(spacing: T.s2) {
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([store.url]) }.buttonStyle(CueButton())
                Button("Copy path") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(store.url.path, forType: .string)
                }
                .buttonStyle(CueButton())
            }
            if let e = store.fileError {
                Text("The file has a problem, so Churchfront Video is still using the last good setup: \(e)")
                    .font(.sans(12, .semibold)).foregroundStyle(T.danger).fixedSize(horizontal: false, vertical: true)
            }
            if store.readOnly {
                Text("A self-test is running, so changes aren't saved.").font(.sans(12)).foregroundStyle(T.warning)
            }
        }
        .frame(maxWidth: 760, alignment: .leading)
    }
}

/// The Canon cameras' admin login, typed here by a person and kept in this Mac's Keychain.
/// Only changing presets stored on the cameras needs it.
struct CameraLoginRow: View {
    @State private var user = CameraLogin.savedUser ?? ""
    @State private var password = ""
    @State private var saved = CameraLogin.isSaved
    @State private var note: String?

    var body: some View {
        VStack(alignment: .leading, spacing: T.s2) {
            HStack(spacing: T.s2) {
                TextField("User name", text: $user).textFieldStyle(CueFieldStyle()).frame(width: 160)
                SecureField(saved ? "Saved (type to replace)" : "Password", text: $password).textFieldStyle(CueFieldStyle()).frame(width: 200)
                Button("Save") {
                    let u = user.trimmingCharacters(in: .whitespaces)
                    guard !u.isEmpty, !password.isEmpty else { note = "Enter both the user name and the password."; return }
                    if CameraLogin.save(user: u, password: password) {
                        password = ""; saved = true; note = "Saved in the Keychain."
                    } else {
                        note = "The Keychain didn't accept it. Try again."
                    }
                }
                .buttonStyle(CueButton(kind: .primary))
                if saved {
                    Button("Remove") { CameraLogin.clear(); saved = false; user = ""; password = ""; note = "Removed." }
                        .buttonStyle(CueButton(kind: .danger))
                }
                if let note { Text(note).font(.sans(12)).foregroundStyle(T.inkMuted) }
            }
        }
    }
}

struct CameraRow: View {
    @EnvironmentObject var atem: ATEMClient
    @EnvironmentObject var ptz: PTZController
    @Binding var camera: PTZCamera
    let remove: () -> Void

    var body: some View {
        HStack(spacing: T.s2) {
            Circle().fill(ptz.online.contains(camera.id) ? T.success : T.lineStrong).frame(width: 8, height: 8)
                .frame(width: 10).help(ptz.online.contains(camera.id) ? "Answering" : "Not answering")
            TextField("Name", text: $camera.name).textFieldStyle(CueFieldStyle()).frame(width: 120)
            TextField("IP address", text: $camera.host).textFieldStyle(CueFieldStyle()).frame(width: 140)
            MenuField(text: camera.proto.label, width: 170) {
                ForEach(VISCAProtocol.allCases) { p in
                    Button(p.label) { camera.proto = p; camera.port = p.defaultPort }
                }
            }
            TextField("Port", value: $camera.port, format: .number.grouping(.never)).textFieldStyle(CueFieldStyle()).frame(width: 64)
            MenuField(text: camera.atemInput.map { atem.state.inputs[$0]?.long ?? "Input \($0)" } ?? "No input", width: 170) {
                Button("No input") { camera.atemInput = nil }
                ForEach(atem.state.busSources.filter(\.isExternal)) { s in Button(s.long) { camera.atemInput = s.id } }
            }
            .help("The switcher input this camera is plugged into")
            if camera.proto != .canonXC {
                MenuField(text: "Count from \(camera.firstPreset)", width: 130) {
                    Button("Count from 0") { camera.firstPreset = 0 }
                    Button("Count from 1") { camera.firstPreset = 1 }
                }
                .help("Some VISCA cameras number their presets from 1 instead of 0")
            } else {
                Text("Read from the camera").font(.sans(11)).foregroundStyle(T.inkSubtle).frame(width: 130, alignment: .leading)
            }
            Spacer(minLength: 0)
            IconButton(icon: "trash", help: "Remove \(camera.name)", action: remove)
        }
    }
}

/// A camera's shots, editable by name and number, plus the presets stored on the camera.
/// Position: pan and tilt in hundredths of a degree, zoom in the camera's steps.
/// Exposure: gain in tenths of a dB, shutter as 1/x, iris as the f-number times 100.
struct ShotEditor: View {
    @EnvironmentObject var ptz: PTZController
    @Binding var camera: PTZCamera
    @State private var open = false
    @State private var deletingPreset: Int?
    @State private var problem: String?

    var body: some View {
        DisclosureGroup(isExpanded: $open) {
            VStack(alignment: .leading, spacing: 6) {
                if camera.shots.isEmpty {
                    Text("No shots saved in Churchfront Video yet. Save one from the main window, or add one here from the camera as it is now.")
                        .font(.sans(12)).foregroundStyle(T.inkSubtle)
                }
                ForEach($camera.shots) { $s in
                    HStack(spacing: T.s2) {
                        Text(s.kind == .exposure ? "Exposure" : "Position").font(.sans(11, .semibold))
                            .foregroundStyle(s.kind == .exposure ? T.warning : T.accentStrong).frame(width: 60, alignment: .leading)
                        TextField("Name", text: $s.name).textFieldStyle(CueFieldStyle()).frame(width: 140)
                        if s.kind == .position {
                            number("Pan", $s.pan); number("Tilt", $s.tilt); number("Zoom", $s.zoom)
                        } else {
                            number("Gain", exposure($s, \.gain)); number("Shutter", exposure($s, \.shutter)); number("Iris", exposure($s, \.iris))
                        }
                        Button("Recall") { ptz.go(to: s, camera: camera.id) }
                            .help("Sends this to \(camera.name) now. Check it isn't live first.")
                        Button("Update to now") { ptz.saveShot("", camera: camera.id, kind: s.kind, replacing: s.id) }
                        Button { move(s.id, -1) } label: { Image(systemName: "chevron.up") }.buttonStyle(.borderless)
                        Button { move(s.id, 1) } label: { Image(systemName: "chevron.down") }.buttonStyle(.borderless)
                        Button { camera.shots.removeAll { $0.id == s.id } } label: { Image(systemName: "minus.circle") }.buttonStyle(.borderless)
                    }
                    .font(.sans(12))
                }
                HStack {
                    Button("Add position from the camera now") { ptz.saveShot("", camera: camera.id, kind: .position) }
                    Button("Add exposure from the camera now") { ptz.saveShot("", camera: camera.id, kind: .exposure) }
                }
                let presets = ptz.presetNames(camera)
                if !presets.isEmpty {
                    Text("Stored on the camera").font(.sans(11, .semibold)).foregroundStyle(T.inkSubtle).padding(.top, T.s2)
                    ForEach(presets.keys.sorted(), id: \.self) { n in
                        HStack(spacing: T.s2) {
                            Text("\(n)").font(.sans(12)).foregroundStyle(T.inkSubtle).frame(width: 24, alignment: .trailing)
                            Text(presets[n] ?? "").font(.sans(12)).frame(width: 160, alignment: .leading)
                            Text((ptz.exposurePresets[camera.id]?.contains(n) ?? false) ? "Exposure" : "Position")
                                .font(.sans(11)).foregroundStyle(T.inkMuted).frame(width: 70, alignment: .leading)
                            Button("Recall") { ptz.recall(n, camera: camera.id) }
                            Button("Delete from camera…") { deletingPreset = n }
                        }
                    }
                }
            }
            .padding(.top, 6)
            .buttonStyle(CueButton())
        } label: {
            Text("\(camera.shots.count) saved shot\(camera.shots.count == 1 ? "" : "s"), \(ptz.presetNames(camera).count) on the camera")
                .font(.sans(12, .semibold)).foregroundStyle(T.inkMuted)
        }
        .confirmationDialog("Delete \"\(deletingPreset.flatMap { ptz.presetNames(camera)[$0] } ?? "this preset")\" from \(camera.name)?",
                            isPresented: Binding(get: { deletingPreset != nil }, set: { if !$0 { deletingPreset = nil } })) {
            Button("Delete from camera", role: .destructive) {
                if let n = deletingPreset {
                    ptz.deleteCameraPreset(n, camera: camera.id) { why in
                        if let why { problem = "Couldn't delete that preset from \(camera.name). \(why)" }
                    }
                }
                deletingPreset = nil
            }
        } message: {
            Text("This removes it from the camera itself, for every controller that uses it. It can't be undone.")
        }
        .alert(problem ?? "", isPresented: Binding(get: { problem != nil }, set: { if !$0 { problem = nil } })) {
            Button("OK", role: .cancel) {}
        }
    }

    func number(_ label: String, _ v: Binding<Int>) -> some View {
        HStack(spacing: 4) {
            Text(label).font(.sans(11)).foregroundStyle(T.inkSubtle)
            TextField("", value: v, format: .number.grouping(.never)).textFieldStyle(CueFieldStyle()).frame(width: 64)
        }
    }

    /// One exposure value as a plain number for editing (0 when the shot doesn't set it).
    func exposure(_ s: Binding<PTZShot>, _ k: WritableKeyPath<PTZExposure, Int?>) -> Binding<Int> {
        Binding(get: { s.wrappedValue.exposure?[keyPath: k] ?? 0 },
                set: { v in var e = s.wrappedValue.exposure ?? PTZExposure(); e[keyPath: k] = v; s.wrappedValue.exposure = e })
    }

    func move(_ id: UUID, _ d: Int) {
        guard let i = camera.shots.firstIndex(where: { $0.id == id }), camera.shots.indices.contains(i + d) else { return }
        camera.shots.swapAt(i, i + d)
    }
}

// MARK: - Status

/// What CueVideo knows and what it has sent, for whoever is looking after the system.
struct StatusTab: View {
    @EnvironmentObject var booth: Booth
    @EnvironmentObject var atem: ATEMClient
    @EnvironmentObject var ptz: PTZController
    @EnvironmentObject var store: ConfigStore

    var body: some View {
        Page {
            PageHeader(title: "Status", purpose: "How Churchfront Video is talking to the switcher and cameras right now.") {
                Button("Copy report") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(StatusReport.text(booth), forType: .string)
                }
                .buttonStyle(CueButton())
                .help("Copies everything on this page as text, ready to paste to Claude or the system owner")
            }
            HStack(alignment: .top, spacing: T.s4) {
                Card(title: "Switcher") { grid(StatusReport.switcherRows(booth)) }
                Card(title: "Setup file") { grid(StatusReport.configRows(store)) }
            }
            VStack(alignment: .leading, spacing: T.s3) {
                Text("Cameras").panelLabel()
                TimelineView(.periodic(from: .now, by: 1)) { _ in
                    // Three to a row. Not a lazy grid: its rows are measured before the text wraps.
                    VStack(alignment: .leading, spacing: T.s3) {
                        ForEach(Array(stride(from: 0, to: ptz.cameras.count, by: 3)), id: \.self) { start in
                            HStack(alignment: .top, spacing: T.s3) {
                                ForEach(ptz.cameras[start..<min(start + 3, ptz.cameras.count)]) { c in
                                    Card(title: c.name) { grid(Array(StatusReport.cameraRows(c, booth).dropFirst())) }
                                }
                            }
                        }
                    }
                }
            }
            Card(title: "Commands sent to the switcher",
                 help: "Newest first. Only commands from this Mac show here; the switcher's own panel and other software aren't listed.") {
                if atem.sentLog.isEmpty {
                    Text("Nothing sent yet.").font(.sans(12)).foregroundStyle(T.inkSubtle)
                }
                ForEach(atem.sentLog.reversed()) { e in
                    HStack(spacing: T.s3) {
                        Text(StatusReport.time(e.time)).font(.system(size: 12, design: .monospaced)).foregroundStyle(T.inkSubtle)
                        Text(e.command).font(.system(size: 12, design: .monospaced)).foregroundStyle(T.inkMuted).frame(width: 44, alignment: .leading)
                        Text(e.describe(atem.state)).font(.sans(12))
                        if !e.sent { Text("not sent, switcher offline").font(.sans(11, .semibold)).foregroundStyle(T.warning) }
                    }
                }
            }
        }
    }

    func grid(_ rows: [(String, String)]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(rows.indices, id: \.self) { i in
                HStack(alignment: .top, spacing: T.s3) {
                    Text(rows[i].0).font(.sans(12)).foregroundStyle(T.inkSubtle).frame(width: 120, alignment: .leading)
                    Text(rows[i].1).font(.sans(12)).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }
}

enum StatusReport {
    static func time(_ d: Date) -> String {
        let f = DateFormatter(); f.dateFormat = "HH:mm:ss.SSS"; return f.string(from: d)
    }

    static func switcherRows(_ b: Booth) -> [(String, String)] {
        let s = b.atem.state
        let link: String = {
            switch b.atem.link {
            case .online: return "Online"
            case .connecting: return "Connecting"
            case .offline(let why): return "Offline: \(why)"
            case .idle: return "Not set up"
            }
        }()
        var rows: [(String, String)] = [
            ("Connection", "\(link), \(b.atem.host.isEmpty ? "no address" : "\(b.atem.host) UDP 9910")"),
            ("Model", s.product.isEmpty ? "Unknown until connected" : "\(s.product), protocol \(s.version)"),
            ("Size", "\(s.meCount) M/E, \(s.keyerCount) keys, \(s.dskCount) DSKs, \(s.auxCount) aux, \(s.inputs.count) sources"),
            ("The operator runs", "M/E \(b.me + 1)"),
        ]
        for me in 0..<s.meCount {
            rows.append(("M/E \(me + 1)", "Live \(s.inputs[s.program[me] ?? -1]?.long ?? "?"), Next \(s.inputs[s.preview[me] ?? -1]?.long ?? "?")"
                         + ((s.ftbBlack[me] ?? false) ? ", faded to black" : "")))
        }
        func name(_ i: Int?) -> String { i.map { s.inputs[$0]?.long ?? "input \($0)" } ?? "?" }
        for me in s.keyFill.keys.sorted() {
            for k in (s.keyFill[me] ?? [:]).keys.sorted() {
                rows.append(("M/E \(me + 1) Key \(k + 1)", "fill \(name(s.keyFill[me]?[k])), key \(name(s.keyCut[me]?[k]))"
                             + ((s.keyOnAir[me]?[k] ?? false) ? ", ON AIR" : "")))
            }
        }
        for d in s.dskFill.keys.sorted() {
            rows.append(("DSK \(d + 1)", "fill \(name(s.dskFill[d])), key \(name(s.dskCut[d]))" + ((s.dskOnAir[d] ?? false) ? ", ON AIR" : "")))
        }
        if s.hasStreaming || s.hasRecording {
            rows.append(("Stream and record", "\(s.hasStreaming ? (s.streaming ? "streaming" : "not streaming") : "no streaming"), \(s.hasRecording ? (s.recording ? "recording" : "not recording") : "no recording")"))
        }
        rows.append(("USB picture", usbPicture(b)))
        return rows
    }

    /// The switcher's USB video on this Mac: what it shows and whether it's coming in.
    static func usbPicture(_ b: Booth) -> String {
        let s = b.atem.state
        guard USBFeedHub.available else { return "No switcher on this Mac's USB (plug the ATEM Mini's USB into the Mac to see HDMI-only cameras)" }
        guard let aux = b.store.usbAux(s) else { return "A Blackmagic video device is on USB, but usbAux isn't set and this model doesn't say which output it carries" }
        let carries = aux == 0 ? "Program" : "aux \(aux): \(b.store.routeLabel(s.aux[aux - 1], s))"
        let shows = b.store.usbInput(s).map { "input \($0) (\(b.store.label($0, s)))" } ?? "no input (nothing to show)"
        let feed = USBFeedHub.shared.feed
        let state: String = {
            switch USBFeedHub.shared.isLive {
            case .some(true): return "coming in" + (feed.shape.isEmpty ? "" : ", \(feed.shape)")
            case .some(false): return feed.problem ?? "waiting for frames"
            case .none: return "not showing on screen right now"
            }
        }()
        return "\(feed.deviceName ?? "Blackmagic Design") carries \(carries), so it shows \(shows). \(state.prefix(1).uppercased() + state.dropFirst())"
    }

    static func cameraRows(_ c: PTZCamera, _ b: Booth) -> [(String, String)] {
        let s = b.atem.state
        let input = c.atemInput.map { "\(s.inputs[$0]?.long ?? "input \($0)") (input \($0))" } ?? "not set"
        let picture: String = {
            guard c.proto == .canonXC else {
                guard let n = b.store.ndi(c.atemInput) else {
                    return c.atemInput == nil ? "No switcher input set, so no picture" : "No NDI picture set for its input (Setup > Volunteer source row)"
                }
                switch NDIFeedHub.shared.isLive(n) {
                case .some(true): return "Coming in (NDI, \(n))"
                case .some(false): return "Waiting for NDI source \(n)"
                case .none: return "Not showing on screen right now (NDI, \(n))"
                }
            }
            switch CanonFeedHub.shared.isLive(c) {
            case .some(true): return "Coming in (Canon video.cgi, motion JPEG)"
            case .some(false): return "Connecting or stopped"
            case .none: return "Not showing on screen right now"
            }
        }()
        let presets = b.ptz.presetNames(c)
        return [
            ("Camera", c.name),
            ("Address", "\(c.host):\(c.port), \(c.proto.label)"),
            ("Control", b.ptz.online.contains(c.id) ? "Answering\(b.ptz.models[c.id].map { ", \($0)" } ?? "")" : "Not answering"),
            ("Switcher input", input),
            ("Picture", picture),
            ("Saved shots", presets.isEmpty ? "None named" : presets.keys.sorted().map { "\($0) \(presets[$0]!)" }.joined(separator: ", ")),
        ]
    }

    static func configRows(_ store: ConfigStore) -> [(String, String)] {
        [
            ("File", store.url.path),
            ("Last read", store.loadedAt.map { time($0) } ?? "Not read this session"),
            ("Problem", store.fileError ?? "None"),
        ]
    }

    /// Everything above as text.
    static func text(_ b: Booth) -> String {
        var out = "Churchfront Video status, \(Date().formatted(date: .abbreviated, time: .standard))\n\nSWITCHER\n"
        out += switcherRows(b).map { "\($0.0): \($0.1)" }.joined(separator: "\n")
        out += "\n\nCAMERAS\n"
        out += b.ptz.cameras.map { c in cameraRows(c, b).map { "\($0.0): \($0.1)" }.joined(separator: "\n") }.joined(separator: "\n\n")
        out += "\n\nCOMMANDS SENT (newest first)\n"
        out += b.atem.sentLog.reversed().map { "\(time($0.time)) \($0.command) \($0.describe(b.atem.state))\($0.sent ? "" : " [not sent]")" }.joined(separator: "\n")
        out += "\n\nCONFIG\n" + configRows(b.store).map { "\($0.0): \($0.1)" }.joined(separator: "\n")
        if let data = try? Data(contentsOf: b.store.url), let json = String(data: data, encoding: .utf8) { out += "\n\n" + json }
        return out
    }
}

/// Picks an NDI source from those on the network (or none). Lists them fresh each time it opens.
struct NDIPicker: View {
    let selection: String?
    let none: String
    let set: (String?) -> Void
    @ObservedObject var ndi = NDIMonitor.shared

    var body: some View {
        MenuField(text: selection.map(NDIMonitor.shortName) ?? none, icon: "dot.radiowaves.left.and.right") {
            Button(none) { set(nil) }
            Divider()
            if !ndi.hasRuntime {
                Text("NDI isn't installed on this Mac (install NDI Tools)")
            } else if ndi.sources.isEmpty {
                Text("No NDI sources found yet")
            }
            ForEach(ndi.sources, id: \.self) { n in
                Button { set(n) } label: { Text(NDIMonitor.shortName(n)) + Text(n == selection ? "  ✓" : "") }
            }
            Divider()
            Button("Look again") { ndi.scan() }
        }
        .onAppear { ndi.scan() }
    }
}


/// Setup > AI assistant: one button that adds Churchfront Video to the Claude desktop app.
struct AssistantSetup: View {
    @State private var state = ClaudeConnect.state()
    @State private var note: String?
    @State private var copied = false

    var body: some View {
        Card(title: "Claude") {
            switch state {
            case .runFromDownloads:
                Text("Move Churchfront Video to your Applications folder and open it from there, then come back here to connect Claude.")
                    .font(.sans(13)).fixedSize(horizontal: false, vertical: true)
            case .noClaude:
                Text("Install the Claude desktop app first. It's free.").font(.sans(13))
                HStack(spacing: T.s2) {
                    Button("Get Claude for Mac") { NSWorkspace.shared.open(URL(string: "https://claude.ai/download")!) }.buttonStyle(CueButton(kind: .primary))
                    Button("I've installed it") { state = ClaudeConnect.state() }.buttonStyle(CueButton())
                }
            case .notConnected, .stalePath:
                Text(state == .stalePath ? "Claude is connected to another copy of Churchfront Video. Connect it to this one." : "Claude isn't connected yet.")
                    .font(.sans(13))
                Button("Connect Claude") {
                    note = ClaudeConnect.connect()
                    state = ClaudeConnect.state()
                }
                .buttonStyle(CueButton(kind: .primary))
            case .connected:
                Text("Connected. Quit Claude (Claude > Quit) and open it again, then ask it something like:")
                    .font(.sans(13)).fixedSize(horizontal: false, vertical: true)
                Text(ClaudeConnect.firstPrompt).font(.sans(13, .semibold)).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                HStack(spacing: T.s2) {
                    Button(copied ? "Copied" : "Copy this") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(ClaudeConnect.firstPrompt, forType: .string)
                        copied = true
                    }
                    .buttonStyle(CueButton(kind: .primary))
                    Button("Disconnect") { note = ClaudeConnect.disconnect(); state = ClaudeConnect.state(); copied = false }.buttonStyle(CueButton(kind: .quiet))
                }
            }
            if let note {
                Text(note).font(.sans(12, .semibold)).foregroundStyle(T.danger).fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: 760, alignment: .leading)
        .onAppear { state = ClaudeConnect.state() }
    }
}
