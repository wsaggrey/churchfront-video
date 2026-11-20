import SwiftUI
import CueATEM

/// Whether a source has a live picture to show (a mix shows what's live on it).
func sourceHasPicture(_ input: Int?, _ state: ATEMState, _ ptz: PTZController, _ store: ConfigStore) -> Bool {
    guard var id = input else { return false }
    if (10000..<11000).contains(id), id % 10 == 0 { id = state.program[(id - 10000) / 10 - 1] ?? id }
    return ptz.cameras.contains { $0.atemInput == id && $0.proto == .canonXC && !$0.host.isEmpty } || store.ndi(id) != nil
        || store.usbShows(id, state)
}

/// A source's live picture, for anywhere one is shown small: the camera's own preview, the
/// NDI picture set for it, or its name. A mix output shows whatever is live on that mix.
struct SourcePicture: View {
    let input: Int?
    /// Write the source's name when it has no picture. Off where a label already says it.
    var named = true
    @EnvironmentObject var atem: ATEMClient
    @EnvironmentObject var ptz: PTZController
    @EnvironmentObject var store: ConfigStore

    private var resolved: Int? {
        guard let input, (10000..<11000).contains(input), input % 10 == 0 else { return input }
        return atem.state.program[(input - 10000) / 10 - 1] ?? input
    }

    var body: some View {
        let id = resolved
        ZStack {
            Color.black
            if let id, let cam = ptz.cameras.first(where: { $0.atemInput == id && $0.proto == .canonXC && !$0.host.isEmpty }) {
                CameraVideo(camera: cam).id(cam.id)
            } else if let n = store.ndi(id) {
                NDIVideo(source: n).id(n)
            } else if store.usbShows(id, atem.state) {
                USBVideo().id("usb")
            } else {
                T.surfaceRaised
                if named { Text(store.routeLabel(id, atem.state)).font(.sans(15, .bold)).foregroundStyle(T.inkMuted)
                    .lineLimit(2).minimumScaleFactor(0.5).multilineTextAlignment(.center).padding(T.s2) }
            }
        }
    }
}

/// Routing as a schematic of the switcher, in two columns: everything that can be sent on
/// the left, everywhere it can go on the right, and a wire for each output's routing.
///
/// The mixes (M/Es) lead the left column, because to an output a mix is a source like any
/// other. Each is drawn as a small switcher showing its Live and Next; the sources that
/// are Live or Next on a mix carry a tag saying so, rather than a wire into it. So a wire
/// only ever means "this output shows that". Each wire is a curve across the gap between
/// the columns, and all of a source's wires leave it from one point. Drag a source or a mix onto a destination (or click one, then
/// the other) to change it right away; drop a source on a mix to put it live there.
struct RoutingSchematic: View {
    @EnvironmentObject var booth: Booth
    @EnvironmentObject var atem: ATEMClient
    @EnvironmentObject var ptz: PTZController
    @EnvironmentObject var store: ConfigStore
    @AppStorage("routingSpareIn") private var showSpareIn = false
    @AppStorage("routingInternal") private var showInternal = false
    @AppStorage("routingSpareOut") private var showSpareOut = false
    @State private var feedsUnlocked = false
    @State private var selected: Int?
    @State private var hover: Int?
    @State private var drag: (source: Int, at: CGPoint)?
    @State private var undo: [(what: String, back: () -> Void)] = []
    @State private var message = ""

    // MARK: Model

    enum Group: String { case mixes = "Mixes", cameras = "Cameras", graphics = "Graphics", ndi = "NDI", spareIn = "Spare inputs", inside = "Media and color"
        case screens = "Screens", feeds = "Encoders and feeds", spareOut = "Spare outputs" }

    struct Head { let group: Group; let y: CGFloat; let count: Int; let foldable: Bool; let open: Bool }
    struct Src { let id: Int; let frame: CGRect; let pic: Bool }
    struct Dst { let screen: ScreenOutput; let frame: CGRect; let pic: Bool; let source: Int?; let mixed: Bool; let locked: Bool }
    struct Mix { let me: Int; let frame: CGRect; let live: CGRect; let next: CGRect; let pic: Bool; let nextPic: Bool
        var output: Int { 10010 + me * 10 } }
    /// The wires from one source: where they all leave it, and where each one arrives.
    struct Wire { let from: Int; let color: Color; let start: CGPoint; var ends: [CGPoint] }
    struct Layout { var heads: [Head] = [], srcs: [Src] = [], dsts: [Dst] = [], mixes: [Mix] = [], wires: [Wire] = []
        var colors: [Int: Color] = [:]; var height: CGFloat = 0 }

    private let rowH: CGFloat = 38, headH: CGFloat = 24, gap: CGFloat = 6

    /// Sizes grow with the page, so a wide window gets bigger pictures instead of empty space.
    struct Sizes { let side: CGFloat, mix: CGFloat, thumb: CGSize
        var picH: CGFloat { thumb.height + 8 } }
    private func sizes(_ w: CGFloat) -> Sizes {
        let side = min(520, max(230, (w * 0.34).rounded()))
        let tw = min(190, (side * 0.42).rounded())
        return Sizes(side: side, mix: side, thumb: CGSize(width: tw, height: (tw * 9 / 16).rounded()))
    }
    /// None is tally red or green, which only ever mean Live and Next.
    private static let palette: [Color] = [0x7CC2EE, 0xF2B84B, 0xB39DF5, 0xD9DE6A, 0xF58FB8, 0xFF9E6B, 0x9BB7C9, 0xC9C9C9].map(T.hex)

    private func isMix(_ id: Int) -> Bool { (10000..<11000).contains(id) }

    private func hasPicture(_ input: Int?) -> Bool { sourceHasPicture(input, atem.state, ptz, store) }

    /// A port that only goes to a patch bay tie line, by its name.
    private func isSpare(_ name: String) -> Bool {
        let n = name.lowercased()
        return n.contains("patchbay") || n.contains("patch bay") || n.range(of: #"\(pb ?\d+\)"#, options: .regularExpression) != nil
    }

    private func group(_ i: ATEMInput) -> Group {
        guard i.isExternal else { return .inside }
        if isSpare(i.long) { return .spareIn }
        let n = (i.long + " " + store.label(i.id, atem.state)).lowercased()
        if store.config.cameras.contains(where: { $0.atemInput == i.id }) || n.contains("cam") || n.contains("ptz") { return .cameras }
        return n.contains("ndi") ? .ndi : .graphics
    }

    private func layout(_ w: CGFloat) -> Layout {
        let s = atem.state
        var L = Layout()
        let z = sizes(w), sw = z.side, dw = z.side, picH = z.picH

        // Destinations: every aux, named or not.
        let named = store.config.screens
        let used = Set(named.flatMap(\.aux))
        let unnamed = (1...max(1, s.auxCount)).filter { !used.contains($0) && s.aux[$0 - 1] != nil }.map { ScreenOutput(name: "Aux \($0)", aux: [$0]) }
        let dGroups: [(Group, [ScreenOutput])] = [
            (.screens, named.filter { $0.forVolunteers && !isSpare($0.name) }),
            (.feeds, named.filter { !$0.forVolunteers && !isSpare($0.name) }),
            (.spareOut, named.filter { isSpare($0.name) } + unnamed)]
        func now(_ sc: ScreenOutput) -> (Int?, Bool) {
            let set = Set(sc.aux.map { s.aux[$0 - 1] })
            return (set.count == 1 ? (set.first ?? nil) : nil, set.count > 1)
        }
        let dOpen: [Group: Bool] = [.screens: true, .feeds: true, .spareOut: showSpareOut]
        let shownDsts = dGroups.flatMap { g, list in dOpen[g] == true ? list : [] }

        // What's in use, so a folded group still shows the sources that matter.
        var inUse = Set(shownDsts.compactMap { now($0).0 })
        for me in s.program.keys { if let v = s.program[me] { inUse.insert(v) }; if let v = s.preview[me] { inUse.insert(v) } }

        // Left column: the mixes first.
        var y: CGFloat = 0
        L.heads.append(Head(group: .mixes, y: y, count: s.program.count, foldable: false, open: true))
        y += headH
        let slotW = ((sw - 26) / 2).rounded(.down)
        for me in s.program.keys.sorted() {
            let pic = hasPicture(s.program[me]), nextPic = hasPicture(s.preview[me])
            let slotH: CGFloat = pic || nextPic ? (slotW * 9 / 16).rounded() : 40
            let live = CGRect(x: 10, y: y + 38, width: slotW, height: slotH)
            let next = CGRect(x: 16 + slotW, y: y + 38, width: slotW, height: slotH)
            let f = CGRect(x: 0, y: y, width: sw, height: 38 + slotH + 10)
            L.mixes.append(Mix(me: me, frame: f, live: live, next: next, pic: pic, nextPic: nextPic))
            y = f.maxY + gap + 2
        }
        y += 8
        let inputs = s.auxSources.filter { !isMix($0.id) && !(7000..<7100).contains($0.id) }
        let sOpen: [Group: Bool] = [.cameras: true, .graphics: true, .ndi: true, .spareIn: showSpareIn, .inside: showInternal]
        for g in [Group.cameras, .graphics, .ndi, .spareIn, .inside] {
            let all = inputs.filter { group($0) == g }
            guard !all.isEmpty else { continue }
            let foldable = g == .spareIn || g == .inside
            L.heads.append(Head(group: g, y: y, count: all.count, foldable: foldable, open: sOpen[g] == true))
            y += headH
            for i in all where sOpen[g] == true || inUse.contains(i.id) {
                let pic = hasPicture(i.id), h = pic ? picH : rowH
                L.srcs.append(Src(id: i.id, frame: CGRect(x: 0, y: y, width: sw, height: h), pic: pic))
                y += h + gap
            }
            y += 8
        }
        let sBottom = y

        // Destinations.
        y = 0
        for (g, list) in dGroups where !list.isEmpty {
            L.heads.append(Head(group: g, y: y, count: list.count, foldable: g == .spareOut, open: dOpen[g] == true))
            y += headH
            if dOpen[g] == true {
                for sc in list {
                    let (src, mixed) = now(sc)
                    let pic = hasPicture(src), h = pic ? picH : rowH
                    L.dsts.append(Dst(screen: sc, frame: CGRect(x: w - dw, y: y, width: dw, height: h), pic: pic, source: src, mixed: mixed,
                                      locked: g == .feeds && !feedsUnlocked))
                    y += h + gap
                }
            }
            y += 8
        }
        let dBottom = y

        L.height = max(sBottom, dBottom)

        // Wires: a curve from each destination back to what feeds it. All of a source's
        // curves leave from one point, so a mix feeding five outputs reads as one fan.
        var color = 0
        func nextColor() -> Color { color += 1; return Self.palette[(color - 1) % Self.palette.count] }
        var origins: [(id: Int, y: CGFloat)] = L.mixes.map { ($0.output, $0.frame.midY) }
        for m in L.mixes { L.colors[m.output] = nextColor() }
        origins += L.srcs.map { ($0.id, $0.frame.midY) }
        for o in origins {
            let ys = L.dsts.filter { $0.source == o.id }.map(\.frame.midY)
            guard !ys.isEmpty else { continue }
            let c = L.colors[o.id] ?? nextColor()
            L.colors[o.id] = c
            L.wires.append(Wire(from: o.id, color: c, start: CGPoint(x: sw, y: o.y), ends: ys.map { CGPoint(x: w - dw, y: $0) }))
        }
        return L
    }

    // MARK: View

    var body: some View {
        let focus = drag?.source ?? selected ?? hover
        VStack(alignment: .leading, spacing: T.s3) {
            // The three columns, named: left to right is the way the signal flows.
            ZStack {
                column("Sources", "Mixes and switcher inputs").frame(maxWidth: .infinity, alignment: .leading)
                column("Destinations", "Switcher outputs").frame(maxWidth: .infinity, alignment: .trailing)
            }
            Rectangle().fill(T.line).frame(height: 1)
            GeometryReader { g in
                let w = g.size.width
                let L = layout(w)
                ZStack(alignment: .topLeading) {
                    Canvas { ctx, _ in
                        for wire in L.wires {
                            let dim = focus != nil && focus != wire.from
                            let c = wire.color.opacity(dim ? 0.15 : 1)
                            // Leaves flat, bends through the gap, arrives flat.
                            var p = Path()
                            for e in wire.ends {
                                let reach = (e.x - wire.start.x) * 0.5
                                p.move(to: wire.start)
                                p.addCurve(to: e, control1: CGPoint(x: wire.start.x + reach, y: wire.start.y), control2: CGPoint(x: e.x - reach, y: e.y))
                            }
                            ctx.stroke(p, with: .color(c), style: StrokeStyle(lineWidth: focus == wire.from ? 4 : 3, lineCap: .round))
                            ctx.fill(Path(ellipseIn: CGRect(x: wire.start.x - 5, y: wire.start.y - 5, width: 10, height: 10)), with: .color(c))
                            for e in wire.ends { ctx.fill(Path(ellipseIn: CGRect(x: e.x - 4, y: e.y - 4, width: 8, height: 8)), with: .color(c)) }
                        }
                        if let drag {
                            ctx.stroke(Path(ellipseIn: CGRect(x: drag.at.x - 7, y: drag.at.y - 7, width: 14, height: 14)), with: .color(T.accent), lineWidth: 2)
                        }
                    }
                    .allowsHitTesting(false)
                    ForEach(L.heads, id: \.group) { h in head(h, w) }
                    ForEach(L.srcs, id: \.id) { s in
                        sourceRow(s, L.colors[s.id], on: focus == s.id || onMix(s.id, focus), L, w).position(x: s.frame.midX, y: s.frame.midY)
                    }
                    ForEach(L.mixes, id: \.me) { m in
                        mixCard(m, L.colors[m.output] ?? T.lineStrong, target: canDrop(on: m), L, w).position(x: m.frame.midX, y: m.frame.midY)
                    }
                    ForEach(L.dsts, id: \.screen.id) { d in
                        destRow(d, d.source.flatMap { L.colors[$0] }, target: target(d, L, w), w).position(x: d.frame.midX, y: d.frame.midY)
                    }
                    if let drag {
                        Text(store.routeLabel(drag.source, atem.state)).font(.sans(12, .semibold)).foregroundStyle(T.onAction)
                            .padding(.horizontal, 8).frame(height: 24).background(Capsule().fill(T.accent))
                            .position(x: drag.at.x, y: drag.at.y - 22).allowsHitTesting(false)
                    }
                }
                .frame(width: w, height: L.height, alignment: .topLeading)
                .coordinateSpace(name: "schematic")
                .preference(key: SchematicHeight.self, value: L.height)
            }
            .frame(height: height)
            .onPreferenceChange(SchematicHeight.self) { height = $0 }
            HStack(spacing: T.s3) {
                Text(selected.map { "Now click where \(store.routeLabel($0, atem.state)) should go." }
                     ?? (message.isEmpty ? "Drag a source or a mix onto a destination, or click one and then the other. It changes right away." : message))
                    .font(.sans(12, message.isEmpty || selected != nil ? .regular : .semibold))
                    .foregroundStyle(selected != nil ? T.accent : (message.isEmpty ? T.inkSubtle : T.success))
                HelpButton(text: "Each switcher output feeds a screen or a piece of gear. Drag a source or a mix onto a destination to change what it shows, right away. The pencil on a destination names it, sets which outputs feed it (a pair listed together switches together) and notes how it's wired. Outputs that feed encoders and recorders are locked so nobody changes the stream by accident, and ports that only go to the patch bay fold away as spare.")
                Spacer()
                Button("Undo") { if let u = undo.popLast() { u.back(); message = "\(u.what) is back to what it was." } }
                    .buttonStyle(CueButton()).disabled(undo.isEmpty).help("Put back the last thing changed here")
            }
        }
        // No card around it: the schematic is the page.
    }

    @State private var height: CGFloat = 400

    private func head(_ h: Head, _ w: CGFloat) -> some View {
        let right = [Group.screens, .feeds, .spareOut].contains(h.group)
        return HStack(spacing: 6) {
            if h.foldable { Image(systemName: h.open ? "chevron.down" : "chevron.right").font(.system(size: 9, weight: .bold)).foregroundStyle(T.inkSubtle) }
            Text(h.group.rawValue).panelLabel()
            if h.foldable { Text("\(h.count)").font(.sans(11, .semibold)).foregroundStyle(T.inkSubtle) }
            if h.group == .feeds {
                Spacer(minLength: 4)
                Button { feedsUnlocked.toggle() } label: {
                    Label(feedsUnlocked ? "Unlocked" : "Locked", systemImage: feedsUnlocked ? "lock.open" : "lock.fill")
                        .font(.sans(11, .semibold)).foregroundStyle(feedsUnlocked ? T.inkMuted : T.warning).fixedSize()
                }
                .buttonStyle(.plain)
                .help(feedsUnlocked ? "Lock these again" : "One of these may carry the live stream. Unlock to change them.")
            }
        }
        .frame(width: sizes(w).side, height: headH - 4, alignment: .leading)
        .contentShape(Rectangle())
        .onTapGesture {
            switch h.group {
            case .spareIn: showSpareIn.toggle()
            case .inside: showInternal.toggle()
            case .spareOut: showSpareOut.toggle()
            default: break
            }
        }
        .help(h.group == .spareIn || h.group == .spareOut ? "Ports that only go to patch bay tie lines" : "")
        .position(x: (right ? w - sizes(w).side / 2 : sizes(w).side / 2), y: h.y + (headH - 4) / 2)
    }

    private func column(_ title: String, _ note: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: T.s2) {
            Text(title).font(.sans(17, .bold))
            Text(note).font(.sans(12)).foregroundStyle(T.inkSubtle).lineLimit(1)
        }
    }

    /// Which connector on the switcher this is: "IN 9", "OUT 4+5".
    private func port(_ text: String) -> some View {
        Text(text).font(.system(size: 13, weight: .bold, design: .monospaced)).foregroundStyle(T.inkMuted)
            .padding(.horizontal, 6).frame(height: 22)
            .background(RoundedRectangle(cornerRadius: T.rSM).fill(T.surfaceRaised.opacity(0.9)))
            .overlay(RoundedRectangle(cornerRadius: T.rSM).stroke(T.line))
            .fixedSize()
    }

    private func thumb(_ input: Int?, _ w: CGFloat) -> some View {
        let t = sizes(w).thumb
        return SourcePicture(input: input, named: false).frame(width: t.width, height: t.height).clipShape(Rectangle())
    }

    private func sourceRow(_ s: Src, _ c: Color?, on: Bool, _ L: Layout, _ w: CGFloat) -> some View {
        HStack(spacing: T.s2) {
            if s.pic { thumb(s.id, w) }
            if s.pic {
                VStack(alignment: .leading, spacing: 4) {
                    Text(store.label(s.id, atem.state)).font(.sans(21, .semibold)).lineLimit(1).minimumScaleFactor(0.7)
                    ForEach(tallies(s.id, short: false), id: \.0) { t in Tag(text: t.0, color: t.1, ink: t.2, size: 12) }
                }
            } else {
                Text(store.label(s.id, atem.state)).font(.sans(17, .semibold)).lineLimit(1).minimumScaleFactor(0.7)
                ForEach(tallies(s.id, short: true), id: \.0) { t in Tag(text: t.0, color: t.1, ink: t.2, size: 11) }
            }
            Spacer(minLength: 0)
            if (1...999).contains(s.id) { port("IN \(s.id)") }
            if (1...999).contains(s.id), !ptz.cameras.contains(where: { $0.atemInput == s.id && $0.proto == .canonXC && !$0.host.isEmpty }) {
                SourcePictureButton(input: s.id)
            }
        }
        .padding(.leading, s.pic ? 4 : 10).padding(.trailing, 4)
        .frame(width: s.frame.width, height: s.frame.height)
        .background(RoundedRectangle(cornerRadius: T.rMD).fill(T.surfaceSunken))
        .overlay(RoundedRectangle(cornerRadius: T.rMD).stroke(on ? T.accent : (c ?? T.line), lineWidth: on ? 3 : (c == nil ? 1 : 2)))
        .draggable(s.id, self, L, w)
        .help(((1...999).contains(s.id) ? "Switcher input \(s.id): \(atem.state.inputs[s.id]?.long ?? "")\n" : "")
              + "Drag onto a destination or a mix, or click this and then click where it should go")
    }

    /// Whether a source is Live or Next on the mix in focus.
    private func onMix(_ id: Int, _ focus: Int?) -> Bool {
        guard let focus, isMix(focus), focus % 10 == 0 else { return false }
        let me = (focus - 10000) / 10 - 1
        return atem.state.program[me] == id || atem.state.preview[me] == id
    }

    private func shortMix(_ me: Int) -> String {
        let n = store.config.mixNames.indices.contains(me) ? store.config.mixNames[me] : ""
        return n.isEmpty ? "M/E \(me + 1)" : n
    }

    /// Where a source is in use on the mixes: "Live · Live stream", "Next · Side screens".
    private func tallies(_ id: Int, short: Bool) -> [(String, Color, Color)] {
        let s = atem.state
        var out: [(String, Color, Color)] = []
        for me in s.program.keys.sorted() {
            let name = short ? "M/E \(me + 1)" : shortMix(me)
            if s.program[me] == id { out.append(("Live · \(name)", T.program, .white)) }
            else if s.preview[me] == id { out.append(("Next · \(name)", T.preview, T.onAction)) }
        }
        return out
    }

    private func slot(_ tag: String, _ color: Color, _ ink: Color, _ input: Int?, pic: Bool, _ r: CGRect) -> some View {
        ZStack(alignment: .topLeading) {
            if pic { SourcePicture(input: input, named: false) } else { T.surfaceSunken }
            HStack(spacing: 5) {
                Tag(text: tag, color: color, ink: ink, size: 11)
                Text(store.label(input, atem.state)).font(.sans(15, .semibold)).foregroundStyle(.white).lineLimit(1).minimumScaleFactor(0.75)
            }
            .padding(.horizontal, 5).frame(height: 27)
            .background(RoundedRectangle(cornerRadius: T.rSM).fill(Color.black.opacity(pic ? 0.6 : 0))).padding(4)
        }
        .frame(width: r.width, height: r.height)
        .clipShape(Rectangle())
        .overlay(Rectangle().stroke(color, lineWidth: tag == "Live" ? 2.5 : 1.5))
    }

    private func mixCard(_ m: Mix, _ c: Color, target: Bool, _ L: Layout, _ w: CGFloat) -> some View {
        let s = atem.state, mine = m.me == booth.me
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(shortMix(m.me)).font(.sans(19, .bold)).lineLimit(1)
                Text("M/E \(m.me + 1)").font(.sans(13)).foregroundStyle(T.inkSubtle)
                Spacer(minLength: 0)
                Text(mine ? "Run from Operate" : "Drop a source to put it live")
                    .font(.sans(13)).foregroundStyle(T.inkSubtle).lineLimit(1).minimumScaleFactor(0.8)
                MixNameButton(me: m.me)
            }
            .frame(height: 26)
            HStack(spacing: 6) {
                slot("Live", T.program, .white, s.program[m.me], pic: m.pic, m.live)
                slot("Next", T.preview, T.onAction, s.preview[m.me], pic: m.nextPic, m.next)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10).padding(.top, 6)
        .frame(width: m.frame.width, height: m.frame.height, alignment: .top)
        .background(RoundedRectangle(cornerRadius: T.rLG).fill(T.surfaceRaised.opacity(0.6)))
        .overlay(RoundedRectangle(cornerRadius: T.rLG).stroke(target ? T.accent : c, lineWidth: target ? 4 : 2.5))
        .onTapGesture {
            if let sel = selected, !isMix(sel), !mine { putLive(sel, m.me) } else { selected = selected == m.output ? nil : m.output }
        }
        .draggable(m.output, self, L, w)
        .help(mine ? "\(store.mixName(m.me)): what Operate cuts and fades. Drag it onto a destination to send it there."
                   : "\(store.mixName(m.me)): drop a source here to put it live, or drag this onto a destination")
    }

    private func destRow(_ d: Dst, _ c: Color?, target: Bool, _ w: CGFloat) -> some View {
        // A mix by its short name ("Live stream"); the M/E number is on its card.
        var label = d.mixed ? "Mixed" : (d.source == nil ? "" : store.routeLabel(d.source, atem.state))
        if let src = d.source, isMix(src), src % 10 == 0 {
            let me = (src - 10000) / 10 - 1
            if store.config.mixNames.indices.contains(me), !store.config.mixNames[me].isEmpty { label = store.config.mixNames[me] }
        }
        let out = "OUT " + d.screen.aux.map(String.init).joined(separator: "+")
        return HStack(spacing: T.s2) {
            // On the picture's corner when there is one, so the name keeps its room.
            if d.pic { thumb(d.source, w).overlay(alignment: .topLeading) { port(out).padding(3) } } else { port(out) }
            if d.pic {
                VStack(alignment: .leading, spacing: 3) {
                    Text(d.screen.name).font(.sans(21, .semibold)).lineLimit(2).minimumScaleFactor(0.8)
                    if !label.isEmpty { Label(label, systemImage: "arrow.left").font(.sans(15)).foregroundStyle(T.inkMuted).lineLimit(1).minimumScaleFactor(0.8) }
                }
                Spacer(minLength: 0)
            } else {
                // No live picture: one line, the name and what it's showing.
                Text(d.screen.name).font(.sans(17, .semibold)).lineLimit(1).minimumScaleFactor(0.8).layoutPriority(1)
                Spacer(minLength: 4)
                Text(label).font(.sans(14)).foregroundStyle(T.inkMuted).lineLimit(1).minimumScaleFactor(0.8)
            }
            if d.locked { Image(systemName: "lock.fill").font(.system(size: 13)).foregroundStyle(T.warning) }
            ScreenEditButton(screen: d.screen)
        }
        .padding(.leading, d.pic ? 4 : 6).padding(.trailing, 2)
        .frame(width: d.frame.width, height: d.frame.height)
        .background(RoundedRectangle(cornerRadius: T.rMD).fill(T.surfaceSunken))
        .overlay(RoundedRectangle(cornerRadius: T.rMD).stroke(target ? T.accent : (c ?? T.line), lineWidth: target ? 4 : (c == nil ? 1 : 2)))
        .contentShape(Rectangle())
        .onHover { hover = $0 ? d.source : (hover == d.source ? nil : hover) }
        .onTapGesture { if let s = selected { route(s, d) } }
        .help("\(d.screen.name), switcher output \(d.screen.aux.map(String.init).joined(separator: ", "))"
              + ((d.screen.note ?? "").isEmpty ? "" : "\n\(d.screen.note!)") + (d.locked ? "\nLocked. Unlock Encoders and feeds to change it." : ""))
    }

    // MARK: Changing things

    private func canDrop(on m: Mix) -> Bool {
        guard m.me != booth.me, let s = drag?.source ?? selected else { return false }
        return !isMix(s)
    }

    private func target(_ d: Dst, _ L: Layout, _ w: CGFloat) -> Bool {
        if let drag { return d.frame.insetBy(dx: -16, dy: -3).contains(drag.at) && !d.locked }
        return selected != nil && !d.locked
    }

    /// Where a drag ended: on a destination, or on a mix that takes drops.
    fileprivate func drop(_ source: Int, at p: CGPoint, _ L: Layout) {
        if let d = L.dsts.first(where: { $0.frame.insetBy(dx: -16, dy: -3).contains(p) }) { route(source, d) }
        else if let m = L.mixes.first(where: { $0.frame.contains(p) }), m.me != booth.me, !isMix(source) { putLive(source, m.me) }
    }

    private func route(_ source: Int, _ d: Dst) {
        let s = atem.state, sc = d.screen
        selected = nil
        guard !d.locked else { message = "\(sc.name) is locked. Unlock Encoders and feeds to change it."; return }
        let was = sc.aux.compactMap { a in s.aux[a - 1].map { (a, $0) } }
        guard was.contains(where: { $0.1 != source }) || was.count < sc.aux.count else { return }
        let atem = atem
        push(sc.name) { for (a, v) in was { atem.setAux(a - 1, v) } }
        for a in sc.aux { atem.setAux(a - 1, source) }
        message = "\(sc.name) now shows \(store.routeLabel(source, s))."
    }

    private func putLive(_ source: Int, _ me: Int) {
        let s = atem.state
        selected = nil
        guard let was = s.program[me], was != source else { return }
        let atem = atem
        push(store.mixName(me)) { atem.setProgram(was, me: me) }
        atem.setProgram(source, me: me)
        message = "\(store.label(source, s)) is now live on \(store.mixName(me))."
    }

    private func push(_ what: String, _ back: @escaping () -> Void) {
        undo.append((what, back))
        if undo.count > 20 { undo.removeFirst() }
    }

    fileprivate func setDrag(_ v: (source: Int, at: CGPoint)?) { drag = v; if v != nil { selected = nil } }
    fileprivate func tap(_ id: Int) { selected = selected == id ? nil : id }
    fileprivate func setHover(_ id: Int, _ on: Bool) { hover = on ? id : (hover == id ? nil : hover) }
}

private struct SchematicHeight: PreferenceKey {
    static let defaultValue: CGFloat = 400
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

private extension View {
    /// Something that can be picked up as a source: hover to see its wires, click to choose
    /// it, drag it onto a destination or a mix.
    func draggable(_ id: Int, _ owner: RoutingSchematic, _ L: RoutingSchematic.Layout, _ w: CGFloat) -> some View {
        self.contentShape(Rectangle())
            .onHover { owner.setHover(id, $0) }
            .onTapGesture { owner.tap(id) }
            .gesture(DragGesture(minimumDistance: 6, coordinateSpace: .named("schematic"))
                .onChanged { owner.setDrag((id, $0.location)) }
                .onEnded { v in owner.drop(id, at: v.location, L); owner.setDrag(nil) })
    }
}

/// The pencil on a mix: what that M/E is for, such as "Live stream".
struct MixNameButton: View {
    let me: Int
    @EnvironmentObject var store: ConfigStore
    @State private var editing = false

    var body: some View {
        IconButton(icon: "pencil", help: "Name what this mix is for", size: 15) { editing = true }
            .popover(isPresented: $editing, arrowEdge: .top) {
                VStack(alignment: .leading, spacing: T.s2) {
                    Text("What M/E \(me + 1) is for").font(.sans(14, .bold))
                    TextField("Such as Live stream", text: Binding(
                        get: { store.config.mixNames.indices.contains(me) ? store.config.mixNames[me] : "" },
                        set: { v in store.update { c in
                            while c.mixNames.count <= me { c.mixNames.append("") }
                            c.mixNames[me] = v
                        } }))
                    .textFieldStyle(CueFieldStyle()).frame(width: 260).onSubmit { editing = false }
                    HStack { Spacer(); Button("Done") { editing = false }.buttonStyle(CueButton(kind: .primary)) }
                }
                .padding(T.s4).foregroundStyle(T.ink)
            }
    }
}

/// The pencil on a source: the NDI picture that shows what this switcher input carries.
struct SourcePictureButton: View {
    let input: Int
    @EnvironmentObject var atem: ATEMClient
    @EnvironmentObject var store: ConfigStore
    @State private var editing = false

    var body: some View {
        IconButton(icon: "pencil", help: "Choose a live picture for this source", size: 15) { editing = true }
            .popover(isPresented: $editing, arrowEdge: .trailing) {
                VStack(alignment: .leading, spacing: T.s2) {
                    Text("Picture for \(store.label(input, atem.state))").font(.sans(14, .bold))
                    Text("An NDI source showing what switcher input \(input) carries. It's only for looking at here; it changes nothing on the switcher.")
                        .font(.sans(12)).foregroundStyle(T.inkMuted).fixedSize(horizontal: false, vertical: true)
                    NDIPicker(selection: store.ndi(input), none: "No picture, just the name") { store.setPicture(input, $0) }
                    HStack { Spacer(); Button("Done") { editing = false }.buttonStyle(CueButton(kind: .primary)) }
                }
                .padding(T.s4).frame(width: 340).foregroundStyle(T.ink)
            }
    }
}
