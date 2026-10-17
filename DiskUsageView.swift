import AppKit

final class DiskUsageView: NSView, NSTableViewDataSource, NSTableViewDelegate {
    private let scope = LightPopup()
    private let scanButton = LightButton(title: "开始扫描", target: nil, action: nil)
    private let cancelButton = LightButton(title: "停止", target: nil, action: nil)
    private let pathLabel = textLabel("", size: 10)
    private let statusLabel = textLabel("手动扫描后显示占用排行，不会删除任何内容。", size: 11)
    private let mode = LightSegments(labels: ["本层占用前 100", "最大文件前 30"])
    private let table = NSTableView()
    private let revealButton = LightButton(title: "在 Finder 中显示", target: nil, action: nil)
    private let enterButton = LightButton(title: "检查此文件夹", target: nil, action: nil)
    private var root = FileManager.default.homeDirectoryForCurrentUser.path
    private var result: DiskUsageResult?
    private var cancellation: ScanCancellation?
    private var rows: [DiskUsageEntry] { mode.selectedSegment == 1 ? result?.largestFiles ?? [] : result?.entries ?? [] }

    override init(frame: NSRect) {
        super.init(frame: frame)
        for button in [scanButton, cancelButton, revealButton, enterButton] { button.isBordered = true }
        scope.addItems(withTitles: ["用户文件夹", "应用程序", "数据卷（全盘，较慢）", "选择文件夹…"])
        scope.target = self; scope.action = #selector(scopeChanged)
        put(scope, x: 0, y: 307, w: 310, h: 28)
        scanButton.target = self; scanButton.action = #selector(startScan)
        put(scanButton, x: 427, y: 307, w: 126, h: 28)
        cancelButton.target = self; cancelButton.action = #selector(cancelScan)
        cancelButton.isEnabled = false; put(cancelButton, x: 560, y: 307, w: 98, h: 28)
        pathLabel.lineBreakMode = .byTruncatingMiddle; pathLabel.textColor = .secondaryLabelColor
        put(pathLabel, x: 2, y: 283, w: 650, h: 19)
        statusLabel.lineBreakMode = .byTruncatingTail
        put(statusLabel, x: 2, y: 258, w: 650, h: 20)
        mode.selectedSegment = 0; mode.target = self; mode.action = #selector(modeChanged)
        put(mode, x: 0, y: 222, w: 280, h: 27)
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 53, width: 660, height: 164))
        scroll.hasVerticalScroller = true; scroll.borderType = .bezelBorder
        let name = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("name")); name.title = "项目 / 路径"; name.width = 510
        let size = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("size")); size.title = "已分配空间"; size.width = 125
        table.addTableColumn(name); table.addTableColumn(size)
        table.headerView = NSTableHeaderView(); table.rowHeight = 35
        table.usesAlternatingRowBackgroundColors = true
        table.delegate = self; table.dataSource = self
        table.target = self; table.doubleAction = #selector(openSelected)
        scroll.documentView = table; addSubview(scroll)
        revealButton.target = self; revealButton.action = #selector(revealSelected); revealButton.isEnabled = false
        put(revealButton, x: 0, y: 20, w: 172, h: 26)
        enterButton.target = self; enterButton.action = #selector(enterSelected); enterButton.isEnabled = false
        put(enterButton, x: 176, y: 20, w: 160, h: 26)
        let note = textLabel("按文件已分配空间统计 · APFS 共享块等可能使合计与全盘已用不同", size: 10)
        note.textColor = .secondaryLabelColor; put(note, x: 2, y: 0, w: 650, h: 17)
        updatePath()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    private func put(_ child: NSView, x: CGFloat, y: CGFloat, w: CGFloat, h: CGFloat) {
        child.frame = NSRect(x: x, y: y, width: w, height: h); addSubview(child)
    }
    private func updatePath() { pathLabel.stringValue = root; pathLabel.toolTip = root }
    @objc private func scopeChanged() {
        switch scope.indexOfSelectedItem {
        case 0: root = FileManager.default.homeDirectoryForCurrentUser.path
        case 1: root = "/Applications"
        case 2: root = "/System/Volumes/Data"
        default:
            let picker = NSOpenPanel(); picker.canChooseFiles = false; picker.canChooseDirectories = true
            picker.allowsMultipleSelection = false; picker.prompt = "检查此文件夹"
            picker.directoryURL = URL(fileURLWithPath: root)
            if picker.runModal() == .OK, let url = picker.url { root = url.path }
        }
        result = nil; table.reloadData(); updatePath(); updateSelection()
        statusLabel.stringValue = "点击“开始扫描”检查此范围。"
    }
    @objc func startScan() {
        guard cancellation == nil else { return }
        let token = ScanCancellation(); cancellation = token
        scanButton.isEnabled = false; scope.isEnabled = false; cancelButton.isEnabled = true
        result = nil; table.reloadData(); updateSelection(); statusLabel.stringValue = "正在扫描…"
        let path = root
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let scanned = autoreleasepool {
                DiskUsageScanner.scan(root: path, cancellation: token) { count, bytes in
                    DispatchQueue.main.async { [weak self] in
                        guard let self, self.cancellation === token else { return }
                        self.statusLabel.stringValue = "扫描中：\(count) 个文件 · 已分配 \(readable(bytes))"
                    }
                }
            }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.cancellation === token else { return }
                self.result = scanned; self.cancellation = nil
                self.scanButton.isEnabled = true; self.scope.isEnabled = true; self.cancelButton.isEnabled = false
                let state = scanned.cancelled ? "已停止（部分结果）" : "扫描完成"
                let skipped = scanned.errors > 0 ? " · \(scanned.errors) 项无法读取，结果不完整" : ""
                let limit = scanned.limited ? " · 部分结果已合并" : ""
                self.statusLabel.stringValue = "\(state)：\(scanned.files) 文件 · \(readable(scanned.total))\(skipped)\(limit)"
                self.statusLabel.toolTip = self.statusLabel.stringValue + "。按已分配空间统计；APFS 共享块、系统快照和其他范围未计入，合计不等同于全盘已用。"
                self.table.reloadData(); self.updateSelection()
            }
        }
    }
    @objc private func cancelScan() { cancellation?.cancel(); statusLabel.stringValue = "正在停止…" }
    func dispose() { cancellation?.cancel(); cancellation = nil; result = nil }
    @objc private func modeChanged() { table.reloadData(); updateSelection() }
    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard rows.indices.contains(row) else { return nil }
        let entry = rows[row]
        let identifier = tableColumn?.identifier ?? NSUserInterfaceItemIdentifier("name")
        let label = (tableView.makeView(withIdentifier: identifier, owner: self) as? LightLabel) ?? textLabel("", size: 11)
        label.identifier = identifier; label.lineBreakMode = .byTruncatingMiddle
        if identifier.rawValue == "size" {
            label.stringValue = readable(entry.bytes); label.alignment = .right
            label.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        } else {
            let relative = entry.path.hasPrefix(root + "/") ? String(entry.path.dropFirst(root.count + 1)) : entry.path
            label.stringValue = (entry.isDirectory ? "▸ " : "") + relative
            label.alignment = .left
        }
        label.toolTip = entry.path
        return label
    }
    func tableViewSelectionDidChange(_ notification: Notification) { updateSelection() }
    private func selected() -> DiskUsageEntry? { rows.indices.contains(table.selectedRow) ? rows[table.selectedRow] : nil }
    private func updateSelection() {
        let entry = selected()
        revealButton.isEnabled = entry?.path.hasPrefix("/") == true
        enterButton.isEnabled = entry?.isDirectory == true && entry?.path.hasPrefix("/") == true && cancellation == nil
    }
    @objc private func revealSelected() {
        if let entry = selected(), entry.path.hasPrefix("/") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: entry.path)]) }
    }
    @objc private func enterSelected() {
        guard let entry = selected(), entry.isDirectory, cancellation == nil else { return }
        root = entry.path; updatePath(); startScan()
    }
    @objc private func openSelected() {
        if selected()?.isDirectory == true { enterSelected() } else { revealSelected() }
    }
}
