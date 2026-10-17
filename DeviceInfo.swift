import AppKit
import Darwin
import IOKit

struct DeviceInfo {
    let name: String
    let model: String
    let system: String
    let processor: String
    let graphics: String
    let memory: String
    let displays: String
    let serial: String
    let uptime: String

    private static func sysString(_ key: String) -> String? {
        var size = 0
        guard sysctlbyname(key, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(key, &buffer, &size, nil, 0) == 0 else { return nil }
        return String(cString: buffer)
    }
    private static func sysInt(_ key: String) -> Int? {
        var value: Int32 = 0; var size = MemoryLayout<Int32>.size
        guard sysctlbyname(key, &value, &size, nil, 0) == 0 else { return nil }
        return Int(value)
    }
    private static func property(_ entry: io_registry_entry_t, _ key: String) -> String? {
        guard let value = IORegistryEntryCreateCFProperty(entry, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() else { return nil }
        if let text = value as? String { return text }
        if let data = value as? Data { return String(data: data.prefix { $0 != 0 }, encoding: .utf8) }
        return nil
    }
    static func read() -> DeviceInfo {
        let product = IORegistryEntryFromPath(kIOMainPortDefault, "IODeviceTree:/product")
        let name = product != 0 ? property(product, "product-description") : nil
        if product != 0 { IOObjectRelease(product) }
        let platform = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPlatformExpertDevice"))
        let serial = platform != 0 ? property(platform, "IOPlatformSerialNumber") : nil
        if platform != 0 { IOObjectRelease(platform) }
        let model = sysString("hw.model") ?? "未知机型"
        let chip = sysString("machdep.cpu.brand_string") ?? "Apple Silicon"
        var cpu = "\(chip) · \(sysInt("hw.physicalcpu") ?? ProcessInfo.processInfo.processorCount) 核心 / \(sysInt("hw.logicalcpu") ?? ProcessInfo.processInfo.processorCount) 线程"
        var levels: [String] = []
        for index in 0..<(sysInt("hw.nperflevels") ?? 0) {
            if let count = sysInt("hw.perflevel\(index).physicalcpu"), let name = sysString("hw.perflevel\(index).name") {
                let label = ["Super": "超级核心", "Performance": "性能核心", "Efficiency": "能效核心"][name] ?? name
                levels.append("\(count) \(label)")
            }
        }
        if !levels.isEmpty { cpu += "\n" + levels.joined(separator: " · ") }
        var graphics = "集成图形（核心数不可用）"
        let gpu = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AGXAccelerator"))
        if gpu != 0 {
            let gpuModel = property(gpu, "model") ?? chip
            if let count = IORegistryEntryCreateCFProperty(gpu, "gpu-core-count" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? NSNumber {
                graphics = "\(gpuModel)（\(count.intValue) 核心）"
            } else { graphics = gpuModel }
            IOObjectRelease(gpu)
        }
        let displays = NSScreen.screens.map { screen -> String in
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
                  let mode = CGDisplayCopyDisplayMode(number.uint32Value) else { return screen.localizedName }
            let rate = mode.refreshRate > 0 ? String(format: " · %.0f Hz", mode.refreshRate) : ""
            return "\(screen.localizedName) · \(mode.pixelWidth) × \(mode.pixelHeight)\(rate)"
        }.joined(separator: "\n")
        let seconds = Int(ProcessInfo.processInfo.systemUptime)
        let uptime = "\(seconds / 86400) 天 \((seconds % 86400) / 3600) 小时"
        return DeviceInfo(name: name ?? "Mac（\(model)）", model: model,
                          system: "macOS \(ProcessInfo.processInfo.operatingSystemVersionString)", processor: cpu,
                          graphics: graphics, memory: readable(ProcessInfo.processInfo.physicalMemory, decimals: 0),
                          displays: displays, serial: serial ?? "不可用", uptime: uptime)
    }
}

// The build exports one small bitmap for its host model. Read it only while the
// dashboard exists, without loading system icon catalogs or image format decoders.
enum DeviceArtwork {
    static func load(model: String, resources: URL? = Bundle.main.resourceURL) -> NSImage? {
        guard let resources,
              let metadata = try? Data(contentsOf: resources.appendingPathComponent("DeviceArtwork.plist")),
              let info = (try? PropertyListSerialization.propertyList(from: metadata, format: nil)) as? [String: Any],
              info["model"] as? String == model,
              let width = info["width"] as? Int, let height = info["height"] as? Int,
              width > 0, width <= 384, height > 0, height <= 384,
              let artwork = BitmapAsset.load(url: resources.appendingPathComponent("DeviceArtwork.rgba"), width: width, height: height) else { return nil }
        return artwork
    }
}

enum BitmapAsset {
    static func load(url: URL, width: Int, height: Int) -> NSImage? {
        guard width > 0, height > 0, width <= 384, height <= 384,
              let pixels = try? Data(contentsOf: url, options: .mappedIfSafe),
              pixels.count == width * height * 4,
              let provider = CGDataProvider(data: pixels as CFData),
              let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                                  bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGBitmapInfo(rawValue: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue),
                                  provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent) else { return nil }
        let artwork = NSImage(cgImage: image, size: NSSize(width: CGFloat(width) / 2, height: CGFloat(height) / 2))
        artwork.cacheMode = .never
        return artwork
    }
}
