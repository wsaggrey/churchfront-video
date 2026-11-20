import SwiftUI
import AppKit
import CueATEM

/// What the whole app shares: the switcher, the cameras and the operator's settings.
final class Booth: ObservableObject {
    static let shared = Booth()
    let atem = ATEMClient()
    let ptz = PTZController(load: ProcessInfo.processInfo.environment["CUEVIDEO_FAKECAMS"] == nil)
    /// The setup, kept in a JSON file people and Claude can edit.
    let store = ConfigStore()
    @Published var simple = UserDefaults.standard.bool(forKey: "simple") { didSet { UserDefaults.standard.set(simple, forKey: "simple") } }
    @Published var followPreview = UserDefaults.standard.object(forKey: "followPreview") as? Bool ?? true {
        didSet { UserDefaults.standard.set(followPreview, forKey: "followPreview") }
    }
    @Published var me = 0
    @Published var showSettings = false
    /// Which view the main window shows. It always opens on Operator. Leaving Operator lets
    /// go of the cameras: the joystick or an arrow key may still be held when the view changes.
    @Published var view: AppView = .operate {
        didSet {
            guard view != oldValue, oldValue == .operate else { return }
            heldArrows.removeAll()
            ptz.stopAllManual()
        }
    }
    /// The page showing in the Engineer view.
    @Published var section: EngineerSection = .scan

    /// Opens a page of the Engineer view.
    func show(_ s: EngineerSection) { section = s; view = .engineer }

    /// The camera on Next, which the camera controls and the Camera menu act on.
    var cameraOnNext: PTZCamera? {
        let next = atem.state.preview[me]
        return ptz.cameras.first { $0.atemInput == next && !$0.host.isEmpty }
    }
    private var heldArrows: Set<UInt16> = []
    /// The title of the volunteer's window (the WindowGroup in CueVideoApp).
    static let mainWindowTitle = "Churchfront Video"

    /// Lets go of any arrow keys being held and stops that camera. Used when the key release
    /// may never reach CueVideo: another window or another app came to the front.
    func releaseArrows() {
        guard !heldArrows.isEmpty else { return }
        heldArrows.removeAll()
        ptz.stopDrive()
    }

    var connectedOnce: Bool { !atem.state.inputs.isEmpty }

    /// Keyboard: 1 to 9 and 0 put that tile of the volunteer's source row on Next, shift
    /// puts it on Live, space cuts, return fades, arrows move the camera on Next.
    ///
    /// These only work in the Operator view, and not while it shows a dialog or a popover:
    /// Space or Return in the Engineer view, or on a "Delete this shot?" question, must never
    /// cut or fade what's live.
    func key(_ e: NSEvent, down: Bool) -> Bool {
        guard view == .operate, let w = NSApp.keyWindow, w.title == Booth.mainWindowTitle, w.attachedSheet == nil else {
            releaseArrows()
            return false
        }
        if let r = w.firstResponder, r is NSTextView { return false }
        if e.modifierFlags.contains(.command) { return false }
        let arrows: [UInt16: (Double, Double)] = [123: (-0.6, 0), 124: (0.6, 0), 125: (0, -0.6), 126: (0, 0.6)]
        if let a = arrows[e.keyCode] {
            // Only the camera on Next moves, as with the joystick.
            let next = atem.state.preview[me]
            guard ptz.cameras.contains(where: { $0.atemInput == next && $0.id == ptz.selected }) else {
                heldArrows.removeAll(); ptz.stopDrive(); return true
            }
            if down { heldArrows.insert(e.keyCode) } else { heldArrows.remove(e.keyCode) }
            let x = heldArrows.compactMap { arrows[$0]?.0 }.reduce(0, +)
            let y = heldArrows.compactMap { arrows[$0]?.1 }.reduce(0, +)
            if heldArrows.isEmpty { ptz.stopDrive() } else { ptz.drive(x: x, y: y) }
            _ = a
            return true
        }
        guard down, !e.isARepeat else { return down }
        switch e.keyCode {
        case 49: atem.cut(me: me); return true
        case 36, 76: atem.auto(me: me); return true
        default: break
        }
        let digits: [UInt16: Int] = [18: 0, 19: 1, 20: 2, 21: 3, 23: 4, 22: 5, 26: 6, 28: 7, 25: 8, 29: 9]
        if let i = digits[e.keyCode] {
            let src = store.volunteerSources(atem.state)
            guard i < src.count else { return true }
            if e.modifierFlags.contains(.shift) { atem.setProgram(src[i].input, me: me) } else { atem.setPreview(src[i].input, me: me) }
            return true
        }
        return false
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var monitor: Any?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.appearance = NSAppearance(named: .darkAqua)
        NSApp.setActivationPolicy(.regular)
        // The Dock keeps an old icon for a rebuilt app at the same path, so set it outright.
        if let url = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"), let icon = NSImage(contentsOf: url) {
            NSApp.applicationIconImage = icon
        }
        NSApp.activate(ignoringOtherApps: true)
        let booth = Booth.shared
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) { e in
            booth.key(e, down: e.type == .keyDown) ? nil : e
        }
        // An arrow key held while another app or window comes forward never sends its release.
        let center = NotificationCenter.default
        center.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { _ in booth.releaseArrows() }
        center.addObserver(forName: NSWindow.didResignKeyNotification, object: nil, queue: .main) { n in
            if (n.object as? NSWindow)?.title == Booth.mainWindowTitle { booth.releaseArrows() }
        }
        let env = ProcessInfo.processInfo.environment
        // Self-tests name their own switcher; otherwise the config file says where it is.
        if let host = env["CUEVIDEO_HOST"], !host.isEmpty { booth.atem.connect(host, port: env["CUEVIDEO_PORT"].flatMap(UInt16.init) ?? 9910) }
        if let fake = env["CUEVIDEO_FAKECAMS"] {
            var cams: [PTZCamera] = []
            for (i, name) in ["Center", "Left", "Right"].enumerated() {
                var c = PTZCamera(); c.name = name; c.host = fake; c.port = UInt16(52381 + i); c.atemInput = i + 1
                c.presetNames = [1: "Pulpit", 2: "Wide", 3: "Band"]
                cams.append(c)
            }
            booth.ptz.cameras = cams
        }
        booth.store.attach(booth)
        AutoTracker.shared.attach()
        // Claude's way in (through the CueVideo MCP server). Not during self-tests, which
        // may run beside the real app.
        if !booth.store.readOnly { ControlServer.shared.start() }
        // For screenshots in self-tests: CUEVIDEO_VIEW=engineer or engineer:routing.
        if let v = env["CUEVIDEO_VIEW"] {
            let parts = v.split(separator: ":").map(String.init)
            if parts.first == "engineer" { booth.show(parts.count > 1 ? EngineerSection(rawValue: parts[1]) ?? .scan : .scan) }
        }
        if let src = env["CUEVIDEO_NDI"] ?? UserDefaults.standard.string(forKey: "ndiSource") {
            NDIMonitor.shared.start(src)
        }
        NDIMonitor.shared.scan()
        if env["CUEVIDEO_FOLLOWTEST"] != nil { SelfTest.followTest() } else if let cams = env["CUEVIDEO_PTZTEST"] { SelfTest.ptzTest(cams) } else if env["CUEVIDEO_REALTEST"] != nil { SelfTest.realTest() } else if env["CUEVIDEO_PROBE"] != nil { SelfTest.probe() } else if env["CUEVIDEO_SELFTEST"] != nil { SelfTest.run() }
    }

    /// Quitting stops every camera CueVideo is moving (auto tracking, the joystick, zoom, a
    /// move Claude started), then waits a moment for the stops to reach the cameras. A Canon
    /// camera keeps turning at the last speed it was given until it's told to stop.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        AutoTracker.shared.stopAll()
        Booth.shared.ptz.stopAllManual()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { sender.reply(toApplicationShouldTerminate: true) }
        return .terminateLater
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

@main
struct CueVideoApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    init() { Fonts.register() }

    var body: some Scene {
        WindowGroup(Booth.mainWindowTitle) {
            ContentView()
                .booth()
                .frame(minWidth: 1100, minHeight: 720)
        }
        .defaultSize(width: 1440, height: 900)
        .windowStyle(.hiddenTitleBar)
        .commands { BoothCommands() }
    }
}

/// The menu bar. View opens each page; Switcher and Camera hold what the Operate page's
/// buttons do, so the keys can be found.
struct BoothCommands: Commands {
    @ObservedObject private var booth = Booth.shared
    @ObservedObject private var store = Booth.shared.store
    @ObservedObject private var cast = StageCast.shared

    var body: some Commands {
        CommandGroup(replacing: .appSettings) {
            Button("Settings…") { booth.show(.setup) }.keyboardShortcut(",")
        }
        CommandGroup(before: .sidebar) {
            Button("Operate") { booth.view = .operate }.keyboardShortcut("1")
            Button("Stage Scan") { booth.show(.scan) }.keyboardShortcut("s", modifiers: [.command, .shift])
            Button("Routing") { booth.show(.routing) }.keyboardShortcut("r", modifiers: [.command, .shift])
            Button("Full Switcher") { booth.show(.switcher) }.keyboardShortcut("k", modifiers: [.command, .shift])
            Button("Setup") { booth.show(.setup) }
            Button("Status") { booth.show(.status) }
            Divider()
        }
        // Switching and camera commands act only from the Operator view, where the person
        // can see what they're about to change.
        CommandMenu("Switcher") {
            Group {
            Button("Cut (Space)") { booth.atem.cut(me: booth.me) }
            Button("Fade (Return)") { booth.atem.auto(me: booth.me) }
            Button("Fade to Black") { booth.atem.fadeToBlack(me: booth.me) }
            if !store.config.keys.isEmpty {
                Divider()
                ForEach(store.config.keys) { k in
                    Button("\(k.label) On or Off") { k.toggle(booth.atem) }
                }
            }
            }
            .disabled(booth.view != .operate)
        }
        CommandMenu("Camera") {
            Group {
            Button("Track the Camera on Next") {
                guard let c = booth.cameraOnNext else { return }
                if AutoTracker.shared.isTracking(c.id) { AutoTracker.shared.stop(c.id) } else { AutoTracker.shared.start(c) }
            }
            .keyboardShortcut("t")
            Button("Stop All Tracking") { AutoTracker.shared.stopAll() }.keyboardShortcut(".")
            Menu("Follow by Name") {
                ForEach(cast.names, id: \.self) { n in
                    Button(n) { if let c = booth.cameraOnNext { AutoTracker.shared.start(c, person: n) } }
                }
            }
            .disabled(cast.names.isEmpty)
            Divider()
            Button("Focus the Camera on Next") { if let c = booth.cameraOnNext { booth.ptz.focusOnce(camera: c.id) } }
                .keyboardShortcut("f", modifiers: [.command, .shift])
            Button("Auto Focus the Camera on Next") { if let c = booth.cameraOnNext { booth.ptz.autoFocus(true, camera: c.id) } }
                .keyboardShortcut("f", modifiers: [.command, .option])
            }
            .disabled(booth.view != .operate)
        }
    }
}

extension View {
    /// Everything the app's windows share.
    func booth() -> some View {
        environmentObject(Booth.shared)
            .environmentObject(Booth.shared.atem)
            .environmentObject(Booth.shared.ptz)
            .environmentObject(Booth.shared.store)
            .environmentObject(NDIMonitor.shared)
    }
}
