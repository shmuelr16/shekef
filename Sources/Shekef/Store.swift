import AppKit
import SwiftUI
import UniformTypeIdentifiers

final class ImportContext {
    let mediaDir: URL
    private var n = 0
    init(packageURL: URL) {
        mediaDir = packageURL.appendingPathComponent("media")
        try? FileManager.default.createDirectory(at: mediaDir, withIntermediateDirectories: true)
    }
    func add(_ data: Data, ext: String) -> String {
        n += 1
        let name = "m\(n)_\(newID().prefix(6)).\(ext.isEmpty ? "bin" : ext.lowercased())"
        try? data.write(to: mediaDir.appendingPathComponent(name))
        return name
    }
    func add(file: URL) -> String? {
        guard let d = try? Data(contentsOf: file) else { return nil }
        return add(d, ext: file.pathExtension)
    }
}

@MainActor
final class AppState: ObservableObject {
    static let shared = AppState()

    @Published var deck: Deck?
    @Published var packageURL: URL?
    @Published var current = 0
    @Published var selection: Set<String> = []
    @Published var editingText: String?
    @Published var thumbs: [String: NSImage] = [:]
    @Published var busy: String?
    @Published var errorMessage: String?
    @Published var recents: [String] = UserDefaults.standard.stringArray(forKey: "recents") ?? []
    @Published var undoStack: [Deck] = []
    @Published var redoStack: [Deck] = []
    @Published var speakingID: String?
    @Published var savedFlash = false

    let scheme = SchemeHandler()
    let audio = AudioEngine()
    lazy var editor: EditorController = {
        let e = EditorController(scheme: scheme)
        e.onMessage = { [weak self] m in self?.handleEditor(m) }
        e.web.onDropFiles = { [weak self] urls in self?.openFiles(urls) }
        return e
    }()
    lazy var renderer = Renderer(scheme: scheme)
    lazy var player = PlayerController(app: self)

    private var lastKey: String?
    private var lastTime = Date.distantPast
    private var saveTask: Task<Void, Never>?
    private var thumbTask: Task<Void, Never>?
    private var thumbHash: [String: Int] = [:]
    private var media: ImportContext?
    static let pasteType = NSPasteboard.PasteboardType("il.shmuel.shekef.elements")

    init() { scheme.mediaDir = { [weak self] in self?.packageURL?.appendingPathComponent("media") } }

    var slide: Slide? { guard let d = deck, d.slides.indices.contains(current) else { return nil }; return d.slides[current] }
    var selectedElements: [Element] { slide?.elements.filter { selection.contains($0.id) } ?? [] }
    var title: String { packageURL?.deletingPathExtension().lastPathComponent ?? "שקף" }
    var deckHeight: Double { deck?.height ?? 1080 }

    // MARK: שינוי + ביטול

    func mutate(_ key: String? = nil, _ body: (inout Deck) -> Void) {
        guard var d = deck else { return }
        let before = d
        body(&d)
        if d == before { return }
        let now = Date()
        if !(key != nil && key == lastKey && now.timeIntervalSince(lastTime) < 1.5) {
            undoStack.append(before)
            if undoStack.count > 150 { undoStack.removeFirst() }
        }
        lastKey = key; lastTime = now; redoStack = []
        deck = d
        afterChange()
    }
    func mutateSlide(_ key: String? = nil, _ body: (inout Slide) -> Void) {
        let i = current
        mutate(key) { d in if d.slides.indices.contains(i) { body(&d.slides[i]) } }
    }
    func mutateSelected(_ key: String? = nil, _ body: (inout Element) -> Void) {
        let ids = selection
        mutateSlide(key) { s in for i in s.elements.indices where ids.contains(s.elements[i].id) { body(&s.elements[i]) } }
    }
    func afterChange() {
        if let d = deck { current = max(0, min(current, d.slides.count - 1)) }
        sync(); scheduleSave(); scheduleThumbs()
    }
    func undo() {
        if editingText != nil { editor.js("document.execCommand('undo')"); return }
        guard let prev = undoStack.popLast(), let d = deck else { return }
        redoStack.append(d); deck = prev; lastKey = nil; afterChange()
    }
    func redo() {
        if editingText != nil { editor.js("document.execCommand('redo')"); return }
        guard let next = redoStack.popLast(), let d = deck else { return }
        undoStack.append(d); deck = next; lastKey = nil; afterChange()
    }

    func sync() {
        guard let d = deck, let s = slide else { return }
        var meta = d; meta.slides = []
        selection = selection.filter { id in s.elements.contains { $0.id == id } }
        editor.js("Editor.load(\(jsonString(s)),\(jsonString(meta)),\(jsonString(Array(selection))))")
    }

    // MARK: קבצים

    static var docsDir: URL {
        let u = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("שקף")
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }
    static func uniquePackage(named name: String) -> URL {
        let dir = docsDir
        let clean = name.replacingOccurrences(of: "/", with: "-")
        var u = dir.appendingPathComponent(clean).appendingPathExtension(PKG_EXT)
        var i = 2
        while FileManager.default.fileExists(atPath: u.path) {
            u = dir.appendingPathComponent("\(clean) \(i)").appendingPathExtension(PKG_EXT); i += 1
        }
        return u
    }
    static func writePackage(_ deck: Deck, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.appendingPathComponent("media"), withIntermediateDirectories: true)
        let e = JSONEncoder(); e.outputFormatting = [.withoutEscapingSlashes]
        try e.encode(deck).write(to: url.appendingPathComponent("deck.json"), options: .atomic)
    }

    func newDeck() {
        saveNow()
        let url = Self.uniquePackage(named: "מצגת חדשה")
        var d = Deck()
        var s = Slide()
        var t = Element(type: "text", x: 260, y: 360, w: 1400, h: 170)
        t.html = "כותרת המצגת"; t.size = 110; t.bold = true; t.align = "center"
        var sub = Element(type: "text", x: 360, y: 560, w: 1200, h: 100)
        sub.html = "לחיצה כפולה לעריכה"; sub.size = 52; sub.align = "center"; sub.color = "#5b6478"
        s.elements = [t, sub]
        d.slides = [s]
        do { try Self.writePackage(d, to: url); loadPackage(url) } catch { errorMessage = error.localizedDescription }
    }

    func loadPackage(_ url: URL) {
        saveNow()
        guard let data = try? Data(contentsOf: url.appendingPathComponent("deck.json")),
              let d = try? JSONDecoder().decode(Deck.self, from: data) else {
            errorMessage = "לא ניתן לפתוח את הקובץ \(url.lastPathComponent)"; return
        }
        audio.stopVoice()
        packageURL = url
        media = ImportContext(packageURL: url)
        deck = d.slides.isEmpty ? { var x = d; x.slides = [Slide()]; return x }() : d
        current = 0; selection = []; editingText = nil
        undoStack = []; redoStack = []; thumbs = [:]; thumbHash = [:]
        recents.removeAll { $0 == url.path }
        recents.insert(url.path, at: 0)
        recents = Array(recents.prefix(12))
        UserDefaults.standard.set(recents, forKey: "recents")
        sync(); scheduleThumbs()
    }

    func closeDeck() { saveNow(); audio.stopVoice(); deck = nil; packageURL = nil }

    func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 700_000_000)
            if Task.isCancelled { return }
            self?.saveNow()
        }
    }
    func saveNow() {
        saveTask?.cancel()
        guard let d = deck, let u = packageURL else { return }
        try? Self.writePackage(d, to: u)
    }
    /// כפתור "שמור": שומר מיד ומראה אישור קצר
    func saveClicked() {
        editor.js("Editor.stopEdit()")
        Task {
            try? await Task.sleep(nanoseconds: 120_000_000)
            saveNow()
            savedFlash = true
            try? await Task.sleep(nanoseconds: 1_600_000_000)
            savedFlash = false
        }
    }
    func goHome() {
        editor.js("Editor.stopEdit()")
        Task { try? await Task.sleep(nanoseconds: 120_000_000); closeDeck() }
    }
    func removeRecent(_ path: String) {
        recents.removeAll { $0 == path }
        UserDefaults.standard.set(recents, forKey: "recents")
    }
    func saveAs() {
        guard deck != nil, let src = packageURL else { return }
        let p = NSSavePanel()
        p.allowedContentTypes = [UTType(filenameExtension: PKG_EXT) ?? .data]
        p.nameFieldStringValue = title
        p.prompt = "שמור"
        guard p.runModal() == .OK, var dst = p.url else { return }
        if dst.pathExtension != PKG_EXT { dst.appendPathExtension(PKG_EXT) }
        saveNow()
        do {
            if FileManager.default.fileExists(atPath: dst.path) { try FileManager.default.removeItem(at: dst) }
            try FileManager.default.copyItem(at: src, to: dst)
            loadPackage(dst)
        } catch { errorMessage = error.localizedDescription }
    }

    func openPanel() {
        let p = NSOpenPanel()
        p.allowsMultipleSelection = true
        p.canChooseDirectories = false
        p.treatsFilePackagesAsDirectories = false
        p.prompt = "פתח"
        p.message = "מצגת שקף, PowerPoint, Keynote, ODP, PDF, HTML או תמונות"
        guard p.runModal() == .OK else { return }
        openFiles(p.urls, forceNewDeck: true)
    }

    func openFiles(_ urls: [URL], forceNewDeck: Bool = false) {
        guard !urls.isEmpty else { return }
        if let pkg = urls.first(where: { $0.pathExtension.lowercased() == PKG_EXT }) { loadPackage(pkg); return }
        let exts = urls.map { $0.pathExtension.lowercased() }
        let allMedia = exts.allSatisfy { IMAGE_EXT.contains($0) || AUDIO_EXT.contains($0) }
        if deck != nil && allMedia && !forceNewDeck {
            for u in urls {
                if AUDIO_EXT.contains(u.pathExtension.lowercased()) { attachAudio(u) } else { addImage(u) }
            }
            return
        }
        Task { await importFiles(urls) }
    }

    func importFiles(_ urls: [URL]) async {
        saveNow()
        let first = urls[0]
        busy = "מייבא את \(first.lastPathComponent)…"
        defer { busy = nil }
        let pkg = Self.uniquePackage(named: first.deletingPathExtension().lastPathComponent)
        let ctx = ImportContext(packageURL: pkg)
        do {
            let d = try await Importer.importAny(urls, ctx: ctx, app: self)
            guard !d.slides.isEmpty else { throw ImportError("לא נמצאו שקפים בקובץ") }
            try Self.writePackage(d, to: pkg)
            loadPackage(pkg)
        } catch {
            try? FileManager.default.removeItem(at: pkg)
            errorMessage = "הייבוא נכשל: \((error as? ImportError)?.message ?? error.localizedDescription)"
        }
    }

    // MARK: תמונות ממוזערות

    func scheduleThumbs() {
        thumbTask?.cancel()
        thumbTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 350_000_000)
            if Task.isCancelled { return }
            await self?.refreshThumbs()
        }
    }
    private func refreshThumbs() async {
        guard let d = deck else { return }
        let extra = jsonString(d.fonts ?? []) + "\(d.height)" + (packageURL?.path ?? "")
        // השקף הנוכחי קודם
        var order = Array(d.slides.indices)
        if order.contains(current) { order.removeAll { $0 == current }; order.insert(current, at: 0) }
        for i in order {
            if Task.isCancelled { return }
            let s = d.slides[i]
            let h = (jsonString(s) + extra).hashValue
            if thumbHash[s.id] == h { continue }
            if let img = await renderer.snapshot(s, deck: d, width: 300) {
                if Task.isCancelled { return }
                thumbs[s.id] = img; thumbHash[s.id] = h
                if i == 0, let u = packageURL, let png = pngData(img) { try? png.write(to: u.appendingPathComponent("thumb.png")) }
            }
        }
    }

    // MARK: שקפים

    func goto(_ i: Int) {
        guard let d = deck, d.slides.indices.contains(i), i != current else { return }
        audio.stopVoice()
        current = i; selection = []; sync(); scheduleThumbs()
    }
    func addSlide() {
        guard deck != nil else { return }
        var s = Slide()
        s.bg = slide?.bg ?? "#ffffff"
        s.transition = slide?.transition ?? "fade"
        var t = Element(type: "text", x: 160, y: 90, w: 1600, h: 130)
        t.html = "כותרת"; t.size = 84; t.bold = true
        if let c = slide?.elements.first(where: { $0.type == "text" }) { t.color = c.color; t.font = c.font }
        s.elements = [t]
        let at = current + 1
        mutate { $0.slides.insert(s, at: min(at, $0.slides.count)) }
        current = min(at, (deck?.slides.count ?? 1) - 1); selection = []; sync()
    }
    func duplicateSlide() {
        guard var s = slide else { return }
        s.id = newID()
        var map: [String: String] = [:]
        for i in s.elements.indices { let n = newID(); map[s.elements[i].id] = n; s.elements[i].id = n }
        for i in s.elements.indices { if let t = s.elements[i].target, let n = map[t] { s.elements[i].target = n } }
        let at = current + 1
        mutate { $0.slides.insert(s, at: at) }
        current = at; selection = []; sync()
    }
    func deleteSlide() {
        guard let d = deck, d.slides.count > 1 else { return }
        let i = current
        mutate { $0.slides.remove(at: i) }
        selection = []; sync()
    }
    func moveSlides(from: IndexSet, to: Int) {
        guard let cur = slide?.id else { return }
        mutate { $0.slides.move(fromOffsets: from, toOffset: to) }
        if let i = deck?.slides.firstIndex(where: { $0.id == cur }) { current = i }
        sync()
    }
    func moveSlide(by delta: Int) {
        guard let d = deck else { return }
        let j = current + delta
        guard d.slides.indices.contains(j) else { return }
        let i = current
        mutate { $0.slides.swapAt(i, j) }
        current = j; sync()
    }

    // MARK: אלמנטים

    func insert(_ els: [Element]) {
        guard !els.isEmpty else { return }
        mutateSlide { $0.elements.append(contentsOf: els) }
        selection = Set(els.map { $0.id }); sync()
        editor.web.window?.makeFirstResponder(editor.web)
    }
    func addText() {
        var e = Element(type: "text", x: 460, y: deckHeight / 2 - 70, w: 1000, h: 140)
        e.html = "טקסט חדש"; e.size = 64; e.align = "center"
        if let c = slide?.elements.last(where: { $0.type == "text" }) { e.color = c.color; e.font = c.font }
        insert([e])
    }
    func addShape(_ kind: String) {
        var e = Element(type: "shape", x: 760, y: deckHeight / 2 - 200, w: 400, h: kind == "line" ? 30 : 400)
        e.shape = kind
        if kind == "line" { e.stroke = "#1b2540"; e.strokeW = 6 } else { e.fill = "#2f7bf6" }
        if kind == "rect" || kind == "round" || kind == "arrow" { e.h = 260 }
        insert([e])
    }
    func chooseImage() {
        let p = NSOpenPanel()
        p.allowedContentTypes = [.image]; p.allowsMultipleSelection = true; p.prompt = "הוסף"
        guard p.runModal() == .OK else { return }
        p.urls.forEach { addImage($0) }
    }
    func addImage(_ url: URL) {
        guard let m = media, let name = m.add(file: url) else { return }
        insert([imageElement(name)])
    }
    func imageElement(_ name: String) -> Element {
        let size = media.flatMap { imagePixelSize($0.mediaDir.appendingPathComponent(name)) } ?? CGSize(width: 800, height: 600)
        let k = min(1, min(SLIDE_W * 0.7 / size.width, deckHeight * 0.7 / size.height))
        let w = (size.width * k).rounded(), h = (size.height * k).rounded()
        var e = Element(type: "image", x: ((SLIDE_W - w) / 2).rounded(), y: ((deckHeight - h) / 2).rounded(), w: w, h: h)
        e.src = name; e.fit = "contain"
        return e
    }
    func chooseAudio() -> String? {
        let p = NSOpenPanel()
        p.allowedContentTypes = [.audio]; p.prompt = "צרף"
        guard p.runModal() == .OK, let u = p.url else { return nil }
        return media?.add(file: u)
    }
    func attachAudio(_ url: URL) {
        guard let name = media?.add(file: url) else { return }
        mutateSlide { $0.audio = name; $0.audioAuto = true }
    }
    func chooseBackgroundImage() {
        let p = NSOpenPanel()
        p.allowedContentTypes = [.image]; p.prompt = "בחר"
        guard p.runModal() == .OK, let u = p.url, let name = media?.add(file: u) else { return }
        mutateSlide { $0.bgImage = name }
    }
    func deleteSelection() {
        let ids = selection
        guard !ids.isEmpty else { return }
        mutateSlide { s in s.elements.removeAll { ids.contains($0.id) || ($0.type == "read" && $0.target != nil && ids.contains($0.target!)) } }
        selection = []; sync()
    }
    func cloned(_ els: [Element], offset: Double) -> [Element] {
        var map: [String: String] = [:]
        var out = els.map { e -> Element in var c = e; c.id = newID(); map[e.id] = c.id; c.x += offset; c.y += offset; return c }
        for i in out.indices { if let t = out[i].target, let n = map[t] { out[i].target = n } }
        return out
    }
    func duplicateSelection() { insert(cloned(selectedElements, offset: 30)) }
    func copySelection() {
        let els = selectedElements
        guard !els.isEmpty else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(jsonString(els), forType: Self.pasteType)
        let txt = els.filter { $0.type == "text" }.map { plainText(fromHTML: $0.html) }.joined(separator: "\n")
        if !txt.isEmpty { pb.setString(txt, forType: .string) }
    }
    func paste() {
        let pb = NSPasteboard.general
        if let s = pb.string(forType: Self.pasteType), let d = s.data(using: .utf8), let els = try? JSONDecoder().decode([Element].self, from: d) {
            insert(cloned(els, offset: 30)); return
        }
        if let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty {
            openFiles(urls); return
        }
        if let img = NSImage(pasteboard: pb), let png = pngData(img), let m = media {
            insert([imageElement(m.add(png, ext: "png"))]); return
        }
        if let s = pb.string(forType: .string), !s.isEmpty {
            var e = Element(type: "text", x: 360, y: deckHeight / 2 - 100, w: 1200, h: 200)
            e.html = escapeHTML(s).replacingOccurrences(of: "\n", with: "<br>"); e.size = 48
            insert([e])
        }
    }
    func arrange(_ how: String) {
        let ids = selection
        mutateSlide { s in
            let picked = s.elements.filter { ids.contains($0.id) }
            switch how {
            case "front": s.elements.removeAll { ids.contains($0.id) }; s.elements.append(contentsOf: picked)
            case "back": s.elements.removeAll { ids.contains($0.id) }; s.elements.insert(contentsOf: picked, at: 0)
            case "forward":
                for i in s.elements.indices.reversed() where ids.contains(s.elements[i].id) && i + 1 < s.elements.count && !ids.contains(s.elements[i + 1].id) { s.elements.swapAt(i, i + 1) }
            default:
                for i in s.elements.indices where ids.contains(s.elements[i].id) && i > 0 && !ids.contains(s.elements[i - 1].id) { s.elements.swapAt(i, i - 1) }
            }
        }
    }
    func alignSelection(_ how: String) {
        let H = deckHeight
        mutateSelected { e in
            switch how {
            case "left": e.x = 0
            case "hcenter": e.x = ((SLIDE_W - e.w) / 2).rounded()
            case "right": e.x = SLIDE_W - e.w
            case "top": e.y = 0
            case "vcenter": e.y = ((H - e.h) / 2).rounded()
            default: e.y = H - e.h
            }
        }
    }
    func textCommand(_ cmd: String) {
        if editingText != nil { editor.js("Editor.exec('\(cmd)')"); return }
        mutateSelected { e in
            guard e.type == "text" else { return }
            if cmd == "bold" { e.bold = !(e.bold ?? false) }
            if cmd == "italic" { e.italic = !(e.italic ?? false) }
            if cmd == "underline" {
                let h = e.html ?? ""
                e.html = h.hasPrefix("<u>") && h.hasSuffix("</u>") ? String(h.dropFirst(3).dropLast(4)) : "<u>\(h)</u>"
            }
        }
    }

    // MARK: הקראה

    func readButton(for textID: String) -> Element? { slide?.elements.first { $0.type == "read" && $0.target == textID } }
    func toggleReadButton(for textID: String) {
        guard let t = slide?.elements.first(where: { $0.id == textID }) else { return }
        if let r = readButton(for: textID) {
            mutateSlide { $0.elements.removeAll { $0.id == r.id } }
        } else {
            var r = Element(type: "read", x: max(0, t.x + t.w - 230), y: min(deckHeight - 70, t.y + t.h + 8), w: 230, h: 64)
            r.target = textID; r.label = "הקראה"
            mutateSlide { $0.elements.append(r) }
        }
    }
    /// מפעיל כפתור הקראה: קובץ שמע אם צורף, אחרת הקול העברי של המק.
    func performRead(_ id: String, in s: Slide?, notify: @escaping (String, Bool) -> Void) {
        guard let s, let r = s.elements.first(where: { $0.id == id }) else { return }
        if audio.currentKey == id { audio.stopVoice(); return }
        let done: () -> Void = { [weak self] in notify(id, false); if self?.speakingID == id { self?.speakingID = nil } }
        var started = false
        if let src = r.src, let dir = scheme.mediaDir() {
            started = audio.playFile(dir.appendingPathComponent(src), key: id, onEnd: done)
        }
        if !started {
            let target = s.elements.first { $0.id == r.target }
            let text = plainText(fromHTML: target?.html)
            guard !text.isEmpty else { return }
            audio.speak(text, key: id, onEnd: done)
        }
        speakingID = id
        notify(id, true)
    }
    func previewRead(_ id: String) {
        performRead(id, in: slide) { [weak self] rid, on in self?.editor.js("Editor.setSpeaking('\(rid)',\(on))") }
    }
    func previewSlideAudio() {
        guard let a = slide?.audio, let dir = scheme.mediaDir() else { return }
        if audio.currentKey == "slide" { audio.stopVoice(); return }
        audio.playFile(dir.appendingPathComponent(a), key: "slide")
    }

    // MARK: הודעות מהעורך

    func handleEditor(_ m: [String: Any]) {
        switch m["type"] as? String {
        case "select":
            selection = Set((m["ids"] as? [String]) ?? [])
        case "editing":
            editingText = m["id"] as? String
        case "geom":
            guard let items = m["items"] as? [[String: Any]] else { return }
            mutateSlide(m["nudge"] != nil ? "nudge" : nil) { s in
                for it in items {
                    guard let id = it["id"] as? String, let i = s.elements.firstIndex(where: { $0.id == id }) else { continue }
                    func n(_ k: String) -> Double? { (it[k] as? NSNumber)?.doubleValue }
                    if let v = n("x") { s.elements[i].x = v }
                    if let v = n("y") { s.elements[i].y = v }
                    if let v = n("w") { s.elements[i].w = v }
                    if let v = n("h") { s.elements[i].h = v }
                    if let v = n("rot") { s.elements[i].rot = v == 0 ? nil : v }
                }
            }
        case "text":
            guard let id = m["id"] as? String, let html = m["html"] as? String else { return }
            let h = (m["h"] as? NSNumber)?.doubleValue
            mutate("text-\(id)") { d in
                for si in d.slides.indices {
                    if let i = d.slides[si].elements.firstIndex(where: { $0.id == id }) {
                        d.slides[si].elements[i].html = html
                        if let h { d.slides[si].elements[i].h = h }
                    }
                }
            }
        case "cmd":
            switch m["cmd"] as? String {
            case "delete": deleteSelection()
            case "duplicate": duplicateSelection()
            case "copy": copySelection()
            case "cut": copySelection(); deleteSelection()
            case "paste": paste()
            default: break
            }
        case "read":
            if let id = m["id"] as? String { previewRead(id) }
        default: break
        }
    }

    func present(fromStart: Bool) {
        guard let d = deck else { return }
        editor.js("Editor.stopEdit()")
        audio.stopVoice()
        saveNow()
        player.start(deck: d, index: fromStart ? 0 : current)
    }
}
