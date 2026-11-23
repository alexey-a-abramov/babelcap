// Generates Resources/AppIcon.icns. Run: swift scripts/make_icon.swift
import AppKit

func render(_ px: Int) -> Data {
    let size = CGFloat(px)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    // macOS icon grid: art occupies ~80% of the canvas.
    let inset = size * 0.1
    let rect = NSRect(x: inset, y: inset, width: size - 2 * inset, height: size - 2 * inset)
    let bg = NSBezierPath(roundedRect: rect, xRadius: rect.width * 0.225, yRadius: rect.width * 0.225)
    NSGradient(colors: [NSColor(red: 0.20, green: 0.18, blue: 0.55, alpha: 1), NSColor(red: 0.05, green: 0.60, blue: 0.70, alpha: 1)])!
        .draw(in: bg, angle: -50)

    // Soft shadow under the glyph.
    let cfg = NSImage.SymbolConfiguration(pointSize: size * 0.46, weight: .semibold)
        .applying(.init(paletteColors: [.white]))
    if let sym = NSImage(systemSymbolName: "captions.bubble.fill", accessibilityDescription: nil)?.withSymbolConfiguration(cfg) {
        let s = sym.size
        let r = NSRect(x: (size - s.width) / 2, y: (size - s.height) / 2, width: s.width, height: s.height)
        NSGraphicsContext.current?.saveGraphicsState()
        let sh = NSShadow(); sh.shadowColor = NSColor.black.withAlphaComponent(0.3); sh.shadowBlurRadius = size * 0.03
        sh.shadowOffset = NSSize(width: 0, height: -size * 0.015); sh.set()
        sym.draw(in: r)
        NSGraphicsContext.current?.restoreGraphicsState()
    }
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let fm = FileManager.default
let iconset = URL(fileURLWithPath: fm.currentDirectoryPath).appendingPathComponent("build/AppIcon.iconset")
try? fm.removeItem(at: iconset)
try fm.createDirectory(at: iconset, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    try render(base).write(to: iconset.appendingPathComponent("icon_\(base)x\(base).png"))
    try render(base * 2).write(to: iconset.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
print("iconset written: \(iconset.path)")
