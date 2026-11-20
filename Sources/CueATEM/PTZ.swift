import Foundation
import Network
import Combine

// PTZ cameras. Three ways in:
// - Canon (HTTP): Canon's own control protocol on port 80 (CR-N series and
//   other Canon PTZs). Works out of the box and reports the camera's preset names.
// - VISCA over IP (UDP 52381): Sony, BirdDog, newer PTZOptics, Panasonic in VISCA mode,
//   Canon when its VISCA setting is on, and NDI HX cameras such as Fomako (the one
//   tested answered position and zoom inquiries here but never on TCP 5678).
// - VISCA over TCP (5678): PTZOptics and most budget cameras.
//
// Only Canon's protocol reads a picture; every other camera's picture is the NDI source
// set for its switcher input (an NDI HX camera's own stream, say). None of the VISCA
// cameras need a login: the admin login in Setup is for Canon preset changes only.

public enum VISCAProtocol: String, Codable, CaseIterable, Identifiable {
    case canonXC, sonyUDP, rawTCP
    public var id: String { rawValue }
    public var label: String {
        switch self {
        case .canonXC: return "Canon (HTTP)"
        case .sonyUDP: return "VISCA over IP (UDP)"
        case .rawTCP: return "VISCA over TCP"
        }
    }
    public var defaultPort: UInt16 {
        switch self {
        case .canonXC: return 80
        case .sonyUDP: return 52381
        case .rawTCP: return 5678
        }
    }
    /// Canon's HTTP protocol can't save presets without an admin login.
    public var canStorePresets: Bool { self != .canonXC }
}

public struct PTZCamera: Codable, Identifiable, Hashable {
    public var id = UUID()
    public var name = "Camera"
    public var host = ""
    public var port: UInt16 = 52381
    public var proto: VISCAProtocol = .sonyUDP
    /// The ATEM input this camera feeds, so selecting it on preview picks the camera.
    public var atemInput: Int?
    /// Some VISCA cameras count presets from 1 instead of 0.
    public var firstPreset = 0
    /// Names for preset buttons, by preset number (1 based).
    public var presetNames: [Int: String] = [:]
    /// Shots saved in CueVideo (not on the camera), in button order.
    public var shots: [PTZShot] = []
    public init() {}

    private enum Keys: String, CodingKey { case id, name, host, port, proto, atemInput, firstPreset, presetNames, shots }

    /// Lenient, so a camera can be written by hand (or by Claude) in the config file:
    /// only `host` is needed, everything else has a sensible default. The port follows
    /// the protocol when it's left out.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? "Camera"
        host = try c.decodeIfPresent(String.self, forKey: .host) ?? ""
        proto = try c.decodeIfPresent(VISCAProtocol.self, forKey: .proto) ?? .sonyUDP
        port = try c.decodeIfPresent(UInt16.self, forKey: .port) ?? proto.defaultPort
        atemInput = try c.decodeIfPresent(Int.self, forKey: .atemInput)
        firstPreset = try c.decodeIfPresent(Int.self, forKey: .firstPreset) ?? 0
        presetNames = try c.decodeIfPresent([Int: String].self, forKey: .presetNames) ?? [:]
        shots = try c.decodeIfPresent([PTZShot].self, forKey: .shots) ?? []
    }
}

/// Where a camera is pointing, in the camera's own units. For Canon: pan and tilt in
/// hundredths of a degree (pan -17000 to 17000), zoom in the camera's zoom steps.
public struct PTZPosition: Codable, Hashable {
    public var pan: Int
    public var tilt: Int
    public var zoom: Int
    public init(pan: Int, tilt: Int, zoom: Int) { self.pan = pan; self.tilt = tilt; self.zoom = zoom }
}

/// Manual exposure in the camera's own units. For Canon: gain in tenths of a dB (65 is
/// 6.5 dB), shutter as the speed's denominator (60 is 1/60), iris as the f-number times
/// 100 (450 is f/4.5). White balance: a mode (auto, daylight, tungsten or kelvin) and, for
/// kelvin, the color temperature (4300). Any left out stay as they are.
public struct PTZExposure: Codable, Hashable {
    public var gain: Int?
    public var shutter: Int?
    public var iris: Int?
    public var wb: String?
    public var kelvin: Int?
    public init(gain: Int? = nil, shutter: Int? = nil, iris: Int? = nil, wb: String? = nil, kelvin: Int? = nil) {
        self.gain = gain; self.shutter = shutter; self.iris = iris; self.wb = wb; self.kelvin = kelvin
    }
    public var hasExposure: Bool { gain != nil || shutter != nil || iris != nil }
    public var hasWhiteBalance: Bool { wb != nil || kelvin != nil }
}

/// What a camera's exposure is now, and the values it accepts, for the controls.
public struct CameraExposure: Hashable {
    public var value = PTZExposure()
    /// Which of gain, shutter and iris the camera is setting itself.
    public var gainAuto = false, shutterAuto = false, irisAuto = false
    public var gainList: [Int] = [], shutterList: [Int] = [], irisList: [Int] = []
    public var kelvinList: [Int] = []
    /// Gain is a plain level (0, 1, 2…) as the camera's own menu shows it, not tenths of a dB.
    public var gainIsLevel = false
    /// The camera has one auto exposure mode that takes gain, shutter and iris back together.
    public var hasAutoMode = false
    public var allAuto: Bool { gainAuto && shutterAuto && irisAuto }
    public init() {}

    public func gainLabel(_ v: Int?) -> String {
        gainIsLevel ? (v.map { "Level \($0)" } ?? "?") : Self.gainText(v)
    }

    /// "Auto", "Daylight", "Tungsten" or "4300 K".
    public static func wbText(_ mode: String?, _ kelvin: Int?) -> String {
        switch mode {
        case "auto": return "Auto"
        case "daylight": return "Daylight"
        case "tungsten": return "Tungsten"
        case "kelvin": return kelvin.map { "\($0) K" } ?? "Kelvin"
        case nil: return kelvin.map { "\($0) K" } ?? "?"
        default: return "Custom"
        }
    }

    public static func gainText(_ v: Int?) -> String { v.map { String(format: "%.1f dB", Double($0) / 10) } ?? "?" }
    public static func shutterText(_ v: Int?) -> String { v.map { "1/\($0)" } ?? "?" }
    public static func irisText(_ v: Int?) -> String { v.map { String(format: "f/%.1f", Double($0) / 100) } ?? "?" }
}

public enum ShotKind: String, Codable, CaseIterable {
    case position, exposure
}

/// A named shot saved in CueVideo's config file, so it can be made and edited from any Mac,
/// by hand or by Claude, without the camera's admin login. A shot holds either a position
/// (pan, tilt, zoom) or an exposure (gain, shutter, iris).
public struct PTZShot: Codable, Hashable, Identifiable {
    public var id = UUID()
    public var name: String
    public var kind: ShotKind = .position
    public var pan = 0
    public var tilt = 0
    public var zoom = 0
    public var exposure: PTZExposure?
    /// Made by a stage scan, not by hand. The next scan replaces these; yours are kept.
    public var auto = false
    public var position: PTZPosition { PTZPosition(pan: pan, tilt: tilt, zoom: zoom) }

    public init(name: String, _ p: PTZPosition) { self.name = name; pan = p.pan; tilt = p.tilt; zoom = p.zoom }
    public init(name: String, exposure e: PTZExposure) { self.name = name; kind = .exposure; exposure = e }

    private enum Keys: String, CodingKey { case id, name, kind, pan, tilt, zoom, exposure, auto }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? "Shot"
        exposure = try c.decodeIfPresent(PTZExposure.self, forKey: .exposure)
        kind = try c.decodeIfPresent(ShotKind.self, forKey: .kind) ?? (exposure != nil ? .exposure : .position)
        pan = try c.decodeIfPresent(Int.self, forKey: .pan) ?? 0
        tilt = try c.decodeIfPresent(Int.self, forKey: .tilt) ?? 0
        zoom = try c.decodeIfPresent(Int.self, forKey: .zoom) ?? 0
        auto = try c.decodeIfPresent(Bool.self, forKey: .auto) ?? false
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Keys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(kind, forKey: .kind)
        if auto { try c.encode(true, forKey: .auto) }
        if kind == .position {
            try c.encode(pan, forKey: .pan); try c.encode(tilt, forKey: .tilt); try c.encode(zoom, forKey: .zoom)
        } else {
            try c.encodeIfPresent(exposure, forKey: .exposure)
        }
    }
}

/// One camera connection, whatever the protocol.
protocol PTZLink: AnyObject {
    var onState: ((Bool) -> Void)? { get set }
    /// Preset names the camera reports, by number from 1.
    var onPresets: (([Int: String]) -> Void)? { get set }
    var onModel: ((String) -> Void)? { get set }
    /// Numbers of the camera's presets that hold only exposure, not a position.
    var onExposurePresets: ((Set<Int>) -> Void)? { get set }
    var onExposure: ((CameraExposure) -> Void)? { get set }
    /// Whether this app holds control of the camera (Canon gives control to one session at a time).
    var onControl: ((Bool) -> Void)? { get set }
    func start()
    func stop()
    /// Speeds from -1 to 1; up is positive tilt. Zero stops that axis.
    func drive(pan: Double, tilt: Double)
    /// Speeds in the camera's own units, signed (right and up positive), 0 stops. On Canon
    /// that's hundredths of a degree a second (10 to 10000). Used by auto tracking.
    func driveRaw(pan: Int, tilt: Int)
    func zoom(_ v: Double)
    func autoFocus(_ on: Bool)
    func focusOnce()
    func home()
    func recall(_ n: Int)
    func store(_ n: Int)
    /// Where the camera is now, or nil if it can't say.
    func readPosition(_ done: @escaping (PTZPosition?) -> Void)
    /// Where the camera is now, in whatever form goTo takes back exactly, for saving a shot.
    func readShotPosition(_ done: @escaping (PTZPosition?) -> Void)
    /// Move straight to a saved position.
    func goTo(_ p: PTZPosition)
    /// Delete a preset stored on the camera itself. Calls back with nil when it worked, or why not.
    func deletePreset(_ n: Int, _ done: @escaping (String?) -> Void)
    /// Read the exposure now (reported through onExposure).
    func readExposure()
    /// Set any of gain, shutter and iris, switching just those to manual.
    func setExposure(_ e: PTZExposure)
    /// Hand gain, shutter and iris back to the camera, where it has one mode for that.
    func autoExposure()
}

extension PTZLink {
    func readShotPosition(_ done: @escaping (PTZPosition?) -> Void) { readPosition(done) }
}

// MARK: - VISCA

/// How one make of VISCA camera counts. VISCA fixes the commands but not the units, so each
/// make needs its own numbers; this is the start of a per-camera library (exposure tables
/// and speed steps would live here too).
public struct VISCAUnits {
    /// Pan and tilt position counts in one degree.
    public var countsPerDegree: Double
    /// Zoom position when zoomed all the way in.
    public var zoomMax: Double
    /// Horizontal angle of view zoomed all the way out, in degrees, and the lens's zoom ratio.
    public var wideFOV: Double
    public var zoomRatio: Double
    /// Exposure. The camera counts in positions; these say what each one is: shutter position
    /// to the speed's denominator (60 is 1/60), iris position to the f-number times 100.
    /// Gain stays a level, 0 to gainMax, as the camera's own menu shows it.
    public var shutter: [Int: Int] = [:]
    public var iris: [Int: Int] = [:]
    public var gainMax = 0
    /// Color temperature: position 0 is kelvinBase, each step kelvinStep more, up to kelvinTop.
    public var kelvinBase = 2500, kelvinStep = 100, kelvinTop = 8000

    public func position(of value: Int, in table: [Int: Int]) -> Int? { table.first { $0.value == value }?.key }

    /// PTZOptics (and the other cameras built on the same VISCA firmware): 0x0990 counts is
    /// 170 degrees, zoom runs 0 to 0x4000. The angle of view is an estimate for a 20x lens,
    /// assuming it narrows evenly along the zoom range; it errs narrow on a 12x, which makes
    /// auto tracking gentler, not jumpy.
    ///
    /// Exposure: the color temperature range is from PTZOptics' VISCA document. The shutter
    /// and iris tables are the ones PTZOptics has published for its earlier cameras; their
    /// current document gives the commands but no tables, so check these against the
    /// camera's own menu.
    public static let ptzOptics = VISCAUnits(
        countsPerDegree: 14.4, zoomMax: 16384, wideFOV: 58, zoomRatio: 20,
        shutter: [1: 30, 2: 60, 3: 90, 4: 100, 5: 125, 6: 180, 7: 250, 8: 350, 9: 500, 10: 725, 11: 1000,
                  12: 1500, 13: 2000, 14: 3000, 15: 4000, 16: 6000, 17: 10000],
        iris: [1: 1100, 2: 960, 3: 800, 4: 680, 5: 560, 6: 480, 7: 400, 8: 340, 9: 280, 10: 240, 11: 200, 12: 180],
        gainMax: 14)

    public func fov(zoom: Int) -> Double {
        wideFOV * pow(1 / zoomRatio, min(1, max(0, Double(zoom) / zoomMax)))
    }

    /// As a Canon reports it: pan and tilt in hundredths of a degree (right and up positive),
    /// zoom as the horizontal angle of view in hundredths of a degree.
    public func position(pan: Int, tilt: Int, zoom: Int) -> PTZPosition {
        PTZPosition(pan: Int((Double(pan) / countsPerDegree * 100).rounded()),
                    tilt: Int((Double(tilt) / countsPerDegree * 100).rounded()),
                    zoom: Int((fov(zoom: zoom) * 100).rounded()))
    }
}

final class VISCALink: PTZLink {
    let camera: PTZCamera
    private let queue: DispatchQueue
    private var conn: NWConnection?
    private var seq: UInt32 = 0
    var onState: ((Bool) -> Void)?
    var onPresets: (([Int: String]) -> Void)?
    var onModel: ((String) -> Void)?
    var onExposurePresets: ((Set<Int>) -> Void)?
    var onExposure: ((CameraExposure) -> Void)?
    var onControl: ((Bool) -> Void)?
    private var online = false { didSet { if online != oldValue { onState?(online) } } }
    /// UDP has no connection to tell us the camera went away, so a position inquiry goes out
    /// every `udpCheckEvery` seconds and the camera counts as gone after `udpSilence` seconds
    /// without an answer. Only touched on `queue`.
    private var lastRx = Date.distantPast
    private var liveness: DispatchSourceTimer?
    static var udpCheckEvery = 4.0
    static var udpSilence = 10.0
    // Reading the position. Only touched on `queue`.
    private var rx: [UInt8] = []
    /// Who is waiting for the position, and whether they want the camera's own counts (to save
    /// a shot that goTo can return to exactly) or degrees (for auto tracking).
    private var posWaiters: [(counts: Bool, done: (PTZPosition?) -> Void)] = []
    private var posPanTilt: (Int, Int)?
    private var posZoom: Int?
    private var posAsk = 0
    /// Inquiries sent and not yet answered, oldest first. A reply doesn't say what it answers;
    /// see `received` for how it's matched.
    private enum Inq { case panTilt, zoom, aeMode, shutter, iris, gain, wbMode, colorTemp
        var length: Int { switch self { case .panTilt: return 11; case .zoom, .shutter, .iris, .gain: return 7; default: return 4 } }
    }
    private var pending: [(kind: Inq, at: Date)] = []
    private let units = VISCAUnits.ptzOptics
    // The exposure being read, and the last one read.
    private var reading = CameraExposure()
    private var aeMode = -1
    private var lastExposure: CameraExposure?

    init(_ camera: PTZCamera, queue: DispatchQueue) {
        self.camera = camera
        self.queue = queue
    }

    func start() {
        rx.removeAll(); pending.removeAll()
        guard !camera.host.isEmpty, let port = NWEndpoint.Port(rawValue: camera.port) else { return }
        let params: NWParameters
        if camera.proto == .sonyUDP {
            params = .udp
        } else {
            // Keepalive notices a camera that lost power or was unplugged, which never closes the stream.
            let tcp = NWProtocolTCP.Options()
            tcp.enableKeepalive = true
            tcp.keepaliveIdle = 5
            tcp.keepaliveInterval = 2
            tcp.keepaliveCount = 3
            tcp.connectionTimeout = 5
            params = NWParameters(tls: nil, tcp: tcp)
        }
        let c = NWConnection(host: NWEndpoint.Host(camera.host), port: port, using: params)
        c.stateUpdateHandler = { [weak self, weak c] st in
            guard let self, let c, c === self.conn else { return }
            switch st {
            case .ready:
                if self.camera.proto == .rawTCP { self.online = true; self.readExposure() }
            case .failed, .waiting:
                self.online = false
                c.cancel()
                self.queue.asyncAfter(deadline: .now() + 3) { [weak self] in
                    guard let self, c === self.conn else { return }
                    self.start()
                }
            default: break
            }
        }
        conn = c
        c.start(queue: queue)
        receive(c)
        if camera.proto == .sonyUDP {
            seq = 0
            // Reset the camera's sequence number, then ask where it points so we know it
            // answers (some cameras turn down the power inquiry, but all answer this one).
            c.send(content: Data([0x02, 0x00, 0x00, 0x01, 0, 0, 0, 0, 0x01]), completion: .contentProcessed { _ in })
            ask(.panTilt, [0x81, 0x09, 0x06, 0x12, 0xFF])
            liveness?.cancel()
            let t = DispatchSource.makeTimerSource(queue: queue)
            t.schedule(deadline: .now() + Self.udpCheckEvery, repeating: Self.udpCheckEvery)
            t.setEventHandler { [weak self] in
                guard let self, self.conn === c else { return }
                if self.online, Date().timeIntervalSince(self.lastRx) > Self.udpSilence { self.online = false }
                self.ask(.panTilt, [0x81, 0x09, 0x06, 0x12, 0xFF])
            }
            t.resume()
            liveness = t
        }
    }

    func stop() { liveness?.cancel(); liveness = nil; conn?.cancel(); conn = nil; online = false }

    private func receive(_ c: NWConnection) {
        let handler: (Data?, NWConnection.ContentContext?, Bool, NWError?) -> Void = { [weak self] data, _, done, err in
            guard let self, c === self.conn else { return }
            if let data, !data.isEmpty { self.lastRx = Date(); self.online = true; self.received(data) }
            // A TCP camera that reboots closes the stream (or errors) without the connection
            // ever leaving .ready, so reconnect here or every later command goes nowhere.
            if self.camera.proto == .rawTCP, err != nil || (done && (data?.isEmpty ?? true)) {
                self.reconnect(c)
                return
            }
            if err == nil { self.receive(c) }
        }
        if camera.proto == .sonyUDP { c.receiveMessage(completion: handler) }
        else { c.receive(minimumIncompleteLength: 1, maximumLength: 4096, completion: handler) }
    }

    /// Drops a dead connection and dials again in 3 seconds.
    private func reconnect(_ c: NWConnection) {
        guard c === conn else { return }
        online = false
        c.cancel()
        queue.asyncAfter(deadline: .now() + 3) { [weak self] in
            guard let self, c === self.conn else { return }
            self.start()
        }
    }

    func send(_ visca: [UInt8], inquiry: Bool = false) {
        guard let conn else { return }
        if camera.proto == .rawTCP {
            conn.send(content: Data(visca), completion: .contentProcessed { [weak self, weak conn] err in
                guard let self, let conn, err != nil else { return }
                self.queue.async { self.reconnect(conn) }
            })
            return
        }
        seq &+= 1
        let n = UInt16(visca.count)
        let header: [UInt8] = [0x01, inquiry ? 0x10 : 0x00, UInt8(n >> 8), UInt8(n & 0xFF),
                               UInt8(seq >> 24), UInt8((seq >> 16) & 0xFF), UInt8((seq >> 8) & 0xFF), UInt8(seq & 0xFF)]
        conn.send(content: Data(header + visca), completion: .contentProcessed { _ in })
    }

    func drive(pan: Double, tilt: Double) {
        let ps = pan == 0 ? 1 : max(1, min(0x18, Int((pan * pan * 24).rounded())))
        let ts = tilt == 0 ? 1 : max(1, min(0x14, Int((tilt * tilt * 20).rounded())))
        let p: UInt8 = pan == 0 ? 0x03 : (pan < 0 ? 0x01 : 0x02)
        let t: UInt8 = tilt == 0 ? 0x03 : (tilt > 0 ? 0x01 : 0x02)
        send([0x81, 0x01, 0x06, 0x01, UInt8(ps), UInt8(ts), p, t, 0xFF])
    }

    func driveRaw(pan: Int, tilt: Int) {
        func v(_ r: Int) -> Double { r == 0 ? 0 : (r < 0 ? -1 : 1) * min(1, (Double(abs(r)) / 10000).squareRoot() * 1.8) }
        drive(pan: v(pan), tilt: v(tilt))
    }

    func zoom(_ v: Double) {
        let p = UInt8(min(7, max(0, Int((abs(v) * 7).rounded()))))
        if v == 0 { send([0x81, 0x01, 0x04, 0x07, 0x00, 0xFF]) }
        else { send([0x81, 0x01, 0x04, 0x07, (v > 0 ? 0x20 : 0x30) | p, 0xFF]) }
    }

    func autoFocus(_ on: Bool) { send([0x81, 0x01, 0x04, 0x38, on ? 0x02 : 0x03, 0xFF]) }
    /// One-push autofocus. In auto focus the camera is focusing anyway and some ignore this;
    /// in manual focus it focuses once and holds, like a focus lock. Camera > Auto Focus
    /// (autoFocus(true)) hands focus back to the camera.
    func focusOnce() { send([0x81, 0x01, 0x04, 0x18, 0x01, 0xFF]) }
    func home() { send([0x81, 0x01, 0x06, 0x04, 0xFF]) }
    func recall(_ n: Int) { send([0x81, 0x01, 0x04, 0x3F, 0x02, UInt8(clamping: n - 1 + camera.firstPreset), 0xFF]) }
    func store(_ n: Int) { send([0x81, 0x01, 0x04, 0x3F, 0x01, UInt8(clamping: n - 1 + camera.firstPreset), 0xFF]) }
    // VISCA cameras keep shots in their own presets (store/recall above) for now.

    /// Where the camera is, in the same units a Canon reports (see VISCAUnits): asks for pan
    /// and tilt and for zoom, and answers when both come back, or nil after half a second.
    func readPosition(_ done: @escaping (PTZPosition?) -> Void) { readPosition(counts: false, done) }

    /// A shot keeps the camera's own counts, so recalling it doesn't depend on how well
    /// CueVideo knows this make's degrees and angle of view.
    func readShotPosition(_ done: @escaping (PTZPosition?) -> Void) { readPosition(counts: true, done) }

    private func readPosition(counts: Bool, _ done: @escaping (PTZPosition?) -> Void) {
        posWaiters.append((counts, done))
        guard posWaiters.count == 1 else { return }   // already asking: this one gets the same answer
        posPanTilt = nil; posZoom = nil
        posAsk &+= 1
        let n = posAsk
        ask(.panTilt, [0x81, 0x09, 0x06, 0x12, 0xFF])
        ask(.zoom, [0x81, 0x09, 0x04, 0x47, 0xFF])
        queue.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self, self.posAsk == n, !self.posWaiters.isEmpty else { return }
            self.answerPosition(nil)
        }
    }

    private func answerPosition(_ counts: PTZPosition?) {
        let w = posWaiters
        posWaiters = []
        let degrees = counts.map { units.position(pan: $0.pan, tilt: $0.tilt, zoom: $0.zoom) }
        for f in w { f.done(f.counts ? counts : degrees) }
    }

    private func ask(_ kind: Inq, _ bytes: [UInt8]) {
        let now = Date()
        // Answers come within a few hundredths of a second. Anything still waiting after 1.5 s
        // was lost, and would put every later answer against the wrong question.
        if let first = pending.first, now.timeIntervalSince(first.at) > 1.5 { pending.removeAll() }
        pending.append((kind, now))
        send(bytes, inquiry: true)
    }

    /// Replies end in FF. y0 50 … answers the oldest inquiry; y0 60 … refuses it. Everything
    /// else (acknowledgements and completions of commands) is skipped.
    private func received(_ data: Data) {
        // VISCA over IP puts an 8-byte header in front of each message.
        rx.append(contentsOf: camera.proto == .sonyUDP ? data.dropFirst(8) : data[...])
        while let end = rx.firstIndex(of: 0xFF) {
            let m = Array(rx[...end])
            rx.removeSubrange(...end)
            guard m.count >= 3, m[1] == 0x50 || m[1] == 0x60, !pending.isEmpty else { continue }
            // A refusal: of the oldest inquiry, as far as anyone can tell.
            guard m[1] == 0x50 else { pending.removeFirst(); continue }
            // The camera answers its lens and picture questions in the order asked, but pan
            // and tilt are a separate part of it and can answer before or after them. So an
            // answer goes to the oldest inquiry it has the right shape for.
            guard let at = pending.firstIndex(where: { $0.kind.length == m.count }) else { continue }
            let kind = pending.remove(at: at).kind
            func word(_ at: Int) -> Int {
                let v = m[at..<at + 4].reduce(0) { ($0 << 4) | Int($1 & 0x0F) }
                return v >= 0x8000 ? v - 0x10000 : v
            }
            let low = m.count == 7 ? (Int(m[4] & 0x0F) << 4) | Int(m[5] & 0x0F) : Int(m[2])
            switch kind {
            case .panTilt, .zoom:
                if kind == .panTilt { posPanTilt = (word(2), word(6)) } else { posZoom = word(2) }
                if let pt = posPanTilt, let z = posZoom, !posWaiters.isEmpty {
                    answerPosition(PTZPosition(pan: pt.0, tilt: pt.1, zoom: z))
                }
            case .aeMode:
                // 0 full auto, 3 manual, 0A shutter priority, 0B iris priority, 0D bright.
                aeMode = low
                reading = CameraExposure()
                reading.shutterAuto = !(low == 0x03 || low == 0x0A)
                reading.irisAuto = !(low == 0x03 || low == 0x0B)
                reading.gainAuto = low != 0x03
            case .shutter: reading.value.shutter = units.shutter[low]
            case .iris: reading.value.iris = units.iris[low]
            case .gain: reading.value.gain = low
            case .wbMode:
                reading.value.wb = [0x00: "auto", 0x01: "tungsten", 0x02: "daylight", 0x20: "kelvin"][low] ?? "custom"
            case .colorTemp:
                reading.value.kelvin = min(units.kelvinTop, units.kelvinBase + low * units.kelvinStep)
                reading.gainIsLevel = true
                reading.hasAutoMode = true
                reading.gainList = Array(0...units.gainMax)
                reading.shutterList = units.shutter.values.sorted()
                reading.irisList = units.iris.values.sorted()
                reading.kelvinList = Array(stride(from: units.kelvinBase, through: units.kelvinTop, by: units.kelvinStep))
                lastExposure = reading
                onExposure?(reading)
            }
        }
        if rx.count > 256 { rx.removeAll() }
    }

    /// Gain, shutter, iris and white balance as they are now, reported through onExposure.
    func readExposure() {
        ask(.aeMode, [0x81, 0x09, 0x04, 0x39, 0xFF])
        ask(.shutter, [0x81, 0x09, 0x04, 0x4A, 0xFF])
        ask(.iris, [0x81, 0x09, 0x04, 0x4B, 0xFF])
        ask(.gain, [0x81, 0x09, 0x04, 0x4C, 0xFF])
        ask(.wbMode, [0x81, 0x09, 0x04, 0x35, 0xFF])
        ask(.colorTemp, [0x81, 0x09, 0x04, 0x20, 0xFF])
    }

    func autoExposure() {
        send([0x81, 0x01, 0x04, 0x39, 0x00, 0xFF])
        queue.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.readExposure() }
    }

    /// These cameras have one exposure mode for all three, not one each as a Canon has:
    /// setting any of gain, shutter or iris puts the camera in manual exposure. So the
    /// picture doesn't jump, the other two are set to what the camera had them at.
    func setExposure(_ e: PTZExposure) {
        func direct(_ op: UInt8, _ v: Int) { send([0x81, 0x01, 0x04, op, 0x00, 0x00, UInt8((v >> 4) & 0x0F), UInt8(v & 0x0F), 0xFF]) }
        if e.hasExposure {
            let had = aeMode == 0x03 ? nil : lastExposure?.value
            send([0x81, 0x01, 0x04, 0x39, 0x03, 0xFF])
            if let v = e.shutter ?? had?.shutter, let p = units.position(of: v, in: units.shutter) { direct(0x4A, p) }
            if let v = e.iris ?? had?.iris, let p = units.position(of: v, in: units.iris) { direct(0x4B, p) }
            if let v = e.gain ?? had?.gain { direct(0x0C, max(0, min(units.gainMax, v))) }
        }
        // White balance: a kelvin value sets color temperature mode; a mode alone sets just that.
        if let k = e.kelvin, e.wb == nil || e.wb == "kelvin" {
            let p = max(0, min((units.kelvinTop - units.kelvinBase) / units.kelvinStep, (k - units.kelvinBase) / units.kelvinStep))
            send([0x81, 0x01, 0x04, 0x35, 0x20, 0xFF])
            send([0x81, 0x01, 0x04, 0x20, UInt8((p >> 4) & 0x0F), UInt8(p & 0x0F), 0xFF])
        } else if let m = e.wb, let code: UInt8 = ["auto": 0x00, "tungsten": 0x01, "daylight": 0x02][m] {
            send([0x81, 0x01, 0x04, 0x35, code, 0xFF])
        }
        // Read back what the camera actually took, once the commands have gone.
        queue.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.readExposure() }
    }

    /// Straight to a saved shot (in the camera's own counts, from readShotPosition): pan and
    /// tilt together at a brisk speed, and zoom.
    func goTo(_ p: PTZPosition) {
        func nibbles(_ v: Int) -> [UInt8] { (0..<4).map { UInt8((v >> (12 - 4 * $0)) & 0x0F) } }
        send([0x81, 0x01, 0x06, 0x02, 0x14, 0x12] + nibbles(p.pan) + nibbles(p.tilt) + [0xFF])
        send([0x81, 0x01, 0x04, 0x47] + nibbles(max(0, p.zoom)) + [0xFF])
    }
    /// Clears a preset slot on the camera. The camera can't say whether the slot held anything.
    func deletePreset(_ n: Int, _ done: @escaping (String?) -> Void) {
        send([0x81, 0x01, 0x04, 0x3F, 0x00, UInt8(clamping: n - 1 + camera.firstPreset), 0xFF])
        done(nil)
    }
}

// MARK: - Canon (HTTP)

/// Canon's control protocol: open a session, claim control, then control.cgi
/// with pan=left|right|stop, tilt=up|down|stop, zoom=tele|wide|stop, p=<preset>.
final class CanonLink: PTZLink {
    let camera: PTZCamera
    private let queue: DispatchQueue
    private let http: URLSession
    private var session: String?
    private var opening = false
    private var stopped = false
    private var timer: DispatchSourceTimer?
    private var lastPresetRead = Date.distantPast
    var onState: ((Bool) -> Void)?
    var onPresets: (([Int: String]) -> Void)?
    var onModel: ((String) -> Void)?
    var onExposurePresets: ((Set<Int>) -> Void)?
    var onExposure: ((CameraExposure) -> Void)?
    var onControl: ((Bool) -> Void)?
    private var online = false { didSet { if online != oldValue { onState?(online) } } }

    init(_ camera: PTZCamera, queue: DispatchQueue) {
        self.camera = camera
        self.queue = queue
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 3
        cfg.httpMaximumConnectionsPerHost = 2
        http = URLSession(configuration: cfg)
        // Position reads (auto tracking asks several times a second) get their own connection,
        // so they never hold up a joystick or zoom command.
        let rc = URLSessionConfiguration.ephemeral
        rc.timeoutIntervalForRequest = 2
        rc.httpMaximumConnectionsPerHost = 1
        reads = URLSession(configuration: rc)
    }
    private let reads: URLSession

    private var base: String { "http://\(camera.host)\(camera.port == 80 ? "" : ":\(camera.port)")/-wvhttp-01-/" }

    /// Canon replies with "key:=value" lines ("key==value" while a value is changing).
    static func parse(_ text: String) -> [String: String] {
        var out: [String: String] = [:]
        for line in text.split(whereSeparator: \.isNewline) {
            let l = String(line)
            if let r = l.range(of: ":=") ?? l.range(of: "==") { out[String(l[..<r.lowerBound])] = String(l[r.upperBound...]) }
        }
        return out
    }

    private func get(_ path: String, _ done: ((String?) -> Void)? = nil) {
        guard let url = URL(string: base + path) else { done?(nil); return }
        http.dataTask(with: url) { [weak self] data, resp, err in
            guard let self else { return }
            let text = data.map { String(decoding: $0, as: UTF8.self) }
            let ok = err == nil && (resp as? HTTPURLResponse)?.statusCode == 200
            self.queue.async {
                if !ok, text?.contains("Error") != false {
                    done?(nil)
                } else {
                    done?(text)
                }
            }
        }.resume()
    }

    func start() {
        stopped = false
        guard !camera.host.isEmpty else { return }
        open()
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 10, repeating: 10)
        t.setEventHandler { [weak self] in self?.keepAlive() }
        t.resume()
        timer = t
    }

    func stop() {
        stopped = true
        timer?.cancel(); timer = nil
        if let s = session { get("close.cgi?s=\(s)") }
        session = nil
        online = false
        hasControl = false
    }

    private func open() {
        guard !opening, !stopped else { return }
        opening = true
        get("open.cgi") { [weak self] text in
            guard let self else { return }
            self.opening = false
            guard let text, let s = Self.parse(text)["s"] else {
                self.online = false
                self.queue.asyncAfter(deadline: .now() + 3) { [weak self] in self?.open() }
                return
            }
            self.session = s
            self.claim(s) { [weak self] in self?.readInfo() }
        }
    }

    /// Whether this session holds control. Canon hands control to one session at a time;
    /// the rest are told to wait (a logged-in session, such as the camera's own web page,
    /// outranks this one).
    private var hasControl = false { didSet { if hasControl != oldValue { onControl?(hasControl) } } }
    private var claimRetry = false

    /// Asks for control and reads the answer. While told to wait, asks again every 1.5 s.
    private func claim(_ s: String, then: (() -> Void)? = nil) {
        get("claim.cgi?s=\(s)") { [weak self] text in
            guard let self, self.session == s else { return }
            guard let text else {
                // The session is gone; start a new one.
                self.session = nil; self.hasControl = false; self.online = false; self.open(); return
            }
            self.online = true
            self.hasControl = (Self.parse(text)["s.control"] ?? "").hasPrefix("enabled")
            if !self.hasControl && !self.claimRetry {
                self.claimRetry = true
                self.queue.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                    guard let self else { return }
                    self.claimRetry = false
                    if !self.stopped, !self.hasControl, let cur = self.session { self.claim(cur) }
                }
            }
            if self.hasControl { self.pump() }  // anything kept while control was away (a stop)
            then?()
        }
    }

    private func keepAlive() {
        guard let s = session else { open(); return }
        claim(s)
        if Date().timeIntervalSince(lastPresetRead) > 60 { readInfo() }
    }

    private func readInfo() {
        lastPresetRead = Date()
        get("info.cgi") { [weak self] text in
            guard let self, let text else { return }
            let kv = Self.parse(text)
            if let model = kv["s.hardware"] { self.onModel?(model) }
            var names: [Int: String] = [:]
            var exposureOnly: Set<Int> = []
            for (k, v) in kv where k.hasPrefix("p.") && k.hasSuffix(".name.utf8") && !v.isEmpty {
                guard let n = Int(k.dropFirst(2).dropLast(10)), kv["p.\(n).content"] != "disabled" else { continue }
                names[n] = v
                // Presets like "Exposure" hold the picture's exposure but no position.
                if kv["p.\(n).content.ptz"] == "disabled" { exposureOnly.insert(n) }
            }
            self.onPresets?(names)
            self.onExposurePresets?(exposureOnly)
            self.onExposure?(Self.exposure(kv))
        }
    }

    static func exposure(_ kv: [String: String]) -> CameraExposure {
        func list(_ k: String) -> [Int] { (kv["c.1.\(k).list"] ?? "").split(separator: ",").compactMap { Int($0) } }
        var e = CameraExposure()
        e.value = PTZExposure(gain: kv["c.1.me.gain"].flatMap(Int.init), shutter: kv["c.1.me.shutter"].flatMap(Int.init),
                              iris: kv["c.1.me.diaphragm"].flatMap(Int.init))
        let auto = kv["c.1.exp"] == "auto"
        e.gainAuto = auto || kv["c.1.me.gain.mode"] == "auto"
        e.shutterAuto = auto || kv["c.1.me.shutter.mode"] == "auto"
        e.irisAuto = auto || kv["c.1.me.diaphragm.mode"] == "auto"
        e.gainList = list("me.gain"); e.shutterList = list("me.shutter"); e.irisList = list("me.diaphragm")
        e.value.wb = kv["c.1.wb"]
        e.value.kelvin = kv["c.1.wb.kelvin"].flatMap(Int.init)
        e.kelvinList = list("wb.kelvin")
        return e
    }

    func readExposure() {
        get("info.cgi") { [weak self] text in
            guard let self, let text else { return }
            self.onExposure?(Self.exposure(Self.parse(text)))
        }
    }

    // A Canon sets gain, shutter and iris to auto one at a time; CueVideo doesn't yet.
    func autoExposure() {}

    /// Exposure goes through the same control channel as pan and tilt, as on the camera's own
    /// web page. Each value set also switches that one setting (and the camera) to manual.
    func setExposure(_ e: PTZExposure) {
        var q: [String] = e.hasExposure ? ["exp=manual"] : []
        if let g = e.gain { q += ["me.gain.mode=manual", "me.gain=\(g)"] }
        if let s = e.shutter { q += ["me.shutter.mode=speed", "me.shutter=\(s)"] }
        if let i = e.iris { q += ["me.diaphragm.mode=manual", "me.diaphragm=\(i)"] }
        // White balance: a kelvin value sets kelvin mode; a mode alone (auto, daylight,
        // tungsten) sets just that.
        if let k = e.kelvin, e.wb == nil || e.wb == "kelvin" { q += ["wb=kelvin", "wb.kelvin=\(k)"] }
        else if let m = e.wb { q += ["wb=\(m)"] }
        guard !q.isEmpty else { return }
        control(q.joined(separator: "&"))
        // Read back what the camera actually took, once the command has gone.
        queue.asyncAfter(deadline: .now() + 0.4) { [weak self] in self?.readExposure() }
    }

    // One control request at a time, and the newest joystick or zoom move replaces any
    // that is still waiting. A drag makes dozens of updates a second; sent in parallel
    // they queued up (lag) and could land out of order, so a stop overtaken by an older
    // move left the camera drifting.
    private var sending = false
    private var queued: [(key: String?, query: String, tries: Int)] = []
    private var lastDrive = "", lastZoom = ""

    private func control(_ query: String, key: String? = nil) {
        if let key, let i = queued.firstIndex(where: { $0.key == key }) {
            queued[i].query = query
            queued[i].tries = 0
        } else {
            queued.append((key, query, 0))
        }
        pump()
    }

    private static func isStop(_ query: String) -> Bool { query == "pan=stop&tilt=stop" || query == "zoom=stop" }

    private func pump() {
        guard !sending, !queued.isEmpty else { return }
        // No session: moves that were waiting are dropped, but a stop is kept and sent as
        // soon as the camera is back, so it can't be left moving.
        guard let s = session else { queued.removeAll { !Self.isStop($0.query) }; open(); return }
        let next = queued.removeFirst()
        sending = true
        get("control.cgi?s=\(s)&\(next.query)") { [weak self] text in
            guard let self else { return }
            self.sending = false
            if text == nil {
                // The camera turned the request down, didn't answer, or control was taken.
                // Drop the moves that were waiting, but never a stop: keep any that is
                // queued, and try a failed stop again (a few times) unless something newer
                // for the same control has replaced it. Then ask for control again;
                // claim() opens a new session if this one is gone, and sends what's kept.
                self.queued.removeAll { !Self.isStop($0.query) }
                if Self.isStop(next.query), next.tries < 3, !self.queued.contains(where: { $0.key == next.key }) {
                    self.queued.insert((next.key, next.query, next.tries + 1), at: 0)
                }
                self.hasControl = false
                self.claim(s)
            } else {
                self.pump()
            }
        }
    }

    // Canon speeds run 10 to 10000 for pan and tilt (very fast at the top), 0 to 127 for zoom.
    private func speed(_ v: Double) -> Int { min(10000, Int(10 + v * v * 3000)) }

    func drive(pan: Double, tilt: Double) {
        let p = pan == 0 ? "pan=stop" : "pan=\(pan < 0 ? "left" : "right")&pan.speed=\(speed(pan))"
        let t = tilt == 0 ? "tilt=stop" : "tilt=\(tilt > 0 ? "up" : "down")&tilt.speed=\(speed(tilt))"
        let q = p + "&" + t
        lastDrive = q
        control(q, key: "drive")
        if pan == 0 && tilt == 0 { resendStop(q, key: "drive") { $0.lastDrive } }
    }

    func driveRaw(pan: Int, tilt: Int) {
        let p = pan == 0 ? "pan=stop" : "pan=\(pan < 0 ? "left" : "right")&pan.speed=\(min(10000, max(20, abs(pan))))"
        let t = tilt == 0 ? "tilt=stop" : "tilt=\(tilt > 0 ? "up" : "down")&tilt.speed=\(min(10000, max(20, abs(tilt))))"
        let q = p + "&" + t
        lastDrive = q
        control(q, key: "drive")
        if pan == 0 && tilt == 0 { resendStop(q, key: "drive") { $0.lastDrive } }
    }

    func zoom(_ v: Double) {
        let q = v == 0 ? "zoom=stop" : "zoom=\(v > 0 ? "tele" : "wide")&zoom.speed=\(min(127, Int(1 + abs(v) * 60)))"
        lastZoom = q
        control(q, key: "zoom")
        if v == 0 { resendStop(q, key: "zoom") { $0.lastZoom } }
    }

    /// Sends a stop once more shortly after, unless something newer was sent, so a camera
    /// never keeps moving because one stop went missing.
    private func resendStop(_ q: String, key: String, latest: @escaping (CanonLink) -> String) {
        queue.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self, latest(self) == q else { return }
            self.control(q, key: key)
        }
    }

    func autoFocus(_ on: Bool) { control("focus=\(on ? "auto" : "manual")") }
    func focusOnce() { control("focus.action=one_shot") }
    func home() { control("pan=0&tilt=0") }
    func recall(_ n: Int) { control("p=\(n)") }
    func store(_ n: Int) {}

    func readPosition(_ done: @escaping (PTZPosition?) -> Void) {
        // Only pan, tilt and zoom: about 1 KB instead of the whole 30 KB info page.
        guard let url = URL(string: base + "info.cgi?item=c.1.pan,c.1.tilt,c.1.zoom") else { done(nil); return }
        reads.dataTask(with: url) { [weak self] data, _, _ in
            let kv = data.map { Self.parse(String(decoding: $0, as: UTF8.self)) } ?? [:]
            self?.queue.async { Self.position(kv, done) }
        }.resume()
    }

    private static func position(_ kv: [String: String], _ done: @escaping (PTZPosition?) -> Void) {
        do {
            guard let p = kv["c.1.pan"].flatMap(Int.init), let t = kv["c.1.tilt"].flatMap(Int.init),
                  let z = kv["c.1.zoom"].flatMap(Int.init) else { done(nil); return }
            done(PTZPosition(pan: p, tilt: t, zoom: z))
        }
    }

    /// Deletes a preset the way the camera's own web page does: changing presets needs a
    /// logged-in session (priority 40, above the anonymous one CueVideo drives with), so this
    /// opens one with the saved admin login, takes control, deletes, and closes it again.
    /// CueVideo's everyday session gets control back on its next keep-alive.
    func deletePreset(_ n: Int, _ done: @escaping (String?) -> Void) {
        guard let login = CameraLogin.load() else {
            done("No camera login saved. Add the cameras' admin login in Setup, under PTZ cameras."); return
        }
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 5
        let admin = URLSession(configuration: cfg, delegate: LoginDelegate(login), delegateQueue: nil)
        // Every step reports the HTTP status, the camera's livescope-status and the body.
        func call(_ path: String, _ next: @escaping (Int, String, String) -> Void) {
            guard let url = URL(string: base + path) else { next(0, "", ""); return }
            admin.dataTask(with: url) { data, resp, _ in
                let r = resp as? HTTPURLResponse
                let status = r?.value(forHTTPHeaderField: "livescope-status") ?? ""
                let body = data.map { String(decoding: $0, as: UTF8.self) } ?? ""
                self.queue.async { next(r?.statusCode ?? 0, status, body) }
            }.resume()
        }
        func finish(_ why: String?, _ sid: String?) {
            if let sid { call("close.cgi?s=\(sid)") { _, _, _ in } }
            admin.finishTasksAndInvalidate()
            done(why)
            readInfo()  // refresh the preset list either way
        }
        call("open.cgi?s.priority=40") { code, _, body in
            if code == 401 { finish("The camera turned down the saved login. Check the user name and password in Setup.", nil); return }
            guard let sid = Self.parse(body)["s"] else { finish("The camera wouldn't open a logged-in session (HTTP \(code)).", nil); return }
            var tries = 0
            func claim() {
                call("claim.cgi?s=\(sid)") { _, _, body in
                    let control = Self.parse(body)["s.control"] ?? ""
                    if control.hasPrefix("enabled") {
                        call("preset/set?p=\(n)&cmd=delete&s=\(sid)") { _, status, body in
                            if status.hasPrefix("0") { finish(nil, sid) }
                            else { finish("The camera said: \(status.isEmpty ? body.trimmingCharacters(in: .whitespacesAndNewlines) : status)", sid) }
                        }
                    } else if tries < 6 {
                        tries += 1
                        self.queue.asyncAfter(deadline: .now() + 0.5) { claim() }
                    } else {
                        finish("Another controller has the camera, so it wouldn't hand over control (\(control)).", sid)
                    }
                }
            }
            claim()
        }
    }

    func goTo(_ p: PTZPosition) {
        let q = "pan=\(p.pan)&tilt=\(p.tilt)&zoom=\(p.zoom)"
        lastDrive = q  // so a joystick stop still waiting to be re-sent can't cut this move short
        control(q, key: "drive")
    }
}

// MARK: - Controller

public final class PTZController: ObservableObject {
    @Published public var cameras: [PTZCamera] = [] { didSet { save(); if links(differ: oldValue) { restart() } } }
    /// The camera the joystick, zoom and arrow keys drive. When it changes while the old
    /// camera is being moved by hand (Next was cut to Live with the joystick still held),
    /// the old camera is stopped, so it is never left moving on Live.
    @Published public var selected: UUID? {
        didSet {
            guard oldValue != selected else { return }
            lastDrive = nil
            if let old = oldValue { stopManual(old) }
        }
    }
    @Published public private(set) var online: Set<UUID> = []
    /// Preset names the cameras report themselves (Canon), by camera.
    @Published public private(set) var reportedPresets: [UUID: [Int: String]] = [:]
    @Published public private(set) var models: [UUID: String] = [:]
    /// Each camera's exposure now and the values it accepts.
    @Published public private(set) var exposure: [UUID: CameraExposure] = [:]
    /// Camera presets that hold only exposure, by camera.
    @Published public private(set) var exposurePresets: [UUID: Set<Int>] = [:]
    /// Cameras this app currently holds control of. A camera can be answering but not in
    /// here when another controller (such as its web page) has it.
    @Published public private(set) var controlled: Set<UUID> = []

    private let queue = DispatchQueue(label: "cuevideo.ptz")
    private var links: [UUID: PTZLink] = [:]
    private var lastDrive: (Int, Int)?
    /// Cameras being panned, tilted or zoomed by hand (or by Claude) right now. Main thread.
    private var moving: Set<UUID> = [], zooming: Set<UUID> = []
    private let key = "ptzCameras"

    public init(load: Bool = true) {
        if load, let d = UserDefaults.standard.data(forKey: key), let c = try? JSONDecoder().decode([PTZCamera].self, from: d) {
            cameras = c
        }
        selected = cameras.first?.id
        restart()
    }

    private func save() {
        if let d = try? JSONEncoder().encode(cameras) { UserDefaults.standard.set(d, forKey: key) }
    }

    /// Only reconnect when an address or protocol changed, not when a name did.
    private func links(differ old: [PTZCamera]) -> Bool {
        old.map { "\($0.id)\($0.host)\($0.port)\($0.proto)\($0.firstPreset)" } != cameras.map { "\($0.id)\($0.host)\($0.port)\($0.proto)\($0.firstPreset)" }
    }

    private func restart() {
        let cams = cameras
        queue.async {
            for l in self.links.values { l.stop() }
            self.links = [:]
            for c in cams {
                let l: PTZLink = c.proto == .canonXC ? CanonLink(c, queue: self.queue) : VISCALink(c, queue: self.queue)
                l.onState = { [weak self] on in
                    DispatchQueue.main.async { if on { self?.online.insert(c.id) } else { self?.online.remove(c.id) } }
                }
                l.onPresets = { [weak self] names in DispatchQueue.main.async { self?.reportedPresets[c.id] = names } }
                l.onModel = { [weak self] m in DispatchQueue.main.async { self?.models[c.id] = m } }
                l.onExposure = { [weak self] e in DispatchQueue.main.async { self?.exposure[c.id] = e } }
                l.onControl = { [weak self] on in
                    DispatchQueue.main.async { if on { self?.controlled.insert(c.id) } else { self?.controlled.remove(c.id) } }
                }
                l.onExposurePresets = { [weak self] s in DispatchQueue.main.async { self?.exposurePresets[c.id] = s } }
                self.links[c.id] = l
                l.start()
            }
        }
        if let s = selected, !cameras.contains(where: { $0.id == s }) { selected = cameras.first?.id }
        if selected == nil { selected = cameras.first?.id }
    }

    public var current: PTZCamera? { cameras.first { $0.id == selected } }

    /// Preset names for a camera: what you typed wins, then what the camera reports.
    public func presetNames(_ c: PTZCamera) -> [Int: String] {
        (reportedPresets[c.id] ?? [:]).merging(c.presetNames) { _, mine in mine }
    }

    /// Picks the camera wired to this ATEM input, if there is one.
    public func follow(atemInput: Int?) {
        guard let i = atemInput, let c = cameras.first(where: { $0.atemInput == i }), c.id != selected else { return }
        selected = c.id
    }

    /// Called (on main) with the camera whenever a person or Claude moves it: the joystick,
    /// a shot, a preset or home. Auto tracking uses it to hand the camera straight back.
    public var onManualMove: ((UUID) -> Void)?
    /// Overall speed for manual control (joystick, zoom rocker, arrow keys, Claude's moves):
    /// 1 is normal, 0.25 very slow and fine, 2 twice as fast. Auto tracking has its own speed.
    public var manualSpeed = 1.0
    /// Called (on main) whenever a person or Claude zooms a camera. Auto tracking keeps
    /// following and takes the new zoom as the shot size to hold.
    public var onManualZoom: ((UUID) -> Void)?

    private func manual(_ camera: UUID?) {
        guard let id = camera ?? selected else { return }
        if Thread.isMainThread { onManualMove?(id) } else { DispatchQueue.main.async { self.onManualMove?(id) } }
    }

    /// Zoom for auto tracking, -1 to 1, without counting as a manual zoom.
    public func trackZoom(_ v: Double, camera: UUID) { with(camera) { $0.zoom(max(-1, min(1, v))) } }

    /// Pan and tilt for auto tracking in the camera's own speed units (Canon: hundredths of a
    /// degree a second), signed, without counting as a manual move.
    public func trackDriveRaw(pan: Int, tilt: Int, camera: UUID) { with(camera) { $0.driveRaw(pan: pan, tilt: tilt) } }

    /// Where a camera is now (Canon: pan and tilt in hundredths of a degree, zoom as the
    /// horizontal angle of view in hundredths of a degree), on main; nil if it can't say.
    public func readPosition(camera: UUID, _ done: @escaping (PTZPosition?) -> Void) {
        with(camera) { $0.readPosition { p in DispatchQueue.main.async { done(p) } } }
    }

    /// Pan and tilt for auto tracking: speeds -1 to 1, sent as given, without counting as a manual move.
    public func trackDrive(pan: Double, tilt: Double, camera: UUID) {
        with(camera) { $0.drive(pan: max(-1, min(1, pan)), tilt: max(-1, min(1, tilt))) }
    }

    private func with(_ id: UUID? = nil, _ f: @escaping (PTZLink) -> Void) {
        guard let id = id ?? selected else { return }
        queue.async { if let l = self.links[id] { f(l) } }
    }

    /// Pan and tilt from a joystick: x and y from -1 to 1, up is positive y.
    /// Every camera command below goes to the selected camera unless `camera` names another.
    public func drive(x: Double, y: Double, camera: UUID? = nil) {
        let dead = 0.08
        let px = abs(x) < dead ? 0 : max(-1, min(1, x)), py = abs(y) < dead ? 0 : max(-1, min(1, y))
        // Only send when the direction or speed step changes, so a drag doesn't flood the camera.
        let step = (Int((px * 12).rounded()), Int((py * 12).rounded()))
        if px != 0 || py != 0 { manual(camera) }
        if let id = camera ?? selected {
            if px != 0 || py != 0 { moving.insert(id) } else { moving.remove(id) }
        }
        if camera == nil, let l = lastDrive, l == step { return }
        if camera == nil { lastDrive = step }
        let k = manualSpeed
        with(camera) { $0.drive(pan: px * k, tilt: py * k) }
    }

    public func stopDrive(camera: UUID? = nil) {
        if camera == nil { lastDrive = nil }
        if let id = camera ?? selected { moving.remove(id) }
        with(camera) { $0.drive(pan: 0, tilt: 0) }
    }

    /// Stops one camera's manual pan, tilt and zoom, if it has any under way.
    private func stopManual(_ id: UUID) {
        if moving.remove(id) != nil { with(id) { $0.drive(pan: 0, tilt: 0) } }
        if zooming.remove(id) != nil { with(id) { $0.zoom(0) } }
    }

    /// Stops every camera that is being moved or zoomed by hand. Called when CueVideo quits
    /// or stops being the front app, when a key or mouse release may never arrive.
    public func stopAllManual() {
        lastDrive = nil
        for id in moving.union(zooming) { stopManual(id) }
    }

    /// Zoom speed from -1 (wide) to 1 (tele); 0 stops.
    public func zoom(_ v: Double, camera: UUID? = nil) {
        let z = abs(v) < 0.05 ? 0 : v
        if let id = camera ?? selected {
            if z != 0 { zooming.insert(id) } else { zooming.remove(id) }
            if Thread.isMainThread { onManualZoom?(id) } else { DispatchQueue.main.async { self.onManualZoom?(id) } }
        }
        let k = manualSpeed
        with(camera) { $0.zoom(z * k) }
    }
    public func autoFocus(_ on: Bool, camera: UUID? = nil) { with(camera) { $0.autoFocus(on) } }
    public func focusOnce(camera: UUID? = nil) { with(camera) { $0.focusOnce() } }
    public func home(camera: UUID? = nil) { manual(camera); with(camera) { $0.home() } }

    /// Presets are numbered from 1 here, whatever the camera counts from.
    public func recall(_ n: Int, camera: UUID? = nil) { manual(camera); with(camera) { $0.recall(n) } }
    public func store(_ n: Int) { with { $0.store(n) } }

    /// Recall a saved shot: move to its position, or set its exposure.
    public func go(to shot: PTZShot, camera: UUID? = nil) {
        switch shot.kind {
        case .position: manual(camera); with(camera) { $0.goTo(shot.position) }
        case .exposure: if let e = shot.exposure { setExposure(e, camera: camera) }
        }
    }

    /// Set any of gain, shutter and iris on a camera (the selected one by default).
    public func setExposure(_ e: PTZExposure, camera: UUID? = nil) {
        // Show the new value straight away; the camera's read-back confirms it.
        if let id = camera ?? selected {
            var x = exposure[id] ?? CameraExposure()
            if let g = e.gain { x.value.gain = g; x.gainAuto = false }
            if let s = e.shutter { x.value.shutter = s; x.shutterAuto = false }
            if let i = e.iris { x.value.iris = i; x.irisAuto = false }
            if let k = e.kelvin, e.wb == nil || e.wb == "kelvin" { x.value.wb = "kelvin"; x.value.kelvin = k }
            else if let m = e.wb { x.value.wb = m }
            exposure[id] = x
        }
        with(camera) { $0.setExposure(e) }
    }

    /// Hands gain, shutter and iris back to the camera (cameras with one auto exposure mode).
    public func autoExposure(camera: UUID? = nil) {
        if let id = camera ?? selected, var x = exposure[id], x.hasAutoMode {
            x.gainAuto = true; x.shutterAuto = true; x.irisAuto = true
            exposure[id] = x
        }
        with(camera) { $0.autoExposure() }
    }

    /// Re-read a camera's exposure, for when someone may have changed it elsewhere.
    public func refreshExposure(camera: UUID? = nil) { with(camera) { $0.readExposure() } }

    /// Reads the camera now and saves it as a shot: a new one, or over `replacing`. A position
    /// shot keeps pan, tilt and zoom; an exposure shot keeps gain, shutter and iris.
    /// Calls back on the main thread with false if the camera couldn't say.
    public func saveShot(_ name: String, camera id: UUID, kind: ShotKind = .position, replacing: UUID? = nil, done: ((Bool) -> Void)? = nil) {
        if kind == .exposure {
            refreshExposure(camera: id)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                guard let e = self.exposure[id]?.value, e.gain != nil || e.shutter != nil || e.iris != nil,
                      let i = self.cameras.firstIndex(where: { $0.id == id }) else { done?(false); return }
                if let r = replacing, let j = self.cameras[i].shots.firstIndex(where: { $0.id == r }) {
                    self.cameras[i].shots[j].kind = .exposure
                    self.cameras[i].shots[j].exposure = e
                    if !name.isEmpty { self.cameras[i].shots[j].name = name }
                } else {
                    let n = self.cameras[i].shots.filter { $0.kind == .exposure }.count + 1
                    self.cameras[i].shots.append(PTZShot(name: name.isEmpty ? "Exposure \(n)" : name, exposure: e))
                }
                done?(true)
            }
            return
        }
        queue.async {
            guard let l = self.links[id] else { DispatchQueue.main.async { done?(false) }; return }
            l.readShotPosition { p in
                DispatchQueue.main.async {
                    guard let p, let i = self.cameras.firstIndex(where: { $0.id == id }) else { done?(false); return }
                    if let r = replacing, let j = self.cameras[i].shots.firstIndex(where: { $0.id == r }) {
                        self.cameras[i].shots[j].kind = .position
                        self.cameras[i].shots[j].pan = p.pan
                        self.cameras[i].shots[j].tilt = p.tilt
                        self.cameras[i].shots[j].zoom = p.zoom
                        if !name.isEmpty { self.cameras[i].shots[j].name = name }
                    } else {
                        self.cameras[i].shots.append(PTZShot(name: name.isEmpty ? "Shot \(self.cameras[i].shots.count + 1)" : name, p))
                    }
                    done?(true)
                }
            }
        }
    }

    /// Deletes a preset stored on the camera. Calls back on the main thread with nil when it
    /// worked, or the reason it didn't.
    public func deleteCameraPreset(_ n: Int, camera id: UUID, done: @escaping (String?) -> Void) {
        queue.async {
            guard let l = self.links[id] else { DispatchQueue.main.async { done("That camera isn't set up.") }; return }
            l.deletePreset(n) { why in DispatchQueue.main.async { done(why) } }
        }
    }

    /// Whether moves will reach the camera: Canon needs this app to hold control; VISCA
    /// cameras take commands from anyone, so answering is enough.
    public func hasControl(_ c: PTZCamera) -> Bool {
        c.proto == .canonXC ? controlled.contains(c.id) : online.contains(c.id)
    }

    /// Whether this camera can save shots in CueVideo: it has to report where it is. Canon
    /// does over HTTP, VISCA cameras by inquiry.
    public func canSaveShots(_ c: PTZCamera) -> Bool { !c.host.isEmpty }
}
