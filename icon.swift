import AppKit

// מצייר את אייקון האפליקציה: שקף לבן עם כותרת, על רקע כחול
let out = CommandLine.arguments[1]
func draw(_ px: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = CGFloat(px) / 1024
    let bg = NSBezierPath(roundedRect: NSRect(x: 100 * s, y: 100 * s, width: 824 * s, height: 824 * s), xRadius: 186 * s, yRadius: 186 * s)
    NSGradient(colors: [NSColor(red: 0.20, green: 0.50, blue: 0.98, alpha: 1), NSColor(red: 0.10, green: 0.22, blue: 0.62, alpha: 1)])!.draw(in: bg, angle: -90)
    let shadow = NSShadow(); shadow.shadowColor = NSColor.black.withAlphaComponent(0.3); shadow.shadowBlurRadius = 30 * s; shadow.shadowOffset = NSSize(width: 0, height: -12 * s)
    shadow.set()
    NSColor.white.setFill()
    NSBezierPath(roundedRect: NSRect(x: 220 * s, y: 330 * s, width: 584 * s, height: 364 * s), xRadius: 34 * s, yRadius: 34 * s).fill()
    NSShadow().set()
    NSColor(red: 0.10, green: 0.22, blue: 0.62, alpha: 1).setFill()
    NSBezierPath(roundedRect: NSRect(x: 440 * s, y: 590 * s, width: 310 * s, height: 44 * s), xRadius: 22 * s, yRadius: 22 * s).fill()
    NSColor(white: 0.72, alpha: 1).setFill()
    NSBezierPath(roundedRect: NSRect(x: 520 * s, y: 510 * s, width: 230 * s, height: 28 * s), xRadius: 14 * s, yRadius: 14 * s).fill()
    NSBezierPath(roundedRect: NSRect(x: 560 * s, y: 450 * s, width: 190 * s, height: 28 * s), xRadius: 14 * s, yRadius: 14 * s).fill()
    NSColor(red: 0.98, green: 0.74, blue: 0.20, alpha: 1).setFill()
    NSBezierPath(ovalIn: NSRect(x: 280 * s, y: 420 * s, width: 180 * s, height: 180 * s)).fill()
    NSColor.white.setFill()
    let tri = NSBezierPath(); tri.move(to: NSPoint(x: 345 * s, y: 465 * s)); tri.line(to: NSPoint(x: 345 * s, y: 555 * s)); tri.line(to: NSPoint(x: 420 * s, y: 510 * s)); tri.close(); tri.fill()
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}
let fm = FileManager.default
try? fm.createDirectory(atPath: out, withIntermediateDirectories: true)
for (name, px) in [("16x16", 16), ("16x16@2x", 32), ("32x32", 32), ("32x32@2x", 64), ("128x128", 128), ("128x128@2x", 256), ("256x256", 256), ("256x256@2x", 512), ("512x512", 512), ("512x512@2x", 1024)] {
    try! draw(px).write(to: URL(fileURLWithPath: "\(out)/icon_\(name).png"))
}
