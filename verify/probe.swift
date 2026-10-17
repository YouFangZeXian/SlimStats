// 数据口径验证探针：确认文档中引用的 API 与字段在目标机器上可用、数值合理
import Foundation
import Darwin

func hostPageSize() -> UInt64 {
    var ps: vm_size_t = 0
    host_page_size(mach_host_self(), &ps)
    return UInt64(ps)
}

func readSwapUsed() -> UInt64 {
    var mib: [Int32] = [CTL_VM, VM_SWAPUSAGE]
    var xsu = xsw_usage()
    var size = MemoryLayout<xsw_usage>.size
    let rc = sysctl(&mib, 2, &xsu, &size, nil, 0)
    return rc == 0 ? xsu.xsu_used : 0
}

func readMemory() {
    var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
    var vmstat = vm_statistics64_data_t()
    let kr = withUnsafeMutablePointer(to: &vmstat) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
        }
    }
    guard kr == KERN_SUCCESS else { print("host_statistics64 failed"); return }
    let ps = hostPageSize()
    let total = ProcessInfo.processInfo.physicalMemory
    let compressed = min(UInt64(vmstat.compressor_page_count) * ps, total)
    let wired = min(UInt64(vmstat.wire_count) * ps, total - compressed)
    let occupied = (Int64(vmstat.active_count) + Int64(vmstat.inactive_count)
                    + Int64(vmstat.speculative_count) + Int64(vmstat.wire_count)
                    + Int64(vmstat.compressor_page_count) - Int64(vmstat.purgeable_count)
                    - Int64(vmstat.external_page_count)) * Int64(ps)
    let used = max(wired + compressed, UInt64(max(0, min(occupied, Int64(total)))))
    let app = used - wired - compressed
    let available = total - used
    precondition(used + available == total)
    precondition(app + wired + compressed == used)
    let gb = { (b: UInt64) in String(format: "%.2f GB", Double(b) / 1073741824) }
    print("physical total : \(gb(total))")
    print("used           : \(gb(used))  (\(String(format: "%.0f", Double(used) / Double(total) * 100))%)")
    print("app            : \(gb(app))")
    print("wired          : \(gb(wired))")
    print("compressed     : \(gb(compressed))")
    print("available      : \(gb(available))")
    print("swap used      : \(gb(readSwapUsed()))")
}

func readDisk() {
    let url = URL(fileURLWithPath: "/")
    if let v = try? url.resourceValues(forKeys: [.volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey]) {
        let total = Double(v.volumeTotalCapacity ?? 0) / 1e9
        let free = Double(v.volumeAvailableCapacityForImportantUsage ?? 0) / 1e9
        print(String(format: "disk total: %.0f GB, free: %.0f GB, used: %.0f GB", total, free, total - free))
    }
}

func topProcesses(_ n: Int) {
    let count = proc_listallpids(nil, 0)
    var pids = [pid_t](repeating: 0, count: Int(count))
    let got = pids.withUnsafeMutableBufferPointer { buf -> Int32 in
        proc_listallpids(buf.baseAddress, Int32(buf.count * MemoryLayout<pid_t>.size))
    }
    var out: [(String, UInt64)] = []
    for pid in pids.prefix(Int(got)) where pid > 0 {
        var ru = rusage_info_current()
        let rc = withUnsafeMutablePointer(to: &ru) {
            $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(pid, RUSAGE_INFO_CURRENT, $0)
            }
        }
        guard rc == 0, ru.ri_resident_size > 20 * 1024 * 1024 else { continue }
        let buf = UnsafeMutablePointer<CChar>.allocate(capacity: Int(MAXPATHLEN))
        defer { buf.deallocate() }
        guard proc_pidpath(pid, buf, UInt32(MAXPATHLEN)) > 0 else { continue }
        let name = URL(fileURLWithPath: String(cString: buf)).lastPathComponent
        out.append((name, ru.ri_resident_size))
    }
    var merged: [String: UInt64] = [:]
    for (name, rss) in out { merged[name, default: 0] += rss }
    print("--- top processes ---")
    for (name, rss) in merged.sorted(by: { $0.value > $1.value }).prefix(n) {
        print(String(format: "%-28@ %8.1f MB", name as NSString, Double(rss) / 1048576))
    }
}

readMemory()
readDisk()
topProcesses(10)
