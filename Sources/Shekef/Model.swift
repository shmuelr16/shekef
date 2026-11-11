import AppKit
import SwiftUI

struct FontFace: Codable, Equatable {
    var family: String
    var weight: String?
    var style: String?
    var src: String
}

struct Loop: Codable, Equatable {
    var k: String          // move | scale | spin
    var dx: Double?
    var dy: Double?
    var by: Double?
    var deg: Double?
    var dur: Double
    var delay: Double?
    var once: Bool?
}

struct Element: Codable, Equatable, Identifiable {
    var id: String
    var type: String            // text | image | shape | embed | read
    var x: Double
    var y: Double
    var w: Double
    var h: Double
    var rot: Double?
    var opacity: Double?
    var name: String?
    var morph: String?
    // טקסט
    var html: String?
    var font: String?
    var size: Double?
    var color: String?
    var align: String?
    var valign: String?
    var bold: Bool?
    var italic: Bool?
    var lineHeight: Double?
    var pad: Double?
    var dir: String?
    // תיבה
    var fill: String?
    var stroke: String?
    var strokeW: Double?
    var radius: Double?
    var shadow: Bool?
    var shape: String?
    var src: String?
    var fit: String?
    var params: String?
    // אנימציה
    var anim: String?
    var animWith: Bool?
    var aSound: String?
    var step: Int?
    var delay: Double?
    var dur: Double?
    var loops: [Loop]?
    // הקראה
    var target: String?
    var label: String?

    init(type: String, x: Double, y: Double, w: Double, h: Double) {
        self.id = newID(); self.type = type; self.x = x; self.y = y; self.w = w; self.h = h
        self.morph = self.id
    }
}

struct Slide: Codable, Equatable, Identifiable {
    var id: String = newID()
    var bg: String? = "#ffffff"
    var bgImage: String?
    var elements: [Element] = []
    var transition: String? = "fade"
    var tSound: String?
    var audio: String?
    var audioAuto: Bool?
    var notes: String?
}

struct Deck: Codable, Equatable {
    var version: Int = 1
    var height: Double = 1080
    var fonts: [FontFace]?
    var slides: [Slide] = []

    init() {}
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        version = (try? c.decode(Int.self, forKey: .version)) ?? 1
        height = (try? c.decode(Double.self, forKey: .height)) ?? 1080
        fonts = try? c.decode([FontFace].self, forKey: .fonts)
        slides = try c.decode([Slide].self, forKey: .slides)
    }
}

let SLIDE_W: Double = 1920

func newID() -> String { String(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(10)).lowercased() }

func jsonString<T: Encodable>(_ v: T) -> String {
    let e = JSONEncoder()
    e.outputFormatting = [.withoutEscapingSlashes]
    guard let d = try? e.encode(v), let s = String(data: d, encoding: .utf8) else { return "null" }
    return s.replacingOccurrences(of: "\u{2028}", with: "\\u2028").replacingOccurrences(of: "\u{2029}", with: "\\u2029")
}

// MARK: צבעים

struct RGBA { var r: Double; var g: Double; var b: Double; var a: Double
    var hex: String { String(format: "%02X%02X%02X", Int((r * 255).rounded()), Int((g * 255).rounded()), Int((b * 255).rounded())) }
    var css: String { a >= 0.995 ? "#" + hex.lowercased() : String(format: "rgba(%d,%d,%d,%.3f)", Int((r * 255).rounded()), Int((g * 255).rounded()), Int((b * 255).rounded()), a) }
}

func parseCSSColor(_ str: String?) -> RGBA? {
    guard var s = str?.trimmingCharacters(in: .whitespaces).lowercased(), !s.isEmpty else { return nil }
    if s == "transparent" || s == "none" { return RGBA(r: 0, g: 0, b: 0, a: 0) }
    if s == "white" { return RGBA(r: 1, g: 1, b: 1, a: 1) }
    if s == "black" { return RGBA(r: 0, g: 0, b: 0, a: 1) }
    if s.hasPrefix("#") {
        s.removeFirst()
        if s.count == 3 || s.count == 4 { s = s.map { "\($0)\($0)" }.joined() }
        guard s.count == 6 || s.count == 8, let v = UInt64(s, radix: 16) else { return nil }
        if s.count == 6 { return RGBA(r: Double((v >> 16) & 255) / 255, g: Double((v >> 8) & 255) / 255, b: Double(v & 255) / 255, a: 1) }
        return RGBA(r: Double((v >> 24) & 255) / 255, g: Double((v >> 16) & 255) / 255, b: Double((v >> 8) & 255) / 255, a: Double(v & 255) / 255)
    }
    if s.hasPrefix("rgb") {
        let nums = s.components(separatedBy: CharacterSet(charactersIn: "0123456789.").inverted).compactMap { Double($0) }
        guard nums.count >= 3 else { return nil }
        return RGBA(r: nums[0] / 255, g: nums[1] / 255, b: nums[2] / 255, a: nums.count > 3 ? nums[3] : 1)
    }
    return nil
}

/// צבע ראשון מתוך מחרוזת CSS (כולל גרדיאנט)
func firstColor(_ css: String?) -> RGBA? {
    guard let css else { return nil }
    if let c = parseCSSColor(css) { return c }
    let patterns = ["rgba?\\([^)]*\\)", "#[0-9a-fA-F]{3,8}"]
    for p in patterns {
        if let r = css.range(of: p, options: .regularExpression), let c = parseCSSColor(String(css[r])) { return c }
    }
    return nil
}

extension Color {
    init(css: String?, fallback: Color = .black) {
        if let c = firstColor(css) { self = Color(.sRGB, red: c.r, green: c.g, blue: c.b, opacity: c.a) } else { self = fallback }
    }
    var css: String {
        let n = NSColor(self).usingColorSpace(.sRGB) ?? .black
        return RGBA(r: Double(n.redComponent), g: Double(n.greenComponent), b: Double(n.blueComponent), a: Double(n.alphaComponent)).css
    }
}

// MARK: טקסט

func plainText(fromHTML html: String?) -> String {
    guard var s = html else { return "" }
    s = s.replacingOccurrences(of: "<br\\s*/?>", with: "\n", options: .regularExpression)
    s = s.replacingOccurrences(of: "</(div|p|li|h[1-6])>", with: "\n", options: [.regularExpression, .caseInsensitive])
    s = s.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
    for (a, b) in [("&nbsp;", " "), ("&amp;", "&"), ("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&#39;", "'")] {
        s = s.replacingOccurrences(of: a, with: b)
    }
    return s.trimmingCharacters(in: .whitespacesAndNewlines)
}

func escapeHTML(_ s: String) -> String {
    s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
}

func escapeXML(_ s: String) -> String {
    escapeHTML(s).replacingOccurrences(of: "\"", with: "&quot;")
}

let SFX: [(id: String, name: String)] = [("whoosh", "משב רוח"), ("chime", "פעמון"), ("pop", "פופ"), ("sparkle", "נצנוץ")]
let TRANSITIONS: [(id: String, name: String)] = [("none", "ללא"), ("fade", "עמעום"), ("push", "דחיפה"), ("zoom", "זום"), ("morph", "מורף")]
let ANIMS: [(id: String, name: String)] = [("none", "ללא"), ("fade", "עמעום"), ("up", "מלמטה"), ("down", "מלמעלה"), ("right", "מימין"), ("left", "משמאל"), ("zoom", "זום"), ("pop", "קפיצה"), ("wipe", "חשיפה")]
let SHAPES: [(id: String, name: String, icon: String)] = [("rect", "מלבן", "rectangle"), ("round", "מלבן מעוגל", "app"), ("ellipse", "עיגול", "circle"), ("triangle", "משולש", "triangle"), ("diamond", "מעוין", "diamond"), ("star", "כוכב", "star"), ("arrow", "חץ", "arrowshape.left"), ("line", "קו", "minus")]
let SYSTEM_FONTS = ["Arial Hebrew", "Arial", "Arial Hebrew Scholar", "SF Hebrew", "Times New Roman", "New Peninim MT", "Raanana", "Corsiva Hebrew", "Lucida Grande", "Helvetica Neue", "Courier New", "Tahoma"]
let AUDIO_EXT: Set<String> = ["mp3", "wav", "m4a", "aac", "aiff", "aif", "caf"]
let IMAGE_EXT: Set<String> = ["png", "jpg", "jpeg", "gif", "webp", "svg", "heic", "tiff", "tif", "bmp"]
let DECK_EXT: Set<String> = ["pptx", "ppt", "key", "odp", "pdf", "html", "htm"]
let PKG_EXT = "shekef"
