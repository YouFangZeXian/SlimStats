import AppKit
import ImageIO
import Darwin

// Build-time only: resolve and decode the host Mac's system-provided artwork.
enum SystemDeviceArtwork {
    static func sourceURL(for model: String) -> URL? {
        let root = URL(fileURLWithPath: "/System/Library/CoreServices/CoreTypes.bundle")
        let library = root.appendingPathComponent("Contents/Library")
        let children = (try? FileManager.default.contentsOfDirectory(at: library, includingPropertiesForKeys: nil)) ?? []
        let bundles = [root] + children.filter { $0.pathExtension == "bundle" && $0.lastPathComponent.hasPrefix("CoreTypes-") }
        // Filter the small catalogs by their ASCII identifiers before parsing. This
        // avoids materializing the entire system icon registry for one machine.
        func find(_ token: String, match: ([String: Any]) -> Bool) -> (URL, [String: Any])? {
            let needle = Data(token.utf8)
            for bundle in bundles {
                let contents = bundle.appendingPathComponent("Contents")
                let result: [String: Any]? = autoreleasepool {
                    guard let data = try? Data(contentsOf: contents.appendingPathComponent("Info.plist"), options: .mappedIfSafe),
                          data.range(of: needle) != nil,
                          let info = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any],
                          let declarations = info["UTExportedTypeDeclarations"] as? [[String: Any]] else { return nil }
                    return declarations.first(where: match)
                }
                if let result { return (contents, result) }
            }
            return nil
        }
        let matched = find(model) { declaration in
            let tags = declaration["UTTypeTagSpecification"] as? [String: Any]
            let codes = tags?["com.apple.device-model-code"]
            return (codes as? [String])?.contains(model) == true || (codes as? String) == model
        }
        var queue = [matched?.1["UTTypeIdentifier"] as? String ?? "com.apple.mac"]
        var visited: Set<String> = []
        while !queue.isEmpty {
            let id = queue.removeFirst()
            guard visited.insert(id).inserted,
                  let (contents, declaration) = find(id, match: { $0["UTTypeIdentifier"] as? String == id }) else { continue }
            let icons = declaration["UTTypeIcons"] as? [String: Any]
            if let filename = icons?["UTTypeIconFile"] as? String {
                let icon = contents.appendingPathComponent("Resources").appendingPathComponent(filename)
                if FileManager.default.fileExists(atPath: icon.path) { return icon }
            }
            let parent = declaration["UTTypeConformsTo"]
            queue.append(contentsOf: (parent as? [String]) ?? (parent as? String).map { [$0] } ?? [])
        }
        return nil
    }
    static func load(model: String) -> NSImage? {
        guard let url = sourceURL(for: model),
              let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: 384,
                kCGImageSourceShouldCacheImmediately: true
              ] as CFDictionary) else { return nil }
        // Hardware icons have a large transparent square around the device. Trim it
        // so the physical machine is legible without stretching its proportions.
        let width = thumbnail.width, height = thumbnail.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let cropped: CGImage? = pixels.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height,
                                          bitsPerComponent: 8, bytesPerRow: width * 4,
                                          space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
            context.draw(thumbnail, in: CGRect(x: 0, y: 0, width: width, height: height))
            let bytes = buffer.bindMemory(to: UInt8.self)
            var minX = width, minY = height, maxX = -1, maxY = -1
            for y in 0..<height {
                for x in 0..<width where bytes[(y * width + x) * 4 + 3] > 8 {
                    minX = min(minX, x); minY = min(minY, y)
                    maxX = max(maxX, x); maxY = max(maxY, y)
                }
            }
            guard maxX >= minX, maxY >= minY else { return nil }
            return context.makeImage()?.cropping(to: CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1))
        }
        guard let cropped else { return nil }
        let image = NSImage(cgImage: cropped, size: NSSize(width: CGFloat(cropped.width) / 2, height: CGFloat(cropped.height) / 2))
        image.cacheMode = .never
        return image
    }
}

var size = 0
precondition(sysctlbyname("hw.model", nil, &size, nil, 0) == 0 && size > 0)
var modelBytes = [CChar](repeating: 0, count: size)
precondition(sysctlbyname("hw.model", &modelBytes, &size, nil, 0) == 0)
let model = String(cString: modelBytes)
let destination = URL(fileURLWithPath: CommandLine.arguments[1])
guard let image = SystemDeviceArtwork.load(model: model),
      let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
    print("No system hardware artwork; dashboard will use its vector fallback")
    exit(0)
}
let width = cgImage.width, height = cgImage.height
var pixels = [UInt8](repeating: 0, count: width * height * 4)
let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
    guard let context = CGContext(data: buffer.baseAddress, width: width, height: height,
                                  bitsPerComponent: 8, bytesPerRow: width * 4,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
    context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
    return true
}
precondition(drawn)
try Data(pixels).write(to: destination.appendingPathComponent("DeviceArtwork.rgba"))
let metadata: [String: Any] = ["model": model, "width": width, "height": height]
let data = try PropertyListSerialization.data(fromPropertyList: metadata, format: .binary, options: 0)
try data.write(to: destination.appendingPathComponent("DeviceArtwork.plist"))
print("Prepared hardware artwork: \(model), \(width) × \(height) pixels, \(pixels.count) bytes")
