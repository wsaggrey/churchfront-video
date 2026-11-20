import XCTest
import Network
@testable import CueATEM

/// A camera must never be left moving: these run the real camera code against pretend
/// cameras on this Mac (no hardware) and check that the stop goes out.
final class CameraStopTests: XCTestCase {

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: "ptzCameras")
    }

    /// Lets the main thread carry on (published updates land there) for a while, or until `until` is true.
    private func wait(_ seconds: Double, until: () -> Bool = { false }) {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end, !until() { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
    }

    // MARK: Next is cut to Live while the joystick is held

    /// The joystick drives the selected camera (the one on Next). When the selection moves to
    /// another camera mid-move, the first camera, now Live, has to be told to stop.
    func testSelectionChangeStopsTheCameraBeingMoved() throws {
        let a = try FakeVISCACamera(), b = try FakeVISCACamera()
        var camA = PTZCamera(); camA.name = "A"; camA.host = "127.0.0.1"; camA.port = a.port; camA.proto = .sonyUDP
        var camB = PTZCamera(); camB.name = "B"; camB.host = "127.0.0.1"; camB.port = b.port; camB.proto = .sonyUDP
        let ptz = PTZController(load: false)
        ptz.cameras = [camA, camB]
        ptz.selected = camA.id

        ptz.drive(x: 1, y: 0)                     // joystick held to the right
        wait(1) { a.moves.contains { !$0.isStop } }
        XCTAssertTrue(a.moves.contains { !$0.isStop }, "camera A should have started panning")

        ptz.selected = camB.id                    // Cut: the other camera is on Next now
        wait(1) { a.moves.last?.isStop == true }
        XCTAssertEqual(a.moves.last?.isStop, true, "camera A was left panning after the selection moved on")
        XCTAssertTrue(b.moves.isEmpty, "camera B must not move until the joystick moves again")
    }

    /// Quitting (or losing the keyboard) stops whatever is being moved or zoomed by hand.
    func testStopAllManualStopsPanAndZoom() throws {
        let a = try FakeVISCACamera()
        var cam = PTZCamera(); cam.host = "127.0.0.1"; cam.port = a.port; cam.proto = .sonyUDP
        let ptz = PTZController(load: false)
        ptz.cameras = [cam]
        ptz.drive(x: 0, y: 1, camera: cam.id)
        ptz.zoom(1, camera: cam.id)
        wait(1) { a.moves.contains { !$0.isStop } && a.zooms.contains { !$0 } }

        ptz.stopAllManual()
        wait(1) { a.moves.last?.isStop == true && a.zooms.last == true }
        XCTAssertEqual(a.moves.last?.isStop, true, "pan and tilt weren't stopped")
        XCTAssertEqual(a.zooms.last, true, "zoom wasn't stopped")
    }

    // MARK: A camera over UDP stops answering

    /// UDP has no connection to drop, so a camera over VISCA over IP counts as answering
    /// only while it answers the regular position inquiry, and as gone once it stops.
    func testAUDPCameraCountsAsAnsweringOnlyWhileItAnswers() throws {
        let a = try FakeVISCACamera()
        a.answers = true
        let (every, silence) = (VISCALink.udpCheckEvery, VISCALink.udpSilence)
        VISCALink.udpCheckEvery = 0.3; VISCALink.udpSilence = 1
        defer { VISCALink.udpCheckEvery = every; VISCALink.udpSilence = silence }
        var cam = PTZCamera(); cam.host = "127.0.0.1"; cam.port = a.port; cam.proto = .sonyUDP
        let ptz = PTZController(load: false)
        ptz.cameras = [cam]
        wait(3) { ptz.online.contains(cam.id) }
        XCTAssertTrue(ptz.online.contains(cam.id), "a camera that answers inquiries should show as answering")

        a.answers = false                         // unplugged
        wait(4) { !ptz.online.contains(cam.id) }
        XCTAssertFalse(ptz.online.contains(cam.id), "a camera that stopped answering is still shown as answering")
    }

    // MARK: A Canon request fails while a stop is waiting

    /// Canon commands go one at a time. If one fails (here the camera turns down an exposure
    /// value) while a stop is waiting behind it, the stop must still be sent.
    func testCanonStopSurvivesAFailedRequest() throws {
        let canon = try FakeCanonCamera()
        var cam = PTZCamera(); cam.host = "127.0.0.1"; cam.port = canon.port; cam.proto = .canonXC
        let ptz = PTZController(load: false)
        ptz.cameras = [cam]
        wait(5) { ptz.controlled.contains(cam.id) }
        XCTAssertTrue(ptz.controlled.contains(cam.id), "the pretend Canon camera never gave control")

        canon.slowNextControl = 0.6               // the move is still on the wire while the rest queue up
        ptz.drive(x: 1, y: 0, camera: cam.id)
        ptz.setExposure(PTZExposure(gain: 60), camera: cam.id)   // the camera answers this with an error
        ptz.stopDrive(camera: cam.id)

        wait(5) { canon.controls.contains { $0.contains("pan=stop") } }
        let log = canon.controls
        let failed = try XCTUnwrap(log.firstIndex { $0.contains("me.gain") }, "the exposure request never arrived: \(log)")
        let stop = log.lastIndex { $0.contains("pan=stop&tilt=stop") }
        XCTAssertNotNil(stop, "the stop was dropped after the failed request, so the camera keeps panning: \(log)")
        if let stop { XCTAssertGreaterThan(stop, failed) }
    }
}

// MARK: - Pretend cameras

/// Listens on a UDP port and records the VISCA pan/tilt and zoom commands it's sent.
final class FakeVISCACamera {
    struct Move { let isStop: Bool }
    private let listener: NWListener
    private let queue = DispatchQueue(label: "fake.visca")
    private let lock = NSLock()
    private var _moves: [Move] = [], _zooms: [Bool] = []
    private var _answers = false
    private(set) var port: UInt16 = 0

    /// Whether the camera answers position inquiries (with the VISCA over IP header), as a
    /// real camera does. Off, it swallows everything, like one that lost power.
    var answers: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _answers }
        set { lock.lock(); _answers = newValue; lock.unlock() }
    }

    var moves: [Move] { lock.lock(); defer { lock.unlock() }; return _moves }
    /// One entry per zoom command: true for a zoom stop.
    var zooms: [Bool] { lock.lock(); defer { lock.unlock() }; return _zooms }

    init() throws {
        listener = try NWListener(using: .udp, on: .any)
        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { if case .ready = $0 { ready.signal() } }
        listener.newConnectionHandler = { [weak self] c in
            guard let self else { return }
            c.start(queue: self.queue)
            self.receive(c)
        }
        listener.start(queue: queue)
        guard ready.wait(timeout: .now() + 3) == .success, let p = listener.port?.rawValue else { throw URLError(.cannotConnectToHost) }
        port = p
    }

    deinit { listener.cancel() }

    private func receive(_ c: NWConnection) {
        c.receiveMessage { [weak self] data, _, _, err in
            guard let self else { return }
            if let data, data.count > 8 {
                let v = [UInt8](data.dropFirst(8))  // after the VISCA over IP header
                self.lock.lock()
                // Pan/tilt drive: 81 01 06 01 speed speed pan tilt FF; 03 03 is stop.
                if v.count == 9, v[2] == 0x06, v[3] == 0x01 { self._moves.append(Move(isStop: v[6] == 0x03 && v[7] == 0x03)) }
                // Zoom: 81 01 04 07 xx FF; 00 is stop.
                if v.count == 6, v[2] == 0x04, v[3] == 0x07 { self._zooms.append(v[4] == 0x00) }
                let answer = self._answers
                self.lock.unlock()
                // Pan/tilt position inquiry 81 09 06 12 FF: answer "pointing straight ahead".
                if answer, v == [0x81, 0x09, 0x06, 0x12, 0xFF] {
                    let header = [0x01, 0x11, 0x00, 0x0B] + Array(data[4..<8])
                    let reply: [UInt8] = [0x90, 0x50, 0, 0, 0, 0, 0, 0, 0, 0, 0xFF]
                    c.send(content: Data(header + reply), completion: .contentProcessed { _ in })
                }
            }
            if err == nil { self.receive(c) }
        }
    }
}

/// A tiny HTTP server that answers like a Canon camera's control interface: gives a session
/// and control, accepts pan, tilt and zoom, and turns down exposure values with an error.
final class FakeCanonCamera {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "fake.canon")
    private let lock = NSLock()
    private var _controls: [String] = []
    private var _slow = 0.0
    private(set) var port: UInt16 = 0

    /// The control.cgi requests received, in order.
    var controls: [String] { lock.lock(); defer { lock.unlock() }; return _controls }
    /// Holds back the answer to the next control request by this many seconds.
    var slowNextControl: Double {
        get { lock.lock(); defer { lock.unlock() }; return _slow }
        set { lock.lock(); _slow = newValue; lock.unlock() }
    }

    init() throws {
        listener = try NWListener(using: .tcp, on: .any)
        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { if case .ready = $0 { ready.signal() } }
        listener.newConnectionHandler = { [weak self] c in
            guard let self else { return }
            c.start(queue: self.queue)
            self.read(c, Data())
        }
        listener.start(queue: queue)
        guard ready.wait(timeout: .now() + 3) == .success, let p = listener.port?.rawValue else { throw URLError(.cannotConnectToHost) }
        port = p
    }

    deinit { listener.cancel() }

    private func read(_ c: NWConnection, _ got: Data) {
        c.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, done, err in
            guard let self else { return }
            var buf = got
            if let data { buf.append(data) }
            if buf.range(of: Data("\r\n\r\n".utf8)) != nil {
                let first = String(decoding: buf, as: UTF8.self).components(separatedBy: "\r\n").first ?? ""
                let parts = first.split(separator: " ")
                self.answer(c, parts.count > 1 ? String(parts[1]) : "")
            } else if done || err != nil {
                c.cancel()
            } else {
                self.read(c, buf)
            }
        }
    }

    private func answer(_ c: NWConnection, _ path: String) {
        var status = "200 OK", body = "OK\n", delay = 0.0
        if path.contains("open.cgi") { body = "s:=abc123\n" }
        else if path.contains("claim.cgi") { body = "s.control:=enabled\n" }
        else if path.contains("info.cgi") { body = "s.hardware:=Pretend Canon\n" }
        else if path.contains("control.cgi") {
            lock.lock()
            _controls.append(path.components(separatedBy: "control.cgi?").last ?? path)
            delay = _slow; _slow = 0
            lock.unlock()
            if path.contains("me.gain") { status = "406 Not Acceptable"; body = "--- WebView Livescope Http Server Error ---\nParameter Error\n" }
        }
        let text = "HTTP/1.1 \(status)\r\nContent-Type: text/plain\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
        queue.asyncAfter(deadline: .now() + delay) {
            c.send(content: Data(text.utf8), completion: .contentProcessed { _ in c.cancel() })
        }
    }
}

/// Showing Setup must not open the Keychain item (macOS asks for the Mac's password when it does).
final class CameraLoginTests: XCTestCase {
    func testTheUserNameComesFromPreferencesNotTheKeychain() {
        let before = UserDefaults.standard.string(forKey: "cameraLoginUser")
        defer { UserDefaults.standard.set(before, forKey: "cameraLoginUser") }
        UserDefaults.standard.set("booth", forKey: "cameraLoginUser")
        XCTAssertEqual(CameraLogin.savedUser, "booth")
        UserDefaults.standard.removeObject(forKey: "cameraLoginUser")
        XCTAssertNil(CameraLogin.savedUser)
    }
}
