import SwiftUI
import AVFoundation
import CoreImage
import CueATEM

/// The switcher's USB video output, as a picture. An ATEM Mini plugged into this Mac over USB
/// shows up as a webcam called "Blackmagic Design" carrying whatever its webcam output is set
/// to (Program, on an ATEM Mini Pro that's aux 2). That's the only way to see an HDMI-only
/// camera (a DJI Osmo Pocket, a camcorder) in Churchfront Video: it has no network picture of
/// its own, so its tile and the Live monitor show the USB picture while it's the source on
/// that output. Nothing is sent to the switcher; this only looks at what it puts out.
///
/// macOS asks for camera access the first time this runs (the ATEM counts as a camera).
final class USBFeed: NSObject, ObservableObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    @Published private(set) var image: CGImage?
    @Published private(set) var live = false
    /// The USB device's name, once found: "Blackmagic Design". Nil while there isn't one.
    @Published private(set) var deviceName: String?
    /// Why there's no picture, for Status: no device, access refused, or nothing yet.
    @Published private(set) var problem: String?
    private(set) var shape = ""

    /// Devices whose name has any of these are switchers (or other Blackmagic video out), not
    /// someone's webcam, which must never be grabbed by mistake.
    static let deviceNames = ["Blackmagic"]

    private let work = DispatchQueue(label: "cuevideo.usbfeed")
    private var session: AVCaptureSession?
    private var running = false
    private var lastShown = Date.distantPast
    private var lastFrame = Date.distantPast
    private var watchdog: DispatchSourceTimer?
    private let ci = CIContext(options: [.useSoftwareRenderer: false])

    func start() {
        work.async {
            guard !self.running else { return }
            self.running = true
            self.open()
            // The ATEM may be plugged in later, or its picture may stop: look again every few seconds.
            let t = DispatchSource.makeTimerSource(queue: self.work)
            t.schedule(deadline: .now() + 3, repeating: 3)
            t.setEventHandler { [weak self] in
                guard let self, self.running else { return }
                if self.session == nil { self.open() }
                else if Date().timeIntervalSince(self.lastFrame) > 3 { self.setLive(false) }
            }
            t.resume()
            self.watchdog = t
        }
    }

    func stop() {
        work.async {
            self.running = false
            self.watchdog?.cancel(); self.watchdog = nil
            self.session?.stopRunning(); self.session = nil
            self.setLive(false)
        }
    }

    /// The switcher's USB video device, if one is plugged in.
    static func device() -> AVCaptureDevice? {
        let found = AVCaptureDevice.DiscoverySession(deviceTypes: [.external], mediaType: .video, position: .unspecified).devices
        return found.first { d in deviceNames.contains { d.localizedName.localizedCaseInsensitiveContains($0) } }
    }

    private func open() {
        guard let dev = Self.device() else {
            DispatchQueue.main.async { self.deviceName = nil; self.problem = "No switcher on USB (no Blackmagic video device)" }
            return
        }
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: break
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] ok in
                self?.work.async { if ok, let self, self.running { self.open() } }
            }
            DispatchQueue.main.async { self.problem = "Waiting for camera access (macOS is asking)" }
            return
        default:
            DispatchQueue.main.async { self.problem = "Camera access is off for Churchfront Video in System Settings > Privacy & Security > Camera" }
            return
        }
        do {
            let s = AVCaptureSession()
            s.sessionPreset = .high
            let input = try AVCaptureDeviceInput(device: dev)
            guard s.canAddInput(input) else { return }
            s.addInput(input)
            let out = AVCaptureVideoDataOutput()
            out.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
            out.alwaysDiscardsLateVideoFrames = true
            out.setSampleBufferDelegate(self, queue: work)
            guard s.canAddOutput(out) else { return }
            s.addOutput(out)
            s.startRunning()
            session = s
            lastFrame = Date()
            DispatchQueue.main.async { self.deviceName = dev.localizedName; self.problem = nil }
        } catch {
            DispatchQueue.main.async { self.problem = "Couldn't open \(dev.localizedName): \(error.localizedDescription)" }
        }
    }

    private func setLive(_ v: Bool) {
        DispatchQueue.main.async { if self.live != v { self.live = v } }
    }

    // On `work`.
    func captureOutput(_ output: AVCaptureOutput, didOutput sb: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard running, let pb = CMSampleBufferGetImageBuffer(sb) else { return }
        lastFrame = Date()
        // About 20 frames a second is plenty for a monitor.
        guard lastFrame.timeIntervalSince(lastShown) >= 0.05 else { return }
        lastShown = lastFrame
        let w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb)
        // Half size is enough for the monitors and costs a quarter of the drawing.
        let scale: CGFloat = w > 1280 ? 0.5 : 1
        let img = CIImage(cvPixelBuffer: pb).transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        guard let cg = ci.createCGImage(img, from: img.extent) else { return }
        let shape = "\(w)x\(h)"
        DispatchQueue.main.async {
            self.image = cg
            if self.shape != shape { self.shape = shape }
            if !self.live { self.live = true }
        }
    }
}

/// One capture, shared by everything showing the USB picture, running only while something is.
final class USBFeedHub {
    static let shared = USBFeedHub()
    let feed = USBFeed()
    private var users = 0

    func retain() {
        users += 1
        if users == 1 { feed.start() }
    }

    func release() {
        guard users > 0 else { return }
        users -= 1
        if users == 0 { feed.stop() }
    }

    /// For Status: whether the picture is coming in (nil when nothing is showing it).
    var isLive: Bool? { users == 0 ? nil : feed.live }

    /// Whether a switcher is on this Mac's USB right now. Cheap enough to ask on every draw.
    static var available: Bool { USBFeed.device() != nil }
}

extension ConfigStore {
    /// The switcher output the Mac's USB video comes from, as an aux counted from 1, or 0 when
    /// the USB output is always Program (an ATEM Mini without aux outputs). Set in the config
    /// file as `usbAux`; otherwise worked out from the model: on an ATEM Mini Pro, ISO or
    /// Extreme the USB output is the last aux (aux 2 on a Mini Pro: aux 1 is its HDMI out).
    func usbAux(_ state: ATEMState) -> Int? {
        if let a = config.usbAux { return a < 0 ? nil : a }
        guard state.product.localizedCaseInsensitiveContains("ATEM Mini") else { return nil }
        return state.auxCount == 0 ? 0 : state.auxCount
    }

    /// The switcher input the USB picture shows right now: what's on the USB output, with an
    /// M/E's program or preview followed through to the input that's on it. Nil when there's
    /// no switcher on USB or the output carries something that isn't an input (the multiview).
    func usbInput(_ state: ATEMState) -> Int? {
        guard state.product.isEmpty == false, USBFeedHub.available, let aux = usbAux(state) else { return nil }
        var source = aux == 0 ? 10010 : (state.aux[aux - 1] ?? -1)
        if (10000..<11000).contains(source) {
            let me = (source - 10000) / 10 - 1
            source = (source % 10 == 1 ? state.preview[me] : state.program[me]) ?? -1
        }
        return (1...999).contains(source) ? source : nil
    }

    /// Whether an input's picture can come from the switcher's USB output right now.
    func usbShows(_ input: Int?, _ state: ATEMState) -> Bool {
        guard let input else { return false }
        return usbInput(state) == input
    }
}

/// The switcher's USB picture, fitted to its frame.
struct USBVideo: View {
    @ObservedObject private var feed = USBFeedHub.shared.feed

    var body: some View {
        ZStack {
            Color.black
            if let img = feed.image {
                Image(decorative: img, scale: 1).resizable().aspectRatio(contentMode: .fit)
            }
            if !feed.live {
                VStack(spacing: T.s1) {
                    ProgressView().controlSize(.small)
                    Text(feed.problem ?? (feed.image == nil ? "Waiting for the switcher's USB picture" : "Picture stopped"))
                        .font(.sans(11)).foregroundStyle(T.inkMuted).lineLimit(2).minimumScaleFactor(0.7).multilineTextAlignment(.center)
                }
                .padding(T.s2)
                .background(RoundedRectangle(cornerRadius: T.rMD).fill(Color.black.opacity(0.6)))
            }
        }
        .allowsHitTesting(false)
        .onAppear { USBFeedHub.shared.retain() }
        .onDisappear { USBFeedHub.shared.release() }
    }
}
