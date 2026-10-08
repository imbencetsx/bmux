import AppKit
import CoreText

for name in ["GeistMono-Regular", "GeistMono-SemiBold"] {
    let url = URL(fileURLWithPath: "Assets/Fonts/\(name).ttf")
    guard CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil) else {
        fatalError("Unable to load \(name)")
    }
}
let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1800, pixelsHigh: 800,
    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
bitmap.size = NSSize(width: 900, height: 400)
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
// Finder's native filenames stay accessible beside the icons; its black
// filename ink blends into the canvas. Visible captions use Geist Mono below.
NSColor.black.setFill()
NSRect(x: 0, y: 0, width: 900, height: 400).fill()

func text(_ value: String, x: CGFloat = 450, y: CGFloat, size: CGFloat,
          weight: String = "Regular", brightness: CGFloat = 0.9) {
    guard let font = NSFont(name: "GeistMono-\(weight)", size: size) else {
        fatalError("Geist Mono font unavailable")
    }
    let attributes: [NSAttributedString.Key: Any] = [
        .font: font, .foregroundColor: NSColor(calibratedWhite: brightness, alpha: 1)
    ]
    let width = (value as NSString).size(withAttributes: attributes).width
    (value as NSString).draw(at: NSPoint(x: x - width / 2, y: y), withAttributes: attributes)
}
text("[bmux]", y: 320, size: 28, weight: "SemiBold", brightness: 0.96)
text("Drag [bmux] to Applications to install", y: 285, size: 15, brightness: 0.75)
text("[bmux]", x: 300, y: 118, size: 14)
text("Applications", x: 600, y: 118, size: 14)
NSGraphicsContext.restoreGraphicsState()
try bitmap.representation(using: .png, properties: [:])!.write(
    to: URL(fileURLWithPath: CommandLine.arguments[1]))
