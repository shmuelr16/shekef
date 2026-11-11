import AppKit
import PDFKit
import WebKit

enum Importer {
    @MainActor
    static func importAny(_ urls: [URL], ctx: ImportContext, app: AppState) async throws -> Deck {
        let images = urls.filter { IMAGE_EXT.contains($0.pathExtension.lowercased()) }
        if images.count == urls.count { return imageDeck(images, ctx: ctx) }
        let url = urls.first { !IMAGE_EXT.contains($0.pathExtension.lowercased()) }!
        switch url.pathExtension.lowercased() {
        case "pptx", "ppsx", "potx":
            return try await detached { try pptx(url, ctx: ctx) }
        case "odp":
            return try await detached { try ODPImporter(file: url, ctx: ctx).parse() }
        case "pdf":
            return try await detached { try pdf(url, ctx: ctx) }
        case "html", "htm":
            return try await HTMLImporter().run(url, ctx: ctx)
        case "key", "ppt", "pps":
            app.busy = "ממיר את \(url.lastPathComponent) (נפתח לרגע ב-Keynote)…"
            let converted = try await detached { try convertLegacy(url) }
            return try await detached { try pptx(converted, ctx: ctx) }
        default:
            throw ImportError("סוג קובץ לא נתמך: .\(url.pathExtension)")
        }
    }

    static func detached<T>(_ work: @escaping () throws -> T) async throws -> T {
        try await Task.detached(priority: .userInitiated) { try work() }.value
    }

    static func pptx(_ url: URL, ctx: ImportContext) throws -> Deck {
        let dir = try unzip(url)
        defer { try? FileManager.default.removeItem(at: dir) }
        return try PPTXImporter(root: dir, ctx: ctx).parse()
    }

    static func imageDeck(_ urls: [URL], ctx: ImportContext) -> Deck {
        var d = Deck()
        for u in urls {
            guard let name = addImageMedia(u, ctx: ctx) else { continue }
            let size = imagePixelSize(ctx.mediaDir.appendingPathComponent(name)) ?? CGSize(width: 1920, height: 1080)
            let k = min(SLIDE_W / size.width, 1080 / size.height)
            var e = Element(type: "image", x: ((SLIDE_W - size.width * k) / 2).rounded(), y: ((1080 - size.height * k) / 2).rounded(), w: (size.width * k).rounded(), h: (size.height * k).rounded())
            e.src = name; e.fit = "contain"
            var s = Slide(); s.bg = "#000000"; s.elements = [e]
            d.slides.append(s)
        }
        return d
    }

    static func pdf(_ url: URL, ctx: ImportContext) throws -> Deck {
        guard let doc = PDFDocument(url: url), doc.pageCount > 0 else { throw ImportError("קובץ PDF לא תקין") }
        var d = Deck()
        for i in 0..<doc.pageCount {
            guard let page = doc.page(at: i) else { continue }
            let box = page.bounds(for: .cropBox)
            let rotated = page.rotation % 180 != 0
            let pw = rotated ? box.height : box.width, ph = rotated ? box.width : box.height
            if i == 0 { d.height = (SLIDE_W * ph / pw).rounded() }
            let scale = 2400 / pw
            let W = Int(pw * scale), H = Int(ph * scale)
            guard let cg = CGContext(data: nil, width: W, height: H, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { continue }
            cg.setFillColor(.white); cg.fill(CGRect(x: 0, y: 0, width: W, height: H))
            cg.scaleBy(x: scale, y: scale)
            page.draw(with: .cropBox, to: cg)
            guard let img = cg.makeImage(), let data = NSBitmapImageRep(cgImage: img).representation(using: .jpeg, properties: [.compressionFactor: 0.9]) else { continue }
            let name = ctx.add(data, ext: "jpg")
            let hh = SLIDE_W * ph / pw
            var e = Element(type: "image", x: 0, y: ((d.height - hh) / 2).rounded(), w: SLIDE_W, h: hh.rounded())
            e.src = name; e.fit = "fill"; e.name = "עמוד \(i + 1)"
            var s = Slide(); s.elements = [e]
            d.slides.append(s)
        }
        return d
    }

    /// Keynote ו-PowerPoint הישן: המרה ל-pptx דרך Keynote (או PowerPoint אם אין)
    static func convertLegacy(_ url: URL) throws -> URL {
        let out = tempDir().appendingPathComponent("converted.pptx")
        let src = url.path.replacingOccurrences(of: "\"", with: "\\\"")
        let dst = out.path.replacingOccurrences(of: "\"", with: "\\\"")
        let keynote = """
        tell application "Keynote"
          set d to open POSIX file "\(src)"
          delay 1
          export d to POSIX file "\(dst)" as Microsoft PowerPoint
          close d saving no
        end tell
        """
        let ppt = """
        tell application "Microsoft PowerPoint"
          open POSIX file "\(src)"
          delay 1
          save active presentation in (POSIX file "\(dst)") as save as Open XML presentation
          close active presentation saving no
        end tell
        """
        var scripts: [String] = []
        let fm = FileManager.default
        if fm.fileExists(atPath: "/Applications/Keynote.app") { scripts.append(keynote) }
        if url.pathExtension.lowercased() != "key", fm.fileExists(atPath: "/Applications/Microsoft PowerPoint.app") { scripts.append(ppt) }
        var last = ""
        for s in scripts {
            let r = runProcess("/usr/bin/osascript", ["-e", s])
            if fm.fileExists(atPath: out.path) { return out }
            last = r.out
        }
        throw ImportError(scripts.isEmpty ? "לייבוא קובץ .\(url.pathExtension) צריך Keynote או PowerPoint מותקן" : "ההמרה נכשלה. \(last)")
    }
}

// MARK: ODP (LibreOffice Impress)

final class ODPImporter {
    let file: URL, ctx: ImportContext
    var styles: [String: XMLElement] = [:]
    var k = 1.0
    var dir: URL!
    init(file: URL, ctx: ImportContext) { self.file = file; self.ctx = ctx }

    func cm(_ s: String?) -> Double {
        guard let s else { return 0 }
        let v = Double(s.trimmingCharacters(in: CharacterSet(charactersIn: "0123456789.-").inverted)) ?? 0
        if s.hasSuffix("mm") { return v / 10 }
        if s.hasSuffix("in") { return v * 2.54 }
        if s.hasSuffix("pt") { return v * 2.54 / 72 }
        if s.hasSuffix("px") { return v * 2.54 / 96 }
        return v
    }
    func prop(_ styleName: String?, _ group: String, _ attr: String, depth: Int = 0) -> String? {
        guard let n = styleName, let st = styles[n], depth < 8 else { return nil }
        if let v = st.kid(group)?.attr(attr) { return v }
        return prop(st.attr("parent-style-name"), group, attr, depth: depth + 1)
    }

    func parse() throws -> Deck {
        dir = try unzip(file)
        defer { try? FileManager.default.removeItem(at: dir) }
        guard let content = xmlRoot(dir.appendingPathComponent("content.xml")) else { throw ImportError("קובץ ODP לא תקין") }
        let stylesDoc = xmlRoot(dir.appendingPathComponent("styles.xml"))
        for doc in [stylesDoc, content].compactMap({ $0 }) {
            for st in doc.desc("style") { if let n = st.attr("name") { styles[n] = st } }
        }
        var pw = 28.0, ph = 15.75
        if let pl = stylesDoc?.desc("page-layout-properties").first { pw = cm(pl.attr("page-width")); ph = cm(pl.attr("page-height")) }
        if pw <= 0 { pw = 28; ph = 15.75 }
        k = SLIDE_W / pw
        var deck = Deck()
        deck.height = (ph * k).rounded()
        for page in content.desc("page") {
            var s = Slide()
            if let c = prop(page.attr("style-name"), "drawing-page-properties", "fill-color"), prop(page.attr("style-name"), "drawing-page-properties", "fill") != "none" { s.bg = c }
            walk(page, into: &s)
            deck.slides.append(s)
        }
        return deck
    }

    func walk(_ node: XMLElement, into s: inout Slide) {
        for n in node.elems {
            let name = n.localName ?? ""
            if name == "g" { walk(n, into: &s); continue }
            guard ["frame", "custom-shape", "rect", "ellipse", "line", "connector"].contains(name) else { continue }
            var x = cm(n.attr("x")) * k, y = cm(n.attr("y")) * k, w = cm(n.attr("width")) * k, h = cm(n.attr("height")) * k
            if name == "line" || name == "connector" {
                let x1 = cm(n.attr("x1")) * k, y1 = cm(n.attr("y1")) * k, x2 = cm(n.attr("x2")) * k, y2 = cm(n.attr("y2")) * k
                x = min(x1, x2); y = min(y1, y2) - 10; w = max(abs(x2 - x1), 4); h = 20
            }
            let gs = n.attr("style-name")
            var fill: String? = prop(gs, "graphic-properties", "fill") == "none" ? nil : prop(gs, "graphic-properties", "fill-color")
            let stroke: String? = prop(gs, "graphic-properties", "stroke") == "none" ? nil : prop(gs, "graphic-properties", "stroke-color")
            if name == "frame" {
                if let img = n.kid("image"), let href = img.attr("href") {
                    if let m = addImageMedia(dir.appendingPathComponent(href), ctx: ctx) {
                        var e = Element(type: "image", x: x.rounded(), y: y.rounded(), w: w.rounded(), h: h.rounded()); e.src = m; e.fit = "fill"
                        s.elements.append(e)
                    }
                    continue
                }
                guard let tb = n.kid("text-box") else { continue }
                if prop(gs, "graphic-properties", "fill") == nil { fill = nil }
                var e = Element(type: "text", x: x.rounded(), y: y.rounded(), w: w.rounded(), h: max(20, h.rounded()))
                text(tb, into: &e, presClass: n.attr("class"))
                e.fill = fill
                if !(e.html ?? "").isEmpty { s.elements.append(e) }
                continue
            }
            let hasText = !n.desc("p").compactMap { $0.stringValue }.joined().trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            if name == "line" || name == "connector" {
                var e = Element(type: "shape", x: x.rounded(), y: y.rounded(), w: w.rounded(), h: h); e.shape = "line"; e.stroke = stroke ?? "#000000"; e.strokeW = 4
                s.elements.append(e); continue
            }
            let geo = n.kid("enhanced-geometry")?.attr("type") ?? ""
            var sh = Element(type: "shape", x: x.rounded(), y: y.rounded(), w: w.rounded(), h: h.rounded())
            sh.shape = name == "ellipse" || geo == "ellipse" ? "ellipse" : (geo.contains("round") ? "round" : (geo.contains("triangle") ? "triangle" : (geo == "diamond" ? "diamond" : (geo.contains("star") ? "star" : "rect"))))
            sh.fill = fill; sh.stroke = stroke; sh.strokeW = stroke != nil ? 2 : nil
            if fill != nil || stroke != nil { s.elements.append(sh) }
            if hasText {
                var e = Element(type: "text", x: x.rounded(), y: y.rounded(), w: w.rounded(), h: h.rounded())
                text(n, into: &e, presClass: nil); e.valign = "middle"
                if e.align == nil { e.align = "center" }
                s.elements.append(e)
            }
        }
    }

    func text(_ box: XMLElement, into e: inout Element, presClass: String?) {
        var html = ""
        var first: (size: Double, color: String?, font: String?)?
        var firstAlign: String?
        let defPt: Double = presClass == "title" ? 44 : (presClass == "subtitle" ? 32 : (presClass == "outline" ? 28 : 18))
        func runStyle(_ names: [String?], hebrew: Bool) -> (Double, String?, Bool, Bool, String?) {
            func p(_ a: String) -> String? { for n in names { if let v = prop(n, "text-properties", a) { return v } }; return nil }
            let szS = (hebrew ? p("font-size-complex") : nil) ?? p("font-size")
            let pt = szS.map { Double($0.replacingOccurrences(of: "pt", with: "")) ?? defPt } ?? defPt
            let bold = ((hebrew ? p("font-weight-complex") : nil) ?? p("font-weight")) == "bold"
            let italic = ((hebrew ? p("font-style-complex") : nil) ?? p("font-style")) == "italic"
            let font = (hebrew ? p("font-name-complex") : nil) ?? p("font-name") ?? p("font-family")
            return ((pt * k * 2.54 / 72 * 10).rounded() / 10, p("color"), bold, italic, font?.replacingOccurrences(of: "'", with: ""))
        }
        func paragraphs(_ n: XMLElement) -> [XMLElement] {
            var out: [XMLElement] = []
            for c in n.elems {
                if c.localName == "p" || c.localName == "h" { out.append(c) }
                else if ["list", "list-item", "text-box"].contains(c.localName ?? "") { out.append(contentsOf: paragraphs(c)) }
            }
            return out
        }
        for p in paragraphs(box) {
            let ps = p.attr("style-name")
            var al = prop(ps, "paragraph-properties", "text-align")
            let rtl = prop(ps, "paragraph-properties", "writing-mode") == "rl-tb"
            al = ["start": rtl ? "right" : "left", "end": rtl ? "left" : "right", "center": "center", "justify": "justify", "left": "left", "right": "right"][al ?? ""]
            if firstAlign == nil { firstAlign = al }
            var inner = ""
            func emit(_ t: String, _ names: [String?]) {
                guard !t.isEmpty else { return }
                let heb = t.unicodeScalars.contains { $0.value >= 0x590 && $0.value <= 0x6FF }
                let (px, col, b, i, font) = runStyle(names, hebrew: heb)
                if first == nil { first = (px, col, font) }
                var st = ""
                if px != first!.size { st += "font-size:\(px)px;" }
                if let col, col != first!.color { st += "color:\(col);" }
                if b { st += "font-weight:700;" }
                if i { st += "font-style:italic;" }
                inner += st.isEmpty ? escapeHTML(t) : "<span style=\"\(st)\">\(escapeHTML(t))</span>"
            }
            func inline(_ n: XMLNode, _ names: [String?]) {
                for c in n.children ?? [] {
                    if c.kind == .text { emit(c.stringValue ?? "", names) }
                    else if let el = c as? XMLElement {
                        switch el.localName {
                        case "span", "a": inline(el, [el.attr("style-name")] + names)
                        case "line-break": inner += "<br>"
                        case "s": emit(String(repeating: " ", count: Int(el.attr("c") ?? "1") ?? 1), names)
                        case "tab": emit("    ", names)
                        default: inline(el, names)
                        }
                    }
                }
            }
            inline(p, [ps, box.parent.flatMap { ($0 as? XMLElement)?.attr("text-style-name") }])
            let style = al != nil && al != firstAlign ? " style=\"text-align:\(al!)\"" : ""
            html += "<div\(style)>\(inner.isEmpty ? "<br>" : inner)</div>"
        }
        if plainText(fromHTML: html).isEmpty { e.html = ""; return }
        e.html = html
        e.size = first?.size ?? defPt * k * 2.54 / 72
        e.color = first?.color ?? "#000000"
        e.font = first?.font
        let heb = html.unicodeScalars.contains { $0.value >= 0x590 && $0.value <= 0x5FF }
        e.dir = heb ? "rtl" : "ltr"
        e.align = firstAlign ?? (presClass == "title" ? "center" : (heb ? "right" : "left"))
        e.lineHeight = 1.2; e.pad = 10
    }
}

// MARK: HTML

@MainActor
final class HTMLImporter: NSObject, WKNavigationDelegate {
    private var cont: CheckedContinuation<Void, Never>?
    private var window: NSWindow?

    struct Out: Decodable {
        struct F: Decodable { var family: String; var weight: String?; var style: String?; var url: String }
        struct E: Decodable {
            var type: String; var x: Double; var y: Double; var w: Double; var h: Double
            var url: String?; var svg: String?; var fit: String?; var opacity: Double?; var radius: Double?
            var shape: String?; var fill: String?; var stroke: String?; var strokeW: Double?; var shadow: Bool?
            var html: String?; var font: String?; var size: Double?; var color: String?; var align: String?; var dir: String?
            var bold: Bool?; var italic: Bool?; var lineHeight: Double?; var pad: Double?
        }
        struct S: Decodable { var bg: String?; var bgImage: String?; var elements: [E] }
        var ratio: Double; var slides: [S]; var fonts: [F]
    }

    func run(_ url: URL, ctx: ImportContext) async throws -> Deck {
        // קובץ שיוצא מהאפליקציה הזאת: טוענים את הנתונים המקוריים
        if let text = try? String(contentsOf: url, encoding: .utf8), let d = Self.embeddedDeck(text, base: url, ctx: ctx) { return d }
        let frame = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        let web = WKWebView(frame: frame, configuration: WKWebViewConfiguration())
        let win = NSWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
        win.isReleasedWhenClosed = false; win.contentView = web; win.setFrameOrigin(NSPoint(x: -30000, y: -30000))
        window = win
        web.navigationDelegate = self
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            cont = c
            web.loadFileURL(url, allowingReadAccessTo: URL(fileURLWithPath: "/"))
            DispatchQueue.main.asyncAfter(deadline: .now() + 15) { [weak self] in self?.done() }
        }
        try? await Task.sleep(nanoseconds: 700_000_000)
        let js = (try? String(contentsOf: SchemeHandler.webDir.appendingPathComponent("import_html.js"), encoding: .utf8)) ?? ""
        guard let s = try await web.callAsyncJavaScript(js, arguments: [:], contentWorld: .defaultClient) as? String,
              let data = s.data(using: .utf8) else { throw ImportError("לא ניתן לקרוא את דף ה-HTML") }
        let out = try JSONDecoder().decode(Out.self, from: data)
        window = nil
        var deck = Deck()
        deck.height = min(2400, max(600, (SLIDE_W * out.ratio).rounded()))
        var cache: [String: String] = [:]
        func fetch(_ u: String?, image: Bool) async -> String? {
            guard let u, let url = URL(string: u) else { return nil }
            if let c = cache[u] { return c }
            var data: Data?
            var ext = url.pathExtension
            if url.scheme == "data" {
                data = try? Data(contentsOf: url)
                if let r = u.range(of: "data:[a-z]+/([a-z0-9+.-]+)", options: .regularExpression) { ext = String(u[r]).components(separatedBy: "/").last?.replacingOccurrences(of: "+xml", with: "") ?? "png" }
                if ext == "jpeg" { ext = "jpg" }
            } else if url.isFileURL { data = try? Data(contentsOf: url) }
            else { data = try? await URLSession.shared.data(from: url).0 }
            guard let d = data else { return nil }
            let name = ctx.add(d, ext: ext.isEmpty ? (image ? "png" : "bin") : ext)
            cache[u] = name
            return name
        }
        var fonts: [FontFace] = []
        for f in out.fonts {
            if let name = await fetch(f.url, image: false) { fonts.append(FontFace(family: f.family, weight: f.weight, style: f.style, src: name)) }
        }
        deck.fonts = fonts.isEmpty ? nil : fonts
        for s in out.slides {
            var slide = Slide()
            slide.bg = s.bg ?? "#ffffff"
            slide.bgImage = await fetch(s.bgImage, image: true)
            for e in s.elements {
                var el = Element(type: e.type, x: e.x.rounded(), y: e.y.rounded(), w: max(2, e.w.rounded()), h: max(2, e.h.rounded()))
                if let o = e.opacity, o < 0.99 { el.opacity = o }
                switch e.type {
                case "image":
                    if let svg = e.svg, let d = svg.data(using: .utf8) { el.src = ctx.add(d, ext: "svg") }
                    else { el.src = await fetch(e.url, image: true) }
                    guard el.src != nil else { continue }
                    el.fit = e.fit; el.radius = (e.radius ?? 0) > 0 ? e.radius : nil
                case "shape":
                    el.shape = e.shape ?? "rect"; el.fill = e.fill; el.stroke = e.stroke; el.strokeW = e.strokeW
                    el.radius = e.radius; el.shadow = e.shadow == true ? true : nil
                case "text":
                    el.html = e.html; el.font = e.font; el.size = e.size; el.color = e.color; el.align = e.align; el.dir = e.dir
                    el.bold = e.bold == true ? true : nil; el.italic = e.italic == true ? true : nil; el.lineHeight = e.lineHeight; el.pad = 0
                default: continue
                }
                slide.elements.append(el)
            }
            deck.slides.append(slide)
        }
        return deck
    }

    private func done() { cont?.resume(); cont = nil }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { done() }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { done() }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { done() }

    static func embeddedDeck(_ text: String, base: URL, ctx: ImportContext) -> Deck? {
        guard let a = text.range(of: "<script type=\"application/json\" id=\"shekef-deck\">"),
              let b = text.range(of: "</script>", range: a.upperBound..<text.endIndex) else { return nil }
        let json = String(text[a.upperBound..<b.lowerBound]).replacingOccurrences(of: "<\\/", with: "</")
        guard let d = json.data(using: .utf8), var deck = try? JSONDecoder().decode(Deck.self, from: d) else { return nil }
        var mediaMap: [String: String] = [:]
        if let ma = text.range(of: "window.MEDIA="), let mb = text.range(of: ";</script>", range: ma.upperBound..<text.endIndex),
           let md = String(text[ma.upperBound..<mb.lowerBound]).data(using: .utf8), let m = try? JSONDecoder().decode([String: String].self, from: md) {
            mediaMap = m
        }
        func restore(_ name: String?) -> String? {
            guard let name else { return nil }
            let dst = ctx.mediaDir.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: dst.path) { return name }
            try? FileManager.default.createDirectory(at: dst.deletingLastPathComponent(), withIntermediateDirectories: true)
            if let uri = mediaMap[name], let u = URL(string: uri), let data = try? Data(contentsOf: u) { try? data.write(to: dst) }
            else {
                let src = base.deletingLastPathComponent().appendingPathComponent("media").appendingPathComponent(name)
                if name.contains("/") {
                    // תיקיית הטמעה שלמה
                    let top = name.components(separatedBy: "/").prefix(2).joined(separator: "/")
                    let sdir = base.deletingLastPathComponent().appendingPathComponent("media").appendingPathComponent(top)
                    let ddir = ctx.mediaDir.appendingPathComponent(top)
                    if !FileManager.default.fileExists(atPath: ddir.path) {
                        try? FileManager.default.createDirectory(at: ddir.deletingLastPathComponent(), withIntermediateDirectories: true)
                        try? FileManager.default.copyItem(at: sdir, to: ddir)
                    }
                } else { try? FileManager.default.copyItem(at: src, to: dst) }
            }
            return name
        }
        for i in deck.slides.indices {
            deck.slides[i].bgImage = restore(deck.slides[i].bgImage)
            deck.slides[i].audio = restore(deck.slides[i].audio)
            for j in deck.slides[i].elements.indices { deck.slides[i].elements[j].src = restore(deck.slides[i].elements[j].src) }
        }
        for i in (deck.fonts ?? []).indices { _ = restore(deck.fonts![i].src) }
        return deck
    }
}
