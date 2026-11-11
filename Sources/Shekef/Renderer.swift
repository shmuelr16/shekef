import AppKit
import WebKit
import PDFKit

struct TextRun: Decodable { var t: String?; var br: Bool?; var b: Bool?; var i: Bool?; var u: Bool?; var color: String?; var size: Double?; var font: String? }
struct TextPara: Decodable { var align: String?; var runs: [TextRun] }
struct TextLayout: Decodable { var paras: [TextPara]; var lineHeight: Double? }

/// WKWebView נסתר שמצייר שקפים: תמונות ממוזערות, PDF, תמונות לייצוא, וחילוץ טקסט.
@MainActor
final class Renderer: NSObject, WKNavigationDelegate {
    private let web: WKWebView
    private let window: NSWindow
    private let proxy = MessageProxy()
    private var ready = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var tail: Task<Void, Never>?
    private let scheme: SchemeHandler

    init(scheme: SchemeHandler) {
        self.scheme = scheme
        let frame = CGRect(x: 0, y: 0, width: SLIDE_W, height: 1080)
        web = makeWebView(WKWebView.self, scheme: scheme, proxy: proxy, frame: frame)
        window = NSWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = web
        window.setFrameOrigin(NSPoint(x: -30000, y: -30000))
        super.init()
        proxy.handler = { [weak self] m in
            guard let self, m["type"] as? String == "ready" else { return }
            self.ready = true; self.waiters.forEach { $0.resume() }; self.waiters = []
        }
        web.load(URLRequest(url: URL(string: "shekef://app/render.html")!))
    }

    private func waitReady() async {
        if ready { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    /// מריץ פעולות אחת אחרי השנייה
    private func serial<T>(_ op: @escaping @MainActor () async -> T) async -> T {
        let prev = tail
        let t = Task { @MainActor () -> T in
            await prev?.value
            await self.waitReady()
            return await op()
        }
        tail = Task { _ = await t.value }
        return await t.value
    }

    private func show(_ slide: Slide, _ deck: Deck) async {
        let h = deck.height
        if web.frame.height != h {
            window.setContentSize(NSSize(width: SLIDE_W, height: h)); web.frame = CGRect(x: 0, y: 0, width: SLIDE_W, height: h)
        }
        var meta = deck; meta.slides = []
        _ = try? await web.callAsyncJavaScript("return await Render.show(JSON.parse(s), JSON.parse(m))",
                                               arguments: ["s": jsonString(slide), "m": jsonString(meta)], contentWorld: .page)
    }

    func snapshot(_ slide: Slide, deck: Deck, width: CGFloat? = nil, rect: CGRect? = nil) async -> NSImage? {
        await serial {
            await self.show(slide, deck)
            let cfg = WKSnapshotConfiguration()
            cfg.rect = rect ?? CGRect(x: 0, y: 0, width: SLIDE_W, height: deck.height)
            if let width { cfg.snapshotWidth = NSNumber(value: Double(width)) }
            cfg.afterScreenUpdates = true
            return try? await self.web.takeSnapshot(configuration: cfg)
        }
    }

    func pdfPage(_ slide: Slide, deck: Deck) async -> Data? {
        await serial {
            await self.show(slide, deck)
            let cfg = WKPDFConfiguration()
            cfg.rect = CGRect(x: 0, y: 0, width: SLIDE_W, height: deck.height)
            return try? await self.web.pdf(configuration: cfg)
        }
    }

    func textLayouts(_ slide: Slide, deck: Deck) async -> [String: TextLayout] {
        await serial {
            await self.show(slide, deck)
            guard let s = try? await self.web.callAsyncJavaScript("return JSON.stringify(Render.runs())", arguments: [:], contentWorld: .page) as? String,
                  let d = s.data(using: .utf8), let r = try? JSONDecoder().decode([String: TextLayout].self, from: d) else { return [:] }
            return r
        }
    }
}

func pngData(_ image: NSImage) -> Data? {
    guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
    return NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:])
}

func imagePixelSize(_ url: URL) -> CGSize? {
    if url.pathExtension.lowercased() == "svg" {
        guard let s = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        func num(_ attr: String) -> Double? {
            guard let r = s.range(of: "\\s\(attr)=\"([0-9.]+)", options: .regularExpression) else { return nil }
            return Double(s[r].components(separatedBy: "\"").last ?? "")
        }
        if let w = num("width"), let h = num("height") { return CGSize(width: w, height: h) }
        if let r = s.range(of: "viewBox=\"[^\"]+\"", options: .regularExpression) {
            let n = s[r].components(separatedBy: CharacterSet(charactersIn: "0123456789.-").inverted).compactMap { Double($0) }
            if n.count == 4 { return CGSize(width: n[2], height: n[3]) }
        }
        return nil
    }
    guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
          let p = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
          let w = p[kCGImagePropertyPixelWidth] as? Double, let h = p[kCGImagePropertyPixelHeight] as? Double else { return nil }
    if let o = p[kCGImagePropertyOrientation] as? Int, o >= 5 { return CGSize(width: h, height: w) }
    return CGSize(width: w, height: h)
}
