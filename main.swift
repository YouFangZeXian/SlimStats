import AppKit
import Darwin
import ServiceManagement

private let bytesPerGB = 1_073_741_824.0
private let bytesPerMB = 1_048_576.0

struct MemorySnapshot {
    let total: UInt64
    let used: UInt64
    let app: UInt64
    let wired: UInt64
    let compressed: UInt64
    let available: UInt64
    let swapUsed: UInt64

    var usage: Double { total == 0 ? 0 : Double(used) / Double(total) }
}

struct DiskSnapshot {
    let total: UInt64
    let free: UInt64

    var used: UInt64 { total > free ? total - free : 0 }
}

struct ProcessSnapshot {
    let name: String
    let rss: UInt64
    let bundlePath: String?
    var exitIdentity: ProcessIdentity? = nil
    var key: String { bundlePath ?? "\(name)#\(exitIdentity?.pid ?? 0)" }
}

enum SystemMetrics {
    private static let hostPort = mach_host_self()
    static func memory() -> MemorySnapshot? {
        var stats = vm_statistics64_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &stats) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(hostPort, HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }

        var pageSize: vm_size_t = 0
        guard host_page_size(hostPort, &pageSize) == KERN_SUCCESS else { return nil }
        let page = UInt64(pageSize)
        let total = ProcessInfo.processInfo.physicalMemory
        let compressed = min(UInt64(stats.compressor_page_count) * page, total)
        let wired = min(UInt64(stats.wire_count) * page, total - compressed)
        // Same accounting as Stats: exclude purgeable memory and file-backed pages.
        let occupied = (Int64(stats.active_count) + Int64(stats.inactive_count)
                      + Int64(stats.speculative_count) + Int64(stats.wire_count)
                      + Int64(stats.compressor_page_count) - Int64(stats.purgeable_count)
                      - Int64(stats.external_page_count)) * Int64(page)
        let used = max(wired + compressed, UInt64(max(0, min(occupied, Int64(total)))))
        let available = total - used
        let app = used - wired - compressed

        var mib: [Int32] = [CTL_VM, VM_SWAPUSAGE]
        var swap = xsw_usage()
        var swapSize = MemoryLayout<xsw_usage>.size
        let swapResult = sysctl(&mib, 2, &swap, &swapSize, nil, 0)
        let swapUsed = swapResult == 0 ? swap.xsu_used : 0

        return MemorySnapshot(total: total, used: used, app: app, wired: wired,
                              compressed: compressed, available: available, swapUsed: swapUsed)
    }

    static func disk() -> DiskSnapshot? {
        let url = URL(fileURLWithPath: "/")
        guard let values = try? url.resourceValues(forKeys: [.volumeTotalCapacityKey,
                                                              .volumeAvailableCapacityForImportantUsageKey]),
              let total = values.volumeTotalCapacity,
              let free = values.volumeAvailableCapacityForImportantUsage else { return nil }
        return DiskSnapshot(total: UInt64(max(total, 0)), free: UInt64(max(free, 0)))
    }

    static func topProcesses(limit: Int = 8) -> [ProcessSnapshot] {
        let count = proc_listallpids(nil, 0)
        guard count > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(count) + 128)
        let returned = pids.withUnsafeMutableBufferPointer {
            proc_listallpids($0.baseAddress, Int32($0.count * MemoryLayout<pid_t>.size))
        }
        guard returned > 0 else { return [] }
        var totals: [String: (rss: UInt64, bundle: String?, name: String, candidates: [pid_t], largestPID: pid_t, largestRSS: UInt64)] = [:]
        for pid in pids.prefix(min(Int(returned), pids.count)) where pid > 0 {
            autoreleasepool {
                var usage = rusage_info_current()
                let rc = withUnsafeMutablePointer(to: &usage) { pointer in
                    pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                        proc_pid_rusage(pid, RUSAGE_INFO_CURRENT, $0)
                    }
                }
                guard rc == 0 else { return }
                var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
                guard proc_pidpath(pid, &buffer, UInt32(MAXPATHLEN)) > 0 else { return }
                let path = String(cString: buffer)
                // The outermost app owns its embedded helpers, even when their names differ.
                let bundlePath = path.range(of: ".app/").map { String(path[..<$0.lowerBound]) + ".app" }
                let key = bundlePath ?? "\(path)#\(pid)"
                let name = (((bundlePath ?? path) as NSString).lastPathComponent as NSString).deletingPathExtension
                var entry = totals[key] ?? (0, bundlePath, name, [], pid, 0)
                entry.rss += usage.ri_resident_size
                if usage.ri_resident_size > entry.largestRSS { entry.largestPID = pid; entry.largestRSS = usage.ri_resident_size }
                if let bundlePath, path.hasPrefix(bundlePath + "/Contents/MacOS/"), entry.candidates.count < 16 {
                    entry.candidates.append(pid)
                }
                totals[key] = entry
            }
        }
        return totals.values.filter { $0.rss > 20 * 1024 * 1024 }
            .sorted { $0.rss > $1.rss }.prefix(limit).map {
                let entry = $0
                let pid = entry.candidates.first { sameApplicationBundle(NSRunningApplication(processIdentifier: $0)?.bundleURL?.path, entry.bundle) } ?? entry.largestPID
                return ProcessSnapshot(name: entry.name, rss: entry.rss, bundlePath: entry.bundle, exitIdentity: ProcessIdentity.capture(pid))
            }
    }
}

func readable(_ bytes: UInt64, decimals: Int = 2) -> String {
    let value = Double(bytes)
    if value >= bytesPerGB { return String(format: "%.\(decimals)f GB", value / bytesPerGB) }
    if value >= bytesPerMB { return String(format: "%.\(decimals)f MB", value / bytesPerMB) }
    return String(format: "%.0f KB", value / 1024.0)
}

func diskReadable(_ bytes: UInt64) -> String { String(format: "%.0f GB", Double(bytes) / 1_000_000_000) }

func textLabel(_ text: String, size: CGFloat = 13, weight: NSFont.Weight = .regular) -> LightLabel {
    let label = LightLabel(text)
    label.font = NSFont.systemFont(ofSize: size, weight: weight)
    return label
}

final class HistoryView: NSView {
    var values: [Double] = [] { didSet { needsDisplay = true } }
    var grid = false
    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let rect = bounds.insetBy(dx: grid ? 38 : 1, dy: 8)
        if grid {
            for step in 0...4 {
                let y = rect.minY + rect.height * CGFloat(step) / 4
                NSColor.separatorColor.withAlphaComponent(0.4).setStroke()
                let line = NSBezierPath(); line.move(to: NSPoint(x: rect.minX, y: y))
                line.line(to: NSPoint(x: rect.maxX, y: y)); line.stroke()
                LightText.draw("\(step * 25)%", in: NSRect(x: 0, y: y - 7, width: 32, height: 14), font: NSFont.systemFont(ofSize: 10), color: .secondaryLabelColor)
            }
        }
        guard !values.isEmpty else { return }
        let path = CGMutablePath()
        // Keep 120 samples on a stable horizontal scale.
        for (index, value) in values.enumerated() {
            let x = rect.minX + rect.width * CGFloat(120 - values.count + index) / 119
            let y = rect.minY + rect.height * CGFloat(min(max(value, 0), 1))
            if index == 0 { path.move(to: CGPoint(x: x, y: y)) }
            else { path.addLine(to: CGPoint(x: x, y: y)) }
        }
        let fill = CGMutablePath(); fill.addPath(path)
        fill.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        fill.addLine(to: CGPoint(x: rect.minX + rect.width * CGFloat(120 - values.count) / 119, y: rect.minY))
        fill.closeSubpath()
        context.setFillColor(NSColor.systemBlue.withAlphaComponent(0.18).cgColor)
        context.addPath(fill); context.fillPath()
        context.setStrokeColor(NSColor.systemBlue.cgColor)
        context.setLineWidth(1.5); context.addPath(path); context.strokePath()
    }
}

final class SegmentBarView: NSView {
    var segments: [(CGFloat, NSColor)] = [] { didSet { needsDisplay = true } }
    override func draw(_ dirtyRect: NSRect) {
        NSGraphicsContext.saveGraphicsState()
        let path = NSBezierPath(roundedRect: bounds, xRadius: bounds.height / 2, yRadius: bounds.height / 2)
        path.addClip()
        NSColor.quaternaryLabelColor.setFill(); bounds.fill()
        var x = bounds.minX
        for (fraction, color) in segments {
            let width = bounds.width * min(max(fraction, 0), 1)
            color.setFill(); NSRect(x: x, y: 0, width: width, height: bounds.height).fill()
            x += width
        }
        NSGraphicsContext.restoreGraphicsState()
    }
}

func memorySegments(_ memory: MemorySnapshot) -> [(CGFloat, NSColor)] {
    let total = max(Double(memory.total), 1)
    return [(CGFloat(Double(memory.app) / total), .systemBlue),
            (CGFloat(Double(memory.wired) / total), .systemOrange),
            (CGFloat(Double(memory.compressed) / total), .systemPink),
            (CGFloat(Double(memory.available) / total), .systemGray.withAlphaComponent(0.3))]
}

final class RingView: NSView {
    var segments: [(CGFloat, NSColor)] = [] { didSet { needsDisplay = true } }
    var caption = "—" { didSet { needsDisplay = true } }
    override func draw(_ dirtyRect: NSRect) {
        var angle: CGFloat = 90
        for (value, color) in segments {
            let arc = NSBezierPath()
            arc.appendArc(withCenter: NSPoint(x: bounds.midX, y: bounds.midY), radius: min(bounds.width, bounds.height) / 2 - 8,
                          startAngle: angle, endAngle: angle - value * 360, clockwise: true)
            arc.lineWidth = 9; arc.lineCapStyle = .round; color.setStroke(); arc.stroke()
            angle -= value * 360
        }
        LightText.draw(caption, in: bounds, font: NSFont.monospacedDigitSystemFont(ofSize: 23, weight: .medium), color: .labelColor, alignment: .center)
    }
}

final class ProcessRow: NSView {
    private let iconButton = LightButton()
    private let nameButton = LightButton(title: "", target: nil, action: nil)
    private let amountLabel = textLabel("", size: 12)
    private var target: ProcessExitTarget?
    private var selected = false
    private var smallIcon: NSImage?
    var onSelect: (() -> Void)?
    var onQuitApp: ((ProcessExitTarget) -> Void)?
    let key: String

    init(process: ProcessSnapshot) {
        key = process.key
        super.init(frame: NSRect(x: 0, y: 0, width: 292, height: 27))
        iconButton.frame = NSRect(x: 0, y: 2, width: 24, height: 24)
        iconButton.isBordered = false
        iconButton.target = self; iconButton.action = #selector(iconClicked)
        addSubview(iconButton)
        nameButton.frame = NSRect(x: 31, y: 5, width: 162, height: 18)
        nameButton.font = NSFont.systemFont(ofSize: 12); nameButton.alignment = .left
        nameButton.isBordered = false; nameButton.lineBreakMode = .byTruncatingTail
        nameButton.target = self; nameButton.action = #selector(cancelSelection)
        nameButton.toolTip = "点击名称取消退出选择"; addSubview(nameButton)
        amountLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        amountLabel.alignment = .right
        amountLabel.toolTip = "驻留内存 RSS，按应用及辅助进程合计；与活动监视器的“内存”列口径不同。"
        amountLabel.frame = NSRect(x: 193, y: 5, width: 98, height: 18); addSubview(amountLabel)
        smallIcon = SmallAppIcon.load(bundlePath: process.bundlePath, name: process.name)
        iconButton.image = smallIcon
        update(process)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func update(_ process: ProcessSnapshot) {
        if target?.identity != process.exitIdentity || target?.isRunning == false {
            target = process.exitIdentity.map { ProcessExitTarget(identity: $0, bundlePath: process.bundlePath) }
            cancelSelection()
        }
        let reason = target?.blockedReason ?? (target == nil ? "无法读取此进程的身份或权限。" : nil)
        iconButton.isEnabled = target != nil && reason == nil
        iconButton.setAccessibilityLabel(reason.map { "\(process.name)，\($0)" } ?? "退出 \(process.name)")
        if !selected { iconButton.toolTip = reason ?? "点击图标显示 ×；点击名称取消" }
        nameButton.title = target?.application?.localizedName ?? process.name
        nameButton.toolTip = process.exitIdentity.map { "PID \($0.pid) · \($0.executable)\n点击名称取消退出选择" } ?? "点击名称取消退出选择"
        amountLabel.toolTip = process.bundlePath == nil ? "此进程的驻留内存 RSS；与活动监视器的“内存”列口径不同。" : "应用及辅助进程合计 RSS；结束单个辅助进程不保证释放整个合计。与活动监视器的“内存”列口径不同。"
        nameButton.setAccessibilityLabel("\(nameButton.title)，点击取消退出选择")
        amountLabel.stringValue = readable(process.rss, decimals: process.rss >= UInt64(bytesPerGB) ? 2 : 1)
    }
    @objc private func iconClicked() {
        guard let target, target.blockedReason == nil, target.isRunning else { return }
        if selected { cancelSelection(); onQuitApp?(target) }
        else {
            onSelect?()
            selected = true; iconButton.image = nil; iconButton.title = "×"
            iconButton.font = NSFont.systemFont(ofSize: 22, weight: .medium)
            iconButton.contentTintColor = .systemRed
            iconButton.toolTip = "退出 \(target.name)（PID \(target.identity.pid)）"
        }
    }
    @objc func cancelSelection() {
        selected = false; iconButton.title = ""; iconButton.image = smallIcon
        iconButton.contentTintColor = nil
        iconButton.toolTip = target?.blockedReason ?? "点击图标显示 ×；点击名称取消"
    }

}

final class StatsPanelViewController: NSViewController {
    private let showProcesses: Bool
    init(showProcesses: Bool) { self.showProcesses = showProcesses; super.init(nibName: nil, bundle: nil) }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    private let historyView = HistoryView()
    private let memoryBar = SegmentBarView()
    private let diskBar = SegmentBarView()
    private var labels: [String: LightLabel] = [:]
    private let processStack = NSView()
    private var processRows: [ProcessRow] = []
    private let diskDetail = textLabel("正在读取储存空间…", size: 11)
    var onSettings: (() -> Void)?
    var onQuit: (() -> Void)?
    var onQuitApp: ((ProcessExitTarget) -> Void)?

    override func loadView() {
        let root = FlippedView(frame: NSRect(x: 0, y: 0, width: 320, height: showProcesses ? 664 : 406))
        func put(_ child: NSView, _ x: CGFloat, _ y: CGFloat, _ width: CGFloat, _ height: CGFloat) {
            child.frame = NSRect(x: x, y: y, width: width, height: height); root.addSubview(child)
        }
        func title(_ name: String, _ y: CGFloat) {
            let label = textLabel(name, size: 11, weight: .semibold); label.textColor = .secondaryLabelColor
            put(label, 14, y, 292, 14)
        }
        func row(_ name: String, _ y: CGFloat, bold: Bool = false, color: NSColor = .labelColor) {
            let label = textLabel(name, size: 12); label.textColor = color
            put(label, 14, y, 130, 18)
            let value = textLabel("—", size: 12)
            value.font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: bold ? .semibold : .regular)
            value.alignment = .right; labels[name] = value
            put(value, 144, y, 162, 18)
        }
        put(textLabel("SlimStats · 内存", size: 14, weight: .semibold), 14, 12, 250, 22)
        let settings = LightButton(image: UIIcon.image("gearshape"), target: self, action: #selector(openSettings))
        settings.isBordered = false; settings.toolTip = "设置…"; settings.setAccessibilityLabel("设置…")
        put(settings, 280, 10, 28, 26)
        title("负载历史", 42); put(historyView, 14, 62, 292, 62)
        title("详细信息", 132); row("已用", 152, bold: true)
        put(memoryBar, 14, 178, 292, 8)
        for (index, entry) in [("App 内存", NSColor.systemBlue), ("联动内存", .systemOrange), ("压缩内存", .systemPink), ("可用", .secondaryLabelColor), ("交换区", .secondaryLabelColor)].enumerated() {
            row(entry.0, 194 + CGFloat(index) * 24, color: entry.1)
        }
        var y: CGFloat = 314
        if showProcesses {
            title("应用与进程排行 · RSS", y); put(processStack, 14, y + 20, 292, 230)
            y += 258
        }
        title("储存", y); put(diskBar, 14, y + 20, 292, 8)
        diskDetail.lineBreakMode = .byTruncatingTail; put(diskDetail, 14, y + 36, 292, 18)
        put(textLabel("F 空闲 · U 已用", size: 10), 14, y + 62, 220, 22)
        let quit = LightButton(title: "退出", target: self, action: #selector(quitClicked))
        quit.isBordered = false; put(quit, 264, y + 62, 44, 22)
        self.view = root
    }
    func update(memory: MemorySnapshot, disk: DiskSnapshot?, history: [Double]) {
        _ = view
        historyView.values = history; memoryBar.segments = memorySegments(memory)
        for (name, bytes) in [("已用", memory.used), ("App 内存", memory.app), ("联动内存", memory.wired), ("压缩内存", memory.compressed), ("可用", memory.available), ("交换区", memory.swapUsed)] {
            labels[name]?.stringValue = readable(bytes)
        }
        if let disk {
            diskBar.segments = [(CGFloat(Double(disk.used) / Double(max(disk.total, 1))), .systemBlue)]
            diskDetail.stringValue = "已用 \(diskReadable(disk.used)) / 共 \(diskReadable(disk.total)) · 剩余 \(diskReadable(disk.free))"
        }
    }
    func updateProcesses(_ processes: [ProcessSnapshot]) {
        _ = view
        let keys = processes.map(\.key)
        if processRows.map(\.key) == keys {
            for (row, process) in zip(processRows, processes) { row.update(process) }
            return
        }
        for child in processStack.subviews { child.removeFromSuperview() }
        processRows = processes.enumerated().map { index, process in
            let row = ProcessRow(process: process); row.onQuitApp = { [weak self] app in self?.onQuitApp?(app) }
            row.onSelect = { [weak self] in self?.processRows.forEach { $0.cancelSelection() } }
            row.frame = NSRect(x: 0, y: 230 - 27 - CGFloat(index) * 29, width: 292, height: 27)
            processStack.addSubview(row)
            return row
        }
        if processes.isEmpty {
            let label = textLabel("正在读取…", size: 12)
            label.frame = NSRect(x: 0, y: 203, width: 292, height: 27); processStack.addSubview(label)
        }
    }
    @objc private func openSettings() { onSettings?() }
    @objc private func quitClicked() { onQuit?() }
}
final class FlippedView: NSView { override var isFlipped: Bool { true } }
final class CardBackgroundView: NSView {
    var radius: CGFloat = 8
    override func draw(_ dirtyRect: NSRect) {
        NSColor.controlBackgroundColor.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: radius, yRadius: radius).fill()
    }
}

final class SettingsViewController: NSViewController {
    private let content = NSView(frame: NSRect(x: 180, y: 0, width: 720, height: 620))
    private var navigation: [LightButton] = []
    private(set) var page = 0
    private let heading = textLabel("仪表盘", size: 26, weight: .bold)
    private let dashboardPage = NSView()
    private let memoryPage = NSView()
    private let diskPage = NSView()
    private let generalPage = NSView()
    private lazy var ring = RingView()
    private lazy var memoryBar = SegmentBarView()
    private lazy var historyView = HistoryView()
    private lazy var memorySummary = textLabel("—", size: 16)
    private lazy var totalSummary = textLabel("—", size: 14)
    private var memoryDetails: [LightLabel] = []
    private lazy var swapLabel = textLabel("—", size: 15)
    private lazy var diskSummary = textLabel("—", size: 17, weight: .semibold)
    private lazy var diskFree = textLabel("—", size: 12)
    private lazy var diskBar = SegmentBarView()
    private lazy var deviceDisk = textLabel("正在读取容量…", size: 13)
    private lazy var diskUsage = DiskUsageView(frame: NSRect(x: 0, y: 0, width: 660, height: 340))
    private var diskUsageLoaded = false
    private var builtPages: Set<Int> = []
    private var savedSettings = (status: true, interval: 5.0, launch: false, processes: true)
    private lazy var moduleToggle = LightToggle("在顶部菜单栏显示 F / U 内存数字")
    private lazy var launchToggle = LightToggle("登录后自动启动 SlimStats")
    private lazy var processToggle = LightToggle("详情显示应用排行（仅展开时采集）")
    private lazy var intervalPopup = LightPopup()
    var onStatusToggle: ((Bool) -> Void)?
    var onIntervalChange: ((Double) -> Void)?
    var onLaunchToggle: ((Bool) -> Void)?
    var onProcessToggle: ((Bool) -> Void)?
    var onLowResourcePreset: (() -> Void)?
    var onPageChanged: (() -> Void)?

    override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 900, height: 620))
        let sidebar = CardBackgroundView(frame: NSRect(x: 0, y: 0, width: 180, height: 620))
        sidebar.radius = 0
        root.addSubview(sidebar)
        put(textLabel("SlimStats", size: 21, weight: .bold), in: sidebar, x: 22, y: 552, w: 150, h: 32)
        for (index, item) in [("square.grid.2x2", "仪表盘"), ("memorychip", "内存"), ("internaldrive", "磁盘"), ("gearshape", "通用设置")].enumerated() {
            let button = LightButton(title: item.1, image: UIIcon.image(item.0), target: self, action: #selector(navigate(_:)))
            button.imagePosition = .imageLeading; button.imageHugsTitle = true
            button.tag = index; button.isBordered = false; button.alignment = .left
            button.font = NSFont.systemFont(ofSize: 15, weight: .medium)
            put(button, in: sidebar, x: 18, y: 468 - CGFloat(index) * 54, w: 148, h: 38)
            navigation.append(button)
        }
        let hint = textLabel("仅监测内存与储存空间", size: 10); hint.textColor = .secondaryLabelColor
        put(hint, in: sidebar, x: 20, y: 22, w: 155, h: 20)
        root.addSubview(content)
        put(heading, in: content, x: 28, y: 550, w: 460, h: 38)
        let gear = LightButton(image: UIIcon.image("gearshape"), target: self, action: #selector(showGeneral))
        gear.isBordered = false; gear.setAccessibilityLabel("通用设置")
        put(gear, in: content, x: 646, y: 554, w: 35, h: 30)
        for container in [dashboardPage, memoryPage, diskPage, generalPage] {
            container.frame = NSRect(x: 28, y: 22, width: 660, height: 510)
            content.addSubview(container)
        }
        self.view = root
        showPage(0)
    }
    private func put(_ child: NSView, in parent: NSView, x: CGFloat, y: CGFloat, w: CGFloat, h: CGFloat) {
        child.frame = NSRect(x: x, y: y, width: w, height: h); parent.addSubview(child)
    }
    private func card(in parent: NSView, y: CGFloat, h: CGFloat) -> NSView {
        let card = CardBackgroundView(); card.radius = 12
        put(card, in: parent, x: 0, y: y, w: 660, h: h)
        return card
    }
    private func buildDashboard() {
        let device = DeviceInfo.read()
        let document = FlippedView(frame: NSRect(x: 0, y: 0, width: 638, height: 510))
        let image = NSImageView()
        if let artwork = DeviceArtwork.load(model: device.model) { image.image = artwork }
        else { image.image = UIIcon.image("macmini"); image.contentTintColor = .secondaryLabelColor }
        image.imageScaling = .scaleProportionallyUpOrDown
        image.setAccessibilityLabel("\(device.name) 设备外观")
        put(image, in: document, x: 241, y: 0, w: 156, h: 80)
        let name = textLabel(device.name, size: 23, weight: .semibold); name.alignment = .center
        put(name, in: document, x: 0, y: 80, w: 638, h: 30)
        let system = textLabel(device.system, size: 13); system.alignment = .center; system.textColor = .secondaryLabelColor
        put(system, in: document, x: 0, y: 112, w: 638, h: 22)
        let rows: [(String, String, CGFloat)] = [("处理器", device.processor, 50), ("内存", device.memory, 38),
            ("图形", device.graphics, 38), ("磁盘", "", 38), ("显示器", device.displays, 52),
            ("机型标识符", device.model, 38), ("序列号", device.serial, 38), ("本页打开时的运行时长", device.uptime, 38)]
        var y: CGFloat = 140
        for (title, value, height) in rows {
            let row = CardBackgroundView()
            put(row, in: document, x: 0, y: y, w: 638, h: height)
            put(textLabel(title, size: 13), in: row, x: 15, y: (height - 22) / 2, w: 160, h: 22)
            let label = title == "磁盘" ? deviceDisk : textLabel(value, size: 13)
            label.alignment = .right; label.maximumNumberOfLines = 3; label.lineBreakMode = .byTruncatingTail
            put(label, in: row, x: 180, y: 8, w: 440, h: height - 16)
            y += height + 4
        }
        dashboardPage.addSubview(document)
    }
    private func buildMemory() {
        let overview = card(in: memoryPage, y: 336, h: 168)
        put(ring, in: overview, x: 18, y: 24, w: 120, h: 120)
        put(memorySummary, in: overview, x: 159, y: 120, w: 260, h: 24)
        totalSummary.alignment = .right; put(totalSummary, in: overview, x: 465, y: 120, w: 170, h: 24)
        put(memoryBar, in: overview, x: 159, y: 96, w: 476, h: 10)
        for (index, color) in [NSColor.systemBlue, .systemOrange, .systemPink, .secondaryLabelColor].enumerated() {
            let label = textLabel("—", size: 13); label.textColor = color
            put(label, in: overview, x: index % 2 == 0 ? 159 : 401, y: index < 2 ? 60 : 28, w: 240, h: 22)
            memoryDetails.append(label)
        }
        put(textLabel("内存占用历史", size: 15, weight: .semibold), in: memoryPage, x: 0, y: 295, w: 300, h: 24)
        let graph = card(in: memoryPage, y: 110, h: 180)
        historyView.grid = true; put(historyView, in: graph, x: 14, y: 16, w: 632, h: 150)
        put(swapLabel, in: memoryPage, x: 8, y: 64, w: 640, h: 28)
        let note = textLabel("仅当前内存页可见时绘制图表 · 历史上限 120 点", size: 11); note.textColor = .secondaryLabelColor
        put(note, in: memoryPage, x: 8, y: 22, w: 640, h: 25)
    }
    private func buildDisk() {
        let overview = card(in: diskPage, y: 353, h: 151)
        put(textLabel("本机储存空间", size: 14, weight: .semibold), in: overview, x: 20, y: 111, w: 500, h: 24)
        put(diskSummary, in: overview, x: 20, y: 75, w: 610, h: 28)
        put(diskBar, in: overview, x: 20, y: 53, w: 620, h: 10)
        put(diskFree, in: overview, x: 20, y: 16, w: 610, h: 24)
    }
    private func buildGeneral() {
        let group = card(in: generalPage, y: 162, h: 342)
        put(textLabel("菜单栏与采样", size: 17, weight: .semibold), in: group, x: 24, y: 292, w: 500, h: 30)
        moduleToggle.target = self; moduleToggle.action = #selector(statusChanged(_:))
        put(moduleToggle, in: group, x: 24, y: 249, w: 600, h: 26)
        launchToggle.target = self; launchToggle.action = #selector(launchChanged(_:))
        put(launchToggle, in: group, x: 24, y: 209, w: 600, h: 26)
        put(textLabel("内存刷新间隔", size: 14), in: group, x: 24, y: 163, w: 300, h: 28)
        intervalPopup.addItems(withTitles: ["1 秒", "3 秒", "5 秒（推荐）", "10 秒", "30 秒"])
        intervalPopup.target = self; intervalPopup.action = #selector(intervalChanged(_:))
        put(intervalPopup, in: group, x: 453, y: 163, w: 177, h: 28)
        processToggle.target = self; processToggle.action = #selector(processChanged(_:))
        put(processToggle, in: group, x: 24, y: 116, w: 600, h: 26)
        let preset = LightButton(title: "应用低占用设置（10 秒，关闭应用排行）", target: self, action: #selector(applyLowResource))
        put(preset, in: group, x: 20, y: 68, w: 500, h: 28)
        let systemSettings = LightButton(title: "系统菜单栏显示设置…", target: self, action: #selector(openSystemMenuSettings))
        preset.isBordered = true; put(systemSettings, in: group, x: 20, y: 20, w: 230, h: 26)
        let description = LightLabel( "日常推荐 5 秒；更低占用可选 10–30 秒并关闭应用排行。关闭设置窗口会释放界面，菜单栏继续工作。磁盘排行仅手动扫描；关闭窗口会停止扫描并释放结果。1 秒主要增加采样与绘图次数，不会让历史数据无限增长。")
        description.maximumNumberOfLines = 0; description.lineBreakMode = .byWordWrapping
        description.font = NSFont.systemFont(ofSize: 12); description.textColor = .secondaryLabelColor
        put(description, in: generalPage, x: 8, y: 35, w: 636, h: 106)
    }
    func synchronize(status: Bool, interval: Double, launch: Bool, processes: Bool) {
        savedSettings = (status, interval, launch, processes)
        guard builtPages.contains(3) else { return }
        moduleToggle.state = status ? .on : .off; launchToggle.state = launch ? .on : .off
        processToggle.state = processes ? .on : .off
        intervalPopup.selectItem(at: [1.0, 3, 5, 10, 30].firstIndex(of: interval) ?? 2)
    }
    func update(memory: MemorySnapshot, disk: DiskSnapshot?, history: [Double]) {
        guard isViewLoaded else { return }
        if page == 1 {
            memorySummary.stringValue = "已用：\(readable(memory.used))"
            totalSummary.stringValue = "共计：\(readable(memory.total, decimals: 0))"
            memoryBar.segments = memorySegments(memory)
            ring.segments = memorySegments(memory); ring.caption = String(format: "%.0f%%", memory.usage * 100)
            for (label, value) in zip(memoryDetails, ["App 内存：\(readable(memory.app))", "联动内存：\(readable(memory.wired))", "压缩内存：\(readable(memory.compressed))", "可用：\(readable(memory.available))"]) { label.stringValue = value }
            historyView.values = history; swapLabel.stringValue = "交换区已用：\(readable(memory.swapUsed))"
        }
        if let disk {
            if page == 2 {
                diskSummary.stringValue = "已用 \(diskReadable(disk.used)) / 共计 \(diskReadable(disk.total))"
                diskFree.stringValue = "可用：\(diskReadable(disk.free)) · 容量按需刷新，排行需手动扫描"
                diskBar.segments = [(CGFloat(Double(disk.used) / Double(max(disk.total, 1))), .systemBlue)]
            }
            if page == 0 { deviceDisk.stringValue = "Macintosh HD · \(diskReadable(disk.total))（可用 \(diskReadable(disk.free))）" }
        }
    }
    private func showPage(_ selected: Int) {
        if builtPages.insert(selected).inserted {
            switch selected {
            case 0: buildDashboard()
            case 1: buildMemory()
            case 2: buildDisk()
            default:
                buildGeneral()
                synchronize(status: savedSettings.status, interval: savedSettings.interval,
                            launch: savedSettings.launch, processes: savedSettings.processes)
            }
        }
        page = selected; heading.stringValue = ["仪表盘", "内存", "磁盘", "通用设置"][selected]
        dashboardPage.isHidden = selected != 0; memoryPage.isHidden = selected != 1
        diskPage.isHidden = selected != 2; generalPage.isHidden = selected != 3
        if selected == 2 && !diskUsageLoaded { diskPage.addSubview(diskUsage); diskUsageLoaded = true }
        navigation.enumerated().forEach { index, button in
            button.contentTintColor = index == selected ? .controlAccentColor : .labelColor
            button.state = index == selected ? .on : .off
        }
        onPageChanged?()
    }
    func dispose() { if diskUsageLoaded { diskUsage.dispose() } }
    @objc private func openSystemMenuSettings() { NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.ControlCenter-Settings.extension")!) }
    @objc private func navigate(_ sender: LightButton) { showPage(sender.tag) }
    @objc private func showGeneral() { showPage(3) }
    @objc private func statusChanged(_ sender: LightToggle) { onStatusToggle?(sender.state == .on) }
    @objc private func launchChanged(_ sender: LightToggle) { onLaunchToggle?(sender.state == .on) }
    @objc private func processChanged(_ sender: LightToggle) { onProcessToggle?(sender.state == .on) }
    @objc private func intervalChanged(_ sender: LightPopup) { onIntervalChange?([1.0, 3, 5, 10, 30][sender.indexOfSelectedItem]) }
    @objc private func applyLowResource() { onLowResourcePreset?() }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, NSWindowDelegate {
    private let quitter = ApplicationQuitter()
    private var statusItem: NSStatusItem?
    private let detailMenu = NSMenu()
    private let statusContextMenu = NSMenu()
    private var panel: StatsPanelViewController?
    private var settings: SettingsViewController?
    private var settingsWindow: NSWindow?
    private var timer: Timer?
    private var memory: MemorySnapshot?
    private var disk: DiskSnapshot?
    private var history: [Double] = []
    private var detailVisible = false
    private var scanning = false
    private var diskScanning = false
    private var lastDiskRefresh = Date.distantPast
    private var lastProcessRefresh = Date.distantPast
    private var lastStatusText = ""
    private let defaults = UserDefaults.standard
    private var interval: Double { defaults.double(forKey: "refreshInterval") }
    private var statusEnabled: Bool { defaults.bool(forKey: "showMemoryStatus") }
    private var processListEnabled: Bool { defaults.bool(forKey: "showProcessList") }
    private var lowResourceMode: Bool { interval >= 10 && !processListEnabled }
    private var launchEnabled = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        defaults.register(defaults: ["refreshInterval": 5.0, "showMemoryStatus": true, "showProcessList": true])
        launchEnabled = SMAppService.mainApp.status == .enabled
        installMainMenu()
        installStatusContextMenu()
        detailMenu.autoenablesItems = false; detailMenu.delegate = self
        detailMenu.addItem(NSMenuItem(title: "正在读取内存…", action: nil, keyEquivalent: ""))
        refresh(); startTimer()
        DispatchQueue.main.async { [weak self] in
            self?.configureStatusItem()
            // Normal/login launches stay in the menu bar. Reopening the app is
            // still a recovery path if its status item was disabled.
            if CommandLine.arguments.contains("--settings") || self?.statusEnabled == false {
                self?.showSettings()
            }
        }
    }
    private func installMainMenu() {
        let menu = NSMenu(); let item = NSMenuItem(); menu.addItem(item)
        let appMenu = NSMenu(title: "SlimStats"); item.submenu = appMenu
        let settingsItem = NSMenuItem(title: "设置…", action: #selector(settingsClicked), keyEquivalent: ",")
        settingsItem.target = self; appMenu.addItem(settingsItem); appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "退出 SlimStats", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        NSApp.mainMenu = menu
    }
    private func installStatusContextMenu() {
        statusContextMenu.autoenablesItems = false
        let settingsItem = NSMenuItem(title: "设置…", action: #selector(settingsClicked), keyEquivalent: "")
        settingsItem.target = self; statusContextMenu.addItem(settingsItem)
        statusContextMenu.addItem(.separator())
        statusContextMenu.addItem(withTitle: "退出 SlimStats", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "")
    }
    private func menuForStatusClick(_ event: NSEvent?) -> NSMenu {
        let contextClick = event?.type == .rightMouseUp || event?.modifierFlags.contains(.control) == true
        return contextClick ? statusContextMenu : detailMenu
    }
    @objc private func statusClicked(_ sender: NSStatusBarButton) {
        let menu = menuForStatusClick(NSApp.currentEvent)
        sender.highlight(true)
        defer { sender.highlight(false) }
        // Present at the status button so both menus remain attached to F/U.
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.minY), in: sender)
    }
    private func configureStatusItem() {
        if !statusEnabled {
            if let statusItem { NSStatusBar.system.removeStatusItem(statusItem) }
            statusItem = nil; lastStatusText = ""; return
        }
        if statusItem == nil {
            let item = NSStatusBar.system.statusItem(withLength: 82)
            item.autosaveName = "SlimStats.Memory.v2"; item.isVisible = true
            item.button?.target = self; item.button?.action = #selector(statusClicked(_:))
            item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
            item.button?.imagePosition = .imageOnly; item.button?.imageScaling = .scaleNone
            item.button?.toolTip = "SlimStats · F 空闲 / U 已用 · 左键查看详情，右键打开设置"
            item.button?.setAccessibilityLabel("SlimStats 内存详情"); statusItem = item
        }
        updateStatusImage()
    }
    private func updateStatusImage() {
        guard let button = statusItem?.button else { return }
        let free = memory.map { String(format: "%.2f", Double($0.available) / bytesPerGB) } ?? "—"
        let used = memory.map { String(format: "%.2f", Double($0.used) / bytesPerGB) } ?? "—"
        let text = free + "\n" + used
        guard text != lastStatusText else { return }
        lastStatusText = text
        let image = NSImage(size: NSSize(width: 76, height: 22), flipped: false) { _ in
            let font = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .medium)
            // Keep values right aligned and GB in a fixed column, even below 1 GB.
            let valueRight: CGFloat = 52
            let unitLeft: CGFloat = 56
            for (label, value, y) in [("F:", free, CGFloat(10)), ("U:", used, CGFloat(0))] {
                LightText.draw(label, in: NSRect(x: 0, y: y, width: 17, height: 12), font: font, color: .black)
                LightText.draw(value, in: NSRect(x: 18, y: y, width: valueRight - 18, height: 12), font: font, color: .black, alignment: .right)
                LightText.draw("GB", in: NSRect(x: unitLeft, y: y, width: 20, height: 12), font: font, color: .black)
            }
            return true
        }
        image.isTemplate = true; button.image = image
        button.setAccessibilityValue("F: \(free) GB，U: \(used) GB")
    }
    private func startTimer() {
        timer?.invalidate()
        let period = [1.0, 3, 5, 10, 30].contains(interval) ? interval : 5
        let timer = Timer(timeInterval: period, repeats: true) { [weak self] _ in autoreleasepool { self?.refresh() } }
        timer.tolerance = min(period * 0.2, 1)
        RunLoop.main.add(timer, forMode: .common); self.timer = timer
    }
    private func refresh() {
        if let snapshot = SystemMetrics.memory() {
            memory = snapshot; history.append(snapshot.usage)
            if history.count > 120 { history.removeFirst(history.count - 120) }
            updateStatusImage(); updateViews()
        }
        refreshDiskIfNeeded()
        if detailVisible { reloadProcesses() }
    }
    private func refreshDiskIfNeeded() {
        let needsDisk = detailVisible || (settingsWindow?.isVisible == true && [0, 2].contains(settings?.page ?? -1))
        guard needsDisk, !diskScanning, Date().timeIntervalSince(lastDiskRefresh) >= (lowResourceMode ? 300 : 60) else { return }
        diskScanning = true; lastDiskRefresh = Date()
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let snapshot = autoreleasepool { SystemMetrics.disk() }
            DispatchQueue.main.async {
                guard let self else { return }
                self.diskScanning = false; self.disk = snapshot; self.updateViews(includeStatic: true)
            }
        }
    }
    private func updateViews(includeStatic: Bool = false) {
        guard let memory else { return }
        if settingsWindow?.isVisible == true, settings?.page == 1 || includeStatic { settings?.update(memory: memory, disk: disk, history: history) }
        if detailVisible { panel?.update(memory: memory, disk: disk, history: history) }
    }
    func menuNeedsUpdate(_ menu: NSMenu) { if menu === detailMenu { preparePanel() } }
    private func preparePanel() {
        guard panel == nil else { return }
        let controller = StatsPanelViewController(showProcesses: processListEnabled)
        controller.onSettings = { [weak self] in self?.detailMenu.cancelTracking(); self?.showSettings() }
        controller.onQuit = { [weak self] in self?.detailMenu.cancelTracking(); NSApp.terminate(nil) }
        controller.onQuitApp = { [weak self] app in self?.quitApplication(app) }
        detailMenu.removeAllItems()
        let item = NSMenuItem(); item.view = controller.view; detailMenu.addItem(item)
        panel = controller
    }
    func menuWillOpen(_ menu: NSMenu) {
        guard menu === detailMenu else { return }
        preparePanel(); detailVisible = true; lastProcessRefresh = .distantPast
        updateViews(); refreshDiskIfNeeded(); reloadProcesses()
    }
    func menuDidClose(_ menu: NSMenu) {
        guard menu === detailMenu else { return }
        detailVisible = false
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.detailVisible else { return }
            self.detailMenu.removeAllItems(); self.panel = nil
            self.detailMenu.addItem(NSMenuItem(title: "正在读取内存…", action: nil, keyEquivalent: ""))
            self.releaseUnusedMemory()
        }
    }
    private func reloadProcesses() {
        guard processListEnabled, !scanning, detailVisible, Date().timeIntervalSince(lastProcessRefresh) >= 5 else { return }
        scanning = true; lastProcessRefresh = Date()
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let processes = autoreleasepool { SystemMetrics.topProcesses() }
            DispatchQueue.main.async {
                guard let self else { return }
                self.scanning = false
                if self.detailVisible, self.processListEnabled { self.panel?.updateProcesses(processes) }
            }
        }
    }
    private func quitApplication(_ target: ProcessExitTarget) {
        guard target.blockedReason == nil, target.isRunning else { return }
        detailMenu.cancelTracking()
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let alert = QuitConfirmation(message: "\(target.application == nil ? "结束" : "关闭")“\(target.name)”？",
                                         detail: target.confirmationDetail,
                                         confirmTitle: target.application == nil ? "结束进程" : "关闭应用")
            guard alert.runModal() else { return }
            self.quitter.close(target) { result in
                guard case .failed(let reason) = result else { return }
                let failure = QuitConfirmation(message: "未能结束“\(target.name)”",
                    detail: reason, confirmTitle: "知道了", cancellable: false)
                _ = failure.runModal()
            }
        }
    }
    @objc private func settingsClicked() { showSettings() }
    private func showSettings() {
        if settingsWindow == nil {
            let controller = SettingsViewController()
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 620), styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
            window.title = "SlimStats — 设置"; window.isReleasedWhenClosed = false
            window.delegate = self; window.contentViewController = controller; window.center()
            settings = controller; settingsWindow = window
            controller.onStatusToggle = { [weak self] enabled in
                guard let self else { return }
                self.defaults.set(enabled, forKey: "showMemoryStatus"); self.configureStatusItem()
            }
            controller.onIntervalChange = { [weak self] value in
                guard let self else { return }
                self.defaults.set(value, forKey: "refreshInterval"); self.startTimer()
            }
            controller.onLaunchToggle = { [weak self] enabled in self?.setLaunchAtLogin(enabled) }
            controller.onProcessToggle = { [weak self] enabled in self?.defaults.set(enabled, forKey: "showProcessList") }
            controller.onLowResourcePreset = { [weak self] in
                guard let self else { return }
                self.defaults.set(10.0, forKey: "refreshInterval"); self.defaults.set(false, forKey: "showProcessList")
                self.startTimer(); self.synchronizeSettings()
            }
            controller.onPageChanged = { [weak self] in self?.updateViews(includeStatic: true); self?.refreshDiskIfNeeded() }
        }
        synchronizeSettings()
        settingsWindow?.deminiaturize(nil); settingsWindow?.makeKeyAndOrderFront(nil)
        updateViews(includeStatic: true); refreshDiskIfNeeded(); NSApp.activate(ignoringOtherApps: true)
    }
    private func synchronizeSettings() {
        settings?.synchronize(status: statusEnabled, interval: interval, launch: launchEnabled, processes: processListEnabled)
    }
    func windowWillClose(_ notification: Notification) {
        guard let closing = notification.object as? NSWindow, closing === settingsWindow else { return }
        settings?.dispose()
        DispatchQueue.main.async { [weak self] in
            guard let self, self.settingsWindow === closing, !closing.isVisible else { return }
            closing.contentViewController = nil; self.settingsWindow = nil; self.settings = nil
            self.releaseUnusedMemory()
        }
    }
    private func releaseUnusedMemory() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            guard let self, !self.detailVisible, self.settingsWindow?.isVisible != true else { return }
            // Return free allocator pages after UI teardown, never on the sampling path.
            DispatchQueue.global(qos: .utility).async { _ = malloc_zone_pressure_relief(nil, 0) }
        }
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { showSettings(); return true }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationWillTerminate(_ notification: Notification) { settings?.dispose() }
    private func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            let alert = NSAlert(); alert.messageText = "无法更新开机启动设置"; alert.informativeText = error.localizedDescription
            if let settingsWindow { alert.beginSheetModal(for: settingsWindow) }
        }
        launchEnabled = SMAppService.mainApp.status == .enabled; synchronizeSettings()
    }
}

let application = NSApplication.shared
application.setActivationPolicy(.accessory)
let delegate = AppDelegate()
application.delegate = delegate
application.run()
