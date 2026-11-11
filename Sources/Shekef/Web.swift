import AppKit
import WebKit
import UniformTypeIdentifiers

/// מגיש קבצים ל-WKWebView: shekef://app/<קובץ מהחבילה>  ו- shekef://media/<קובץ מדיה של המצגת>
final class SchemeHandler: NSObject, WKURLSchemeHandler {
    var mediaDir: () -> URL? = { nil }
    static let webDir: URL = Bundle.main.resourceURL!.appendingPathComponent("web")

    func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
        guard let url = task.request.url else { return }
        let rel = url.path.removingPercentEncoding ?? url.path
        var file: URL?
        if url.host == "app" { file = Self.webDir.appendingPathComponent(rel) }
        else if url.host == "media", let m = mediaDir() { file = m.appendingPathComponent(rel) }
        guard let f = file, let data = try? Data(contentsOf: f) else {
            task.didFailWithError(NSError(domain: NSURLErrorDomain, code: NSURLErrorFileDoesNotExist)); return
        }
        let mime = UTType(filenameExtension: f.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
        let resp = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1",
                                   headerFields: ["Content-Type": mime + (mime.hasPrefix("text/") || mime.contains("javascript") ? "; charset=utf-8" : ""),
                                                  "Content-Length": "\(data.count)", "Access-Control-Allow-Origin": "*", "Cache-Control": "no-cache"])!
        task.didReceive(resp); task.didReceive(data); task.didFinish()
    }
    func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) {}
}

final class MessageProxy: NSObject, WKScriptMessageHandler {
    var handler: (([String: Any]) -> Void)?
    func userContentController(_ c: WKUserContentController, didReceive message: WKScriptMessage) {
        if let d = message.body as? [String: Any] { handler?(d) }
    }
}

final class DropWebView: WKWebView {
    var onDropFiles: (([URL]) -> Void)?
    private func files(_ s: NSDraggingInfo) -> [URL]? {
        let urls = s.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]
        return (urls?.isEmpty ?? true) ? nil : urls
    }
    override func draggingEntered(_ s: NSDraggingInfo) -> NSDragOperation { files(s) != nil ? .copy : super.draggingEntered(s) }
    override func draggingUpdated(_ s: NSDraggingInfo) -> NSDragOperation { files(s) != nil ? .copy : super.draggingUpdated(s) }
    override func prepareForDragOperation(_ s: NSDraggingInfo) -> Bool { files(s) != nil ? true : super.prepareForDragOperation(s) }
    override func performDragOperation(_ s: NSDraggingInfo) -> Bool {
        if let u = files(s) { onDropFiles?(u); return true }
        return super.performDragOperation(s)
    }
}

func makeWebView<T: WKWebView>(_ type: T.Type, scheme: SchemeHandler, proxy: MessageProxy, frame: CGRect = .zero) -> T {
    let cfg = WKWebViewConfiguration()
    cfg.setURLSchemeHandler(scheme, forURLScheme: "shekef")
    cfg.userContentController.add(proxy, name: "shekef")
    cfg.mediaTypesRequiringUserActionForPlayback = []
    cfg.preferences.setValue(true, forKey: "developerExtrasEnabled")
    let w = T(frame: frame, configuration: cfg)
    w.setValue(false, forKey: "drawsBackground")
    return w
}

/// תצוגת העריכה
final class EditorController: NSObject {
    let web: DropWebView
    let proxy = MessageProxy()
    private var ready = false
    private var queue: [String] = []
    var onMessage: (([String: Any]) -> Void)?

    init(scheme: SchemeHandler) {
        web = makeWebView(DropWebView.self, scheme: scheme, proxy: proxy)
        super.init()
        proxy.handler = { [weak self] m in
            guard let self else { return }
            if m["type"] as? String == "ready" { self.ready = true; self.queue.forEach { self.web.evaluateJavaScript($0, completionHandler: nil) }; self.queue = [] }
            else { self.onMessage?(m) }
        }
        web.load(URLRequest(url: URL(string: "shekef://app/editor.html")!))
    }
    func js(_ s: String) {
        if ready { web.evaluateJavaScript(s, completionHandler: nil) } else { queue.append(s) }
    }
}
