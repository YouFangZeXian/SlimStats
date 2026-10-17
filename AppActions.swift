import AppKit
import ImageIO
import Darwin

// Decode just the small icon used by a row. Avoid IconServices' multi-size icon cache.
enum SmallAppIcon {
    static func load(bundlePath: String?, name: String) -> NSImage {
        if let bundlePath, let bundle = Bundle(path: bundlePath),
           let file = bundle.object(forInfoDictionaryKey: "CFBundleIconFile") as? String {
            let filename = (file as NSString).pathExtension.isEmpty ? file + ".icns" : file
            let url = URL(fileURLWithPath: bundlePath).appendingPathComponent("Contents/Resources").appendingPathComponent(filename)
            if let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
               let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceThumbnailMaxPixelSize: 48,
                    kCGImageSourceShouldCacheImmediately: true
               ] as CFDictionary) {
                return NSImage(cgImage: image, size: NSSize(width: 24, height: 24))
            }
        }
        return NSImage(size: NSSize(width: 24, height: 24), flipped: false) { _ in
            NSColor.secondaryLabelColor.withAlphaComponent(0.15).setFill()
            NSBezierPath(roundedRect: NSRect(x: 2, y: 2, width: 20, height: 20), xRadius: 5, yRadius: 5).fill()
            LightText.draw(String(name.prefix(1)).uppercased(), in: NSRect(x: 0, y: 0, width: 24, height: 24), font: NSFont.systemFont(ofSize: 12, weight: .semibold), color: .labelColor, alignment: .center)
            return true
        }
    }
}

func sameApplicationBundle(_ lhs: String?, _ rhs: String?) -> Bool {
    guard let lhs, let rhs else { return false }
    if lhs == rhs { return true }
    return URL(fileURLWithPath: lhs).resolvingSymlinksInPath().path == URL(fileURLWithPath: rhs).resolvingSymlinksInPath().path
}

// Capture the start time as well as the PID: a refreshed list must not redirect an
// armed quit action to a later process that happens to reuse the same PID.
struct ProcessIdentity: Equatable {
    let pid: pid_t
    let executable: String
    let uid: uid_t
    let realUID: uid_t
    let startSeconds: UInt64
    let startMicroseconds: UInt64

    private static func info(_ pid: pid_t) -> proc_bsdinfo? {
        var info = proc_bsdinfo()
        let size = MemoryLayout<proc_bsdinfo>.size
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(size)) == size else { return nil }
        return info
    }
    static func capture(_ pid: pid_t) -> ProcessIdentity? {
        guard pid > 0, let info = info(pid), info.pbi_status != SZOMB else { return nil }
        var path = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        guard proc_pidpath(pid, &path, UInt32(path.count)) > 0,
              let after = self.info(pid), after.pbi_start_tvsec == info.pbi_start_tvsec,
              after.pbi_start_tvusec == info.pbi_start_tvusec else { return nil }
        return ProcessIdentity(pid: pid, executable: String(cString: path), uid: info.pbi_uid,
                               realUID: info.pbi_ruid, startSeconds: info.pbi_start_tvsec,
                               startMicroseconds: info.pbi_start_tvusec)
    }
    enum State { case running, exited, unavailable }
    var state: State {
        guard let info = Self.info(pid) else {
            // Only ESRCH is proof of exit. Permission/read failures are not success.
            return errno == ESRCH ? .exited : .unavailable
        }
        guard info.pbi_start_tvsec == startSeconds, info.pbi_start_tvusec == startMicroseconds,
              info.pbi_status != SZOMB else { return .exited }
        guard let current = Self.capture(pid) else { return .unavailable }
        return current == self ? .running : .unavailable
    }
    var blockedReason: String? {
        if pid == getpid() { return "这是 SlimStats 自身；请使用详情底部的退出按钮。" }
        let name = (executable as NSString).lastPathComponent
        if pid <= 1 || ["/sbin/launchd", "/System/Library/CoreServices/loginwindow.app/Contents/MacOS/loginwindow",
                        "/System/Library/PrivateFrameworks/SkyLight.framework/Resources/WindowServer"].contains(executable) {
            return "\(name) 负责系统或登录会话，不能从内存排行结束。"
        }
        if uid != getuid() && realUID != getuid() {
            return "此进程属于系统或其他用户（UID \(uid)），SlimStats 没有结束权限。"
        }
        return nil
    }
}

final class ProcessExitTarget {
    let identity: ProcessIdentity
    let application: NSRunningApplication?
    let grouped: Bool
    var name: String { application?.localizedName ?? (identity.executable as NSString).lastPathComponent }
    var blockedReason: String? { identity.blockedReason }
    var isRunning: Bool { application?.isTerminated != true && identity.state == .running }
    init(identity: ProcessIdentity, bundlePath: String?) {
        self.identity = identity; grouped = bundlePath != nil
        if let candidate = NSRunningApplication(processIdentifier: identity.pid),
           let bundlePath, sameApplicationBundle(candidate.bundleURL?.path, bundlePath), !candidate.isTerminated {
            application = candidate
        } else { application = nil }
    }
    var confirmationDetail: String {
        let target = "\(application == nil ? "进程" : "应用") · PID \(identity.pid)"
        let scope = application == nil && grouped ? "仅结束此进程，排行是应用合计。" : ""
        return "\(target)\n\(scope)先请求退出，5 秒未退出则强制结束。未保存内容可能丢失；后台服务可能自动重启。"
    }
}

final class ApplicationQuitter {
    enum Result { case exited, forced, failed(String) }
    private var pending: Set<pid_t> = []

    // The caller confirms the concrete target. Every signal rechecks its identity.
    func close(_ target: ProcessExitTarget, gracePeriod: TimeInterval = 5,
               completion: @escaping (Result) -> Void) {
        let identity = target.identity
        let pid = identity.pid
        if let reason = target.blockedReason { completion(.failed(reason)); return }
        if identity.state == .exited || target.application?.isTerminated == true { completion(.exited); return }
        guard identity.state == .running else { completion(.failed("无法核实原进程身份，未发送退出指令。")); return }
        guard pending.insert(pid).inserted else { completion(.failed("此进程正在退出，请稍候。")); return }
        func send(_ force: Bool) -> Result? {
            switch identity.state {
            case .exited: return force ? .forced : .exited
            case .unavailable: return .failed("无法核实原进程身份，已停止退出操作。")
            case .running: break
            }
            guard let current = ProcessIdentity.capture(pid), current == identity else {
                return identity.state == .exited ? (force ? .forced : .exited) : .failed("进程身份发生变化，未发送退出指令。")
            }
            if let reason = current.blockedReason { return .failed(reason) }
            if let app = target.application {
                // Retain the original AppKit object, never re-resolve by application name.
                if app.isTerminated { return force ? .forced : .exited }
                let accepted = force ? app.forceTerminate() : app.terminate()
                if force && !accepted && !app.isTerminated { return .failed("macOS 未允许强制退出此应用。") }
            } else if Darwin.kill(pid, force ? SIGKILL : SIGTERM) != 0 {
                let error = errno
                if error == ESRCH { return force ? .forced : .exited }
                return .failed(error == EPERM ? "macOS 拒绝结束此进程，当前用户没有权限或该进程受系统保护。" : "发送退出指令失败（错误 \(error)）。")
            }
            return nil
        }
        if let result = send(false) { pending.remove(pid); completion(result); return }
        let deadline = Date().addingTimeInterval(gracePeriod)
        var forced = false
        var forcedAt: Date?
        let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] timer in
            func finish(_ result: Result) {
                timer.invalidate(); self?.pending.remove(pid); completion(result)
            }
            if target.application?.isTerminated == true || identity.state == .exited {
                finish(forced ? .forced : .exited)
            } else if identity.state == .unavailable {
                finish(.failed("无法继续核实进程状态，未将此次操作报告为成功。"))
            } else if !forced && Date() >= deadline {
                forced = true; forcedAt = Date()
                if let result = send(true) { finish(result) }
            } else if let forcedAt, Date().timeIntervalSince(forcedAt) >= 2 {
                finish(.failed("原进程仍在运行，macOS 未完成退出。"))
            }
        }
        timer.tolerance = 0.05
        RunLoop.main.add(timer, forMode: .common)
    }
}

// Small vector drawings keep these few controls independent of the symbol catalog.
enum UIIcon {
    static func image(_ name: String) -> NSImage {
        let image = NSImage(size: NSSize(width: 24, height: 24), flipped: false) { _ in
            NSColor.labelColor.setStroke(); NSColor.labelColor.setFill()
            func stroke(_ rect: NSRect, radius: CGFloat = 2) {
                let path = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
                path.lineWidth = 1.5; path.stroke()
            }
            func line(_ from: NSPoint, _ to: NSPoint) {
                let path = NSBezierPath(); path.move(to: from); path.line(to: to)
                path.lineWidth = 1.5; path.lineCapStyle = .round; path.stroke()
            }
            switch name {
            case "square.grid.2x2":
                for x in [CGFloat(3), 14] { for y in [CGFloat(3), 14] { stroke(NSRect(x: x, y: y, width: 7, height: 7), radius: 1) } }
            case "memorychip":
                stroke(NSRect(x: 6, y: 6, width: 12, height: 12))
                stroke(NSRect(x: 9, y: 9, width: 6, height: 6), radius: 0.5)
                for p in [CGFloat(8), 12, 16] {
                    line(NSPoint(x: p, y: 3), NSPoint(x: p, y: 6)); line(NSPoint(x: p, y: 18), NSPoint(x: p, y: 21))
                    line(NSPoint(x: 3, y: p), NSPoint(x: 6, y: p)); line(NSPoint(x: 18, y: p), NSPoint(x: 21, y: p))
                }
            case "internaldrive":
                stroke(NSRect(x: 3, y: 5, width: 18, height: 14))
                line(NSPoint(x: 3, y: 10), NSPoint(x: 21, y: 10))
                NSBezierPath(ovalIn: NSRect(x: 16, y: 6.5, width: 2, height: 2)).fill()
            case "macmini":
                stroke(NSRect(x: 2, y: 4, width: 20, height: 15), radius: 3)
                line(NSPoint(x: 2, y: 8), NSPoint(x: 22, y: 8))
                NSBezierPath(ovalIn: NSRect(x: 18, y: 5.5, width: 1, height: 1)).fill()
            default:
                let gear = NSBezierPath()
                for i in 0..<48 {
                    let angle = CGFloat(i) * .pi / 24
                    let radius: CGFloat = [0, 3].contains(i % 6) ? 8 : 10
                    let point = NSPoint(x: 12 + cos(angle) * radius, y: 12 + sin(angle) * radius)
                    if i == 0 { gear.move(to: point) } else { gear.line(to: point) }
                }
                gear.close(); gear.lineWidth = 1.5; gear.stroke()
                NSBezierPath(ovalIn: NSRect(x: 8, y: 8, width: 8, height: 8)).stroke()
            }
            return true
        }
        image.cacheMode = .never
        return image
    }
}

final class QuitConfirmation: NSObject, NSWindowDelegate {
    private final class Panel: NSPanel {
        override func cancelOperation(_ sender: Any?) { NSApp.stopModal(withCode: .cancel) }
    }
    private let panel: NSPanel
    init(message: String, detail: String, confirmTitle: String = "关闭应用", cancellable: Bool = true) {
        panel = Panel(contentRect: NSRect(x: 0, y: 0, width: 430, height: 226),
                      styleMask: [.titled, .closable], backing: .buffered, defer: false)
        super.init()
        panel.title = "SlimStats"; panel.isReleasedWhenClosed = false; panel.delegate = self
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 430, height: 226))
        let heading = textLabel(message, size: 17, weight: .semibold)
        heading.frame = NSRect(x: 24, y: 172, width: 382, height: 30); root.addSubview(heading)
        let body = textLabel(detail, size: 13)
        body.maximumNumberOfLines = 0; body.lineBreakMode = .byWordWrapping
        body.frame = NSRect(x: 24, y: 64, width: 382, height: 100); root.addSubview(body)
        let confirm = LightButton(title: confirmTitle, target: self, action: #selector(confirmed))
        confirm.isBordered = true; confirm.contentTintColor = cancellable ? .systemRed : .controlAccentColor
        confirm.frame = NSRect(x: 266, y: 22, width: 140, height: 30); root.addSubview(confirm)
        if cancellable {
            let cancel = LightButton(title: "取消", target: self, action: #selector(cancelled))
            cancel.isBordered = true; cancel.frame = NSRect(x: 166, y: 22, width: 88, height: 30); root.addSubview(cancel)
            panel.initialFirstResponder = cancel
        } else { panel.initialFirstResponder = confirm }
        panel.contentView = root; panel.center()
    }
    func runModal() -> Bool {
        panel.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
        let response = NSApp.runModal(for: panel)
        panel.close()
        return response == .OK
    }
    @objc private func confirmed() { NSApp.stopModal(withCode: .OK) }
    @objc private func cancelled() { NSApp.stopModal(withCode: .cancel) }
    func windowWillClose(_ notification: Notification) {
        if NSApp.modalWindow === panel { NSApp.stopModal(withCode: .cancel) }
    }
}
