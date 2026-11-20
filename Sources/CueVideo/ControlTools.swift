import Foundation
import AppKit
import CueATEM

/// Everything a person can do in CueVideo's windows, as tools for Claude (through the
/// CueVideo MCP server and ControlServer). One place defines both the tool list and what
/// each tool does, so the two can't drift apart.
///
/// Sources can be named by input number or by any of their names (the volunteer label,
/// a camera's name, or the switcher's long or short name). Cameras can be named by name,
/// IP address or switcher input; left out, a camera tool acts on the camera that's on Next,
/// just like the volunteer screen. A camera that's on Live won't move or change unless the
/// call says allow_live: true.
enum ControlTools {
    typealias Done = ([String: Any]) -> Void

    static var booth: Booth { Booth.shared }
    static var atem: ATEMClient { booth.atem }
    static var ptz: PTZController { booth.ptz }
    static var store: ConfigStore { booth.store }

    // MARK: Tool list

    private static func tool(_ name: String, _ description: String, _ props: [String: [String: Any]] = [:], required: [String] = []) -> [String: Any] {
        ["name": name, "description": description,
         "inputSchema": ["type": "object", "properties": props, "required": required] as [String: Any]]
    }
    private static func str(_ d: String) -> [String: Any] { ["type": "string", "description": d] }
    private static func num(_ d: String) -> [String: Any] { ["type": "number", "description": d] }
    private static func int(_ d: String) -> [String: Any] { ["type": "integer", "description": d] }
    private static func bool(_ d: String) -> [String: Any] { ["type": "boolean", "description": d] }
    private static func choice(_ d: String, _ values: [String]) -> [String: Any] { ["type": "string", "enum": values, "description": d] }
    private static func any(_ d: String) -> [String: Any] { ["type": ["string", "integer"], "description": d] }

    private static let source = any("Input number, or a name: the volunteer label, camera name, or the switcher's long or short name.")
    private static let camera = any("Camera name, IP address or switcher input. Leave out for the camera on Next.")
    private static let me = int("M/E, counted from 1. Leave out for the M/E volunteers run.")
    private static let allowLive = bool("Required as true to change a camera that's on Live (program).")

    static let definitions: [[String: Any]] = [
        // Status and setup
        tool("get_status", "Everything Churchfront Video knows right now: switcher connection, what's Live and Next on each M/E, keys, DSKs, aux, macros, recording and streaming, every source, the volunteer source row and key buttons, and each camera's connection, control, exposure, saved shots and on-camera presets."),
        tool("get_config", "The setup as saved in Churchfront Video's config file (JSON): switcher address, volunteer M/E, source row, key buttons, cameras and their saved shots."),
        tool("update_config", "Change the setup. Give any of the top-level fields (atemHost, me, sources, keys, cameras, trackSpeed 0.5 to 4, ptzSpeed 0.25 to 2 (manual camera control speed), trackTilt, trackZoom). Sources and keys take an optional ndi: an NDI source name from list_ndi_sources. pictures ({input number: NDI source name}, a live picture for a switcher input that is not in sources, such as a stage display). Routing: mixNames (what each M/E is for, from M/E 1), screens ([{name, aux: [numbers from 1], note, volunteer, pinned (a small preview in the top bar)}]), routes (volunteer routing buttons: [{label, set: [{aux, source}]}], source as an input number; M/E 1 program is 10010, M/E 2 program 10020); each one given replaces that whole field. Read get_config first and send back the edited field.",
             ["config": ["type": "object", "description": "Fields to replace, in the config file's format."]], required: ["config"]),
        tool("show_window", "Show a view of Churchfront Video's window on screen: operator (the booth screen, also called main), or a page of the Engineer view: scan (stage scan), routing, switcher (the full switcher), setup or status.", ["window": choice("Which view or page.", ["operator", "main", "scan", "routing", "switcher", "setup", "status"])], required: ["window"]),

        // Volunteer screen
        tool("set_next", "Put a source on Next (preview), like tapping its tile.", ["source": source, "me": me], required: ["source"]),
        tool("set_live", "Put a source straight on Live (program) with no transition, like Shift plus its number key.", ["source": source, "me": me], required: ["source"]),
        tool("cut", "Switch Next to Live instantly (Cut).", ["me": me]),
        tool("fade", "Fade from Live to Next (Fade, the auto transition).", ["me": me]),
        tool("fade_to_black", "Fade everything to black, or back up if already black (Black).", ["me": me]),
        tool("set_key_button", "Turn one of the volunteer key buttons (such as Lower thirds) on or off. Leave out on to toggle.",
             ["button": str("The button's label, such as Lower thirds."), "on": bool("true to put it on air, false to take it off.")], required: ["button"]),
        tool("set_recording", "Start or stop the switcher's recording.", ["on": bool("true to record.")], required: ["on"]),
        tool("set_streaming", "Start or stop the switcher's stream.", ["on": bool("true to stream.")], required: ["on"]),

        // Cameras
        tool("camera_move", "Pan and tilt a camera for a short time, like holding the joystick, then stop. Speeds run -1 to 1 (right and up are positive); small values are slow and smooth.",
             ["camera": camera, "pan": num("-1 (left) to 1 (right)."), "tilt": num("-1 (down) to 1 (up)."),
              "duration_ms": int("How long to move, 50 to 5000 ms. Default 500."), "allow_live": allowLive]),
        tool("camera_zoom", "Zoom a camera for a short time, then stop. Speed -1 (wide) to 1 (tight).",
             ["camera": camera, "speed": num("-1 (wide) to 1 (tight)."), "duration_ms": int("50 to 5000 ms. Default 500."), "allow_live": allowLive], required: ["speed"]),
        tool("camera_stop", "Stop any pan, tilt and zoom on a camera.", ["camera": camera]),
        tool("camera_focus", "Focus a camera: once (one-shot autofocus, like the Focus button), auto, or manual.",
             ["camera": camera, "mode": choice("Focus mode.", ["once", "auto", "manual"]), "allow_live": allowLive], required: ["mode"]),
        tool("get_routing", "Video routing in plain words: what each M/E mix is for and shows, every aux output with the screen it feeds, its wiring note and the picture it gets now, and the volunteer routing buttons (lit or not)."),
        tool("route_screen", "Send a picture to a screen (all of its linked aux outputs) or to one aux. Changes what that screen shows right away. Screens hidden from volunteers (encoders, recorders, patch bay feeds) need allow_hidden: true; confirm with the person first, since one may feed the live stream.",
             ["screen": any("Screen name, or aux number (from 1)."), "source": any("Input number or name, a mix name (such as Live stream or Side screens), or M/E 1 / M/E 2 (their program). Add 'preview' for an M/E's preview."),
              "allow_hidden": bool("Required as true to change a screen hidden from volunteers.")], required: ["screen", "source"]),
        tool("run_route_button", "Press one of the volunteer routing buttons, by label.", ["button": str("The button's label.")], required: ["button"]),
        tool("find_devices", "Find the switcher and cameras on this Mac's network, for first-time setup: ATEM switchers (they answer on UDP 9910), Canon PTZ cameras (their HTTP control page), and everything announcing itself over Bonjour (NDI sources, which include most PTZOptics, Fomako and BirdDog cameras, Blackmagic devices, device web pages), each with its IP address. Takes about 4 seconds and changes nothing. Then confirm with the person which is which and save it with update_config (atemHost, cameras with name, host, proto and atemInput; for an NDI HX camera also put its NDI name as the ndi of the source for its atemInput, which is where its picture comes from)."),
        tool("list_ndi_sources", "The NDI sources on the network now, by their exact names, for the ndi field of a volunteer source (a picture for its tile and the Next and Live monitors, such as Churchfront Screens' graphics) or of a key button (a picture with alpha laid over Next and Live when that key is on them, such as Churchfront Screens' lower thirds). Set them with update_config."),
        tool("start_tracking", "Auto tracking: make a camera follow a person, by watching its preview picture (a Canon's own, or for other cameras the NDI picture set for their switcher input). It frames them as a broadcast follow shot: shoulders up, waist up or full length (the shot the camera is closest to unless shot is given), eyes near the upper third, lead room on the side they face or walk toward, eased pan and tilt, and slow zooms to hold the size. Picks the person nearest the middle, or nearest x/y if given (0 to 1 across and down the picture), or with person, someone labelled in the last stage scan, by name, wherever they are in the shot. It keeps to that person by what they look like, so it stays with them when people cross and waits for them after losing sight. Waits up to 4 seconds for someone to be found. Any manual pan, tilt, shot or preset stops tracking; a manual zoom keeps it and holds the new size.",
             ["camera": camera, "shot": choice("Follow shot size.", ["shoulders", "waist", "full"]), "x": num("0 (left) to 1 (right) across the picture."), "y": num("0 (top) to 1 (bottom) down the picture."), "person": str("A name given in the last stage scan (get_status lists them)."), "allow_live": allowLive]),
        tool("scan_stage", "Stage scan, for before a service with everyone in place: each Canon camera that isn't on Live, tracking or out of Churchfront Video's control goes to a wide shot (its shot named Stage or Wide, else where it points now zoomed all the way out), Churchfront Video finds the people in it and works out the shot that frames each one from that camera, and the camera goes back. Returns every person each camera saw, with a number, a small picture, the proposed shot, and a letter: the same letter is a guess (by their look) at the same person on another camera. Nothing is saved until label_stage_scan. This moves cameras, so confirm with the person first.",
             ["cameras": ["type": "array", "items": ["type": ["string", "integer"]], "description": "Cameras to scan. Leave out for all."],
              "shot": choice("How to frame each person. Default waist.", ["shoulders", "waist", "full"]),
              "pictures": bool("Include each person's picture (default true).")]),
        tool("label_stage_scan", "Name the people from the last scan_stage and save: a shot per labelled person on each camera that saw them (replacing shots from earlier scans, keeping hand-made ones), and their look, so start_tracking can follow them by name until Churchfront Video quits. Label each number, or a letter to label everyone with that letter at once. Unlabelled people are skipped.",
             ["labels": ["type": "array", "items": ["type": "object", "properties": ["person": any("A person's number, or a letter for everyone with that letter."), "label": str("A name or role, such as Pastor or Keys.")] as [String: Any]] as [String: Any],
                         "description": "Who is who."]], required: ["labels"]),
        tool("get_framing", "The follow-shot framing rules auto tracking uses for each shot size (shoulders, waist, full), the built-in standard and any changes, plus the tracking response settings. Use with camera_snapshots to judge framing."),
        tool("set_framing", "Change how a follow shot is framed, live, while Churchfront Video runs: takes effect on tracking cameras within a frame. All measured as a share of the frame. eye_line: where the eyes sit, down from the top (less = less headroom). size: eyes-to-shoulders drop against frame height (bigger = tighter). lead_room: offset toward where they face or walk. dead_x / dead_y: how far they can drift before the camera moves. reset: true returns this size to the standard.",
             ["shot": choice("Shot size.", ["shoulders", "waist", "full"]), "eye_line": num("0.1 to 0.5."), "size": num("Shoulders about 0.36, waist 0.21, full 0.095."),
              "lead_room": num("0 to 0.2."), "dead_x": num("0.02 to 0.2."), "dead_y": num("0.02 to 0.2."), "reset": bool("Back to the standard.")], required: ["shot"]),
        tool("set_tracking_tuning", "Change how auto tracking responds, live. correction: pull toward the mark (default 1.2; higher reacts harder, too high wobbles). latency: seconds the preview runs behind (0.45). walk_threshold: speed in frames a second that counts as walking (0.12; higher ignores more small moves). zoom_threshold: how wrong the shot size must look before zooming (0.3, about a third). zoom_wait: seconds it must stay wrong first (1.5). speed: overall follow speed 0.5 to 4. reset: true returns all to defaults.",
             ["correction": num("0.4 to 2.5."), "latency": num("0.2 to 0.8."), "walk_threshold": num("0.05 to 0.4."), "zoom_threshold": num("0.1 to 0.8."),
              "zoom_wait": num("0.5 to 5."), "speed": num("0.5 to 4."), "reset": bool("Back to defaults.")]),
        tool("set_tracking_shot", "Reframe a tracking camera as a different follow shot: shoulders up, waist up or full length.",
             ["camera": camera, "shot": choice("Follow shot size.", ["shoulders", "waist", "full"]), "allow_live": allowLive], required: ["shot"]),
        tool("stop_tracking", "Stop auto tracking on a camera, or on every camera with all: true.", ["camera": camera, "all": bool("Stop every camera.")]),
        tool("camera_home", "Send a camera to its home position (pan and tilt 0).", ["camera": camera, "allow_live": allowLive]),
        tool("set_exposure", "Set a camera's gain, shutter, iris and/or white balance. Gain, shutter and iris each switch that setting to manual. Units: gain in tenths of a dB on a Canon (65 = 6.5 dB) or a plain level on a VISCA camera (get_status gives gain_unit), shutter as 1/x (60 = 1/60), iris as f-number times 100 (450 = f/4.5). On a VISCA camera, setting any of the three puts all three in manual, holding the other two where they were. auto: true hands gain, shutter and iris back to the camera (VISCA cameras only for now). White balance: auto, daylight, tungsten, or a color temperature in kelvin (4300); higher kelvin looks warmer. Values snap to the nearest the camera accepts; get_status lists them.",
             ["camera": camera, "gain": int("Tenths of a dB."), "shutter": int("Shutter speed denominator."), "iris": int("f-number times 100."),
              "white_balance": any("auto, daylight, tungsten, or kelvin as a number such as 4300."),
              "auto": bool("Auto exposure: the camera sets gain, shutter and iris itself. Not with gain, shutter or iris."), "allow_live": allowLive]),
        tool("camera_snapshots", "A still picture from each camera Churchfront Video has a picture for (or the ones named): Canon cameras, and others with an NDI picture set for their switcher input (that one is NDI's small preview, about 640 wide). With color measurements, to compare and match them: average red, green and blue, the color cast (red÷green and blue÷green; balanced is about 1), brightness (0 to 255), and the share of the picture clipped to white or crushed to black. Point the cameras at the same scene to compare fairly. Fix differences with set_exposure or match_exposure.",
             ["cameras": ["type": "array", "items": ["type": ["string", "integer"]], "description": "Cameras to look at. Leave out for all."],
              "pictures": bool("Include the pictures themselves (default true). False gives only the measurements.")]),
        tool("match_exposure", "Make cameras match one camera's exposure: copies gain, shutter, iris and white balance (or only the settings named) from one camera to the others, each value snapped to the nearest the other camera accepts (models differ). Leave out to for every other camera. Cameras on Live are skipped unless allow_live is true.",
             ["from": any("The camera to copy from (name, IP or input)."), "to": ["type": "array", "items": ["type": ["string", "integer"]], "description": "Cameras to change. Leave out for all the others."],
              "settings": ["type": "array", "items": ["type": "string", "enum": ["gain", "shutter", "iris", "white_balance"]], "description": "Which settings to copy. Leave out for all four."],
              "allow_live": allowLive], required: ["from"]),
        tool("recall_shot", "Recall a shot saved in Churchfront Video: move to its position, or set its exposure.",
             ["camera": camera, "shot": str("The shot's name."), "allow_live": allowLive], required: ["shot"]),
        tool("save_shot", "Save the camera as it is now as a Churchfront Video shot: its position (pan, tilt, zoom, the default) or its exposure (gain, shutter, iris).",
             ["camera": camera, "name": str("A short name, such as Pulpit."), "kind": choice("What to save. Default position.", ["position", "exposure"]),
              "replace": bool("true to overwrite an existing shot with this name instead of adding another.")], required: ["name"]),
        tool("rename_shot", "Rename a Churchfront Video shot.", ["camera": camera, "shot": str("Current name."), "new_name": str("New name.")], required: ["shot", "new_name"]),
        tool("delete_shot", "Delete a Churchfront Video shot (from the config file, not the camera).", ["camera": camera, "shot": str("The shot's name.")], required: ["shot"]),
        tool("recall_camera_preset", "Recall a preset stored on the camera itself.",
             ["camera": camera, "preset": any("Preset number or name."), "allow_live": allowLive], required: ["preset"]),
        tool("delete_camera_preset", "Delete a preset stored on the camera itself, for every controller. Can't be undone. Needs the camera admin login saved in Setup.",
             ["camera": camera, "preset": any("Preset number or name.")], required: ["preset"]),

        // Full switcher
        tool("switcher_set_program", "Full switcher: put a source on program on any M/E.", ["source": source, "me": me], required: ["source"]),
        tool("switcher_set_preview", "Full switcher: put a source on preview on any M/E.", ["source": source, "me": me], required: ["source"]),
        tool("set_transition_style", "Full switcher: transition style.", ["me": me, "style": choice("Style.", ["mix", "dip", "wipe", "dve"])], required: ["style"]),
        tool("set_mix_rate", "Full switcher: mix transition length in frames (30 = 1 second at 30 fps).", ["me": me, "frames": int("1 to 250.")], required: ["frames"]),
        tool("set_tbar", "Full switcher: move the T-bar, 0 to 1.", ["me": me, "position": num("0 to 1.")], required: ["position"]),
        tool("set_next_transition", "Full switcher: what the next transition takes: background and/or upstream keys.",
             ["me": me, "background": bool("Include the background."), "keys": ["type": "array", "items": ["type": "integer"], "description": "Keys to include, counted from 1."]]),
        tool("set_upstream_key", "Full switcher: put an upstream key on or off air.", ["me": me, "keyer": int("Key, counted from 1."), "on": bool("On air.")], required: ["keyer", "on"]),
        tool("dsk", "Full switcher: a downstream key. on/off cut it, auto fades it, tie_on/tie_off tie it to the next transition.",
             ["dsk": int("DSK, counted from 1."), "action": choice("What to do.", ["on", "off", "auto", "tie_on", "tie_off"])], required: ["dsk", "action"]),
        tool("set_aux", "Full switcher: route a source to an aux output.", ["aux": int("Aux, counted from 1."), "source": source], required: ["aux", "source"]),
        tool("run_macro", "Full switcher: run a recorded macro.", ["macro": any("Macro number (from 1) or name.")], required: ["macro"]),
        tool("stop_macro", "Full switcher: stop the running macro."),
    ]

    // MARK: Running a tool

    struct Failure: Error { let message: String }
    static func fail(_ m: String) -> Failure { Failure(message: m) }

    static func call(_ name: String, _ a: [String: Any], _ done: @escaping Done) {
        do {
            try run(name, a, done)
        } catch let f as Failure {
            done(["error": f.message])
        } catch {
            done(["error": "\(error)"])
        }
    }

    private static func ok(_ what: String, _ extra: [String: Any] = [:]) -> [String: Any] { extra.merging(["ok": true, "done": what]) { a, _ in a } }

    private static func run(_ name: String, _ a: [String: Any], _ done: @escaping Done) throws {
        let s = atem.state
        switch name {
        case "get_status": done(status())
        case "get_config": done(["config": try configObject(), "file": store.url.path])
        case "update_config":
            guard let patch = a["config"] as? [String: Any] else { throw fail("Give config as an object.") }
            var obj = try configObject()
            for (k, v) in patch where ["atemHost", "me", "sources", "keys", "cameras", "trackSpeed", "ptzSpeed", "framing", "trackTuning", "trackTilt", "trackZoom", "mixNames", "pictures", "screens", "routes"].contains(k) { obj[k] = v }
            let data = try JSONSerialization.data(withJSONObject: obj)
            let c: CueConfig
            do { c = try JSONDecoder().decode(CueConfig.self, from: data) } catch { throw fail("That config doesn't fit the format: \(error)") }
            store.update { $0 = c }
            done(ok("Config updated", ["config": try configObject()]))
        case "show_window":
            let w = a["window"] as? String ?? "main"
            NotificationCenter.default.post(name: .cueVideoShowWindow, object: w)
            NSApp.activate(ignoringOtherApps: true)
            done(ok("Showing \(w)"))

        case "set_next":
            let m = try me(a), i = try source(a["source"])
            atem.setPreview(i, me: m); done(ok("\(store.label(i, s)) is on Next, M/E \(m + 1)"))
        case "set_live", "switcher_set_program":
            let m = try me(a), i = try source(a["source"])
            atem.setProgram(i, me: m); done(ok("\(store.label(i, s)) is on Live, M/E \(m + 1)"))
        case "switcher_set_preview":
            let m = try me(a), i = try source(a["source"])
            atem.setPreview(i, me: m); done(ok("\(store.label(i, s)) is on preview, M/E \(m + 1)"))
        case "cut": let m = try me(a); atem.cut(me: m); done(ok("Cut on M/E \(m + 1)"))
        case "fade": let m = try me(a); atem.auto(me: m); done(ok("Fading on M/E \(m + 1)"))
        case "fade_to_black": let m = try me(a); atem.fadeToBlack(me: m); done(ok("Fade to black on M/E \(m + 1)"))
        case "set_key_button":
            let label = (a["button"] as? String ?? "").lowercased()
            guard let k = store.config.keys.first(where: { $0.label.lowercased() == label }) else {
                throw fail("No key button called that. Buttons: \(store.config.keys.map(\.label).joined(separator: ", ")).")
            }
            let want = a["on"] as? Bool ?? !k.isOn(s)
            if want != k.isOn(s) { k.toggle(atem) }
            done(ok("\(k.label) \(want ? "on" : "off") air"))
        case "set_recording":
            guard s.hasRecording else { throw fail("This switcher doesn't record.") }
            // Never guess: a call without a clear true or false must not stop the recording.
            guard let on = a["on"] as? Bool else { throw fail("Give on as true (record) or false (stop). Nothing was changed.") }
            atem.setRecording(on); done(ok("Recording \(on ? "started" : "stopped")"))
        case "set_streaming":
            guard s.hasStreaming else { throw fail("This switcher doesn't stream.") }
            guard let on = a["on"] as? Bool else { throw fail("Give on as true (stream) or false (stop). Nothing was changed.") }
            atem.setStreaming(on); done(ok("Streaming \(on ? "started" : "stopped")"))

        case "camera_move":
            let c = try cam(a, changing: true)
            let ms = clampMs(a["duration_ms"])
            ptz.drive(x: dbl(a["pan"]), y: dbl(a["tilt"]), camera: c.id)
            DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(ms)) {
                ptz.stopDrive(camera: c.id)
                done(ok("Moved \(c.name) for \(ms) ms", ["warning": controlWarning(c)].compactMapValues { $0 }))
            }
        case "camera_zoom":
            let c = try cam(a, changing: true)
            let ms = clampMs(a["duration_ms"])
            ptz.zoom(dbl(a["speed"]), camera: c.id)
            DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(ms)) {
                ptz.zoom(0, camera: c.id)
                done(ok("Zoomed \(c.name) for \(ms) ms", ["warning": controlWarning(c)].compactMapValues { $0 }))
            }
        case "camera_stop":
            let c = try cam(a, changing: false)
            AutoTracker.shared.stop(c.id)
            ptz.stopDrive(camera: c.id); ptz.zoom(0, camera: c.id); done(ok("Stopped \(c.name)"))
        case "camera_focus":
            let c = try cam(a, changing: true)
            switch a["mode"] as? String {
            case "once": ptz.focusOnce(camera: c.id)
            case "auto": ptz.autoFocus(true, camera: c.id)
            case "manual": ptz.autoFocus(false, camera: c.id)
            default: throw fail("mode is once, auto or manual.")
            }
            done(ok("Focus \(a["mode"] as? String ?? "") on \(c.name)"))
        case "get_routing":
            done(routing())
        case "route_screen":
            let auxes: [Int], what: String, hidden: Bool
            if let n = intValue(a["screen"]) {
                guard s.aux[n - 1] != nil else { throw fail("The switcher has no aux \(n). It has \(s.auxCount).") }
                auxes = [n]; what = store.screen(aux: n)?.name ?? "Aux \(n)"; hidden = !(store.screen(aux: n)?.forVolunteers ?? true)
            } else {
                let q = (a["screen"] as? String ?? "").lowercased().trimmingCharacters(in: .whitespaces)
                guard !q.isEmpty, let sc = try store.config.screens.first(where: { $0.name.lowercased() == q })
                        ?? onlyOne(store.config.screens.filter { $0.name.lowercased().contains(q) }, q, "screen", \.name) else {
                    throw fail("No screen called \(a["screen"] ?? ""). Screens: \(store.config.screens.map(\.name).joined(separator: ", ")), or use an aux number.")
                }
                auxes = sc.aux; what = sc.name; hidden = !sc.forVolunteers
            }
            if hidden, a["allow_hidden"] as? Bool != true { throw fail("\(what) is hidden from volunteers (it may feed an encoder or the stream). Send allow_hidden: true to change it.") }
            let src = try routeSource(a["source"])
            for x in auxes { atem.setAux(x - 1, src) }
            done(ok("\(what) now shows \(store.routeLabel(src, s))"))
        case "run_route_button":
            let q = (a["button"] as? String ?? "").lowercased()
            guard !q.isEmpty, let r = try store.config.routes.first(where: { $0.label.lowercased() == q })
                    ?? onlyOne(store.config.routes.filter { $0.label.lowercased().contains(q) }, q, "routing button", \.label) else {
                throw fail("No routing button called \(a["button"] ?? ""). Buttons: \(store.config.routes.map(\.label).joined(separator: ", ")).")
            }
            r.run(atem); done(ok("Ran \(r.label): \(RoutingText.detail(r, store, s).replacingOccurrences(of: "\n", with: "; "))"))
        case "find_devices":
            DeviceFinder.find { list, nets in
                done(["networks": nets, "devices": list.map { ["kind": $0.kind, "name": $0.name, "host": $0.host] },
                      "note": list.isEmpty ? "Nothing answered. Check this Mac is on the same network as the switcher and cameras, and that Churchfront Video is allowed Local Network access (System Settings > Privacy & Security > Local Network)." : "Ask the person to confirm which device is which before saving."])
            }
        case "list_ndi_sources":
            let ndi = NDIMonitor.shared
            ndi.scan()
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                guard ndi.hasRuntime else { done(["error": "NDI isn't installed on this Mac. Install NDI Tools."]); return }
                done(["sources": ndi.sources])
            }
        case "start_tracking":
            let c = try cam(a, changing: true)
            let pt: CGPoint? = (a["x"] == nil && a["y"] == nil) ? nil : CGPoint(x: dbl(a["x"] ?? 0.5), y: dbl(a["y"] ?? 0.5))
            let size = (a["shot"] as? String).flatMap(ShotSize.init(rawValue:))
            let person = (a["person"] as? String).flatMap { $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0 }
            AutoTracker.shared.start(c, at: pt, size: size, person: person) { why in
                let t = AutoTracker.shared.sessions[c.id]
                let z = t?.size.name.lowercased() ?? ""
                done(why == nil ? ok("\(c.name) is following \(t?.person ?? "someone"), framed \(z)", ["warning": controlWarning(c)].compactMapValues { $0 })
                                : ["error": "\(c.name): \(why!) It keeps looking until stop_tracking."])
            }
        case "scan_stage":
            let cams: [PTZCamera]? = try (a["cameras"] as? [Any]).map { list in try list.map { try cam(["camera": $0], changing: false) } }
            let pictures = a["pictures"] as? Bool ?? true
            Task { @MainActor in
                let scan = StageScan.shared
                guard !scan.running else { done(["error": "A stage scan is already running."]); return }
                if let z = (a["shot"] as? String).flatMap(ShotSize.init(rawValue:)) { scan.size = z }
                await scan.scan(cams)
                var out = scanReport()
                if pictures {
                    out["images"] = scan.people.compactMap { p -> [String: Any]? in
                        guard let t = p.thumb, let jpg = Snapshots.jpeg(t, width: 200) else { return nil }
                        return ["label": "Person \(p.id) (\(p.letter)) on \(p.cameraName)", "mimeType": "image/jpeg", "data": jpg.base64EncodedString()]
                    }
                }
                done(out)
            }
        case "label_stage_scan":
            guard let labels = a["labels"] as? [[String: Any]], !labels.isEmpty else { throw fail("Give labels as [{person, label}].") }
            Task { @MainActor in
                let scan = StageScan.shared
                guard !scan.people.isEmpty else { done(["error": "There's no scan to label. Run scan_stage first."]); return }
                var unknown: [String] = []
                for l in labels {
                    let text = (l["label"] as? String ?? "").trimmingCharacters(in: .whitespaces)
                    if let n = intValue(l["person"]), scan.people.contains(where: { $0.id == n }) {
                        scan.label(n, text)
                    } else if let letter = (l["person"] as? String)?.uppercased().trimmingCharacters(in: .whitespaces),
                              case let ids = scan.people.filter({ $0.letter == letter }).map(\.id), !ids.isEmpty {
                        for id in ids { scan.label(id, text) }
                    } else {
                        unknown.append("\(l["person"] ?? "?")")
                    }
                }
                guard unknown.isEmpty else { done(["error": "No one in the scan is \(unknown.joined(separator: ", ")). Nothing was saved."]); return }
                let said = scan.save()
                done(ok(said.joined(separator: " "), scanReport()))
            }
        case "get_framing":
            done(framingReport())
        case "set_framing":
            guard let z = (a["shot"] as? String).flatMap(ShotSize.init(rawValue:)) else { throw fail("shot is shoulders, waist or full.") }
            func clamp(_ v: Any?, _ lo: Double, _ hi: Double) -> Double? { (v as? NSNumber).map { min(hi, max(lo, $0.doubleValue)) } }
            store.update { c in
                if a["reset"] as? Bool == true { c.framing[z.rawValue] = nil }
                var r = c.framing[z.rawValue] ?? FramingRule()
                if let v = clamp(a["eye_line"], 0.1, 0.5) { r.eyeLine = v }
                if let v = clamp(a["size"], 0.04, 0.7) { r.scale = v }
                if let v = clamp(a["lead_room"], 0, 0.2) { r.leadRoom = v }
                if let v = clamp(a["dead_x"], 0.02, 0.2) { r.deadX = v }
                if let v = clamp(a["dead_y"], 0.02, 0.2) { r.deadY = v }
                c.framing[z.rawValue] = r == FramingRule() ? nil : r
            }
            // Tracking cameras on this size reframe to it now.
            for (id, t) in AutoTracker.shared.sessions where t.size == z && t.asked != nil { AutoTracker.shared.setSize(id, z) }
            done(ok("\(z.name) framing updated", framingReport()))
        case "set_tracking_tuning":
            func clamp(_ v: Any?, _ lo: Double, _ hi: Double) -> Double? { (v as? NSNumber).map { min(hi, max(lo, $0.doubleValue)) } }
            store.update { c in
                if a["reset"] as? Bool == true { c.trackTuning = TrackTuning() }
                if let v = clamp(a["correction"], 0.4, 2.5) { c.trackTuning.correction = v }
                if let v = clamp(a["latency"], 0.2, 0.8) { c.trackTuning.latency = v }
                if let v = clamp(a["walk_threshold"], 0.05, 0.4) { c.trackTuning.walkThreshold = v }
                if let v = clamp(a["zoom_threshold"], 0.1, 0.8) { c.trackTuning.zoomThreshold = v }
                if let v = clamp(a["zoom_wait"], 0.5, 5) { c.trackTuning.zoomWait = v }
                if let v = clamp(a["speed"], 0.5, 4) { c.trackSpeed = v }
            }
            done(ok("Tracking tuning updated", framingReport()))
        case "set_tracking_shot":
            let c = try cam(a, changing: true)
            guard let z = (a["shot"] as? String).flatMap(ShotSize.init(rawValue:)) else { throw fail("shot is shoulders, waist or full.") }
            guard AutoTracker.shared.isTracking(c.id) else { throw fail("\(c.name) isn't tracking. Use start_tracking.") }
            AutoTracker.shared.setSize(c.id, z); done(ok("\(c.name) framing \(z.name.lowercased())"))
        case "stop_tracking":
            if a["all"] as? Bool == true { AutoTracker.shared.stopAll(); done(ok("Stopped tracking on every camera")); return }
            let c = try cam(a, changing: false)
            AutoTracker.shared.stop(c.id); done(ok("\(c.name) stopped tracking"))
        case "camera_home":
            let c = try cam(a, changing: true); ptz.home(camera: c.id); done(ok("\(c.name) going home"))
        case "set_exposure":
            let c = try cam(a, changing: true)
            let x = ptz.exposure[c.id] ?? CameraExposure()
            var e = PTZExposure(gain: snap(a["gain"], x.gainList), shutter: snap(a["shutter"], x.shutterList), iris: snap(a["iris"], x.irisList))
            if let w = a["white_balance"] {
                if let k = snap(w, x.kelvinList) ?? intValue(w) { e.wb = "kelvin"; e.kelvin = k }
                else if let m = (w as? String)?.lowercased(), ["auto", "daylight", "tungsten"].contains(m) { e.wb = m }
                else { throw fail("white_balance is auto, daylight, tungsten, or a kelvin number such as 4300.") }
            }
            let auto = a["auto"] as? Bool == true
            if auto {
                guard !e.hasExposure else { throw fail("Give auto, or gain, shutter and iris, not both.") }
                guard x.hasAutoMode else { throw fail("\(c.name) has no single auto exposure mode Churchfront Video can set. That works on VISCA cameras.") }
                ptz.autoExposure(camera: c.id)
            }
            guard auto || e.hasExposure || e.hasWhiteBalance else { throw fail("Give gain, shutter, iris, white_balance and/or auto.") }
            if e.hasExposure || e.hasWhiteBalance { ptz.setExposure(e, camera: c.id) }
            done(ok("Exposure set on \(c.name)", ["sent": expo(e, level: x.gainIsLevel).merging(auto ? ["exposure": "auto"] : [:]) { a, _ in a }]))
        case "camera_snapshots":
            let cams: [PTZCamera] = try (a["cameras"] as? [Any]).map { list in try list.map { try cam(["camera": $0], changing: false) } }
                ?? ptz.cameras.filter { CameraPicture.of($0, store) != nil }
            let pictures = a["pictures"] as? Bool ?? true
            Snapshots.take(cams, pictures: pictures) { results in
                var out: [String: Any] = ["cameras": results.map(\.info)]
                if pictures { out["images"] = results.compactMap(\.image) }
                done(out)
            }
        case "match_exposure":
            let src = try cam(["camera": a["from"] as Any], changing: false)
            guard let x = ptz.exposure[src.id]?.value else { throw fail("\(src.name) hasn't reported its exposure yet. Try again in a moment.") }
            let want = Set((a["settings"] as? [String]) ?? ["gain", "shutter", "iris", "white_balance"])
            let targets: [PTZCamera] = try (a["to"] as? [Any]).map { list in try list.map { try cam(["camera": $0], changing: false) } }
                ?? ptz.cameras.filter { $0.id != src.id && !$0.host.isEmpty }
            var changed: [String: Any] = [:], skipped: [String] = []
            for t in targets where t.id != src.id {
                if let i = t.atemInput, (atem.state.tally[i] ?? 0) & 1 != 0, a["allow_live"] as? Bool != true { skipped.append("\(t.name) (on Live)"); continue }
                let tx = ptz.exposure[t.id] ?? CameraExposure()
                var e = PTZExposure()
                // Gain only carries between cameras that count it the same way (dB or levels).
                if want.contains("gain"), let g = x.gain, tx.gainIsLevel == (ptz.exposure[src.id]?.gainIsLevel ?? false) { e.gain = snap(g, tx.gainList) }
                if want.contains("shutter"), let v = x.shutter { e.shutter = snap(v, tx.shutterList) }
                if want.contains("iris"), let v = x.iris { e.iris = snap(v, tx.irisList) }
                if want.contains("white_balance") {
                    if x.wb == "kelvin" || x.wb == nil, let k = x.kelvin { e.wb = "kelvin"; e.kelvin = snap(k, tx.kelvinList) }
                    else if let m = x.wb { e.wb = m }
                }
                guard e.hasExposure || e.hasWhiteBalance else { continue }
                ptz.setExposure(e, camera: t.id)
                changed[t.name] = expo(e, level: tx.gainIsLevel)
            }
            done(ok("Matched \(changed.count) camera\(changed.count == 1 ? "" : "s") to \(src.name)",
                    ["source": expo(x), "changed": changed, "skipped": skipped]))
        case "recall_shot":
            let c = try cam(a, changing: true), sh = try shot(c, a["shot"])
            ptz.go(to: sh, camera: c.id); done(ok("\(c.name): \(sh.name)"))
        case "save_shot":
            let c = try cam(a, changing: false)
            let name = (a["name"] as? String ?? "").trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty else { throw fail("Give the shot a name.") }
            let kind = ShotKind(rawValue: a["kind"] as? String ?? "position") ?? .position
            let existing = (a["replace"] as? Bool ?? false) ? c.shots.first { $0.name.lowercased() == name.lowercased() } : nil
            ptz.saveShot(name, camera: c.id, kind: kind, replacing: existing?.id) { worked in
                done(worked ? ok("Saved \(kind.rawValue) shot \(name) on \(c.name)")
                            : ["error": "\(c.name) didn't report its settings, so nothing was saved."])
            }
        case "rename_shot":
            let c = try cam(a, changing: false), sh = try shot(c, a["shot"])
            let n = (a["new_name"] as? String ?? "").trimmingCharacters(in: .whitespaces)
            guard !n.isEmpty else { throw fail("Give new_name.") }
            try editShots(c) { shots in if let i = shots.firstIndex(where: { $0.id == sh.id }) { shots[i].name = n } }
            done(ok("Renamed \(sh.name) to \(n)"))
        case "delete_shot":
            let c = try cam(a, changing: false), sh = try shot(c, a["shot"])
            try editShots(c) { $0.removeAll { $0.id == sh.id } }
            done(ok("Deleted \(sh.name) from \(c.name)"))
        case "recall_camera_preset":
            let c = try cam(a, changing: true), n = try preset(c, a["preset"])
            ptz.recall(n, camera: c.id); done(ok("\(c.name): preset \(n) \(ptz.presetNames(c)[n] ?? "")"))
        case "delete_camera_preset":
            let c = try cam(a, changing: false), n = try preset(c, a["preset"])
            let label = ptz.presetNames(c)[n] ?? "preset \(n)"
            ptz.deleteCameraPreset(n, camera: c.id) { why in
                done(why == nil ? ok("Deleted \(label) from \(c.name)") : ["error": why!])
            }

        case "set_transition_style":
            let styles = ["mix": 0, "dip": 1, "wipe": 2, "dve": 3]
            guard let st = styles[a["style"] as? String ?? ""] else { throw fail("style is mix, dip, wipe or dve.") }
            let m = try me(a); atem.setStyle(st, me: m); done(ok("Style \(a["style"]!) on M/E \(m + 1)"))
        case "set_mix_rate":
            let m = try me(a), f = Int(dbl(a["frames"]))
            guard (1...250).contains(f) else { throw fail("frames is 1 to 250.") }
            atem.setMixRate(f, me: m); done(ok("Mix rate \(f) frames on M/E \(m + 1)"))
        case "set_tbar":
            let m = try me(a), p = dbl(a["position"])
            atem.setPosition(min(1, max(0, p)), me: m); done(ok("T-bar at \(Int(p * 100))% on M/E \(m + 1)"))
        case "set_next_transition":
            let m = try me(a)
            var mask = (a["background"] as? Bool ?? true) ? 1 : 0
            for k in (a["keys"] as? [Any] ?? []) { let n = Int(dbl(k)); if n >= 1 { mask |= 2 << (n - 1) } }
            guard mask != 0 else { throw fail("Include the background or at least one key.") }
            atem.setNextSelection(mask, me: m); done(ok("Next transition set on M/E \(m + 1)"))
        case "set_upstream_key":
            let m = try me(a), k = Int(dbl(a["keyer"]))
            guard k >= 1, k <= max(1, s.keyerCount) else { throw fail("keyer is 1 to \(s.keyerCount).") }
            let on = a["on"] as? Bool ?? false
            atem.setKeyOnAir(k - 1, on, me: m); done(ok("M/E \(m + 1) key \(k) \(on ? "on" : "off") air"))
        case "dsk":
            let d = Int(dbl(a["dsk"]))
            guard d >= 1, d <= max(1, s.dskCount) else { throw fail("dsk is 1 to \(s.dskCount).") }
            switch a["action"] as? String {
            case "on": atem.setDSKOnAir(d - 1, true)
            case "off": atem.setDSKOnAir(d - 1, false)
            case "auto": atem.dskAuto(d - 1)
            case "tie_on": atem.setDSKTie(d - 1, true)
            case "tie_off": atem.setDSKTie(d - 1, false)
            default: throw fail("action is on, off, auto, tie_on or tie_off.")
            }
            done(ok("DSK \(d): \(a["action"] as? String ?? "")"))
        case "set_aux":
            let x = Int(dbl(a["aux"])), i = try source(a["source"], aux: true)
            guard x >= 1, x <= max(1, s.auxCount) else { throw fail("aux is 1 to \(s.auxCount).") }
            atem.setAux(x - 1, i); done(ok("Aux \(x): \(s.inputs[i]?.long ?? "\(i)")"))
        case "run_macro":
            let i: Int
            if let n = intValue(a["macro"]) { i = n - 1 }
            else if let name = a["macro"] as? String, let hit = s.macros.first(where: { $0.value.lowercased() == name.lowercased() }) { i = hit.key }
            else { throw fail("No macro by that number or name. Macros: \(s.macros.sorted { $0.key < $1.key }.map { "\($0.key + 1) \($0.value)" }.joined(separator: ", "))") }
            guard s.macros[i] != nil else { throw fail("There's no macro \(i + 1).") }
            atem.runMacro(i); done(ok("Running macro \(i + 1) \(s.macros[i] ?? "")"))
        case "stop_macro": atem.stopMacro(); done(ok("Stopped the macro"))
        default: throw fail("No tool called \(name).")
        }
    }

    // MARK: Lookups

    private static func intValue(_ v: Any?) -> Int? {
        if let n = v as? Int { return n }
        if let d = v as? Double { return Int(d) }
        if let s = v as? String, let n = Int(s.trimmingCharacters(in: .whitespaces)) { return n }
        return nil
    }
    private static func dbl(_ v: Any?) -> Double { (v as? Double) ?? (v as? Int).map(Double.init) ?? Double(v as? String ?? "") ?? 0 }
    private static func clampMs(_ v: Any?) -> Int { max(50, min(5000, intValue(v) ?? 500)) }

    private static func me(_ a: [String: Any]) throws -> Int {
        guard let m = intValue(a["me"]) else { return booth.me }
        guard m >= 1, m <= atem.state.meCount else { throw fail("me is 1 to \(atem.state.meCount).") }
        return m - 1
    }

    private static func source(_ v: Any?, aux: Bool = false) throws -> Int {
        let s = atem.state
        let pool = aux ? s.auxSources : s.busSources
        if let n = intValue(v) {
            guard s.inputs[n] != nil else { throw fail("The switcher has no input \(n).") }
            return n
        }
        let q = (v as? String ?? "").lowercased().trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { throw fail("Name a source.") }
        if let hit = store.config.sources.first(where: { $0.label?.lowercased() == q }) { return hit.input }
        if let c = store.config.cameras.first(where: { $0.name.lowercased() == q }), let i = c.atemInput { return i }
        if let i = pool.first(where: { $0.long.lowercased() == q || $0.short.lowercased() == q }) { return i.id }
        if let i = try onlyOne(pool.filter { $0.long.lowercased().contains(q) }, q, "source", \.long) { return i.id }
        throw fail("No source called \(v ?? ""). Use get_status to see the sources.")
    }

    /// A part of a name is accepted only when it fits exactly one thing. When it fits several,
    /// this refuses and lists them, so a loose name can't put the wrong picture on Live or on
    /// a screen.
    private static func onlyOne<T>(_ hits: [T], _ asked: String, _ what: String, _ name: (T) -> String) throws -> T? {
        guard hits.count > 1 else { return hits.first }
        throw fail("\"\(asked)\" fits more than one \(what): \(hits.map(name).joined(separator: ", ")). Use the full name. Nothing was changed.")
    }

    private static func cam(_ a: [String: Any], changing: Bool) throws -> PTZCamera {
        let c: PTZCamera
        if let v = a["camera"] {
            let q = "\(v)".lowercased().trimmingCharacters(in: .whitespaces)
            if let hit = ptz.cameras.first(where: { $0.name.lowercased() == q || $0.host == q }) { c = hit }
            else if let i = intValue(v), let hit = ptz.cameras.first(where: { $0.atemInput == i }) { c = hit }
            else if let i = try? source(v), let hit = ptz.cameras.first(where: { $0.atemInput == i }) { c = hit }
            else { throw fail("No camera called \(v). Cameras: \(ptz.cameras.map(\.name).joined(separator: ", ")).") }
        } else {
            let next = atem.state.preview[booth.me]
            guard let hit = ptz.cameras.first(where: { $0.atemInput == next && !$0.host.isEmpty }) else {
                throw fail("No camera is on Next. Name one with camera.")
            }
            c = hit
        }
        if changing, let i = c.atemInput, (atem.state.tally[i] ?? 0) & 1 != 0, a["allow_live"] as? Bool != true {
            throw fail("\(c.name) is on Live. Send allow_live: true to change it anyway.")
        }
        return c
    }

    private static func shot(_ c: PTZCamera, _ v: Any?) throws -> PTZShot {
        let q = (v as? String ?? "\(v ?? "")").lowercased()
        guard let s = c.shots.first(where: { $0.name.lowercased() == q }) else {
            throw fail("\(c.name) has no shot called \(v ?? ""). Shots: \(c.shots.map(\.name).joined(separator: ", ")).")
        }
        return s
    }

    private static func preset(_ c: PTZCamera, _ v: Any?) throws -> Int {
        let names = ptz.presetNames(c)
        if let n = intValue(v) { return n }
        let q = (v as? String ?? "").lowercased()
        if let hit = names.first(where: { $0.value.lowercased() == q }) { return hit.key }
        throw fail("\(c.name) has no preset called \(v ?? ""). Presets: \(names.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: ", ")).")
    }

    private static func editShots(_ c: PTZCamera, _ f: (inout [PTZShot]) -> Void) throws {
        guard let i = ptz.cameras.firstIndex(where: { $0.id == c.id }) else { throw fail("That camera is gone.") }
        f(&ptz.cameras[i].shots)
    }

    /// The accepted value nearest to the one asked for.
    private static func snap(_ v: Any?, _ list: [Int]) -> Int? {
        guard let n = intValue(v) else { return nil }
        return list.min { abs($0 - n) < abs($1 - n) } ?? n
    }

    private static func controlWarning(_ c: PTZCamera) -> String? {
        ptz.hasControl(c) ? nil : "\(c.name) isn't under Churchfront Video's control right now (another controller has it), so the camera may have ignored this."
    }

    private static func configObject() throws -> [String: Any] {
        let data = try JSONEncoder().encode(store.config)
        return (try JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }

    // MARK: Status

    /// `level`: this camera's gain is a plain level, not tenths of a dB.
    private static func expo(_ e: PTZExposure, level: Bool = false) -> [String: Any] {
        var d: [String: Any] = [:]
        if let g = e.gain { d["gain"] = g; d["gain_text"] = level ? "Level \(g)" : CameraExposure.gainText(g) }
        if let s = e.shutter { d["shutter"] = s; d["shutter_text"] = CameraExposure.shutterText(s) }
        if let i = e.iris { d["iris"] = i; d["iris_text"] = CameraExposure.irisText(i) }
        if e.hasWhiteBalance { d["white_balance"] = CameraExposure.wbText(e.wb, e.kelvin) }
        return d
    }

    /// A routing source from a number, a mix name, "M/E 2" (with "preview" for its preview), or any source name.
    private static func routeSource(_ v: Any?) throws -> Int {
        if let n = intValue(v) {
            guard atem.state.inputs[n] != nil else { throw fail("The switcher has no source \(n).") }
            return n
        }
        let q = (v as? String ?? "").lowercased().trimmingCharacters(in: .whitespaces)
        let preview = q.contains("preview")
        let base = q.replacingOccurrences(of: "preview", with: "").trimmingCharacters(in: .whitespaces)
        for (i, n) in store.config.mixNames.enumerated() where !n.isEmpty && n.lowercased() == base { return 10000 + (i + 1) * 10 + (preview ? 1 : 0) }
        let digits = base.filter(\.isNumber)
        if (base.hasPrefix("m/e") || base.hasPrefix("me")), let m = Int(digits), m >= 1 { return 10000 + m * 10 + (preview ? 1 : 0) }
        return try source(v, aux: true)
    }

    @MainActor static func scanReport() -> [String: Any] {
        let scan = StageScan.shared
        return [
            "people": scan.people.map { p -> [String: Any] in
                ["person": p.id, "camera": p.cameraName, "same_person_letter": p.letter, "label": p.label,
                 "shot": ["pan": p.shot.pan, "tilt": p.shot.tilt, "zoom": p.shot.zoom], "size_is_a_guess": p.rough]
            },
            "notes": scan.notes,
            "can_follow_by_name": StageCast.shared.names,
        ]
    }

    static func framingReport() -> [String: Any] {
        func d(_ r: FramingRule) -> [String: Any] {
            ["eye_line": r.eyeLine ?? 0, "size": r.scale ?? 0, "lead_room": r.leadRoom ?? 0, "dead_x": r.deadX ?? 0, "dead_y": r.deadY ?? 0]
        }
        var shots: [String: Any] = [:]
        for z in ShotSize.allCases {
            shots[z.rawValue] = ["name": z.name, "now": d(z.rule), "standard": d(z.standard), "changed": store.config.framing[z.rawValue] != nil]
        }
        let t = store.config.trackTuning
        return ["framing": shots, "tracking": [
            "speed": store.config.trackSpeed, "tilt": store.config.trackTilt, "zoom_to_hold_size": store.config.trackZoom,
            "correction": t.correction ?? 1.2, "latency": t.latency ?? 0.45, "walk_threshold": t.walkThreshold ?? 0.12,
            "zoom_threshold": t.zoomThreshold ?? 0.3, "zoom_wait": t.zoomWait ?? 1.5] as [String: Any]]
    }

    static func routing() -> [String: Any] {
        let s = atem.state
        let mixes = s.program.keys.sorted().map { me -> [String: Any] in
            ["me": me + 1, "for": store.config.mixNames.indices.contains(me) ? store.config.mixNames[me] : "",
             "live": store.label(s.program[me], s), "next": store.label(s.preview[me], s), "volunteer_mix": me == booth.me]
        }
        let outs = s.aux.keys.sorted().map { i -> [String: Any] in
            let sc = store.screen(aux: i + 1)
            return ["aux": i + 1, "screen": sc?.name ?? "", "note": sc?.note ?? "", "for_volunteers": sc?.forVolunteers ?? false,
                    "showing": ["source": s.aux[i] ?? -1, "name": store.routeLabel(s.aux[i], s)] as [String: Any]]
        }
        let buttons = store.config.routes.map { r -> [String: Any] in
            ["label": r.label, "on": r.isActive(s), "sets": RoutingText.detail(r, store, s).components(separatedBy: "\n")]
        }
        return ["mixes": mixes, "outputs": outs, "buttons": buttons]
    }

    static func status() -> [String: Any] {
        let s = atem.state
        func src(_ i: Int?) -> Any { i.map { ["input": $0, "name": store.label($0, s)] as [String: Any] } ?? NSNull() }
        let link: String = {
            switch atem.link {
            case .online: return "online"
            case .connecting: return "connecting"
            case .offline(let why): return "offline: \(why)"
            case .idle: return "not set up"
            }
        }()
        var mes: [[String: Any]] = []
        for m in 0..<s.meCount {
            let keys = (s.keyFill[m] ?? [:]).keys.sorted().map { k -> [String: Any] in
                ["keyer": k + 1, "on_air": s.keyOnAir[m]?[k] ?? false, "fill": src(s.keyFill[m]?[k]), "key": src(s.keyCut[m]?[k])]
            }
            mes.append(["me": m + 1, "live": src(s.program[m]), "next": src(s.preview[m]), "in_transition": s.inTransition[m] ?? false,
                        "faded_to_black": s.ftbBlack[m] ?? false, "style": ["mix", "dip", "wipe", "dve", "sting"][min(4, max(0, s.style[m] ?? 0))],
                        "mix_rate_frames": s.mixRate[m] ?? 0, "keys": keys])
        }
        let dsks = s.dskFill.keys.sorted().map { d -> [String: Any] in
            ["dsk": d + 1, "on_air": s.dskOnAir[d] ?? false, "tie": s.dskTie[d] ?? false, "fill": src(s.dskFill[d]), "key": src(s.dskCut[d])]
        }
        let cams = ptz.cameras.map { c -> [String: Any] in
            let x = ptz.exposure[c.id]
            let presets = ptz.presetNames(c).sorted { $0.key < $1.key }.map { n, name -> [String: Any] in
                ["number": n, "name": name, "kind": (ptz.exposurePresets[c.id]?.contains(n) ?? false) ? "exposure" : "position"]
            }
            let shots = c.shots.map { sh -> [String: Any] in
                sh.kind == .position ? ["name": sh.name, "kind": "position", "pan": sh.pan, "tilt": sh.tilt, "zoom": sh.zoom]
                                     : ["name": sh.name, "kind": "exposure"].merging(expo(sh.exposure ?? PTZExposure())) { a, _ in a }
            }
            var d: [String: Any] = [
                "name": c.name, "host": c.host, "protocol": c.proto.rawValue, "atem_input": c.atemInput.map { $0 as Any } ?? NSNull(),
                "answering": ptz.online.contains(c.id), "has_control": ptz.hasControl(c), "model": ptz.models[c.id] ?? "",
                "on_live": c.atemInput.map { (s.tally[$0] ?? 0) & 1 != 0 } ?? false,
                "on_next": c.atemInput.map { (s.tally[$0] ?? 0) & 2 != 0 } ?? false,
                "shots": shots, "camera_presets": presets,
                "tracking": AutoTracker.shared.sessions[c.id].map { t -> Any in
                    ["state": t.phase.rawValue, "framing": t.size.rawValue, "picture_is": t.seen?.rawValue ?? "unknown", "person": t.person ?? ""]
                } ?? false,
            ]
            if let x {
                d["exposure"] = expo(x.value, level: x.gainIsLevel).merging([
                    "gain_unit": x.gainIsLevel ? "level" : "tenths of a dB", "can_auto": x.hasAutoMode,
                    "gain_auto": x.gainAuto, "shutter_auto": x.shutterAuto, "iris_auto": x.irisAuto,
                    "gain_values": x.gainList, "shutter_values": x.shutterList, "iris_values": x.irisList,
                    "white_balance_mode": x.value.wb ?? "", "kelvin_values": x.kelvinList,
                ]) { a, _ in a }
            }
            return d
        }
        return [
            "switcher": [
                "connection": link, "host": atem.host, "model": s.product, "protocol": s.version,
                "volunteer_me": booth.me + 1, "mes": mes, "dsks": dsks,
                "aux": s.aux.keys.sorted().map { ["aux": $0 + 1, "source": src(s.aux[$0])] },
                "macros": s.macros.keys.sorted().map { ["macro": $0 + 1, "name": s.macros[$0] ?? ""] },
                "macro_running": s.macroRunning.map { $0 + 1 as Any } ?? NSNull(),
                "recording": s.hasRecording ? s.recording as Any : NSNull(),
                "streaming": s.hasStreaming ? s.streaming as Any : NSNull(),
                "sources": s.busSources.map { ["input": $0.id, "short": $0.short, "long": $0.long] },
            ] as [String: Any],
            "volunteer": [
                "sources": store.volunteerSources(s).map { ["input": $0.input, "label": store.label($0.input, s)] },
                "key_buttons": store.config.keys.map { ["label": $0.label, "target": $0.target, "on_air": $0.isOn(s)] },
            ] as [String: Any],
            "ndi_previews": (store.config.sources.compactMap { src -> [String: Any]? in
                guard let n = src.ndi else { return nil }
                return ["for": store.label(src.input, s), "source": n, "receiving": NDIFeedHub.shared.isLive(n).map { $0 as Any } ?? "not shown now",
                        "alpha": NDIFeedHub.shared.feed(n).hasAlpha, "picture": NDIFeedHub.shared.shape(n) as Any? ?? NSNull()]
            } + store.config.keys.compactMap { k -> [String: Any]? in
                guard let n = k.ndi else { return nil }
                return ["for": k.label, "source": n, "receiving": NDIFeedHub.shared.isLive(n).map { $0 as Any } ?? "not shown now",
                        "alpha": NDIFeedHub.shared.feed(n).hasAlpha, "on_live": k.isOn(s), "on_next": k.onNext(s)]
            }),
            "cameras": cams,
            "usb_picture": StatusReport.usbPicture(booth),
            "stage_scan_names": StageCast.shared.names,
            "config_file": store.url.path,
        ]
    }
}

extension Notification.Name {
    /// Asks the app to show a view or an Engineer page: object is "operator" (or "main"), "scan", "routing", "switcher", "setup" or "status".
    static let cueVideoShowWindow = Notification.Name("CueVideoShowWindow")
}
