import AppKit
import PDFKit
import UniformTypeIdentifiers

extension AppState {
    func exportPanel(_ kind: String) {
        guard deck != nil else { return }
        editor.js("Editor.stopEdit()")
        let p = NSSavePanel()
        p.nameFieldStringValue = title + "." + kind
        p.allowedContentTypes = [UTType(filenameExtension: kind) ?? .data]
        p.prompt = "ייצא"
        guard p.runModal() == .OK, let url = p.url else { return }
        Task {
            // נותן לטקסט שבעריכה להישמר
            try? await Task.sleep(nanoseconds: 150_000_000)
            await export(kind, to: url, reveal: true)
        }
    }

    func export(_ kind: String, to url: URL, reveal: Bool = false) async {
        guard let d = deck else { return }
        busy = "מייצא \(kind.uppercased())…"
        defer { busy = nil }
        do {
            switch kind {
            case "pdf": try await exportPDF(d, to: url)
            case "pptx": try await PPTXExporter(deck: d, mediaDir: scheme.mediaDir()!, renderer: renderer).write(to: url)
            case "html": try exportHTML(d, to: url)
            default: break
            }
            if reveal { NSWorkspace.shared.activateFileViewerSelecting([url]) }
        } catch {
            errorMessage = "הייצוא נכשל: \((error as? ImportError)?.message ?? error.localizedDescription)"
        }
    }

    func exportPDF(_ d: Deck, to url: URL) async throws {
        let out = PDFDocument()
        for s in d.slides {
            var data = await renderer.pdfPage(s, deck: d)
            if data == nil, let img = await renderer.snapshot(s, deck: d) { data = PDFPage(image: img)?.dataRepresentation }
            if let data, let doc = PDFDocument(data: data), let page = doc.page(at: 0) { out.insert(page, at: out.pageCount) }
        }
        guard out.pageCount > 0, out.write(to: url) else { throw ImportError("לא ניתן לכתוב PDF") }
    }

    func exportHTML(_ d: Deck, to url: URL) throws {
        guard let mediaDir = scheme.mediaDir() else { return }
        let web = SchemeHandler.webDir
        func res(_ n: String) -> String { (try? String(contentsOf: web.appendingPathComponent(n), encoding: .utf8)) ?? "" }
        let hasEmbed = d.slides.contains { $0.elements.contains { $0.type == "embed" } }
        var names = Set<String>()
        var sfx = Set<String>()
        for s in d.slides {
            [s.bgImage, s.audio].compactMap { $0 }.forEach { names.insert($0) }
            if let t = s.tSound { sfx.insert(t) }
            for e in s.elements { if let n = e.src, e.type != "embed" { names.insert(n) }; if let a = e.aSound { sfx.insert(a) } }
        }
        (d.fonts ?? []).forEach { names.insert($0.src) }
        var mediaJSON = "{}"
        var head = ""
        var outURL = url
        if hasEmbed {
            // יש הטמעות HTML: מייצאים תיקייה עם index.html ו-media
            let folder = url.deletingPathExtension()
            let fm = FileManager.default
            if fm.fileExists(atPath: folder.path) { try fm.removeItem(at: folder) }
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
            try fm.copyItem(at: mediaDir, to: folder.appendingPathComponent("media"))
            let sdir = folder.appendingPathComponent("media/sfx")
            try fm.createDirectory(at: sdir, withIntermediateDirectories: true)
            for n in sfx { try? fm.copyItem(at: Bundle.main.resourceURL!.appendingPathComponent("sounds/\(n).wav"), to: sdir.appendingPathComponent("\(n).wav")) }
            head = "<script>window.MEDIA_BASE='media/';</script>"
            outURL = folder.appendingPathComponent("index.html")
        } else {
            var map: [String: String] = [:]
            func uri(_ f: URL) -> String? {
                guard let data = try? Data(contentsOf: f) else { return nil }
                let mime = UTType(filenameExtension: f.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
                return "data:\(mime);base64,\(data.base64EncodedString())"
            }
            for n in names { if let u = uri(mediaDir.appendingPathComponent(n)) { map[n] = u } }
            for n in sfx { if let u = uri(Bundle.main.resourceURL!.appendingPathComponent("sounds/\(n).wav")) { map["sfx/\(n).wav"] = u } }
            mediaJSON = jsonString(map)
        }
        let deckJSON = jsonString(d).replacingOccurrences(of: "</", with: "<\\/")
        let html = """
        <!doctype html>
        <html lang="he" dir="rtl"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
        <title>\(escapeHTML(title))</title>
        <style>\(res("stage.css"))\n\(res("player.css"))</style>\(head)</head>
        <body class="play"><div id="vp"></div>
        <script>window.MEDIA=\(mediaJSON);</script>
        <script type="application/json" id="shekef-deck">\(deckJSON)</script>
        <script>\(res("stage.js"))</script>
        <script>\(res("player.js"))</script>
        <script>Player.start(JSON.parse(document.getElementById('shekef-deck').textContent),0)</script>
        </body></html>
        """
        try html.write(to: outURL, atomically: true, encoding: .utf8)
    }
}

// MARK: PPTX

@MainActor
final class PPTXExporter {
    let deck: Deck, mediaDir: URL, renderer: Renderer
    let E = 6350.0   // EMU לפיקסל
    var dir: URL!
    var mediaNames: [String: String] = [:]   // מקור -> שם ב-ppt/media
    var mediaCount = 0

    init(deck: Deck, mediaDir: URL, renderer: Renderer) { self.deck = deck; self.mediaDir = mediaDir; self.renderer = renderer }

    func emu(_ v: Double) -> Int { Int((v * E).rounded()) }
    func put(_ path: String, _ s: String) throws {
        let u = dir.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
        try s.write(to: u, atomically: true, encoding: .utf8)
    }
    func addMedia(data: Data, ext: String) -> String {
        mediaCount += 1
        let n = "image\(mediaCount).\(ext)"
        let u = dir.appendingPathComponent("ppt/media/\(n)")
        try? FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: u)
        return n
    }
    func addMedia(source: String) -> String? {
        if let n = mediaNames[source] { return n }
        let ext = (source as NSString).pathExtension.lowercased()
        guard ["png", "jpg", "jpeg", "gif"].contains(ext), let d = try? Data(contentsOf: mediaDir.appendingPathComponent(source)) else { return nil }
        let n = addMedia(data: d, ext: ext); mediaNames[source] = n
        return n
    }

    func solid(_ css: String?, opacity: Double = 1) -> String? {
        guard let c = firstColor(css), c.a > 0.01 else { return nil }
        let a = c.a * opacity
        return "<a:solidFill><a:srgbClr val=\"\(c.hex)\">\(a < 0.995 ? "<a:alpha val=\"\(Int(a * 100000))\"/>" : "")</a:srgbClr></a:solidFill>"
    }

    func raster(_ e: Element, in s: Slide) async -> (String, CGRect)? {
        var only = Slide(); only.bg = "transparent"
        var c = e; c.anim = nil
        only.elements = [c]
        let r = (e.rot ?? 0) * .pi / 180
        let bw = abs(e.w * cos(r)) + abs(e.h * sin(r)), bh = abs(e.w * sin(r)) + abs(e.h * cos(r))
        var rect = CGRect(x: e.x + e.w / 2 - bw / 2, y: e.y + e.h / 2 - bh / 2, width: bw, height: bh).insetBy(dx: e.shadow == true ? -50 : 0, dy: e.shadow == true ? -50 : 0)
        rect = rect.intersection(CGRect(x: 0, y: 0, width: SLIDE_W, height: deck.height)).integral
        guard rect.width > 1, rect.height > 1, let img = await renderer.snapshot(only, deck: deck, rect: rect), let png = pngData(img) else { return nil }
        return (addMedia(data: png, ext: "png"), rect)
    }

    func write(to url: URL) async throws {
        dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let H = deck.height
        var slideOverrides = "", presRels = "", sldIds = ""
        for (i, s) in deck.slides.enumerated() {
            let n = i + 1
            var rels: [String] = []
            func rel(_ media: String) -> String {
                rels.append(media); return "rId\(rels.count + 1)"
            }
            var tree = ""
            var spid = 2
            var animated: [(Int, Element)] = []
            let layouts = await renderer.textLayouts(s, deck: deck)
            // רקע
            var bgXML = ""
            let plain = parseCSSColor(s.bg ?? "#ffffff")
            if s.bgImage == nil, let p = plain {
                bgXML = "<p:bg><p:bgPr><a:solidFill><a:srgbClr val=\"\(p.hex)\"/></a:solidFill><a:effectLst/></p:bgPr></p:bg>"
            } else {
                var name = s.bgImage.flatMap { plain != nil || s.bg == nil ? addMedia(source: $0) : nil }
                if name == nil {
                    var b = Slide(); b.bg = s.bg; b.bgImage = s.bgImage
                    if let img = await renderer.snapshot(b, deck: deck), let png = pngData(img) { name = addMedia(data: png, ext: "png") }
                }
                if let name {
                    bgXML = "<p:bg><p:bgPr><a:blipFill dpi=\"0\" rotWithShape=\"1\"><a:blip r:embed=\"\(rel(name))\"/><a:srcRect/><a:stretch><a:fillRect/></a:stretch></a:blipFill><a:effectLst/></p:bgPr></p:bg>"
                }
            }
            for e in s.elements {
                let id = spid; spid += 1
                let nm = escapeXML(e.morph.map { $0.hasPrefix("!!") ? $0 : "!!" + $0 } ?? e.name ?? "\(e.type) \(id)")
                let rot = (e.rot ?? 0) != 0 ? " rot=\"\(Int((e.rot ?? 0) * 60000))\"" : ""
                let op = e.opacity ?? 1
                func xfrm(_ r: CGRect, rot: String) -> String {
                    "<a:xfrm\(rot)><a:off x=\"\(emu(r.minX))\" y=\"\(emu(r.minY))\"/><a:ext cx=\"\(emu(r.width))\" cy=\"\(emu(r.height))\"/></a:xfrm>"
                }
                func pic(_ media: String, _ r: CGRect, rot: String, crop: String = "") -> String {
                    let alpha = op < 0.995 ? "<a:alphaModFix amt=\"\(Int(op * 100000))\"/>" : ""
                    return "<p:pic><p:nvPicPr><p:cNvPr id=\"\(id)\" name=\"\(nm)\"/><p:cNvPicPr><a:picLocks noChangeAspect=\"1\"/></p:cNvPicPr><p:nvPr/></p:nvPicPr><p:blipFill><a:blip r:embed=\"\(rel(media))\">\(alpha)</a:blip>\(crop)<a:stretch><a:fillRect/></a:stretch></p:blipFill><p:spPr>\(xfrm(r, rot: rot))<a:prstGeom prst=\"rect\"><a:avLst/></a:prstGeom></p:spPr></p:pic>"
                }
                let box = CGRect(x: e.x, y: e.y, width: e.w, height: e.h)
                var xml: String?
                let gradient = (e.fill ?? "").contains("gradient")
                switch e.type {
                case "image":
                    if let src = e.src, (e.radius ?? 0) == 0, let m = addMedia(source: src) {
                        var r = box, crop = ""
                        if let sz = imagePixelSize(mediaDir.appendingPathComponent(src)), sz.width > 0, sz.height > 0, e.fit != "fill" {
                            let ia = sz.width / sz.height, ba = e.w / e.h
                            if e.fit == "cover" {
                                if ia > ba { let c = Int((1 - ba / ia) / 2 * 100000); crop = "<a:srcRect l=\"\(c)\" r=\"\(c)\"/>" }
                                else { let c = Int((1 - ia / ba) / 2 * 100000); crop = "<a:srcRect t=\"\(c)\" b=\"\(c)\"/>" }
                            } else {
                                if ia > ba { let h = e.w / ia; r = CGRect(x: e.x, y: e.y + (e.h - h) / 2, width: e.w, height: h) }
                                else { let w = e.h * ia; r = CGRect(x: e.x + (e.w - w) / 2, y: e.y, width: w, height: e.h) }
                            }
                        }
                        xml = pic(m, r, rot: rot, crop: crop)
                    }
                case "shape" where !gradient:
                    let prst = ["rect": "rect", "round": "roundRect", "ellipse": "ellipse", "triangle": "triangle", "diamond": "diamond", "star": "star5", "arrow": "leftArrow", "line": "line"][e.shape ?? "rect"] ?? "rect"
                    var r = box
                    var fillXML = solid(e.fill, opacity: op) ?? "<a:noFill/>"
                    var lnXML = e.strokeW != nil ? "<a:ln w=\"\(emu(e.strokeW!))\">\(solid(e.stroke ?? "#000000", opacity: op) ?? "<a:noFill/>")</a:ln>" : "<a:ln><a:noFill/></a:ln>"
                    if prst == "line" {
                        r = CGRect(x: e.x, y: e.y + e.h / 2, width: e.w, height: 0); fillXML = ""
                        lnXML = "<a:ln w=\"\(emu(e.strokeW ?? 6))\">\(solid(e.stroke ?? e.fill ?? "#1b2540", opacity: op) ?? "")</a:ln>"
                    }
                    xml = "<p:sp><p:nvSpPr><p:cNvPr id=\"\(id)\" name=\"\(nm)\"/><p:cNvSpPr/><p:nvPr/></p:nvSpPr><p:spPr>\(xfrm(r, rot: rot))<a:prstGeom prst=\"\(prst)\"><a:avLst/></a:prstGeom>\(fillXML)\(lnXML)</p:spPr><p:txBody><a:bodyPr/><a:lstStyle/><a:p><a:endParaRPr lang=\"he-IL\"/></a:p></p:txBody></p:sp>"
                case "text":
                    let lay = layouts[e.id]
                    var paras = ""
                    for p in lay?.paras ?? [] {
                        let al = ["left": "l", "center": "ctr", "right": "r", "justify": "just"][p.align ?? "right"] ?? "r"
                        let rtl = (e.dir ?? "rtl") == "rtl" ? " rtl=\"1\"" : ""
                        let lh = Int((lay?.lineHeight ?? 1.3) / 1.2 * 100000)
                        var runs = ""
                        var lastSize = Int((e.size ?? 48) * 50)
                        for r in p.runs {
                            if r.br == true { runs += "<a:br/>"; continue }
                            guard let t = r.t, !t.isEmpty else { continue }
                            lastSize = Int((r.size ?? e.size ?? 48) * 50)
                            let font = escapeXML(r.font ?? e.font ?? "Arial")
                            runs += "<a:r><a:rPr lang=\"he-IL\" sz=\"\(lastSize)\"\(r.b == true ? " b=\"1\"" : " b=\"0\"")\(r.i == true ? " i=\"1\"" : "")\(r.u == true ? " u=\"sng\"" : "") dirty=\"0\"><a:solidFill><a:srgbClr val=\"\((r.color ?? "000000").uppercased())\">\(op < 0.995 ? "<a:alpha val=\"\(Int(op * 100000))\"/>" : "")</a:srgbClr></a:solidFill><a:latin typeface=\"\(font)\"/><a:cs typeface=\"\(font)\"/></a:rPr><a:t>\(escapeXML(t))</a:t></a:r>"
                        }
                        paras += "<a:p><a:pPr algn=\"\(al)\"\(rtl)><a:lnSpc><a:spcPct val=\"\(lh)\"/></a:lnSpc></a:pPr>\(runs)<a:endParaRPr lang=\"he-IL\" sz=\"\(lastSize)\"/></a:p>"
                    }
                    if paras.isEmpty { paras = "<a:p><a:endParaRPr lang=\"he-IL\"/></a:p>" }
                    let pad = emu(e.pad ?? 12)
                    let anchor = ["middle": "ctr", "bottom": "b"][e.valign ?? ""] ?? "t"
                    let fillXML = solid(e.fill, opacity: op) ?? "<a:noFill/>"
                    let lnXML = e.strokeW != nil ? "<a:ln w=\"\(emu(e.strokeW!))\">\(solid(e.stroke ?? "#000000") ?? "<a:noFill/>")</a:ln>" : ""
                    let geom = (e.radius ?? 0) > 0 ? "<a:prstGeom prst=\"roundRect\"><a:avLst><a:gd name=\"adj\" fmla=\"val \(Int(min(50000, (e.radius ?? 0) / max(1, min(e.w, e.h)) * 100000)))\"/></a:avLst></a:prstGeom>" : "<a:prstGeom prst=\"rect\"><a:avLst/></a:prstGeom>"
                    xml = "<p:sp><p:nvSpPr><p:cNvPr id=\"\(id)\" name=\"\(nm)\"/><p:cNvSpPr txBox=\"1\"/><p:nvPr/></p:nvSpPr><p:spPr>\(xfrm(box, rot: rot))\(geom)\(fillXML)\(lnXML)</p:spPr><p:txBody><a:bodyPr wrap=\"square\" lIns=\"\(pad)\" tIns=\"\(pad)\" rIns=\"\(pad)\" bIns=\"\(pad)\" anchor=\"\(anchor)\" rtlCol=\"\((e.dir ?? "rtl") == "rtl" ? 1 : 0)\"><a:noAutofit/></a:bodyPr><a:lstStyle/>\(paras)</p:txBody></p:sp>"
                default: break
                }
                if xml == nil, let (m, r) = await raster(e, in: s) {
                    var saveOp = op; saveOp = 1; _ = saveOp
                    xml = "<p:pic><p:nvPicPr><p:cNvPr id=\"\(id)\" name=\"\(nm)\"/><p:cNvPicPr><a:picLocks noChangeAspect=\"1\"/></p:cNvPicPr><p:nvPr/></p:nvPicPr><p:blipFill><a:blip r:embed=\"\(rel(m))\"/><a:stretch><a:fillRect/></a:stretch></p:blipFill><p:spPr>\(xfrm(r, rot: ""))<a:prstGeom prst=\"rect\"><a:avLst/></a:prstGeom></p:spPr></p:pic>"
                }
                if let xml { tree += xml; if let a = e.anim, a != "none" { animated.append((id, e)) } }
            }
            // מעבר
            var trans = ""
            switch s.transition ?? "fade" {
            case "none": trans = ""
            case "push": trans = "<p:transition spd=\"med\"><p:push dir=\"r\"/></p:transition>"
            case "zoom": trans = "<p:transition spd=\"med\"><p:zoom/></p:transition>"
            case "morph": trans = "<mc:AlternateContent xmlns:mc=\"http://schemas.openxmlformats.org/markup-compatibility/2006\"><mc:Choice xmlns:p159=\"http://schemas.microsoft.com/office/powerpoint/2015/09/main\" Requires=\"p159\"><p:transition spd=\"slow\"><p159:morph option=\"byObject\"/></p:transition></mc:Choice><mc:Fallback><p:transition spd=\"slow\"><p:fade/></p:transition></mc:Fallback></mc:AlternateContent>"
            default: trans = "<p:transition spd=\"med\"><p:fade/></p:transition>"
            }
            // אנימציות כניסה בלחיצה
            var timing = ""
            if !animated.isEmpty {
                var tid = 3
                var groups: [[(Int, Element)]] = []
                for a in animated { if a.1.animWith == true, !groups.isEmpty { groups[groups.count - 1].append(a) } else { groups.append([a]) } }
                var clicks = ""
                for g in groups {
                    var effects = ""
                    for (j, a) in g.enumerated() {
                        let c1 = tid, c2 = tid + 1, c3 = tid + 2; tid += 3
                        effects += "<p:par><p:cTn id=\"\(c1)\" presetID=\"10\" presetClass=\"entr\" presetSubtype=\"0\" fill=\"hold\" nodeType=\"\(j == 0 ? "clickEffect" : "withEffect")\"><p:stCondLst><p:cond delay=\"0\"/></p:stCondLst><p:childTnLst><p:set><p:cBhvr><p:cTn id=\"\(c2)\" dur=\"1\" fill=\"hold\"><p:stCondLst><p:cond delay=\"0\"/></p:stCondLst></p:cTn><p:tgtEl><p:spTgt spid=\"\(a.0)\"/></p:tgtEl><p:attrNameLst><p:attrName>style.visibility</p:attrName></p:attrNameLst></p:cBhvr><p:to><p:strVal val=\"visible\"/></p:to></p:set><p:animEffect transition=\"in\" filter=\"fade\"><p:cBhvr><p:cTn id=\"\(c3)\" dur=\"500\"/><p:tgtEl><p:spTgt spid=\"\(a.0)\"/></p:tgtEl></p:cBhvr></p:animEffect></p:childTnLst></p:cTn></p:par>"
                    }
                    let o1 = tid, o2 = tid + 1; tid += 2
                    clicks += "<p:par><p:cTn id=\"\(o1)\" fill=\"hold\"><p:stCondLst><p:cond delay=\"indefinite\"/></p:stCondLst><p:childTnLst><p:par><p:cTn id=\"\(o2)\" fill=\"hold\"><p:stCondLst><p:cond delay=\"0\"/></p:stCondLst><p:childTnLst>\(effects)</p:childTnLst></p:cTn></p:par></p:childTnLst></p:cTn></p:par>"
                }
                timing = "<p:timing><p:tnLst><p:par><p:cTn id=\"1\" dur=\"indefinite\" restart=\"never\" nodeType=\"tmRoot\"><p:childTnLst><p:seq concurrent=\"1\" nextAc=\"seek\"><p:cTn id=\"2\" dur=\"indefinite\" nodeType=\"mainSeq\"><p:childTnLst>\(clicks)</p:childTnLst></p:cTn><p:prevCondLst><p:cond evt=\"onPrev\" delay=\"0\"><p:tgtEl><p:sldTgt/></p:tgtEl></p:cond></p:prevCondLst><p:nextCondLst><p:cond evt=\"onNext\" delay=\"0\"><p:tgtEl><p:sldTgt/></p:tgtEl></p:cond></p:nextCondLst></p:seq></p:childTnLst></p:cTn></p:par></p:tnLst></p:timing>"
            }
            try put("ppt/slides/slide\(n).xml", "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n<p:sld \(NS)><p:cSld>\(bgXML)<p:spTree>\(GRP)\(tree)</p:spTree></p:cSld><p:clrMapOvr><a:masterClrMapping/></p:clrMapOvr>\(trans)\(timing)</p:sld>")
            var relXML = "<Relationship Id=\"rId1\" Type=\"\(RT)/slideLayout\" Target=\"../slideLayouts/slideLayout1.xml\"/>"
            for (j, m) in rels.enumerated() { relXML += "<Relationship Id=\"rId\(j + 2)\" Type=\"\(RT)/image\" Target=\"../media/\(m)\"/>" }
            try put("ppt/slides/_rels/slide\(n).xml.rels", RELS_HEAD + relXML + "</Relationships>")
            slideOverrides += "<Override PartName=\"/ppt/slides/slide\(n).xml\" ContentType=\"application/vnd.openxmlformats-officedocument.presentationml.slide+xml\"/>"
            presRels += "<Relationship Id=\"rId\(n + 2)\" Type=\"\(RT)/slide\" Target=\"slides/slide\(n).xml\"/>"
            sldIds += "<p:sldId id=\"\(255 + n)\" r:id=\"rId\(n + 2)\"/>"
        }
        try put("[Content_Types].xml", "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n<Types xmlns=\"http://schemas.openxmlformats.org/package/2006/content-types\"><Default Extension=\"rels\" ContentType=\"application/vnd.openxmlformats-package.relationships+xml\"/><Default Extension=\"xml\" ContentType=\"application/xml\"/><Default Extension=\"png\" ContentType=\"image/png\"/><Default Extension=\"jpg\" ContentType=\"image/jpeg\"/><Default Extension=\"jpeg\" ContentType=\"image/jpeg\"/><Default Extension=\"gif\" ContentType=\"image/gif\"/><Override PartName=\"/ppt/presentation.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.presentationml.presentation.main+xml\"/><Override PartName=\"/ppt/slideMasters/slideMaster1.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.presentationml.slideMaster+xml\"/><Override PartName=\"/ppt/slideLayouts/slideLayout1.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.presentationml.slideLayout+xml\"/><Override PartName=\"/ppt/theme/theme1.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.theme+xml\"/>\(slideOverrides)</Types>")
        try put("_rels/.rels", RELS_HEAD + "<Relationship Id=\"rId1\" Type=\"\(RT)/officeDocument\" Target=\"ppt/presentation.xml\"/></Relationships>")
        try put("ppt/presentation.xml", "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n<p:presentation \(NS) rtl=\"1\" saveSubsetFonts=\"1\"><p:sldMasterIdLst><p:sldMasterId id=\"2147483648\" r:id=\"rId1\"/></p:sldMasterIdLst><p:sldIdLst>\(sldIds)</p:sldIdLst><p:sldSz cx=\"12192000\" cy=\"\(emu(H))\"/><p:notesSz cx=\"6858000\" cy=\"9144000\"/></p:presentation>")
        try put("ppt/_rels/presentation.xml.rels", RELS_HEAD + "<Relationship Id=\"rId1\" Type=\"\(RT)/slideMaster\" Target=\"slideMasters/slideMaster1.xml\"/><Relationship Id=\"rId2\" Type=\"\(RT)/theme\" Target=\"theme/theme1.xml\"/>\(presRels)</Relationships>")
        try put("ppt/slideMasters/slideMaster1.xml", "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n<p:sldMaster \(NS)><p:cSld><p:bg><p:bgRef idx=\"1001\"><a:schemeClr val=\"bg1\"/></p:bgRef></p:bg><p:spTree>\(GRP)</p:spTree></p:cSld><p:clrMap bg1=\"lt1\" tx1=\"dk1\" bg2=\"lt2\" tx2=\"dk2\" accent1=\"accent1\" accent2=\"accent2\" accent3=\"accent3\" accent4=\"accent4\" accent5=\"accent5\" accent6=\"accent6\" hlink=\"hlink\" folHlink=\"folHlink\"/><p:sldLayoutIdLst><p:sldLayoutId id=\"2147483649\" r:id=\"rId1\"/></p:sldLayoutIdLst><p:txStyles><p:titleStyle/><p:bodyStyle/><p:otherStyle/></p:txStyles></p:sldMaster>")
        try put("ppt/slideMasters/_rels/slideMaster1.xml.rels", RELS_HEAD + "<Relationship Id=\"rId1\" Type=\"\(RT)/slideLayout\" Target=\"../slideLayouts/slideLayout1.xml\"/><Relationship Id=\"rId2\" Type=\"\(RT)/theme\" Target=\"../theme/theme1.xml\"/></Relationships>")
        try put("ppt/slideLayouts/slideLayout1.xml", "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n<p:sldLayout \(NS) type=\"blank\" preserve=\"1\"><p:cSld name=\"Blank\"><p:spTree>\(GRP)</p:spTree></p:cSld><p:clrMapOvr><a:masterClrMapping/></p:clrMapOvr></p:sldLayout>")
        try put("ppt/slideLayouts/_rels/slideLayout1.xml.rels", RELS_HEAD + "<Relationship Id=\"rId1\" Type=\"\(RT)/slideMaster\" Target=\"../slideMasters/slideMaster1.xml\"/></Relationships>")
        try put("ppt/theme/theme1.xml", THEME)
        let fm = FileManager.default
        let tmpOut = tempDir().appendingPathComponent("out.pptx")
        let a = runProcess("/usr/bin/zip", ["-X", "-q", tmpOut.path, "[Content_Types].xml"], cwd: dir)
        let b = runProcess("/usr/bin/zip", ["-X", "-q", "-r", tmpOut.path, ".", "-x", "[Content_Types].xml", "-x", ".DS_Store"], cwd: dir)
        guard a.status == 0, b.status == 0 else { throw ImportError("יצירת קובץ ה-pptx נכשלה: \(a.out)\(b.out)") }
        if fm.fileExists(atPath: url.path) { try fm.removeItem(at: url) }
        try fm.moveItem(at: tmpOut, to: url)
    }
}

private let NS = "xmlns:a=\"http://schemas.openxmlformats.org/drawingml/2006/main\" xmlns:r=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships\" xmlns:p=\"http://schemas.openxmlformats.org/presentationml/2006/main\""
private let RT = "http://schemas.openxmlformats.org/officeDocument/2006/relationships"
private let RELS_HEAD = "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n<Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\">"
private let GRP = "<p:nvGrpSpPr><p:cNvPr id=\"1\" name=\"\"/><p:cNvGrpSpPr/><p:nvPr/></p:nvGrpSpPr><p:grpSpPr><a:xfrm><a:off x=\"0\" y=\"0\"/><a:ext cx=\"0\" cy=\"0\"/><a:chOff x=\"0\" y=\"0\"/><a:chExt cx=\"0\" cy=\"0\"/></a:xfrm></p:grpSpPr>"
private let THEME = """
<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<a:theme xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" name="Shekef"><a:themeElements><a:clrScheme name="Shekef"><a:dk1><a:sysClr val="windowText" lastClr="000000"/></a:dk1><a:lt1><a:sysClr val="window" lastClr="FFFFFF"/></a:lt1><a:dk2><a:srgbClr val="1B2540"/></a:dk2><a:lt2><a:srgbClr val="E7E6E6"/></a:lt2><a:accent1><a:srgbClr val="2F7BF6"/></a:accent1><a:accent2><a:srgbClr val="ED7D31"/></a:accent2><a:accent3><a:srgbClr val="A5A5A5"/></a:accent3><a:accent4><a:srgbClr val="FFC000"/></a:accent4><a:accent5><a:srgbClr val="5B9BD5"/></a:accent5><a:accent6><a:srgbClr val="70AD47"/></a:accent6><a:hlink><a:srgbClr val="0563C1"/></a:hlink><a:folHlink><a:srgbClr val="954F72"/></a:folHlink></a:clrScheme><a:fontScheme name="Shekef"><a:majorFont><a:latin typeface="Arial"/><a:ea typeface=""/><a:cs typeface="Arial"/></a:majorFont><a:minorFont><a:latin typeface="Arial"/><a:ea typeface=""/><a:cs typeface="Arial"/></a:minorFont></a:fontScheme><a:fmtScheme name="Office"><a:fillStyleLst><a:solidFill><a:schemeClr val="phClr"/></a:solidFill><a:solidFill><a:schemeClr val="phClr"/></a:solidFill><a:solidFill><a:schemeClr val="phClr"/></a:solidFill></a:fillStyleLst><a:lnStyleLst><a:ln w="6350"><a:solidFill><a:schemeClr val="phClr"/></a:solidFill></a:ln><a:ln w="12700"><a:solidFill><a:schemeClr val="phClr"/></a:solidFill></a:ln><a:ln w="19050"><a:solidFill><a:schemeClr val="phClr"/></a:solidFill></a:ln></a:lnStyleLst><a:effectStyleLst><a:effectStyle><a:effectLst/></a:effectStyle><a:effectStyle><a:effectLst/></a:effectStyle><a:effectStyle><a:effectLst/></a:effectStyle></a:effectStyleLst><a:bgFillStyleLst><a:solidFill><a:schemeClr val="phClr"/></a:solidFill><a:solidFill><a:schemeClr val="phClr"/></a:solidFill><a:solidFill><a:schemeClr val="phClr"/></a:solidFill></a:bgFillStyleLst></a:fmtScheme></a:themeElements></a:theme>
"""
