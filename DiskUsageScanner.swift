import Foundation
import Darwin

final class ScanCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var stopped = false
    func cancel() { lock.lock(); stopped = true; lock.unlock() }
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return stopped }
}

struct DiskUsageEntry {
    let path: String
    let bytes: UInt64
    let isDirectory: Bool
    var name: String { URL(fileURLWithPath: path).lastPathComponent }
}

struct DiskUsageResult {
    let root: String
    let entries: [DiskUsageEntry]
    let largestFiles: [DiskUsageEntry]
    let total: UInt64
    let files: Int
    let errors: Int
    let cancelled: Bool
    let limited: Bool
    let duration: TimeInterval
}

enum DiskUsageScanner {
    // Traverse metadata only. No file content, symlink following, external-volume traversal,
    // or persistent full-tree index. Keep just child totals and the largest 30 files.
    static func scan(root: String, cancellation: ScanCancellation,
                     progress: (Int, UInt64) -> Void = { _, _ in }) -> DiskUsageResult {
        let began = Date()
        var entries: [String: (UInt64, Bool)] = [:]
        var largest: [DiskUsageEntry] = []
        var files = 0, errors = 0
        var total: UInt64 = 0
        var currentChild = ""
        var limited = false
        var hardlinks = Set<String>()
        var lastProgress = began
        let rootPath = URL(fileURLWithPath: root).standardizedFileURL.path
        var rootStat = stat()
        guard lstat(rootPath, &rootStat) == 0, (rootStat.st_mode & S_IFMT) == S_IFDIR else {
            return DiskUsageResult(root: rootPath, entries: [], largestFiles: [], total: 0, files: 0, errors: 1, cancelled: false, limited: false, duration: 0)
        }
        guard let path = strdup(rootPath) else {
            return DiskUsageResult(root: rootPath, entries: [], largestFiles: [], total: 0, files: 0, errors: 1, cancelled: false, limited: false, duration: 0)
        }
        defer { free(path) }
        var arguments: [UnsafeMutablePointer<CChar>?] = [path, nil]
        let handle = arguments.withUnsafeMutableBufferPointer { fts_open($0.baseAddress, FTS_PHYSICAL | FTS_NOCHDIR | FTS_XDEV, nil) }
        guard let handle else {
            return DiskUsageResult(root: rootPath, entries: [], largestFiles: [], total: 0, files: 0, errors: 1, cancelled: false, limited: false, duration: Date().timeIntervalSince(began))
        }
        defer { fts_close(handle) }
        while !cancellation.isCancelled {
            errno = 0
            guard let pointer = fts_read(handle) else {
                if errno != 0 { errors += 1 }
                break
            }
            let entry = pointer.pointee
            let kind = Int32(entry.fts_info)
            if [FTS_ERR, FTS_DNR, FTS_NS, FTS_DC].contains(kind) { errors += 1; continue }
            if entry.fts_level == 0 { continue }
            if kind == FTS_DP || kind == FTS_SL || kind == FTS_SLNONE { continue }
            if entry.fts_level == 1 {
                currentChild = String(cString: entry.fts_path)
                if entries[currentChild] == nil {
                    if entries.count < 4096 { entries[currentChild] = (0, kind == FTS_D) }
                    else { limited = true; currentChild = "其他项目（超过 4096 项）" }
                }
            }
            guard kind == FTS_F, let stat = entry.fts_statp?.pointee else { continue }
            if stat.st_nlink > 1 {
                let key = "\(stat.st_dev):\(stat.st_ino)"
                if hardlinks.contains(key) { continue }
                if hardlinks.count < 20_000 { hardlinks.insert(key) }
                else { limited = true }
            }
            let bytes = UInt64(max(stat.st_blocks, 0)) * 512
            total += bytes; files += 1
            let existing = entries[currentChild] ?? (0, false)
            entries[currentChild] = (existing.0 + bytes, existing.1)
            if bytes > 0 && (largest.count < 30 || bytes > (largest.last?.bytes ?? 0)) {
                largest.append(DiskUsageEntry(path: String(cString: entry.fts_path), bytes: bytes, isDirectory: false))
                largest.sort { $0.bytes > $1.bytes }
                if largest.count > 30 { largest.removeLast() }
            }
            if files % 256 == 0 && Date().timeIntervalSince(lastProgress) >= 0.5 {
                lastProgress = Date(); progress(files, total)
            }
        }
        let ranked = entries.map { DiskUsageEntry(path: $0.key, bytes: $0.value.0, isDirectory: $0.value.1) }
            .sorted { $0.bytes > $1.bytes }.prefix(100)
        return DiskUsageResult(root: rootPath, entries: Array(ranked), largestFiles: largest, total: total,
                               files: files, errors: errors, cancelled: cancellation.isCancelled,
                               limited: limited, duration: Date().timeIntervalSince(began))
    }
}
