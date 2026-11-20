import Foundation
import Combine
import CueATEM

/// One tile in the volunteer's source row: an ATEM input, with an optional friendlier name.
struct VolunteerSource: Codable, Hashable, Identifiable {
    var input: Int
    var label: String?
    /// An NDI source showing what this input carries (such as CueScreens' graphics output),
    /// for its tile and the Next and Live pictures. Cameras show their own picture instead.
    var ndi: String?
    var id: Int { input }
}

/// A volunteer button that puts a key on or off air: an upstream key (`me` and `keyer`,
/// both counted from 1) or a downstream key (`dsk`, from 1). Upstream keys cut on and off;
/// DSKs fade with their own rate.
struct KeyButton: Codable, Hashable, Identifiable {
    var label: String
    var me: Int?
    var keyer: Int?
    var dsk: Int?
    /// An NDI source with alpha showing this key (such as CueScreens' lower thirds), laid
    /// over the Next and Live pictures when the key is on them.
    var ndi: String? = nil
    var id: String { "\(label)|\(me ?? 0)|\(keyer ?? 0)|\(dsk ?? 0)" }

    func isOn(_ s: ATEMState) -> Bool {
        if let dsk { return s.dskOnAir[dsk - 1] ?? false }
        guard let keyer else { return false }
        return s.keyOnAir[(me ?? 1) - 1]?[keyer - 1] ?? false
    }

    func toggle(_ atem: ATEMClient) {
        if let dsk { atem.dskAuto(dsk - 1); return }
        guard let keyer else { return }
        atem.setKeyOnAir(keyer - 1, !isOn(atem.state), me: (me ?? 1) - 1)
    }

    /// Whether the key will be on air after the next Cut or Fade: on now, unless the next
    /// transition takes it off; off now, unless it brings it on (a tied DSK, or a key
    /// selected in the next transition).
    func onNext(_ s: ATEMState) -> Bool {
        if let dsk { return (s.dskOnAir[dsk - 1] ?? false) != (s.dskTie[dsk - 1] ?? false) }
        guard let keyer else { return false }
        let m = (me ?? 1) - 1
        let selected = ((s.nextSelection[m] ?? 1) >> keyer) & 1 == 1
        return isOn(s) != selected
    }

    /// "M/E 1 Key 1" or "DSK 2".
    var target: String { dsk.map { "DSK \($0)" } ?? "M/E \(me ?? 1) Key \(keyer ?? 0)" }
}

/// A screen (or other destination) fed by one or more switcher aux outputs, counted from 1.
/// Auxes listed together switch together, such as a left and right pair.
struct ScreenOutput: Codable, Hashable, Identifiable {
    var name: String
    var aux: [Int]
    /// How it's wired, for the Routing page: "Converter 1 → LED processor".
    var note: String?
    /// Shown in the volunteer's screen summary. Off for encoders, recorders and patch bay feeds.
    var volunteer: Bool?
    /// Shown as a small live preview in the top bar. Until any screen says either way, the
    /// first three volunteer screens are.
    var pinned: Bool?
    var id: String { name + aux.map(String.init).joined(separator: ",") }
    var forVolunteers: Bool { volunteer ?? true }
}

/// How a follow shot is framed. Any part left out uses the built-in standard. Measured as a
/// share of the frame: eyeLine down from the top (0.29), scale is eyes to shoulders against
/// frame height (bigger is tighter), leadRoom the offset toward where they face or walk,
/// deadX and deadY how far they can drift before the camera moves.
struct FramingRule: Codable, Hashable {
    var eyeLine: Double?
    var scale: Double?
    var leadRoom: Double?
    var deadX: Double?
    var deadY: Double?

    func merged(_ o: FramingRule?) -> FramingRule {
        guard let o else { return self }
        return FramingRule(eyeLine: o.eyeLine ?? eyeLine, scale: o.scale ?? scale, leadRoom: o.leadRoom ?? leadRoom,
                           deadX: o.deadX ?? deadX, deadY: o.deadY ?? deadY)
    }
}

/// Tracking response, for tuning while it runs. Any left out use the built-in values.
/// correction: pull toward the framing mark (1.2); latency: how far behind the preview picture
/// runs, in seconds (0.45); walkThreshold: how fast (frames a second) counts as walking (0.12);
/// zoomThreshold: how wrong the size must look before zooming, as a log ratio (0.3, about a third);
/// zoomWait: seconds it must stay wrong first (1.5).
struct TrackTuning: Codable, Hashable {
    var correction: Double?
    var latency: Double?
    var walkThreshold: Double?
    var zoomThreshold: Double?
    var zoomWait: Double?
}

/// One change a routing button makes: send this source to this aux (counted from 1).
struct RouteChange: Codable, Hashable {
    var aux: Int
    var source: Int
}

/// A volunteer button that routes one or more screens at once, like a macro. Lit when the
/// switcher already matches every change in it.
struct RouteButton: Codable, Hashable, Identifiable {
    var label: String
    var set: [RouteChange]
    var id: String { label }

    func isActive(_ s: ATEMState) -> Bool { !set.isEmpty && set.allSatisfy { s.aux[$0.aux - 1] == $0.source } }
    func run(_ atem: ATEMClient) { for c in set { atem.setAux(c.aux - 1, c.source) } }
}

/// How CueVideo is set up, kept as plain JSON so a person or Claude can read and edit it:
/// ~/Library/Application Support/CueVideo/config.json. Every field is optional when
/// written by hand.
///
///     {
///       "atemHost": "192.168.1.240",
///       "me": 1,
///       "sources": [ { "input": 9, "label": "Cam 1" }, { "input": 3, "label": "Graphics", "ndi": "GRAPHICS-MAC (CueScreens Stream)" } ],
///       "cameras": [ { "name": "Cam 1", "host": "192.168.1.91", "proto": "canonXC", "atemInput": 9 } ],
///       "keys": [ { "label": "Lower thirds", "me": 1, "keyer": 1, "ndi": "GRAPHICS-MAC (CueScreens Lower Thirds)" } ],
///       "trackSpeed": 1, "ptzSpeed": 1, "trackTilt": true, "trackZoom": true,
///       "mixNames": [ "Live stream", "Side screens" ],
///       "screens": [ { "name": "Lobby TVs", "aux": [4, 5], "note": "Converters 4 and 5" } ],
///       "routes": [ { "label": "Lobby: stream", "set": [ { "aux": 4, "source": 10010 }, { "aux": 5, "source": 10010 } ] } ]
///     }
///
/// `ndi` names an NDI source exactly as it appears on the network (Setup lists them).
/// `proto` is canonXC (Canon HTTP), sonyUDP (VISCA over IP, UDP 52381) or rawTCP (VISCA over TCP 5678).
/// A camera with no network picture at all (HDMI only, such as a DJI Osmo Pocket) shows through the
/// switcher's USB output when it's the source on it; `usbAux` says which output that is (see CueConfig).
/// A VISCA camera's picture is the `ndi` of the source for its `atemInput` (an NDI HX camera's own stream):
///
///     "sources": [ { "input": 1, "label": "Cam 1", "ndi": "NDI_HX (NDI-26567)" } ],
///     "cameras": [ { "name": "Cam 1", "host": "192.168.1.61", "proto": "sonyUDP", "atemInput": 1 } ]
struct CueConfig: Codable, Equatable {
    var atemHost = ""
    /// The M/E the volunteer runs, counted from 1 as on the switcher.
    var me = 1
    /// The volunteer's source row, left to right. Inputs not listed stay out of their way.
    var sources: [VolunteerSource] = []
    var cameras: [PTZCamera] = []
    /// On/off buttons for keys, such as lower thirds, under the take buttons.
    var keys: [KeyButton] = []
    /// Auto tracking: how quickly cameras follow, 0.5 (gentle) to 4 (quick), and whether they tilt too.
    var trackSpeed = 1.0
    /// Overall speed of manual camera control (joystick, zoom, arrow keys), 0.25 to 2.
    var ptzSpeed = 1.0
    var trackTilt = true
    /// Auto tracking zooms to hold the shot size (shoulders, waist or full length) as people
    /// move nearer or farther. Off: zoom is left entirely to the volunteer.
    var trackZoom = true
    /// What each M/E is for, counted from 1: ["Live stream", "Side screens"].
    var mixNames: [String] = []
    /// NDI pictures for switcher inputs that aren't in the volunteer's source row, by input
    /// number: { "4": "GRAPHICS-MAC (CueScreens Stage)" }. Shown wherever that input's picture is.
    var pictures: [String: String] = [:]
    /// The screens and other destinations the aux outputs feed.
    var screens: [ScreenOutput] = []
    /// Volunteer routing buttons, bottom right of the main window.
    var routes: [RouteButton] = []
    /// Changes to the follow-shot framing, by size: "shoulders", "waist", "full".
    var framing: [String: FramingRule] = [:]
    var trackTuning = TrackTuning()
    /// The switcher output this Mac's USB video comes from, for showing HDMI-only cameras: an
    /// aux counted from 1, 0 for a switcher whose USB output is always Program, -1 for off.
    /// Left out, it's worked out from the model (ATEM Mini Pro: aux 2).
    var usbAux: Int?

    init() {}

    private enum Keys: String, CodingKey { case atemHost, me, sources, cameras, keys, trackSpeed, ptzSpeed, trackTilt, trackZoom, mixNames, pictures, screens, routes, framing, trackTuning, usbAux }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        atemHost = try c.decodeIfPresent(String.self, forKey: .atemHost) ?? ""
        me = try c.decodeIfPresent(Int.self, forKey: .me) ?? 1
        sources = try c.decodeIfPresent([VolunteerSource].self, forKey: .sources) ?? []
        cameras = try c.decodeIfPresent([PTZCamera].self, forKey: .cameras) ?? []
        keys = try c.decodeIfPresent([KeyButton].self, forKey: .keys) ?? []
        trackSpeed = min(4, max(0.5, try c.decodeIfPresent(Double.self, forKey: .trackSpeed) ?? 1))
        ptzSpeed = min(2, max(0.25, try c.decodeIfPresent(Double.self, forKey: .ptzSpeed) ?? 1))
        trackTilt = try c.decodeIfPresent(Bool.self, forKey: .trackTilt) ?? true
        trackZoom = try c.decodeIfPresent(Bool.self, forKey: .trackZoom) ?? true
        mixNames = try c.decodeIfPresent([String].self, forKey: .mixNames) ?? []
        pictures = try c.decodeIfPresent([String: String].self, forKey: .pictures) ?? [:]
        screens = try c.decodeIfPresent([ScreenOutput].self, forKey: .screens) ?? []
        routes = try c.decodeIfPresent([RouteButton].self, forKey: .routes) ?? []
        framing = try c.decodeIfPresent([String: FramingRule].self, forKey: .framing) ?? [:]
        trackTuning = try c.decodeIfPresent(TrackTuning.self, forKey: .trackTuning) ?? TrackTuning()
        usbAux = try c.decodeIfPresent(Int.self, forKey: .usbAux)
    }
}

/// Keeps the config file and the running app in step: edits to the file are picked up
/// within a second, and changes made in the app are written back to the file.
final class ConfigStore: ObservableObject {
    @Published private(set) var config = CueConfig()
    /// Why the file couldn't be read, if it couldn't. The app keeps running on the last good setup.
    @Published private(set) var fileError: String?
    @Published private(set) var loadedAt: Date?

    let url: URL
    /// Self-tests (any CUEVIDEO_ environment setting) bring their own switcher and
    /// cameras; they must never be written over the real setup.
    let readOnly: Bool
    private var lastModified: Date?
    /// True while config.json is on disk but couldn't be read (a typing mistake in it). The
    /// app never writes over a file in that state without setting a copy of it aside first.
    private var unreadable = false
    /// A copy of the last setup that loaded or saved cleanly, beside config.json. If
    /// config.json can't be read when CueVideo opens, it runs on this instead of on nothing.
    private var lastGoodURL: URL { url.deletingLastPathComponent().appendingPathComponent("config.last-good.json") }
    private var timer: Timer?
    private var bag = Set<AnyCancellable>()
    private weak var booth: Booth?

    init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        url = support.appendingPathComponent("CueVideo", isDirectory: true).appendingPathComponent("config.json")
        readOnly = ProcessInfo.processInfo.environment.keys.contains { $0.hasPrefix("CUEVIDEO_") }
    }

    func attach(_ booth: Booth) {
        self.booth = booth
        if let c = read() {
            config = c
        } else if fileError == nil {
            config = migrated(booth)
            write()
        } else if let data = try? Data(contentsOf: lastGoodURL), let c = try? JSONDecoder().decode(CueConfig.self, from: data) {
            // config.json has a mistake in it: open on the last setup that worked, and say so.
            config = c
        }
        apply()
        // Cameras edited in the app go back to the file. Write what the cameras are *now*, not
        // the value the notice carried: notices arrive a moment late, and writing an older
        // value back puts it into the cameras again, which sends another notice, and so on.
        // That loop cycled the file through every edit ever typed, once a second, and
        // restarted the camera links each time so no camera ever showed as answering.
        booth.ptz.$cameras.dropFirst().receive(on: RunLoop.main).sink { [weak self, weak booth] _ in
            guard let self, let booth else { return }
            self.update { $0.cameras = booth.ptz.cameras }
        }.store(in: &bag)
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.poll() }
    }

    /// Change the setup from the app. Writes the file and applies what changed.
    func update(_ change: (inout CueConfig) -> Void) {
        var c = config
        change(&c)
        guard c != config else { return }
        config = c
        write()
        apply()
    }

    /// Sources for the volunteer's row: the configured ones, or every camera input until it's set up.
    func volunteerSources(_ state: ATEMState) -> [VolunteerSource] {
        if !config.sources.isEmpty { return config.sources }
        return config.cameras.compactMap(\.atemInput).map { VolunteerSource(input: $0) }
    }

    /// The NDI picture set for a source, if any.
    func ndi(_ input: Int?) -> String? {
        guard let input else { return nil }
        if let n = config.sources.first(where: { $0.input == input })?.ndi, !n.isEmpty { return n }
        if let n = config.pictures["\(input)"], !n.isEmpty { return n }
        return nil
    }

    /// Sets or clears an input's NDI picture: on its source row entry if it has one, else in `pictures`.
    func setPicture(_ input: Int, _ ndi: String?) {
        update { c in
            if let i = c.sources.firstIndex(where: { $0.input == input }) { c.sources[i].ndi = ndi }
            else { c.pictures["\(input)"] = (ndi ?? "").isEmpty ? nil : ndi }
        }
    }

    /// What an M/E is for: "Live stream (M/E 1)", or just "M/E 2".
    func mixName(_ me: Int) -> String {
        let n = config.mixNames.indices.contains(me) ? config.mixNames[me] : ""
        return n.isEmpty ? "M/E \(me + 1)" : "\(n) (M/E \(me + 1))"
    }

    /// A routing source in plain words: M/E outputs by what they're for, others by label.
    func routeLabel(_ source: Int?, _ state: ATEMState) -> String {
        guard let source else { return "Nothing" }
        if (10000..<11000).contains(source) {
            let me = (source - 10000) / 10 - 1, preview = source % 10 == 1
            return preview ? "\(mixName(me)) preview" : mixName(me)
        }
        return label(source, state)
    }

    /// The screen an aux (from 1) feeds, if named.
    /// The screens previewed in the top bar, four at most so the bar stays one row.
    var pinnedScreens: [ScreenOutput] {
        let all = config.screens
        if all.contains(where: { $0.pinned != nil }) { return Array(all.filter { $0.pinned == true }.prefix(4)) }
        return Array(all.filter(\.forVolunteers).prefix(3))
    }

    /// Pins or unpins a screen, first writing down which ones were pinned by default so
    /// the others don't change.
    func setPinned(_ id: String, _ on: Bool) {
        let now = Set(pinnedScreens.map(\.id))
        update { c in
            for i in c.screens.indices { c.screens[i].pinned = c.screens[i].id == id ? on : now.contains(c.screens[i].id) }
        }
    }

    func screen(aux: Int) -> ScreenOutput? { config.screens.first { $0.aux.contains(aux) } }

    func label(_ input: Int?, _ state: ATEMState) -> String {
        guard let input else { return "Nothing" }
        if let l = config.sources.first(where: { $0.input == input })?.label, !l.isEmpty { return l }
        if let cam = config.cameras.first(where: { $0.atemInput == input }), !cam.name.isEmpty { return cam.name }
        return state.inputs[input]?.long ?? "Input \(input)"
    }

    // MARK: Private

    private func apply() {
        guard let b = booth else { return }
        b.ptz.manualSpeed = config.ptzSpeed
        let me = max(0, config.me - 1)
        if b.me != me { b.me = me }
        guard !readOnly else { return }
        if b.atem.host != config.atemHost { b.atem.connect(config.atemHost) }
        if b.ptz.cameras != config.cameras { b.ptz.cameras = config.cameras }
    }

    private func poll() {
        let mod = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
        guard mod != lastModified else { return }
        if let c = read(), c != config {
            config = c
            apply()
        }
    }

    private func read() -> CueConfig? {
        lastModified = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
        guard let data = try? Data(contentsOf: url) else { return nil }
        do {
            let c = try JSONDecoder().decode(CueConfig.self, from: data)
            fileError = nil
            unreadable = false
            loadedAt = Date()
            keepLastGood(c, data)
            return c
        } catch {
            fileError = Self.explain(error)
            unreadable = true
            return nil
        }
    }

    private func write() {
        guard !readOnly else { return }
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        guard let data = try? enc.encode(config) else { return }
        if let old = try? Data(contentsOf: url), old == data { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        do {
            if unreadable {
                // The file on disk has a mistake in it and may hold work that isn't in the
                // app. Keep it under another name before saving over it; if that fails,
                // leave it alone.
                let f = DateFormatter()
                f.locale = Locale(identifier: "en_US_POSIX")
                f.dateFormat = "yyyyMMdd-HHmmss"
                let aside = url.deletingLastPathComponent().appendingPathComponent("config.unreadable-\(f.string(from: Date())).json")
                try FileManager.default.copyItem(at: url, to: aside)
                unreadable = false
            }
            try data.write(to: url, options: .atomic)
            lastModified = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
            fileError = nil
            keepLastGood(config, data)
        } catch {
            fileError = "Couldn't save the setup: \(error.localizedDescription)"
        }
    }

    /// Remembers a setup that loaded or saved cleanly (never an empty one, and never during self-tests).
    private func keepLastGood(_ c: CueConfig, _ data: Data) {
        guard !readOnly, c != CueConfig() else { return }
        if let old = try? Data(contentsOf: lastGoodURL), old == data { return }
        try? data.write(to: lastGoodURL, options: .atomic)
    }

    /// First run with a config file: carry over what earlier versions kept in the app's preferences.
    private func migrated(_ b: Booth) -> CueConfig {
        var c = CueConfig()
        c.atemHost = UserDefaults.standard.string(forKey: "atemHost") ?? ""
        c.me = b.me + 1
        c.cameras = b.ptz.cameras
        return c
    }

    private static func explain(_ error: Error) -> String {
        guard let e = error as? DecodingError else { return error.localizedDescription }
        func path(_ p: [CodingKey]) -> String { p.map { $0.intValue.map { "[\($0)]" } ?? ".\($0.stringValue)" }.joined() }
        switch e {
        case .dataCorrupted(let ctx): return "Not valid JSON: \(ctx.underlyingError?.localizedDescription ?? ctx.debugDescription)"
        case .typeMismatch(_, let ctx), .valueNotFound(_, let ctx): return "Wrong value at \(path(ctx.codingPath)): \(ctx.debugDescription)"
        case .keyNotFound(let k, let ctx): return "Missing \(k.stringValue) at \(path(ctx.codingPath))"
        @unknown default: return error.localizedDescription
        }
    }
}
