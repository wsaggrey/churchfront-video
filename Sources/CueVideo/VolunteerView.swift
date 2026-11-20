import SwiftUI
import CueATEM

/// The volunteer's screen, built around three steps: pick what's next, frame it, take it live.
/// Top half: the Next and Live monitors and the source row. Bottom half: saved shots, camera
/// control (center, under the tiles) and the take buttons. Everything else lives in Setup and the Full Switcher window.
struct VolunteerView: View {
    @AppStorage("showExposure") private var showExposure = false
    @EnvironmentObject var store: ConfigStore
    @EnvironmentObject var booth: Booth
    @EnvironmentObject var atem: ATEMClient
    @EnvironmentObject var ptz: PTZController

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: T.s3) {
                HStack(spacing: T.s3) {
                    BusMonitor(title: "Next", input: atem.state.preview[booth.me], color: T.preview)
                    BusMonitor(title: "Live", input: atem.state.program[booth.me], color: T.program)
                }
                .frame(maxHeight: .infinity)
                SourceRow()
            }
            .padding(T.s4)
            Rectangle().fill(T.line).frame(height: 1)
            // Camera control sits bottom center, right under the source tiles, so the mouse
            // travels as little as possible: pick a tile, drop straight down to frame it.
            // Left to right: exposure, saved shots, the joystick (center), then take right beside it.
            HStack(alignment: .top, spacing: T.s6) {
                VStack(alignment: .leading, spacing: T.s2) {
                    HStack(spacing: T.s2) {
                        NextCameraHeader()
                        Spacer()
                        // Exposure for the camera on Next, shown when wanted, so the shot grid
                        // gets the room the rest of the time.
                        PillButton(title: "Exposure", icon: "camera.aperture", active: showExposure) { showExposure.toggle() }
                            .help(showExposure ? "Hide exposure" : "Show gain, shutter, iris and white balance for the camera on Next")
                    }
                    HStack(alignment: .top, spacing: T.s4) {
                        if showExposure { ExposurePanel() }
                        PresetGrid().frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                FramePanel().fixedSize()
                TakePanel().frame(width: 250).frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(T.s4)
            .frame(height: 290)
            .background(T.surface)
        }
        // The camera controls always drive whatever camera is on Next, so the Live
        // camera can't be moved by accident.
        .onAppear { ptz.follow(atemInput: atem.state.preview[booth.me]) }
        .onChange(of: atem.state.preview[booth.me]) { _, v in ptz.follow(atemInput: v) }
    }
}

/// A numbered step label: 1 Pick, 2 Frame, 3 Take.
struct StepLabel: View {
    let n: Int
    let text: String
    var body: some View {
        HStack(spacing: T.s2) {
            Text("\(n)").font(.sans(12, .bold)).foregroundStyle(T.onAction)
                .frame(width: 20, height: 20).background(Circle().fill(T.accent))
            Text(text).panelLabel()
        }
    }
}

/// The Next or Live picture: the camera's own preview when a Canon camera is on that bus,
/// otherwise the source's name written large.
struct BusMonitor: View {
    @EnvironmentObject var booth: Booth
    let title: String
    let input: Int?
    let color: Color
    @EnvironmentObject var atem: ATEMClient
    @EnvironmentObject var ptz: PTZController
    @EnvironmentObject var store: ConfigStore
    @ObservedObject var tracker = AutoTracker.shared

    /// Held over Live for a moment after a fade ends, if the switcher reports the fade
    /// finished before it reports the new Live source, so the old shot can't flash back.
    @State private var tail: Int?

    var camera: PTZCamera? { camera(on: input) }

    func camera(on input: Int?) -> PTZCamera? { ptz.pictured(on: input, store) }

    /// The shot coming in while a fade runs, and how far in it is (0 to 1).
    struct Incoming: Equatable { var input: Int?; var amount: Double; var dip: Bool }

    /// Live shows the fade the way the switcher's output does: Next comes in over Live as
    /// the transition runs. Only when the transition takes the background (not just a key).
    var incoming: Incoming? {
        guard title == "Live" else { return nil }
        let s = atem.state, me = booth.me
        guard s.inTransition[me] == true, (s.nextSelection[me] ?? 1) & 1 != 0 else { return nil }
        return Incoming(input: s.preview[me], amount: min(1, max(0, s.position[me] ?? 0)), dip: s.style[me] == 1)
    }

    /// A source's picture: the camera's own preview, its NDI picture, or its name.
    @ViewBuilder func picture(_ input: Int?, pick: Bool) -> some View {
        if let camera = camera(on: input) {
            CameraVideo(camera: camera, onPick: pick ? self.pick(camera) : nil).id(camera.id)
        } else if let n = store.ndi(input) {
            NDIVideo(source: n).id(n)
        } else if store.usbShows(input, atem.state) {
            // An HDMI-only camera: seen through the switcher's USB output while it's on it.
            USBVideo().id("usb")
        } else {
            Text(store.label(input, atem.state))
                .font(.sans(34, .bold)).foregroundStyle(T.inkMuted)
                .lineLimit(2).minimumScaleFactor(0.4).multilineTextAlignment(.center).padding(T.s6)
        }
    }

    var keyOverlays: [String] {
        let s = atem.state
        let keys = store.config.keys.filter { k in
            guard let n = k.ndi, !n.isEmpty, n != store.ndi(input) else { return false }
            guard k.dsk != nil || (k.me ?? 1) - 1 == booth.me else { return false }
            return title == "Live" ? k.isOn(s) : k.onNext(s)
        }
        var seen = Set<String>()
        return keys.compactMap(\.ndi).filter { seen.insert($0).inserted }
    }

    /// Clicking a person on Next follows them. On Live, a click only switches who an
    /// already-tracking camera follows, so a stray click can't start moving the live shot.
    func pick(_ camera: PTZCamera) -> ((CGPoint) -> Void)? {
        guard title == "Next" || tracker.isTracking(camera.id) else { return nil }
        return { p in tracker.start(camera, at: p) }
    }

    var body: some View {
        ZStack {
            Color.black
            picture(input, pick: true)
            if let f = incoming {
                // A mix is Next laid over Live, more solid as it goes. A dip goes down to
                // black by halfway, then up to Next.
                let showNext = f.dip ? f.amount >= 0.5 : true
                ZStack {
                    Color.black
                    if showNext { picture(f.input, pick: false) }
                }
                .opacity(f.dip ? (f.amount < 0.5 ? f.amount * 2 : 1) : f.amount)
                .allowsHitTesting(false)
                if f.dip, f.amount >= 0.5 { Color.black.opacity((1 - f.amount) * 2).allowsHitTesting(false) }
            } else if let tail, tail != input {
                ZStack { Color.black; picture(tail, pick: false) }.allowsHitTesting(false)
            }
            // Lower thirds and other keys with an NDI picture, laid over the shot when the
            // key is on it: on Live when it's on air, on Next when it will be after the take.
            ForEach(keyOverlays, id: \.self) { n in NDIVideo(source: n, overlay: true).id("key-" + n) }
        }
        // Video is shown square-cornered, the shape of the picture itself.
        .clipShape(Rectangle())
        .overlay(Rectangle().stroke(color, lineWidth: 3))
        .overlay(alignment: .topLeading) {
            Text(title.uppercased()).font(.sans(13, .bold)).tracking(1.2)
                .foregroundStyle(title == "Next" ? T.onAction : .white)
                .padding(.horizontal, 10).frame(height: 26)
                .background(RoundedRectangle(cornerRadius: T.rSM).fill(color))
                .padding(T.s3)
        }
        .overlay(alignment: .topTrailing) {
            if let camera, let s = tracker.sessions[camera.id] {
                TrackingBadge(phase: s.phase) { tracker.stop(camera.id) }.padding(T.s3)
            }
        }
        .overlay(alignment: .bottomLeading) {
            if camera != nil || store.ndi(input) != nil || store.usbShows(input, atem.state) {
                Text(store.label(input, atem.state)).font(.sans(15, .semibold)).foregroundStyle(.white)
                    .padding(.horizontal, 10).frame(height: 28)
                    .background(Capsule().fill(Color.black.opacity(0.6)))
                    .padding(T.s3)
            }
        }
        .aspectRatio(16 / 9, contentMode: .fit)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onChange(of: incoming) { old, new in
            guard new == nil, let old, old.amount > 0.5, let to = old.input, to != input else { return }
            tail = to
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { if tail == to { tail = nil } }
        }
        .onChange(of: input) { _, _ in tail = nil }
    }
}

/// The sources a volunteer needs, as big tiles. Tap one to put it on Next.
struct SourceRow: View {
    @EnvironmentObject var booth: Booth
    @EnvironmentObject var atem: ATEMClient
    @EnvironmentObject var ptz: PTZController
    @EnvironmentObject var store: ConfigStore

    var body: some View {
        let sources = store.volunteerSources(atem.state)
        // Centered, so the camera control below sits right under the tiles.
        VStack(alignment: .center, spacing: T.s2) {
            if sources.isEmpty {
                Text("No sources set up yet. Add them in Setup (⌘,).").font(.sans(13)).foregroundStyle(T.inkMuted)
                    .frame(height: 96)
            } else {
                HStack(spacing: T.s2) {
                    ForEach(sources) { s in SourceTile(source: s) }
                }
                .frame(height: 96)
            }
        }
        .frame(maxWidth: .infinity)
    }
}

struct SourceTile: View {
    let source: VolunteerSource
    @ObservedObject var tracker = AutoTracker.shared
    @EnvironmentObject var booth: Booth
    @EnvironmentObject var atem: ATEMClient
    @EnvironmentObject var ptz: PTZController
    @EnvironmentObject var store: ConfigStore

    var camera: PTZCamera? { ptz.pictured(on: source.input, store) }
    var isLive: Bool { atem.state.program[booth.me] == source.input }
    var isNext: Bool { atem.state.preview[booth.me] == source.input }

    var body: some View {
        Button { atem.setPreview(source.input, me: booth.me) } label: {
            ZStack(alignment: .bottomLeading) {
                if let camera {
                    CameraVideo(camera: camera).id(camera.id)
                } else if let n = source.ndi, !n.isEmpty {
                    NDIVideo(source: n).id(n)
                } else if store.usbShows(source.input, atem.state) {
                    USBVideo().id("usb")
                } else {
                    T.surfaceRaised
                }
                HStack(spacing: 6) {
                    Text(store.label(source.input, atem.state)).font(.sans(14, .semibold)).lineLimit(1)
                    if isLive { badge("LIVE", T.program) } else if isNext { badge("NEXT", T.preview) }
                    if let camera, AutoTracker.shared.isTracking(camera.id) {
                        Image(systemName: "figure.walk").font(.system(size: 11, weight: .bold)).foregroundStyle(T.accent)
                    }
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 8).frame(height: 26)
                .background(Capsule().fill(Color.black.opacity(camera == nil && (source.ndi ?? "").isEmpty ? 0 : 0.6)))
                .padding(6)
            }
            .frame(maxWidth: 220, maxHeight: .infinity)
            .aspectRatio(16 / 9, contentMode: .fit)
            .clipShape(Rectangle())
            .overlay(Rectangle()
                .stroke(isLive ? T.program : (isNext ? T.preview : T.line), lineWidth: isLive || isNext ? 3 : 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(PressStyle())
        .help("Put \(store.label(source.input, atem.state)) on Next")
    }

    func badge(_ s: String, _ c: Color) -> some View {
        Text(s).font(.sans(10, .bold)).foregroundStyle(c == T.preview ? T.onAction : .white)
            .padding(.horizontal, 5).frame(height: 16)
            .background(RoundedRectangle(cornerRadius: T.rSM).fill(c))
    }
}

/// Step 2: frame the camera that's on Next.
struct FramePanel: View {
    @EnvironmentObject var booth: Booth
    @EnvironmentObject var atem: ATEMClient
    @EnvironmentObject var ptz: PTZController
    @EnvironmentObject var store: ConfigStore

    /// The camera on Next, if Next is a camera.
    var target: PTZCamera? {
        guard let i = atem.state.preview[booth.me] else { return nil }
        return ptz.cameras.first { $0.atemInput == i && !$0.host.isEmpty }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: T.s3) {
            HStack(alignment: .center, spacing: T.s4) {
                Joystick { x, y in ptz.drive(x: x, y: y) } onEnd: { ptz.stopDrive() }
                    .frame(width: 170, height: 170)
                ZoomRocker { ptz.zoom($0) }.frame(width: 44, height: 170)
                VStack(alignment: .leading, spacing: T.s2) {
                    SmallButton("Focus") { ptz.focusOnce() }.frame(width: 140)
                        .help("Focus once on what's in the middle of the shot (⇧⌘F). Camera > Auto Focus (⌥⌘F) hands focus back to the camera if it was left in manual focus.")
                    if let t = target { TrackButton(camera: t).frame(width: 140) }
                    if let t = target, !ptz.online.contains(t.id) {
                        Text("Not answering").font(.sans(11, .semibold)).foregroundStyle(T.warning)
                    } else if let t = target, !ptz.hasControl(t) {
                        Text("Waiting for control. Another controller has \(t.name), maybe its web page. Close it and this takes over.")
                            .font(.sans(11, .semibold)).foregroundStyle(T.warning).frame(width: 140, alignment: .leading)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .opacity(target == nil ? 0.35 : 1)
            .allowsHitTesting(target != nil)
            CameraSpeedDial()
            .overlay {
                if target == nil {
                    Text("Put a camera on Next to frame it")
                        .font(.sans(13, .semibold)).foregroundStyle(T.ink)
                        .padding(.horizontal, T.s3).padding(.vertical, T.s2)
                        .background(RoundedRectangle(cornerRadius: T.rMD).fill(T.surfaceRaised))
                }
            }
        }
        .onAppear { if let t = target { ptz.selected = t.id } }
        .onChange(of: target?.id) { _, id in if let id { ptz.selected = id } }
    }
}

/// How fast the joystick, zoom and arrow keys move the cameras: slow for fine framing on a
/// tight shot, fast for big moves. Shared by every camera and saved in the setup.
struct CameraSpeedDial: View {
    @EnvironmentObject var store: ConfigStore
    @State private var value = 1.0

    var body: some View {
        HStack(spacing: T.s2) {
            Image(systemName: "tortoise").font(.system(size: 11)).foregroundStyle(T.inkSubtle)
            Slider(value: $value, in: 0.25...2) { editing in
                if !editing { store.update { $0.ptzSpeed = (value * 20).rounded() / 20 } }
            }
            .controlSize(.small).frame(width: 150)
            Image(systemName: "hare").font(.system(size: 11)).foregroundStyle(T.inkSubtle)
            Text(String(format: "%.2g×", value)).font(.system(size: 11, design: .monospaced)).foregroundStyle(T.inkMuted).frame(width: 36, alignment: .leading)
            Button("Reset") { value = 1; store.update { $0.ptzSpeed = 1 } }
                .buttonStyle(.borderless).font(.sans(11)).foregroundStyle(T.inkSubtle)
                .opacity(abs(value - 1) < 0.01 ? 0 : 1)
        }
        .help("Camera speed for the joystick, zoom and arrow keys. Slow it down for fine framing on a tight shot.")
        .onAppear { value = store.config.ptzSpeed }
        .onChange(of: store.config.ptzSpeed) { _, v in value = v }
    }
}

/// Names the camera that exposure and saved shots act on: always the one on Next.
struct NextCameraHeader: View {
    @EnvironmentObject var booth: Booth
    @EnvironmentObject var atem: ATEMClient
    @EnvironmentObject var ptz: PTZController
    @EnvironmentObject var store: ConfigStore

    var body: some View {
        let next = atem.state.preview[booth.me]
        let cam = ptz.cameras.first { $0.atemInput == next && !$0.host.isEmpty }
        HStack(spacing: T.s2) {
            Image(systemName: cam == nil ? "video.slash" : "video.fill").font(.system(size: 13, weight: .semibold))
            Text(cam?.name ?? "No camera on Next").font(.sans(16, .bold))
            if cam != nil {
                Text("ON NEXT").font(.sans(10, .bold)).tracking(1).foregroundStyle(T.onAction)
                    .padding(.horizontal, 6).frame(height: 18)
                    .background(RoundedRectangle(cornerRadius: T.rSM).fill(T.preview))
            } else {
                Text(store.label(next, atem.state)).font(.sans(13)).foregroundStyle(T.inkSubtle)
            }
        }
        .foregroundStyle(cam == nil ? T.inkMuted : T.ink)
        .padding(.horizontal, T.s3).frame(height: 32)
        .background(RoundedRectangle(cornerRadius: T.rMD).fill(T.surfaceSunken))
        .overlay(RoundedRectangle(cornerRadius: T.rMD).stroke(cam == nil ? T.line : T.preview, lineWidth: cam == nil ? 1 : 2))
        .help("Exposure and saved shots below act on the camera that's on Next.")
    }
}

/// Bottom left: exposure for the camera on Next.
struct ExposurePanel: View {
    @EnvironmentObject var booth: Booth
    @EnvironmentObject var atem: ATEMClient
    @EnvironmentObject var ptz: PTZController

    var target: PTZCamera? {
        guard let i = atem.state.preview[booth.me] else { return nil }
        return ptz.cameras.first { $0.atemInput == i && !$0.host.isEmpty }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: T.s3) {
            Text("Exposure").panelLabel().frame(height: 20)
            if let t = target, ptz.canSaveShots(t) {
                HStack(alignment: .top, spacing: T.s3) {
                    ExposureControls(camera: t)
                    ExposureShots(camera: t)
                }
            } else {
                Text(target == nil ? "Put a camera on Next" : "Not available for this camera")
                    .font(.sans(12)).foregroundStyle(T.inkSubtle).frame(width: 200, alignment: .leading)
            }
        }
        .frame(alignment: .leading)
    }
}

/// Exposure shots for the camera on Next, beside its exposure controls: the ones saved in
/// CueVideo and the exposure presets stored on the camera. Tap to apply, Save exposure to
/// keep the camera's exposure now (gain, shutter, iris, white balance), right-click to
/// update, rename or delete.
struct ExposureShots: View {
    let camera: PTZCamera
    @EnvironmentObject var ptz: PTZController
    @State private var saving = false
    @State private var newName = ""
    @State private var renaming: PTZShot?
    @State private var deleting: PTZShot?
    @State private var problem: String?
    @State private var lastUsed: String?

    var body: some View {
        let shots = camera.shots.filter { $0.kind == .exposure }
        let presets = (ptz.exposurePresets[camera.id] ?? []).sorted()
        VStack(alignment: .leading, spacing: 4) {
            Button { newName = ""; saving = true } label: {
                Label("Save exposure", systemImage: "plus").font(.sans(11, .bold)).foregroundStyle(T.accentStrong)
            }
            .buttonStyle(.plain)
            .help("Save \(camera.name)'s exposure now (gain, shutter, iris and white balance) as a shot")
            .popover(isPresented: $saving, arrowEdge: .top) { savePopover }
            ScrollView {
                VStack(spacing: 4) {
                    ForEach(shots) { s in
                        item(s.name, nil, used: lastUsed == "shot:\(s.id)") { ptz.go(to: s, camera: camera.id); lastUsed = "shot:\(s.id)" }
                            .contextMenu {
                                Button("Update to the camera's exposure now") {
                                    ptz.saveShot("", camera: camera.id, kind: .exposure, replacing: s.id) { if !$0 { problem = PresetGrid.noReading } }
                                }
                                Button("Rename…") { newName = s.name; renaming = s }
                                Divider()
                                Button("Delete…") { deleting = s }
                            }
                    }
                    ForEach(presets, id: \.self) { n in
                        item(ptz.presetNames(camera)[n] ?? "Preset \(n)", "ON CAMERA", used: lastUsed == "preset:\(n)") {
                            ptz.recall(n, camera: camera.id); lastUsed = "preset:\(n)"
                        }
                    }
                    if shots.isEmpty && presets.isEmpty {
                        Text("No exposure shots yet.").font(.sans(11)).foregroundStyle(T.inkSubtle)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        }
        .frame(width: 140)
        .onChange(of: camera.id) { _, _ in lastUsed = nil }
        .alert("Rename exposure shot", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Bright stage", text: $newName)
            Button("Save") {
                let name = newName.trimmingCharacters(in: .whitespaces)
                if let r = renaming, !name.isEmpty, let i = ptz.cameras.firstIndex(where: { $0.id == camera.id }),
                   let j = ptz.cameras[i].shots.firstIndex(where: { $0.id == r.id }) { ptz.cameras[i].shots[j].name = name }
                renaming = nil
            }
            Button("Cancel", role: .cancel) { renaming = nil }
        }
        .confirmationDialog("Delete \(deleting?.name ?? "this shot")?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
            Button("Delete", role: .destructive) {
                if let d = deleting, let i = ptz.cameras.firstIndex(where: { $0.id == camera.id }) {
                    ptz.cameras[i].shots.removeAll { $0.id == d.id }
                }
                deleting = nil
            }
        }
        .alert(problem ?? "", isPresented: Binding(get: { problem != nil }, set: { if !$0 { problem = nil } })) {
            Button("OK", role: .cancel) {}
        }
    }

    func item(_ title: String, _ subtitle: String?, used: Bool, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 0) {
                Text(title).font(.sans(12, .semibold)).lineLimit(1).minimumScaleFactor(0.75)
                if let subtitle { Text(subtitle).font(.sans(8, .bold)).tracking(0.5).opacity(0.7) }
            }
            .foregroundStyle(used ? T.onAction : T.ink)
            .frame(maxWidth: .infinity).frame(height: 30)
            .background(RoundedRectangle(cornerRadius: T.rSM).fill(used ? T.accent : T.surfaceRaised))
            .overlay(RoundedRectangle(cornerRadius: T.rSM).stroke(used ? T.accent : T.line))
            .contentShape(Rectangle())
        }
        .buttonStyle(PressStyle())
    }

    var savePopover: some View {
        VStack(alignment: .leading, spacing: T.s3) {
            Text("Save \(camera.name)'s exposure").font(.sans(14, .bold))
            Text("Gain, shutter, iris and white balance, as the camera has them now.").font(.sans(12)).foregroundStyle(T.inkMuted)
            TextField("Bright stage", text: $newName).textFieldStyle(.roundedBorder).onSubmit(save)
            HStack {
                Spacer()
                Button("Cancel") { saving = false }.keyboardShortcut(.cancelAction)
                Button("Save", action: save).keyboardShortcut(.defaultAction)
            }
        }
        .padding(T.s4)
        .frame(width: 300)
    }

    func save() {
        let name = newName.trimmingCharacters(in: .whitespaces)
        ptz.saveShot(name, camera: camera.id, kind: .exposure) { if !$0 { problem = PresetGrid.noReading } }
        saving = false
    }
}

/// Gain, shutter and iris for the camera on Next. Each row steps through the values the
/// camera accepts, with darker and brighter buttons rather than raw numbers to reason about.
struct ExposureControls: View {
    let camera: PTZCamera
    @EnvironmentObject var ptz: PTZController

    var body: some View {
        let e = ptz.exposure[camera.id] ?? CameraExposure()
        VStack(spacing: 6) {
            row("Gain", e.gainLabel(e.value.gain), auto: e.gainAuto, list: e.gainList, value: e.value.gain,
                brighterIsUp: true) { ptz.setExposure(PTZExposure(gain: $0), camera: camera.id) }
            row("Shutter", CameraExposure.shutterText(e.value.shutter), auto: e.shutterAuto, list: e.shutterList, value: e.value.shutter,
                brighterIsUp: false) { ptz.setExposure(PTZExposure(shutter: $0), camera: camera.id) }
            row("Iris", CameraExposure.irisText(e.value.iris), auto: e.irisAuto, list: e.irisList, value: e.value.iris,
                brighterIsUp: false) { ptz.setExposure(PTZExposure(iris: $0), camera: camera.id) }
            whiteBalance(e)
            if e.hasAutoMode {
                // One mode for all three on this camera: touching any of them takes it to
                // manual, and this hands them back.
                Button { ptz.autoExposure(camera: camera.id) } label: {
                    Text(e.allAuto ? "Auto exposure on" : "Auto exposure").font(.sans(12, .semibold))
                        .foregroundStyle(e.allAuto ? T.onAction : T.ink)
                        .frame(maxWidth: .infinity).frame(height: 28)
                        .background(RoundedRectangle(cornerRadius: T.rSM).fill(e.allAuto ? T.accent : T.surfaceRaised))
                        .overlay(RoundedRectangle(cornerRadius: T.rSM).stroke(e.allAuto ? T.accent : T.line))
                }
                .buttonStyle(PressStyle())
                .disabled(e.allAuto)
                .help("Let the camera set gain, shutter and iris itself")
            }
        }
        .frame(width: 200)
        .onAppear { ptz.refreshExposure(camera: camera.id) }
    }

    /// `brighterIsUp`: whether a bigger number makes the picture brighter (gain) or darker
    /// (shutter speed and f-number).
    func row(_ label: String, _ text: String, auto: Bool, list: [Int], value: Int?, brighterIsUp: Bool,
             set: @escaping (Int) -> Void) -> some View {
        let i = value.flatMap { v in list.firstIndex(of: v) ?? list.firstIndex { $0 >= v } }
        func step(_ brighter: Bool) {
            guard !list.isEmpty else { return }
            let up = brighter == brighterIsUp
            let j = max(0, min(list.count - 1, (i ?? 0) + (up ? 1 : -1)))
            set(list[j])
        }
        return HStack(spacing: 4) {
            Text(label).font(.sans(11, .semibold)).foregroundStyle(T.inkSubtle).frame(width: 46, alignment: .leading)
            stepButton("sun.min", "Darker") { step(false) }
            Text(auto ? "Auto" : text).font(.sans(13, .semibold)).monospacedDigit()
                .frame(maxWidth: .infinity).frame(height: 28)
                .background(RoundedRectangle(cornerRadius: T.rSM).fill(T.surfaceSunken))
            stepButton("sun.max", "Brighter") { step(true) }
        }
        .disabled(list.isEmpty)
    }

    /// White balance: cooler (bluer) and warmer (more orange) step through the camera's
    /// color temperatures; the middle opens auto, daylight, tungsten, common temperatures,
    /// and matching another camera.
    func whiteBalance(_ e: CameraExposure) -> some View {
        let list = e.kelvinList
        let k = e.value.kelvin
        let i = k.flatMap { v in list.firstIndex(of: v) ?? list.firstIndex { $0 >= v } }
        // A higher kelvin setting makes the picture warmer.
        func step(_ warmer: Bool) {
            guard !list.isEmpty else { return }
            let j = max(0, min(list.count - 1, (i ?? list.count / 2) + (warmer ? 2 : -2)))
            ptz.setExposure(PTZExposure(wb: "kelvin", kelvin: list[j]), camera: camera.id)
        }
        let others = ptz.cameras.filter { $0.id != camera.id && ptz.exposure[$0.id]?.value.wb != nil }
        return HStack(spacing: 4) {
            Text("White").font(.sans(11, .semibold)).foregroundStyle(T.inkSubtle).frame(width: 46, alignment: .leading)
            stepButton("snowflake", "Cooler (bluer)") { step(false) }
            Menu {
                Button("Auto") { ptz.setExposure(PTZExposure(wb: "auto"), camera: camera.id) }
                Button("Daylight") { ptz.setExposure(PTZExposure(wb: "daylight"), camera: camera.id) }
                Button("Tungsten") { ptz.setExposure(PTZExposure(wb: "tungsten"), camera: camera.id) }
                Divider()
                ForEach([3200, 4300, 5600], id: \.self) { v in
                    Button("\(v) K") { ptz.setExposure(PTZExposure(wb: "kelvin", kelvin: v), camera: camera.id) }
                }
                if !others.isEmpty {
                    Divider()
                    ForEach(others) { o in
                        let x = ptz.exposure[o.id]!.value
                        Button("Match \(o.name) (\(CameraExposure.wbText(x.wb, x.kelvin)))") {
                            ptz.setExposure(x.wb == "kelvin" ? PTZExposure(wb: "kelvin", kelvin: x.kelvin) : PTZExposure(wb: x.wb), camera: camera.id)
                        }
                    }
                }
            } label: {
                Text(CameraExposure.wbText(e.value.wb, k)).font(.sans(13, .semibold)).monospacedDigit()
                    .frame(maxWidth: .infinity).frame(height: 28)
                    .background(RoundedRectangle(cornerRadius: T.rSM).fill(T.surfaceSunken))
            }
            .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden)
            .help("White balance. Pick auto, daylight, tungsten, a color temperature, or match another camera.")
            stepButton("flame", "Warmer (more orange)") { step(true) }
        }
        .disabled(list.isEmpty && e.value.wb == nil)
    }

    func stepButton(_ icon: String, _ help: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).font(.system(size: 12, weight: .semibold)).frame(width: 30, height: 28)
                .background(RoundedRectangle(cornerRadius: T.rSM).fill(T.surfaceRaised))
                .overlay(RoundedRectangle(cornerRadius: T.rSM).stroke(T.line))
                .contentShape(Rectangle())
        }
        .buttonStyle(PressStyle())
        .help(help)
    }
}

/// Every camera's positions in one grid: a row per camera, its position shots and presets
/// across (exposure shots stay out of it). Tap one to send that camera there. The camera's
/// name puts it on Next. The + at the end of a row saves where that camera is now. Right-click a shot to update,
/// rename or delete it. A camera on Live asks before it moves.
struct PresetGrid: View {
    @EnvironmentObject var booth: Booth
    @EnvironmentObject var atem: ATEMClient
    @EnvironmentObject var ptz: PTZController
    @EnvironmentObject var store: ConfigStore

    @State private var savingFor: UUID?
    @State private var newName = ""
    @State private var renaming: (camera: UUID, shot: PTZShot)?
    @State private var deleting: (camera: UUID, shot: PTZShot)?
    @State private var deletingPreset: (camera: UUID, n: Int)?
    @State private var liveMove: (camera: UUID, run: () -> Void)?
    @State private var problem: String?
    /// The shot each camera was last sent to, lit in the grid.
    @State private var lastUsed: [UUID: String] = [:]

    var cams: [PTZCamera] { ptz.cameras.filter { !$0.host.isEmpty } }

    func onLive(_ c: PTZCamera) -> Bool { c.atemInput.map { (atem.state.tally[$0] ?? 0) & 1 != 0 } ?? false }
    func onNext(_ c: PTZCamera) -> Bool { c.atemInput == atem.state.preview[booth.me] }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Shots").panelLabel().frame(height: 16)
            if cams.isEmpty {
                Text("No cameras set up yet. Add them in Setup (⌘,).").font(.sans(12)).foregroundStyle(T.inkSubtle)
            }
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(cams) { c in row(c) }
                }
            }
        }
        .alert("Rename shot", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Pulpit", text: $newName)
            Button("Save") { rename() }
            Button("Cancel", role: .cancel) { renaming = nil }
        }
        .confirmationDialog("Delete \(deleting?.shot.name ?? "this shot")?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
            Button("Delete", role: .destructive) {
                if let d = deleting, let i = ptz.cameras.firstIndex(where: { $0.id == d.camera }) {
                    ptz.cameras[i].shots.removeAll { $0.id == d.shot.id }
                }
                deleting = nil
            }
        }
        .confirmationDialog(presetQuestion, isPresented: Binding(get: { deletingPreset != nil }, set: { if !$0 { deletingPreset = nil } })) {
            Button("Delete from camera", role: .destructive) {
                if let d = deletingPreset {
                    ptz.deleteCameraPreset(d.n, camera: d.camera) { why in
                        if let why { problem = "Couldn't delete that preset. \(why)" }
                    }
                }
                deletingPreset = nil
            }
        } message: {
            Text("This removes it from the camera itself, for every controller that uses it. It can't be undone.")
        }
        .confirmationDialog(liveQuestion, isPresented: Binding(get: { liveMove != nil }, set: { if !$0 { liveMove = nil } })) {
            Button("Move it on Live", role: .destructive) { liveMove?.run(); liveMove = nil }
        } message: {
            Text("Everyone watching will see the camera move.")
        }
        .alert(problem ?? "", isPresented: Binding(get: { problem != nil }, set: { if !$0 { problem = nil } })) {
            Button("OK", role: .cancel) {}
        }
    }

    func row(_ c: PTZCamera) -> some View {
        let live = onLive(c), next = onNext(c)
        return HStack(spacing: 6) {
            // The camera: tap to put it on Next.
            Button { if let i = c.atemInput { atem.setPreview(i, me: booth.me) } } label: {
                VStack(alignment: .leading, spacing: 1) {
                    Text(c.name).font(.sans(13, .bold)).lineLimit(1)
                    Text(live ? "LIVE" : (next ? "NEXT" : " ")).font(.sans(9, .bold)).tracking(0.8)
                        .foregroundStyle(live ? T.program : T.preview)
                }
                .foregroundStyle(T.ink)
                .padding(.horizontal, 8)
                .frame(width: 82, height: 40, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: T.rMD).fill(T.surfaceSunken))
                .overlay(RoundedRectangle(cornerRadius: T.rMD).stroke(live ? T.program : (next ? T.preview : T.line), lineWidth: live || next ? 2 : 1))
                .contentShape(Rectangle())
            }
            .buttonStyle(PressStyle())
            .help("Put \(c.name) on Next")
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(c.shots.filter { $0.kind == .position }) { s in
                        cell(s.name, nil, used: lastUsed[c.id] == "shot:\(s.id)", live: live) {
                            go(c) { ptz.go(to: s, camera: c.id); lastUsed[c.id] = "shot:\(s.id)" }
                        }
                        .contextMenu {
                            Button("Update to where the camera is now") {
                                ptz.saveShot("", camera: c.id, kind: s.kind, replacing: s.id) { if !$0 { problem = Self.noReading } }
                            }
                            Button("Rename…") { newName = s.name; renaming = (c.id, s) }
                            Divider()
                            Button("Delete…") { deleting = (c.id, s) }
                        }
                    }
                    ForEach(cameraPresets(c).filter { !(ptz.exposurePresets[c.id]?.contains($0) ?? false) }, id: \.self) { n in
                        cell(ptz.presetNames(c)[n] ?? "Preset \(n)", "ON CAMERA",
                             used: lastUsed[c.id] == "preset:\(n)", live: live) {
                            go(c) { ptz.recall(n, camera: c.id); lastUsed[c.id] = "preset:\(n)" }
                        }
                        .contextMenu {
                            if ptz.canSaveShots(c) { Button("Delete from camera…") { deletingPreset = (c.id, n) } }
                        }
                    }
                    if ptz.canSaveShots(c) {
                        Button { newName = ""; savingFor = c.id } label: {
                            Image(systemName: "plus").font(.system(size: 13, weight: .bold)).foregroundStyle(T.accentStrong)
                                .frame(width: 40, height: 40)
                                .background(RoundedRectangle(cornerRadius: T.rMD).stroke(T.line, style: StrokeStyle(lineWidth: 1, dash: [3, 3])))
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(PressStyle())
                        .help("Save where \(c.name) is now as a new shot")
                        .popover(isPresented: Binding(get: { savingFor == c.id }, set: { if !$0 { savingFor = nil } }), arrowEdge: .top) {
                            savePopover(c)
                        }
                    }
                }
            }
        }
    }

    func cell(_ title: String, _ subtitle: String?, used: Bool, live: Bool, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 1) {
                Text(title).font(.sans(13, .semibold)).lineLimit(1).minimumScaleFactor(0.75)
                if let subtitle { Text(subtitle).font(.sans(8, .bold)).tracking(0.5).opacity(0.7) }
            }
            .foregroundStyle(used ? T.onAction : T.ink)
            .padding(.horizontal, 6)
            .frame(width: 104, height: 40)
            .background(RoundedRectangle(cornerRadius: T.rMD).fill(used ? T.accent : T.surfaceRaised))
            .overlay(RoundedRectangle(cornerRadius: T.rMD).stroke(used ? T.accent : T.line))
            .opacity(live && !used ? 0.75 : 1)
            .contentShape(Rectangle())
        }
        .buttonStyle(PressStyle())
    }

    /// Moves a camera, asking first if it's on Live.
    func go(_ c: PTZCamera, _ run: @escaping () -> Void) {
        if onLive(c) { liveMove = (c.id, run) } else { run() }
    }

    static let noReading = "The camera didn't report its settings, so the shot wasn't saved. Check that it's answering and try again."

    var liveQuestion: String {
        guard let id = liveMove?.camera, let c = ptz.cameras.first(where: { $0.id == id }) else { return "Move the live camera?" }
        return "\(c.name) is on Live. Move it anyway?"
    }

    var presetQuestion: String {
        guard let d = deletingPreset, let c = ptz.cameras.first(where: { $0.id == d.camera }) else { return "Delete this preset?" }
        return "Delete \"\(ptz.presetNames(c)[d.n] ?? "Preset \(d.n)")\" from \(c.name)?"
    }

    func savePopover(_ t: PTZCamera) -> some View {
        VStack(alignment: .leading, spacing: T.s3) {
            Text("Save a shot on \(t.name)").font(.sans(14, .bold))
            Text("Pan, tilt and zoom, where the camera is pointing now.")
                .font(.sans(12)).foregroundStyle(T.inkMuted)
            TextField("Pulpit", text: $newName)
                .textFieldStyle(.roundedBorder).onSubmit { save(t) }
            HStack {
                Spacer()
                Button("Cancel") { savingFor = nil }.keyboardShortcut(.cancelAction)
                Button("Save") { save(t) }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(T.s4)
        .frame(width: 300)
    }

    func save(_ t: PTZCamera) {
        let name = newName.trimmingCharacters(in: .whitespaces)
        ptz.saveShot(name, camera: t.id, kind: .position) { if !$0 { problem = Self.noReading } }
        savingFor = nil
    }

    func rename() {
        let name = newName.trimmingCharacters(in: .whitespaces)
        if let r = renaming, !name.isEmpty,
           let i = ptz.cameras.firstIndex(where: { $0.id == r.camera }), let j = ptz.cameras[i].shots.firstIndex(where: { $0.id == r.shot.id }) {
            ptz.cameras[i].shots[j].name = name
        }
        renaming = nil
    }

    /// Presets stored on the camera: the ones it reports, plus any named in Setup. A VISCA
    /// camera can't say which presets it holds, so it shows only the ones given a name.
    func cameraPresets(_ t: PTZCamera) -> [Int] { ptz.presetNames(t).keys.sorted() }
}

/// Take it live.
struct TakePanel: View {
    @EnvironmentObject var booth: Booth
    @EnvironmentObject var atem: ATEMClient
    @EnvironmentObject var store: ConfigStore

    var body: some View {
        let me = booth.me
        let s = atem.state
        let fading = s.inTransition[me] ?? false
        let black = s.ftbBlack[me] ?? false
        VStack(alignment: .leading, spacing: T.s3) {
            // The two ways to take Next live, side by side and the same size.
            HStack(spacing: T.s2) {
                Button { atem.auto(me: me) } label: {
                    VStack(spacing: 2) {
                        Text(fading ? "FADING" : "FADE").font(.sans(24, .bold))
                        Text(fading ? "\(store.label(s.program[me], s)) to \(store.label(s.preview[me], s))"
                                    : "\(String(format: "%.1f", Double(s.mixRate[me] ?? 30) / 30)) s · Return")
                            .font(.sans(11, .medium)).opacity(0.85).lineLimit(1).minimumScaleFactor(0.7)
                    }
                    .foregroundStyle(.white).padding(.horizontal, 4)
                    .frame(width: 121, height: 92)
                    .background(RoundedRectangle(cornerRadius: T.rMD).fill(T.program.opacity(fading ? 0.55 : 1)))
                    // How far the fade has run, along the bottom edge.
                    .overlay(alignment: .bottomLeading) {
                        if fading { Rectangle().fill(Color.white).frame(width: 121 * min(1, max(0, s.position[me] ?? 0)), height: 5) }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: T.rMD))
                    .overlay(RoundedRectangle(cornerRadius: T.rMD).stroke(Color.white.opacity(0.25)))
                    .contentShape(Rectangle())
                }
                .buttonStyle(PressStyle())
                .help("Fade from Live to Next (Return)")
                Button { atem.cut(me: me) } label: {
                    VStack(spacing: 2) {
                        Text("CUT").font(.sans(24, .bold))
                        Text("Space").font(.sans(11, .medium)).opacity(0.85)
                    }
                    .foregroundStyle(T.ink)
                    .frame(width: 121, height: 92)
                    .background(RoundedRectangle(cornerRadius: T.rMD).fill(T.surfaceRaised))
                    .overlay(RoundedRectangle(cornerRadius: T.rMD).stroke(T.lineStrong))
                    .contentShape(Rectangle())
                }
                .buttonStyle(PressStyle())
                .help("Switch to Next instantly (Space)")
            }
            // Under them, the things that are on or off: black, then keys such as lower
            // thirds. Lit while on air, press to turn on or off.
            LazyVGrid(columns: [GridItem(.fixed(121), spacing: T.s2), GridItem(.fixed(121))], alignment: .leading, spacing: T.s2) {
                let ftb = s.ftbInTransition[me] ?? false
                PanelButton(title: "BLACK", subtitle: black ? "IN BLACK" : (ftb ? "FADING" : "OFF"), lit: black || ftb ? T.program : nil,
                            width: 121, height: 48, titleSize: 14, blink: black) { atem.fadeToBlack(me: me) }
                    .help(black ? "Fade back up from black" : "Fade everything to black")
                ForEach(store.config.keys) { k in
                    let on = k.isOn(s)
                    PanelButton(title: k.label.uppercased(), subtitle: on ? "ON AIR" : "OFF", lit: on ? T.program : nil,
                                width: 121, height: 48, titleSize: 13) { k.toggle(atem) }
                        .help(on ? "Take \(k.label) off (\(k.target))" : "Put \(k.label) on (\(k.target))")
                }
            }
        }
    }
}

/// Turns auto tracking on and off for the camera on Next. On, it follows the person nearest
/// the middle; clicking someone on the Next picture follows them instead.
struct TrackButton: View {
    let camera: PTZCamera
    @ObservedObject var tracker = AutoTracker.shared
    @ObservedObject var cast = StageCast.shared
    @EnvironmentObject var store: ConfigStore

    var body: some View {
        let s = tracker.sessions[camera.id]
        VStack(alignment: .leading, spacing: 4) {
            Button {
                if s != nil { tracker.stop(camera.id) } else { tracker.start(camera) }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "figure.walk").font(.system(size: 12, weight: .bold))
                    LabelText(s == nil ? "Track" : "Tracking", size: 11)
                }
                .foregroundStyle(s == nil ? T.ink : T.onAction)
                .frame(maxWidth: .infinity).frame(height: 30)
                .contentShape(Rectangle())
                .background(RoundedRectangle(cornerRadius: T.rSM).fill(s == nil ? Color.clear : T.accent))
                .overlay(RoundedRectangle(cornerRadius: T.rSM).stroke(s == nil ? T.lineStrong : T.accent))
            }
            .buttonStyle(PressStyle())
            .disabled(CameraPicture.of(camera, store) == nil)
            .help(s == nil ? "Follow the person in the middle of the shot. Or click someone on the Next picture. Moving the joystick stops tracking."
                           : "Stop following. Moving the joystick or recalling a shot also stops it.")
            if let s {
                // The follow shot: tap to reframe. The highlighted one is what it's framing to.
                HStack(spacing: 2) {
                    ForEach(ShotSize.allCases) { z in
                        Button { tracker.setSize(camera.id, z) } label: {
                            Text(z.short).font(.sans(11, .semibold))
                                .foregroundStyle(s.size == z ? T.onAction : T.inkMuted)
                                .frame(maxWidth: .infinity).frame(height: 24)
                                .background(RoundedRectangle(cornerRadius: T.rSM).fill(s.size == z ? T.accent : T.surfaceSunken))
                        }
                        .buttonStyle(PressStyle())
                        .help("Frame \(z.name.lowercased())")
                    }
                }
                // Follow speed, right here so it can be nudged during a service.
                HStack(spacing: 4) {
                    Text("Speed").font(.sans(11)).foregroundStyle(T.inkMuted)
                    Spacer(minLength: 0)
                    speedButton("minus", -0.25)
                    Text(String(format: "%.2g×", store.config.trackSpeed)).font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(T.ink).frame(width: 36)
                    speedButton("plus", 0.25)
                }
                .help("How quickly tracking cameras follow. Raise it if the camera falls behind, lower it if it overshoots.")
                Text([TrackingBadge.words(s.phase), s.person, s.phase == .following ? s.size.name : nil].compactMap { $0 }.joined(separator: " · "))
                    .font(.sans(11, .semibold))
                    .foregroundStyle(s.phase == .following ? T.accent : T.warning)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("Or click a person on Next").font(.sans(11)).foregroundStyle(T.inkSubtle)
                // People labelled in the stage scan can be followed by name, wherever they are in the shot.
                if !cast.names.isEmpty {
                    Menu {
                        ForEach(cast.names, id: \.self) { n in Button(n) { tracker.start(camera, person: n) } }
                    } label: {
                        Text("Follow by name").font(.sans(11, .semibold))
                    }
                    .menuStyle(.borderlessButton).fixedSize()
                    .disabled(CameraPicture.of(camera, store) == nil)
                    .help("Follow someone labelled in the stage scan")
                }
            }
        }
    }
}

extension TrackButton {
    func speedButton(_ icon: String, _ step: Double) -> some View {
        Button {
            store.update { $0.trackSpeed = min(4, max(0.5, (($0.trackSpeed + step) * 4).rounded() / 4)) }
        } label: {
            Image(systemName: icon).font(.system(size: 10, weight: .bold)).foregroundStyle(T.ink)
                .frame(width: 24, height: 20)
                .background(RoundedRectangle(cornerRadius: T.rSM).fill(T.surfaceSunken))
        }
        .buttonStyle(PressStyle())
    }
}

/// Shown on a monitor whose camera is tracking, with a button to stop it.
struct TrackingBadge: View {
    let phase: AutoTracker.Phase
    let stop: () -> Void

    static func words(_ p: AutoTracker.Phase?) -> String? {
        switch p {
        case .starting: return "Looking for someone"
        case .following: return "Following"
        case .searching: return "Lost sight, holding"
        case .lost: return "Lost them, looking"
        case nil: return nil
        }
    }

    var body: some View {
        Button(action: stop) {
            HStack(spacing: 6) {
                Image(systemName: "figure.walk").font(.system(size: 11, weight: .bold))
                Text(Self.words(phase)?.uppercased() ?? "").font(.sans(11, .bold)).tracking(0.8)
                Image(systemName: "xmark").font(.system(size: 9, weight: .bold))
            }
            .foregroundStyle(phase == .following ? T.onAction : .black)
            .padding(.horizontal, 8).frame(height: 24)
            .background(Capsule().fill(phase == .following ? T.accent : T.warning))
        }
        .buttonStyle(PressStyle())
        .help("Stop auto tracking")
    }
}
