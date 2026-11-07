import AppKit
let directory = URL(fileURLWithPath: CommandLine.arguments[1]).deletingLastPathComponent()
func render(_ pixels: Int, to destination: URL) throws {
    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
    let scale = NSAffineTransform(); scale.scale(by: CGFloat(pixels) / 1024); scale.concat()
    NSColor(calibratedRed: 0.07, green: 0.16, blue: 0.19, alpha: 1).setFill()
    NSBezierPath(roundedRect: NSRect(x: 40, y: 40, width: 944, height: 944), xRadius: 210, yRadius: 210).fill()
    let symbol = NSImage(systemSymbolName: "gauge.with.dots.needle.50percent", accessibilityDescription: nil)!
    let styled = symbol.withSymbolConfiguration(NSImage.SymbolConfiguration(paletteColors: [.systemTeal, .white])) ?? symbol
    styled.draw(in: NSRect(x: 200, y: 200, width: 624, height: 624))
    NSGraphicsContext.restoreGraphicsState()
    try bitmap.representation(using: .png, properties: [:])!.write(to: destination)
}
for size in [16, 32, 128, 256, 512] {
    try render(size, to: directory.appendingPathComponent("icon_\(size)x\(size).png"))
    try render(size * 2, to: directory.appendingPathComponent("icon_\(size)x\(size)@2x.png"))
}
