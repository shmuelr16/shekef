import AppKit

struct ImportError: Error { var message: String; init(_ m: String) { message = m } }

extension XMLElement {
    var elems: [XMLElement] { (children ?? []).compactMap { $0 as? XMLElement } }
    func kids(_ name: String) -> [XMLElement] { elems.filter { $0.localName == name } }
    func kid(_ name: String) -> XMLElement? { elems.first { $0.localName == name } }
    func path(_ names: String...) -> XMLElement? {
        var e: XMLElement? = self
        for n in names { e = e?.kid(n) }
        return e
    }
    func attr(_ local: String) -> String? {
        for a in attributes ?? [] where a.localName == local || a.name == local { return a.stringValue }
        return nil
    }
    func num(_ local: String) -> Double? { attr(local).flatMap { Double($0) } }
    func desc(_ name: String) -> [XMLElement] {
        var out: [XMLElement] = []
        for c in elems { if c.localName == name { out.append(c) }; out.append(contentsOf: c.desc(name)) }
        return out
    }
}

@discardableResult
func runProcess(_ path: String, _ args: [String], cwd: URL? = nil) -> (status: Int32, out: String) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: path)
    p.arguments = args
    if let cwd { p.currentDirectoryURL = cwd }
    let pipe = Pipe()
    p.standardOutput = pipe; p.standardError = pipe
    do { try p.run() } catch { return (-1, "\(error)") }
    let d = pipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return (p.terminationStatus, String(data: d, encoding: .utf8) ?? "")
}

func tempDir() -> URL {
    let u = FileManager.default.temporaryDirectory.appendingPathComponent("shekef-" + newID())
    try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
    return u
}

func unzip(_ file: URL) throws -> URL {
    let dir = tempDir()
    let r = runProcess("/usr/bin/unzip", ["-qq", "-o", file.path, "-d", dir.path])
    if r.status > 1 { throw ImportError("לא ניתן לפרוס את הקובץ") }
    return dir
}

func xmlRoot(_ url: URL) -> XMLElement? {
    guard let d = try? Data(contentsOf: url), let doc = try? XMLDocument(data: d, options: []) else { return nil }
    return doc.rootElement()
}

/// ממיר תמונות שהדפדפן לא מציג (tiff, emf...) ל-PNG כשאפשר
func addImageMedia(_ url: URL, ctx: ImportContext) -> String? {
    let ext = url.pathExtension.lowercased()
    if ["png", "jpg", "jpeg", "gif", "svg", "webp"].contains(ext) { return ctx.add(file: url) }
    if let img = NSImage(contentsOf: url), let png = pngData(img) { return ctx.add(png, ext: "png") }
    return ctx.add(file: url)
}

final class PPTXImporter {
    let root: URL
    let ctx: ImportContext
    var k = 1.0             // EMU -> px
    var ptK = 2.0           // pt -> px
    var theme: [String: String] = [:]
    var mediaCache: [String: String] = [:]

    init(root: URL, ctx: ImportContext) { self.root = root; self.ctx = ctx }

    func rels(for part: String) -> [String: String] {
        let dir = (part as NSString).deletingLastPathComponent
        let name = (part as NSString).lastPathComponent
        guard let r = xmlRoot(root.appendingPathComponent("\(dir)/_rels/\(name).rels")) else { return [:] }
        var out: [String: String] = [:]
        for rel in r.kids("Relationship") {
            guard let id = rel.attr("Id"), let t = rel.attr("Target") else { continue }
            if rel.attr("TargetMode") == "External" { continue }
            let full = t.hasPrefix("/") ? String(t.dropFirst()) : URL(fileURLWithPath: "/" + dir + "/" + t).standardized.path.dropFirst().description
            out[id] = full
        }
        return out
    }
    func relsByType(for part: String, suffix: String) -> String? {
        let dir = (part as NSString).deletingLastPathComponent
        let name = (part as NSString).lastPathComponent
        guard let r = xmlRoot(root.appendingPathComponent("\(dir)/_rels/\(name).rels")) else { return nil }
        for rel in r.kids("Relationship") where (rel.attr("Type") ?? "").hasSuffix(suffix) {
            guard let t = rel.attr("Target") else { continue }
            return t.hasPrefix("/") ? String(t.dropFirst()) : URL(fileURLWithPath: "/" + dir + "/" + t).standardized.path.dropFirst().description
        }
        return nil
    }

    func media(_ part: String?) -> String? {
        guard let part else { return nil }
        if let m = mediaCache[part] { return m }
        let u = root.appendingPathComponent(part)
        guard FileManager.default.fileExists(atPath: u.path) else { return nil }
        let isAudio = AUDIO_EXT.contains(u.pathExtension.lowercased())
        let name = isAudio ? ctx.add(file: u) : addImageMedia(u, ctx: ctx)
        mediaCache[part] = name
        return name
    }

    func color(_ parent: XMLElement?) -> String? {
        guard let parent else { return nil }
        var base: String?
        var node: XMLElement?
        if let c = parent.kid("srgbClr") { base = c.attr("val"); node = c }
        else if let c = parent.kid("schemeClr") {
            let map = ["tx1": "dk1", "tx2": "dk2", "bg1": "lt1", "bg2": "lt2"]
            let v = c.attr("val") ?? ""
            base = theme[map[v] ?? v]; node = c
        } else if let c = parent.kid("sysClr") { base = c.attr("lastClr"); node = c }
        else if let c = parent.kid("prstClr") { base = ["black": "000000", "white": "FFFFFF", "red": "FF0000", "blue": "0000FF", "green": "008000", "yellow": "FFFF00"][c.attr("val") ?? ""]; node = c }
        guard let hex = base, var c = parseCSSColor("#" + hex) else { return nil }
        if let a = node?.kid("alpha")?.num("val") { c.a = a / 100000 }
        if let m = node?.kid("lumMod")?.num("val") { let f = m / 100000; c.r *= f; c.g *= f; c.b *= f }
        if let o = node?.kid("lumOff")?.num("val") { let f = o / 100000; c.r = min(1, c.r + f); c.g = min(1, c.g + f); c.b = min(1, c.b + f) }
        return c.css
    }
    func fill(_ spPr: XMLElement?) -> String? {
        guard let spPr else { return nil }
        if spPr.kid("noFill") != nil { return nil }
        if let s = spPr.kid("solidFill") { return color(s) }
        if let g = spPr.kid("gradFill") {
            let stops = g.desc("gs").compactMap { gs -> String? in color(gs) }
            if stops.count >= 2 { return "linear-gradient(180deg,\(stops.joined(separator: ",")))" }
            return stops.first
        }
        return nil
    }

    typealias Xf = (Double, Double, Double, Double) -> (Double, Double, Double, Double)

    func parse() throws -> Deck {
        guard let pres = xmlRoot(root.appendingPathComponent("ppt/presentation.xml")) else { throw ImportError("קובץ PowerPoint לא תקין") }
        let cx = pres.kid("sldSz")?.num("cx") ?? 12192000, cy = pres.kid("sldSz")?.num("cy") ?? 6858000
        k = SLIDE_W / cx
        ptK = 12700 * k
        var deck = Deck()
        deck.height = (cy * k).rounded()
        deckH = deck.height
        let prels = rels(for: "ppt/presentation.xml")
        if let themePart = prels.values.first(where: { $0.contains("theme/") }), let t = xmlRoot(root.appendingPathComponent(themePart)) {
            if let scheme = t.desc("clrScheme").first {
                for c in scheme.elems {
                    if let v = c.kid("srgbClr")?.attr("val") ?? c.kid("sysClr")?.attr("lastClr"), let n = c.localName { theme[n] = v }
                }
            }
        }
        for sid in pres.kid("sldIdLst")?.kids("sldId") ?? [] {
            guard let rid = sid.attr("id") == nil ? nil : (sid.attributes ?? []).first(where: { $0.localName == "id" && ($0.prefix ?? "") != "" })?.stringValue,
                  let part = prels[rid] else { continue }
            if let s = slide(part) { deck.slides.append(s) }
        }
        return deck
    }

    func background(_ rootEl: XMLElement, part: String) -> (String?, String?)? {
        guard let bg = rootEl.path("cSld", "bg") else { return nil }
        if let pr = bg.kid("bgPr") {
            if let blip = pr.path("blipFill", "blip"), let rid = blip.attr("embed"), let m = media(rels(for: part)[rid]) { return (nil, m) }
            if let f = fill(pr) { return (f, nil) }
        }
        if let ref = bg.kid("bgRef"), let c = color(ref) { return (c, nil) }
        return nil
    }

    func slide(_ part: String) -> Slide? {
        guard let rootEl = xmlRoot(root.appendingPathComponent(part)) else { return nil }
        var s = Slide()
        let layoutPart = relsByType(for: part, suffix: "/slideLayout")
        let layout = layoutPart.flatMap { xmlRoot(root.appendingPathComponent($0)) }
        let masterPart = layoutPart.flatMap { relsByType(for: $0, suffix: "/slideMaster") }
        let master = masterPart.flatMap { xmlRoot(root.appendingPathComponent($0)) }
        let bg = background(rootEl, part: part) ?? layout.flatMap { background($0, part: layoutPart!) } ?? master.flatMap { background($0, part: masterPart!) }
        s.bg = bg?.0 ?? "#ffffff"; s.bgImage = bg?.1
        var idMap: [String: String] = [:]
        let ident: Xf = { ($0, $1, $2, $3) }
        if rootEl.attr("showMasterSp") != "0" {
            if let m = master, let mp = masterPart, let tree = m.path("cSld", "spTree") { walk(tree, part: mp, xf: ident, into: &s, ids: &idMap, layout: nil, master: nil, decorOnly: true) }
            if let l = layout, let lp = layoutPart, l.attr("showMasterSp") != "0" || true, let tree = l.path("cSld", "spTree") { walk(tree, part: lp, xf: ident, into: &s, ids: &idMap, layout: nil, master: nil, decorOnly: true) }
        }
        idMap = [:]
        if let tree = rootEl.path("cSld", "spTree") { walk(tree, part: part, xf: ident, into: &s, ids: &idMap, layout: layout, master: master, decorOnly: false) }
        // מעבר
        let trans = rootEl.desc("transition")
        if let t = trans.first {
            let names = Set(trans.flatMap { $0.elems.compactMap { $0.localName } })
            if names.contains("morph") { s.transition = "morph" }
            else if names.contains("push") || names.contains("wipe") || names.contains("cover") || names.contains("pull") { s.transition = "push" }
            else if names.contains("zoom") { s.transition = "zoom" }
            else { s.transition = "fade" }
            _ = t
        } else { s.transition = "none" }
        // אנימציות כניסה
        if let ts = trans.first?.desc("snd").first?.attr("name") {
            let n = (ts as NSString).deletingPathExtension
            if SFX.contains(where: { $0.id == n }) { s.tSound = n }
        }
        if let timing = rootEl.kid("timing") { parseTiming(timing, ids: idMap, into: &s) }
        return s
    }

    /// אנימציות PowerPoint: כניסה (בלחיצה או אוטומטית), לולאות תנועה/גודל/סיבוב, יציאה, וסאונד
    func parseTiming(_ timing: XMLElement, ids: [String: String], into s: inout Slide) {
        var step = 0
        var lastEntr: Int?
        var pendingSound: String?
        let H = s.elements.isEmpty ? 1080.0 : 0
        _ = H
        func index(_ ctn: XMLElement) -> Int? {
            guard let spid = ctn.desc("spTgt").first?.attr("spid"), let eid = ids[spid] else { return nil }
            return s.elements.firstIndex { $0.id == eid }
        }
        func sound(_ audio: XMLElement) {
            guard let raw = audio.desc("sndTgt").first?.attr("name") else { return }
            let n = (raw as NSString).deletingPathExtension
            guard SFX.contains(where: { $0.id == n }) else { return }
            if let i = lastEntr, s.elements[i].aSound == nil { s.elements[i].aSound = n } else { pendingSound = n }
        }
        func handle(_ ctn: XMLElement, _ cls: String, _ delay: Double) {
            let inner = ctn.desc("cTn")
            let dur = inner.compactMap { $0.num("dur") }.max() ?? 500
            ctn.desc("audio").forEach { sound($0) }
            guard let i = index(ctn) else { return }
            switch cls {
            case "entr":
                if ctn.attr("nodeType") == "clickEffect" { step += 1; pendingSound = nil; lastEntr = nil }
                guard s.elements[i].anim == nil else { return }
                s.elements[i].anim = ["22": "wipe", "42": "up", "2": "up", "53": "zoom", "23": "zoom", "26": "pop"][ctn.attr("presetID") ?? ""] ?? "fade"
                s.elements[i].step = step
                s.elements[i].delay = delay > 0 ? delay : nil
                s.elements[i].dur = dur
                if let p = pendingSound { s.elements[i].aSound = p; pendingSound = nil }
                lastEntr = i
            case "path":
                guard let path = ctn.desc("animMotion").first?.attr("path") else { return }
                let nums = path.components(separatedBy: CharacterSet(charactersIn: "0123456789.-").inverted).compactMap { Double($0) }
                guard nums.count >= 4 else { return }
                let l = Loop(k: "move", dx: (nums[nums.count - 2] * SLIDE_W).rounded(), dy: (nums[nums.count - 1] * deckH).rounded(), dur: dur, delay: delay > 0 ? delay : nil, once: ctn.attr("repeatCount") == nil ? true : nil)
                s.elements[i].loops = (s.elements[i].loops ?? []) + [l]
            case "emph":
                if let by = ctn.desc("animScale").first?.kid("by")?.num("x") {
                    s.elements[i].loops = (s.elements[i].loops ?? []) + [Loop(k: "scale", by: by / 100000, dur: dur, delay: delay > 0 ? delay : nil, once: ctn.attr("repeatCount") == nil ? true : nil)]
                } else if let by = ctn.desc("animRot").first?.num("by") {
                    s.elements[i].loops = (s.elements[i].loops ?? []) + [Loop(k: "spin", deg: by / 60000, dur: dur, delay: delay > 0 ? delay : nil, once: ctn.attr("repeatCount") == nil ? true : nil)]
                }
            case "exit":
                let e = s.elements[i]
                let up = ctn.attr("presetSubtype") == "1"
                let l = Loop(k: "move", dx: 0, dy: up ? -(e.y + e.h + 20) : (deckH - e.y + 20), dur: dur, delay: delay > 0 ? delay : nil, once: true)
                s.elements[i].loops = (s.elements[i].loops ?? []) + [l]
            default: break
            }
        }
        func visit(_ n: XMLElement, _ delay: Double) {
            for c in n.elems {
                if c.localName == "audio" { sound(c); continue }
                guard let ctn = c.kid("cTn") else {
                    if c.localName == "childTnLst" || c.localName == "tnLst" { visit(c, delay) }
                    continue
                }
                var d = delay
                if let v = ctn.kid("stCondLst")?.kids("cond").compactMap({ Double($0.attr("delay") ?? "") }).first { d += v }
                if let cls = ctn.attr("presetClass") { handle(ctn, cls, d) }
                else if let ch = ctn.kid("childTnLst") { visit(ch, d) }
            }
        }
        visit(timing, 0)
    }
    var deckH: Double = 1080

    func xfrm(_ x: XMLElement?) -> (Double, Double, Double, Double, Double)? {
        guard let x, let off = x.kid("off"), let ext = x.kid("ext") else { return nil }
        return (off.num("x") ?? 0, off.num("y") ?? 0, ext.num("cx") ?? 0, ext.num("cy") ?? 0, (x.num("rot") ?? 0) / 60000)
    }

    func placeholderXfrm(_ ph: XMLElement, in docs: [XMLElement?]) -> (Double, Double, Double, Double, Double)? {
        let type = ph.attr("type") ?? "body", idx = ph.attr("idx")
        for d in docs {
            guard let tree = d?.path("cSld", "spTree") else { continue }
            for sp in tree.desc("sp") {
                guard let p = sp.path("nvSpPr", "nvPr", "ph") else { continue }
                let pt = p.attr("type") ?? "body"
                let match = (idx != nil && p.attr("idx") == idx) || (pt == type) || (type == "ctrTitle" && pt == "title") || (type == "subTitle" && pt == "body")
                if match, let x = xfrm(sp.path("spPr", "xfrm")) { return x }
            }
        }
        return nil
    }

    func walk(_ tree: XMLElement, part: String, xf: @escaping Xf, into s: inout Slide, ids: inout [String: String], layout: XMLElement?, master: XMLElement?, decorOnly: Bool) {
        let rl = rels(for: part)
        for node in tree.elems {
            switch node.localName {
            case "grpSp":
                var inner = xf
                if let g = node.path("grpSpPr", "xfrm"), let off = g.kid("off"), let ext = g.kid("ext"), let co = g.kid("chOff"), let ce = g.kid("chExt"),
                   let cw = ce.num("cx"), let ch = ce.num("cy"), cw > 0, ch > 0 {
                    let ox = off.num("x") ?? 0, oy = off.num("y") ?? 0, sx = (ext.num("cx") ?? cw) / cw, sy = (ext.num("cy") ?? ch) / ch
                    let cox = co.num("x") ?? 0, coy = co.num("y") ?? 0
                    inner = { x, y, w, h in xf(ox + (x - cox) * sx, oy + (y - coy) * sy, w * sx, h * sy) }
                }
                walk(node, part: part, xf: inner, into: &s, ids: &ids, layout: layout, master: master, decorOnly: decorOnly)
            case "pic":
                let nv = node.path("nvPicPr", "cNvPr")
                if decorOnly && node.path("nvPicPr", "nvPr", "ph") != nil { continue }
                guard let g = xfrm(node.path("spPr", "xfrm")) else { continue }
                let (x, y, w, h) = xf(g.0, g.1, g.2, g.3)
                var e: Element
                if let snd = nv?.kid("hlinkClick")?.kid("snd"), let rid = snd.attr("embed"), let a = media(rl[rid]) {
                    e = Element(type: "read", x: x * k, y: y * k, w: w * k, h: h * k)
                    e.src = a; e.label = nv?.attr("descr") ?? "הקראה"
                } else if let alink = node.path("nvPicPr", "nvPr", "audioFile")?.attr("link"), let a = media(rl[alink]) {
                    if s.audio == nil { s.audio = a; s.audioAuto = false }
                    continue
                } else {
                    guard let blip = node.path("blipFill", "blip"), let rid = blip.attr("embed"), let m = media(rl[rid]) else { continue }
                    e = Element(type: "image", x: x * k, y: y * k, w: w * k, h: h * k)
                    e.src = m; e.fit = "fill"
                    if let a = blip.kid("alphaModFix")?.num("amt") { e.opacity = a / 100000 }
                }
                if g.4 != 0 { e.rot = g.4 }
                finish(&e, nv: nv, into: &s, ids: &ids)
            case "sp", "cxnSp":
                let nvRoot = node.kid("nvSpPr") ?? node.kid("nvCxnSpPr")
                let nv = nvRoot?.kid("cNvPr")
                let ph = nvRoot?.path("nvPr", "ph")
                if decorOnly && ph != nil { continue }
                let spPr = node.kid("spPr")
                guard let g = xfrm(spPr?.kid("xfrm")) ?? ph.flatMap({ placeholderXfrm($0, in: [layout, master]) }) else { continue }
                let (x, y, w, h) = xf(g.0, g.1, g.2, g.3)
                let prst = spPr?.kid("prstGeom")?.attr("prst") ?? "rect"
                let f = fill(spPr)
                let ln = spPr?.kid("ln")
                let stroke = ln.flatMap { $0.kid("noFill") != nil ? nil : color($0.kid("solidFill")) }
                let sw = ln?.num("w").map { max(1, $0 * k) }
                let paras = node.path("txBody")?.kids("p") ?? []
                let hasText = paras.contains { !$0.desc("t").compactMap { $0.stringValue }.joined().trimmingCharacters(in: .whitespaces).isEmpty }
                let shapeKind = ["ellipse": "ellipse", "roundRect": "round", "triangle": "triangle", "diamond": "diamond", "star5": "star", "leftArrow": "arrow", "rightArrow": "arrow", "line": "line", "straightConnector1": "line"][prst]
                var e: Element
                if hasText && (shapeKind == nil || shapeKind == "round") {
                    e = Element(type: "text", x: x * k, y: y * k, w: w * k, h: h * k)
                    e.fill = f; e.stroke = stroke; e.strokeW = stroke != nil ? (sw ?? 1) : nil
                    if shapeKind == "round" { e.radius = min(w, h) * k * 0.16 }
                    textBody(node.kid("txBody")!, into: &e, phType: ph?.attr("type"), isPlaceholder: ph != nil, master: master)
                } else {
                    if f == nil && stroke == nil && !hasText { continue }
                    e = Element(type: "shape", x: x * k, y: y * k, w: w * k, h: max(h * k, shapeKind == "line" ? 20 : 2))
                    if shapeKind == "line" { e.y -= 10 }
                    e.shape = shapeKind ?? "rect"; e.fill = f; e.stroke = stroke; e.strokeW = stroke != nil ? (sw ?? 1) : nil
                    if prst == "rightArrow" { e.rot = 180 }
                    if hasText {
                        finish(&e, nv: nil, into: &s, ids: &ids)
                        var t = Element(type: "text", x: x * k, y: y * k, w: w * k, h: h * k)
                        textBody(node.kid("txBody")!, into: &t, phType: nil, isPlaceholder: false, master: master)
                        if t.valign == nil { t.valign = "middle" }
                        e = t
                    }
                }
                if g.4 != 0 { e.rot = (e.rot ?? 0) + g.4 }
                finish(&e, nv: nv, into: &s, ids: &ids)
            case "AlternateContent":
                if let c = node.kid("Choice") ?? node.kid("Fallback") { walk(c, part: part, xf: xf, into: &s, ids: &ids, layout: layout, master: master, decorOnly: decorOnly) }
            default: break
            }
        }
    }

    func finish(_ e: inout Element, nv: XMLElement?, into s: inout Slide, ids: inout [String: String]) {
        if let n = nv?.attr("name") { e.name = n; if n.hasPrefix("!!") { e.morph = n } }
        if let id = nv?.attr("id") { ids[id] = e.id }
        e.x = e.x.rounded(); e.y = e.y.rounded(); e.w = max(4, e.w.rounded()); e.h = max(4, e.h.rounded())
        s.elements.append(e)
    }

    func textBody(_ body: XMLElement, into e: inout Element, phType: String?, isPlaceholder: Bool, master: XMLElement?) {
        var defPt = 18.0
        var defColor: String? = theme["dk1"].map { "#" + $0.lowercased() }
        if isPlaceholder {
            let isTitle = phType == "title" || phType == "ctrTitle"
            defPt = isTitle ? 44 : (phType == "subTitle" ? 24 : 28)
            if let st = master?.path("txStyles", isTitle ? "titleStyle" : "bodyStyle", "lvl1pPr", "defRPr") {
                if let sz = st.num("sz") { defPt = sz / 100 }
                if let c = color(st.kid("solidFill")) { defColor = c }
            }
            if isTitle { e.bold = nil }
        }
        if let sz = body.path("lstStyle", "lvl1pPr", "defRPr")?.num("sz") { defPt = sz / 100 }
        let bp = body.kid("bodyPr")
        e.valign = ["ctr": "middle", "b": "bottom"][bp?.attr("anchor") ?? ""]
        if let scale = bp?.kid("normAutofit")?.num("fontScale") { defPt *= scale / 100000 }
        var html = ""
        var firstSize: Double?, firstColor: String?, firstFont: String?, firstAlign: String?
        var anyRTL = false
        for p in body.kids("p") {
            let ppr = p.kid("pPr")
            let rtl = ppr?.attr("rtl") == "1"
            if rtl { anyRTL = true }
            let al = ["l": "left", "ctr": "center", "r": "right", "just": "justify"][ppr?.attr("algn") ?? ""] ?? (isPlaceholder && (phType == "ctrTitle" || phType == "subTitle") ? "center" : (rtl ? "right" : nil))
            if firstAlign == nil { firstAlign = al }
            var inner = ""
            for r in p.elems {
                if r.localName == "br" { inner += "<br>"; continue }
                guard r.localName == "r" || r.localName == "fld", let t = r.kid("t")?.stringValue, !t.isEmpty else { continue }
                let pr = r.kid("rPr")
                let px = ((pr?.num("sz").map { $0 / 100 } ?? defPt) * ptK * 10).rounded() / 10
                let col = color(pr?.kid("solidFill")) ?? defColor
                let font = pr?.kid("cs")?.attr("typeface") ?? pr?.kid("latin")?.attr("typeface")
                if firstSize == nil { firstSize = px; firstColor = col; firstFont = (font?.hasPrefix("+") ?? true) ? nil : font }
                var st = ""
                if px != firstSize { st += "font-size:\(px)px;" }
                if let col, col != firstColor { st += "color:\(col);" }
                if pr?.attr("b") == "1" { st += "font-weight:700;" }
                if pr?.attr("i") == "1" { st += "font-style:italic;" }
                if let u = pr?.attr("u"), u != "none" { st += "text-decoration:underline;" }
                if let font, !font.hasPrefix("+"), font != firstFont { st += "font-family:'\(font)';" }
                inner += st.isEmpty ? escapeHTML(t) : "<span style=\"\(st)\">\(escapeHTML(t))</span>"
            }
            let style = al != nil && al != firstAlign ? " style=\"text-align:\(al!)\"" : ""
            html += "<div\(style)>\(inner.isEmpty ? "<br>" : inner)</div>"
        }
        e.html = html
        e.size = firstSize ?? (defPt * ptK)
        e.color = firstColor ?? defColor ?? "#000000"
        e.font = firstFont
        let hebrew = html.unicodeScalars.contains { $0.value >= 0x590 && $0.value <= 0x5FF }
        e.dir = (anyRTL || hebrew) ? "rtl" : "ltr"
        e.align = firstAlign ?? (e.dir == "rtl" ? "right" : "left")
        e.pad = 12
        e.lineHeight = 1.2
    }
}
