import AppKit
let folder = CommandLine.arguments[1]
for (size, suffix) in [(16,"16x16"),(32,"16x16@2x"),(32,"32x32"),(64,"32x32@2x"),(128,"128x128"),(256,"128x128@2x"),(256,"256x256"),(512,"256x256@2x"),(512,"512x512"),(1024,"512x512@2x")] {
    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
    let scale = CGFloat(size) / 1024
    NSAffineTransform(transform: AffineTransform(scale: scale)).concat()
    NSColor(calibratedRed: 0.04, green: 0.36, blue: 0.90, alpha: 1).setFill()
    NSBezierPath(roundedRect: NSRect(x: 70, y: 70, width: 884, height: 884), xRadius: 202, yRadius: 202).fill()
    let chip = NSBezierPath(roundedRect: NSRect(x: 290, y: 330, width: 444, height: 364), xRadius: 55, yRadius: 55)
    NSColor.white.setStroke(); chip.lineWidth = 35; chip.stroke()
    for x in stride(from: CGFloat(350), through: 674, by: 108) {
        let pins = NSBezierPath(); pins.move(to: NSPoint(x:x,y:260)); pins.line(to:NSPoint(x:x,y:330)); pins.move(to:NSPoint(x:x,y:694)); pins.line(to:NSPoint(x:x,y:764)); pins.lineWidth=30; pins.lineCapStyle = .round; pins.stroke()
    }
    let wave=NSBezierPath(); wave.move(to:NSPoint(x:352,y:458)); wave.line(to:NSPoint(x:420,y:458)); wave.line(to:NSPoint(x:470,y:586)); wave.line(to:NSPoint(x:535,y:425)); wave.line(to:NSPoint(x:590,y:536)); wave.line(to:NSPoint(x:675,y:536)); wave.lineWidth=28; wave.lineJoinStyle = .round; wave.stroke()
    NSGraphicsContext.restoreGraphicsState()
    try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: folder).appendingPathComponent("icon_\(suffix).png"))
}
