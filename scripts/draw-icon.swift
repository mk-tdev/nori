import AppKit
// Flat vector artwork: a navy tile and two ocean swells. No gradients or glass effects.
let size = 1024
let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
NSColor(red: 0.025, green: 0.13, blue: 0.25, alpha: 1).setFill()
NSBezierPath(roundedRect: NSRect(x: 64, y: 64, width: 896, height: 896), xRadius: 190, yRadius: 190).fill()
func wave(y: CGFloat, color: NSColor) {
    let path = NSBezierPath()
    path.move(to: NSPoint(x: 244, y: y))
    path.curve(to: NSPoint(x: 512, y: y), controlPoint1: NSPoint(x: 330, y: y + 160), controlPoint2: NSPoint(x: 426, y: y + 160))
    path.curve(to: NSPoint(x: 780, y: y), controlPoint1: NSPoint(x: 598, y: y - 160), controlPoint2: NSPoint(x: 694, y: y - 160))
    path.lineWidth = 66; path.lineCapStyle = .round
    color.setStroke(); path.stroke()
}
wave(y: 612, color: NSColor(red: 0.24, green: 0.69, blue: 0.98, alpha: 1))
wave(y: 410, color: NSColor(red: 0.64, green: 0.88, blue: 1, alpha: 1))
NSGraphicsContext.restoreGraphicsState()
try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
