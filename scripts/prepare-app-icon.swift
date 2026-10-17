import AppKit
import ImageIO
let sourceURL = URL(fileURLWithPath: CommandLine.arguments[1])
let outputURL = URL(fileURLWithPath: CommandLine.arguments[2])
guard let source = CGImageSourceCreateWithURL(sourceURL as CFURL, nil),
      let image = CGImageSourceCreateImageAtIndex(source, 0, nil), image.width == 256, image.height == 256 else { fatalError("Invalid app icon") }
var bytes = [UInt8](repeating: 0, count: 256 * 256 * 4)
let ok = bytes.withUnsafeMutableBytes { pixels -> Bool in
    guard let context = CGContext(data: pixels.baseAddress, width: 256, height: 256, bitsPerComponent: 8,
        bytesPerRow: 256 * 4, space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
    context.draw(image, in: CGRect(x: 0, y: 0, width: 256, height: 256)); return true
}
precondition(ok)
try Data(bytes).write(to: outputURL)
