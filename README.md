# Churchfront Video

A simple ATEM control surface for church booths, with PTZ camera control and live
camera previews. Part of the Churchfront App Suite (Churchfront Cues, Churchfront Screens,
Churchfront Lights, Churchfront Tracks). Native macOS 14+, SwiftUI.

- `Sources/CueATEM`: the shared engine. `ATEM.swift` speaks the ATEM network
  protocol (UDP 9910) with two-way state; `PTZ.swift` drives Canon cameras over
  Canon's HTTP control and VISCA cameras (VISCA over IP UDP 52381, or VISCA over
  TCP 5678); `CameraLogin.swift` keeps the Canon cameras' admin login in the Keychain.
  Meant to be used by Churchfront Screens (slide actions) and Churchfront Cues too.
- `Sources/NDIBridge`: copied from Churchfront Screens; loads the NDI runtime at run time.
- `Sources/CueVideo`: the app.
  - One window with two views, switched in the top bar or the View menu:
    - **Operator** (⌘1, where it always opens), for the booth volunteer: Next and
      Live monitors, the source row, then exposure, saved shots, the joystick and
      Fade / Cut / Black / key buttons. Camera controls always act on the camera on Next.
    - **Engineer** (⌘2), for whoever sets the system up, with a page each for Stage
      scan (⇧⌘S), Routing (⇧⌘R), the Full switcher (⇧⌘K: keys, DSKs, styles, T-bar,
      macros, aux), Setup (⌘,: switcher, source row, key buttons, cameras and their
      shots, the camera admin login) and Status (a log of every command sent). A strip
      across the top shows what's Live and Next. Space, Return, the number keys and
      the arrows do nothing here.
  - Menu bar: **View** (Operator, Engineer), **Switcher** (Cut, Fade, Fade to Black,
    key buttons), **Camera** (Track ⌘T, Stop All Tracking ⌘., Follow by Name, Focus
    ⇧⌘F, Auto Focus ⌥⌘F) and **Engineer** (its pages). Switcher and Camera only act from the Operator view.
- `Sources/CueVideoMCP`: the MCP server Claude uses (see below).

Build: `./build.sh` (or `./build.sh debug`) makes `Churchfront Video.app`. Inside it, the
executable is still `CueVideo` and the bundle ID is still `com.churchfront.cuevideo`, and
the Swift package, targets and folders keep their CueVideo names, so existing setups,
permissions and scripts keep working.

## Setup file

Everything set up in the app is saved as plain JSON in
`~/Library/Application Support/CueVideo/config.json`: the switcher address, the
M/E volunteers run, the source row, key buttons, cameras and each camera's saved
shots. The app picks up edits to the file within a second, so a person or Claude
can set Churchfront Video up by editing it. The camera admin login is never in this file.

## Claude (MCP)

`Churchfront Video.app/Contents/MacOS/cuevideo-mcp` is an MCP server with a tool for every
action in the app (status, Next/Live/Cut/Fade/Black, keys, record and stream,
camera moves, exposure, shots and presets, the full switcher, setup). It passes
calls to the running app over 127.0.0.1:9911, using the key in
`~/Library/Application Support/CueVideo/control-token`. Calling a tool opens
Churchfront Video if it isn't running; listing the tools (which every Claude session does
when it starts) does not. `.mcp.json` registers it for Claude Code sessions in this folder.

**Connecting Claude on a church's Mac:** Setup > AI assistant > **Connect Claude** adds a
`churchfront-video` entry to the Claude desktop app's `claude_desktop_config.json` (everything
else in that file is kept, and a copy of it is saved first). After Claude restarts, asking it
to "help me set up Churchfront Video" works: `find_devices` finds the ATEM (UDP 9910 hello to
the local /24), Canon cameras (their HTTP page) and anything on Bonjour (NDI sources,
Blackmagic devices, web pages), and `update_config` saves what the person confirms.
ChatGPT's desktop app can't use local MCP servers, so this is Claude only for now.
Camera tools refuse a camera that's on Live unless the call says `allow_live: true`.

## Safeguards

- **A camera is never left moving.** If Next is cut to Live while the joystick or an arrow key is held, the camera that was moving is stopped. Quitting Churchfront Video stops every camera it is moving, tracking included. Arrow keys let go when another window or app comes to the front. A stop that is waiting for a Canon camera is kept and re-sent if the request before it fails.
- **Keys only work in the main window.** Space, Return, the number keys and the arrows do nothing in Setup, Video Routing, the Full Switcher, or while a dialog or popover is open.
- **The setup file is protected.** Every setup that loads or saves cleanly is copied to `config.last-good.json`. If `config.json` has a mistake when Churchfront Video opens, it runs on that copy and says so on the main screen. Before Churchfront Video saves over a file it couldn't read, it keeps that file as `config.unreadable-<date>.json`.
- **Claude's tools don't guess.** `set_recording` and `set_streaming` need a clear `on: true` or `on: false`. A part of a name is accepted only when it fits exactly one source, screen or routing button.

`swift test` runs the camera code against pretend cameras on this Mac and checks the stops go out.

## Camera speed, exposure and color matching

- **Manual speed:** a tortoise-to-hare dial under the joystick (0.25× to 2×) sets how fast the joystick, zoom and arrow keys move every camera (config `ptzSpeed`).
- **Tracking speed:** auto tracking works in real angles. It reads each camera's angle of view and position about four times a second. It drives the camera at the person's own speed plus a correction toward the framing mark, and speeds up sharply near the frame edge. It also learns how fast the camera really turns for the speed it was asked for, so zoomed-in shots, or camera modes that slow panning at tele, still keep up.
- **White balance:** a row under gain, shutter and iris. Cooler and warmer step the color temperature, and the middle picks auto, daylight, tungsten, 3200, 4300 or 5600 K, or matches another camera. Exposure shots save white balance too.
- **For Claude:**
  - `set_exposure` takes `white_balance`.
  - `match_exposure` copies gain, shutter, iris and white balance from one camera to the others, snapped to each model's values.
  - `camera_snapshots` returns a picture from each camera with color measurements (average RGB, red÷green and blue÷green cast, brightness, clipping), so cameras can be compared and matched.

## Video routing

**Engineer → Routing** (⇧⌘R) shows how pictures reach the screens:

- **Mixes:** what each M/E is for (M/E 1 the live stream, M/E 2 the side screens), what's on it, and quick buttons to switch the mix the volunteer doesn't run.
- **Screens and outputs:** every aux output, as picture → aux → the screen it feeds and how it's wired. Pick a new picture from the menu and it changes right away. Linked auxes (such as a pair of lobby TVs) switch together. Outputs that feed encoders, recorders or the patch bay can be hidden from volunteers.
- **Volunteer routing buttons:** route the screens the way you want, then save that as a button. The buttons sit in the bottom right of the main window, work like macros (one press can change several screens), and light up while the screens match them. Below them, a short summary says what each volunteer-facing screen is showing.

In the config file, this is `mixNames`, `screens` and `routes`. Claude can use `get_routing`, `route_screen` and `run_route_button`. `route_screen` refuses hidden outputs, such as the stream encoder, unless the call says `allow_hidden: true`.

## NDI HX PTZ cameras (Fomako, PTZOptics, BirdDog) with an ATEM Mini

A camera that sends NDI HX (a Fomako NDI HX3, say) plugs into one of the ATEM Mini's HDMI
inputs for the switcher, and Churchfront Video talks to it over the network for control and
for its picture, with no login:

- **Control:** add the camera in Setup with **VISCA over IP (UDP)**, port 52381 (the Fomako
  tested answered position and zoom inquiries there and never on VISCA over TCP 5678), and
  set its switcher input to the HDMI it's on. Presets count from 0.
- **Picture:** under Volunteer source row, pick the camera's own NDI stream (it announces
  itself as something like `NDI_HX (NDI-26567)`) as the picture for that input. Its tile, the
  Next and Live monitors, auto tracking and Claude's snapshots all use it. Needs NDI Tools on
  this Mac, as every NDI picture does.
- The camera's web page login (often admin / admin) isn't needed: VISCA and NDI take none.
  The admin login in Setup is only for changing presets stored on Canon cameras.

In the config file, that's a camera with `"proto": "sonyUDP"` and `"atemInput"`, and the
source for that input with its `ndi` name.

## HDMI-only cameras (DJI Osmo Pocket, camcorders) through the switcher's USB

A camera that only gives the switcher HDMI has no picture Churchfront Video can fetch over
the network. Plug the ATEM Mini's USB into the Mac and it shows up as a webcam called
"Blackmagic Design" carrying the switcher's USB output (Program, on an ATEM Mini Pro aux 2).
Churchfront Video shows that picture wherever the source on it is drawn: in the Live monitor,
and on that camera's tile while it's Live. Nothing is sent to the switcher. macOS asks for
camera access the first time, since the ATEM counts as a camera; this Mac's own camera is
never used. Engineer → Status says what the USB output carries and whether frames arrive.

In the config file, `usbAux` names the output the USB video comes from (an aux from 1, 0 for
always Program, -1 for off); left out, it's worked out from the switcher model. A DJI Osmo
Pocket 4 / 4P has no HDMI socket: it needs a USB-C to HDMI cable (DJI doesn't officially
support this; dealers report it working, 1080p while recording 4K or 4K while recording 1080p).

## Graphics and lower thirds previews (NDI)

Tiles and the Next and Live monitors can show any NDI source, typically a Churchfront Screens screen with an NDI output added. In Setup, under Volunteer source row, pick the NDI picture for a non-camera source such as Graphics. Under Key buttons, pick an NDI source with alpha (such as Churchfront Screens' lower thirds sent with alpha). It is laid over the Next and Live pictures when the key is on them: on Live when it's on air, and on Next when it will be on air after the next Cut or Fade (a tied DSK or a key selected in the next transition).

Previews use NDI's low-bandwidth preview stream, so they cost little network or processor time. They need the NDI runtime on this Mac (NDI Tools). In the config file, it's the `ndi` field on a source or key, with the exact name from Setup or Claude's `list_ndi_sources`. The preview shows what Churchfront Screens is drawing, not the switcher's actual output.

## Auto tracking

**Track** (under the joystick) makes the Canon camera on Next follow the person nearest the middle of its shot. Click a person on the Next picture to follow them instead. Churchfront Video finds people and their body landmarks (eyes, shoulders, hips, ankles) in the camera's preview picture with Apple's Vision framework. It works out whether the shot is **shoulders up**, **waist up** or **full length**, and frames it the way a broadcast operator would:

- Eyes near the upper third line, with headroom to suit the shot size.
- Frame edges between joints: mid-chest, just below the waist, or a little room under the feet.
- Lead room on the side the person faces or walks toward.
- A dead zone, so the camera doesn't chase small moves, with eased starts and stops.
- Slow zooms that hold the shot size as the person comes nearer or moves away.

The Close / Waist / Full buttons under Track reframe the shot. Zooming by hand keeps tracking going and holds the new size. Moving the joystick, recalling a shot or preset, or clicking the badge on a monitor stops tracking. The person being followed is outlined on every picture of that camera, and tracking carries on when the camera goes Live.

The preview runs slightly behind real time, so tracking suits someone walking the stage, not running. Follow speed (0.5 to 2), tilt on/off and zoom-to-hold-size are in Setup and the config file (`trackSpeed`, `trackTilt`, `trackZoom`). The framing numbers live in `ShotSize` in `Tracker.swift`. Claude can use `start_tracking`, `set_tracking_shot` and `stop_tracking`.

### Telling people apart

Tracking keeps to one person by what they look like (clothes, build and colouring, worked out on this Mac with Apple's Vision framework), as well as by where they were. When two people cross it stays with the one it was following. After losing sight it waits for that person and does not pick up whoever is nearest; the badge says "Lost them, looking" until they're back, and clicking a person on the picture follows them instead. It is not face recognition and stores nothing between runs. People dressed alike are harder to tell apart: then it carries on by position while they're in sight.

## Stage scan

**Engineer → Stage scan** (⇧⌘S), for before a service with everyone in place (rehearsal or soundcheck):

1. Each Canon camera that isn't on Live, tracking or held by another controller goes to a wide shot, and comes back afterwards. The wide shot is that camera's shot named **Stage** or **Wide** if it has one (worth making: frame the stage as tightly as covers everyone, so people are bigger in the picture). Otherwise it's where the camera points now, zoomed all the way out.
2. Churchfront Video finds the people in each wide shot and works out the shot that frames each one from that camera (waist up by default), from the camera's own angles and angle of view.
3. It shows a small picture of each person per camera. A letter marks its guess at the same person on another camera. Type a name or role under one and the others with that letter fill in; fix any it got wrong.
4. **Save shots and names** adds a shot per labelled person to each camera's row in the shot grid (replacing the last scan's; shots made by hand are kept, and marked `"auto": true` in the config file), and remembers each person's look. Under Track, **Follow by name** then follows that person wherever they are in the shot. Names last until Churchfront Video quits.

The shots are for where people stood during the scan. Claude can use `scan_stage`, `label_stage_scan` and `start_tracking` with `person`.

## Canon cameras take one controller at a time

Only one session controls a Canon camera at a time. If another controller (another
copy of Churchfront Video or Churchfront Cues, a Companion Canon connection, an RC-IP100) keeps
claiming the same cameras, the two trade control and the joystick seems broken.
Churchfront Video shows "waiting for control" when this happens; close the other one.

## Testing without hardware

`python3 Tools/fake_atem.py 9910 --cams` starts a pretend ATEM and three pretend
VISCA cameras, then
`CUEVIDEO_HOST=127.0.0.1 CUEVIDEO_FAKECAMS=127.0.0.1 CUEVIDEO_SELFTEST=1 CUEVIDEO_SNAPSHOT=<folder> "./Churchfront Video.app/Contents/MacOS/CueVideo"`
runs every command, prints the state after each, and writes screenshots. Self-tests
never write to the setup file. Never run the self-test against a switcher that is
live on a service.

Keys: 1 to 0 put that source-row tile on Next, Shift plus a number cuts it to Live,
Space cuts, Return fades, arrows move the camera on Next.

## License

Apache License 2.0 (see `LICENSE` and `NOTICE`). The bundled Figtree font is under the SIL Open Font License 1.1 (`Resources/OFL.txt`). The Churchfront name and logo are trademarks of Churchfront LLC and aren't covered by the license. Test with your own gear before using it in a service; it's provided as is.
