import AppKit
import WebKit

final class KeyWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

/// מצב הצגה במסך מלא
@MainActor
final class PlayerController: NSObject {
    private weak var app: AppState?
    private var window: KeyWindow?
    private var web: WKWebView?
    private let proxy = MessageProxy()
    private var deck: Deck?
    private var index = 0
    private var savedOptions: NSApplication.PresentationOptions = []

    init(app: AppState) { self.app = app; super.init() }

    func start(deck: Deck, index: Int) {
        guard let app else { return }
        stop()
        self.deck = deck; self.index = index
        let screen = app.editor.web.window?.screen ?? NSScreen.main!
        let w = KeyWindow(contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        w.isReleasedWhenClosed = false
        w.backgroundColor = .black
        w.level = .normal
        w.collectionBehavior = [.fullScreenAuxiliary, .canJoinAllSpaces]
        let v = makeWebView(WKWebView.self, scheme: app.scheme, proxy: proxy, frame: CGRect(origin: .zero, size: screen.frame.size))
        v.autoresizingMask = [.width, .height]
        w.contentView = v
        proxy.handler = { [weak self] m in self?.handle(m) }
        window = w; web = v
        savedOptions = NSApp.presentationOptions
        NSApp.presentationOptions = [.hideDock, .hideMenuBar]
        w.setFrame(screen.frame, display: true)
        w.makeKeyAndOrderFront(nil)
        w.makeFirstResponder(v)
        NSCursor.setHiddenUntilMouseMoves(true)
        v.load(URLRequest(url: URL(string: "shekef://app/player.html")!))
    }

    func debugJS(_ s: String) { web?.evaluateJavaScript(s, completionHandler: nil) }

    func stop() {
        guard let w = window else { return }
        app?.audio.stopVoice()
        NSApp.presentationOptions = savedOptions
        w.orderOut(nil)
        web?.configuration.userContentController.removeAllScriptMessageHandlers()
        window = nil; web = nil
        if let app, let d = app.deck, d.slides.indices.contains(index) { app.goto(index) }
        app?.editor.web.window?.makeKeyAndOrderFront(nil)
    }

    private func handle(_ m: [String: Any]) {
        guard let app, let deck else { return }
        switch m["type"] as? String {
        case "ready":
            web?.evaluateJavaScript("Player.start(\(jsonString(deck)),\(index))", completionHandler: nil)
        case "slide":
            index = (m["index"] as? NSNumber)?.intValue ?? index
        case "sfx":
            if let n = m["name"] as? String { app.audio.sfx(n) }
        case "stop":
            app.audio.stopVoice()
        case "audio":
            if let src = m["src"] as? String, let dir = app.scheme.mediaDir() { app.audio.playFile(dir.appendingPathComponent(src), key: "slide") }
        case "read":
            guard let id = m["id"] as? String, deck.slides.indices.contains(index) else { return }
            app.performRead(id, in: deck.slides[index]) { [weak self] rid, on in
                self?.web?.evaluateJavaScript("Player.setSpeaking('\(rid)',\(on))", completionHandler: nil)
            }
        case "exit":
            stop()
        default: break
        }
    }
}
