import Foundation
import Darwin
let pid = pid_t(CommandLine.arguments[1])!
let duration = Int(CommandLine.arguments[2]) ?? 30
func sample() -> rusage_info_current? {
    var usage = rusage_info_current()
    let rc = withUnsafeMutablePointer(to: &usage) { pointer in
        pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_CURRENT, $0) }
    }
    return rc == 0 ? usage : nil
}
guard let first = sample() else { fatalError("process unavailable") }
let began = Date()
var resident: [UInt64] = [], footprint: [UInt64] = []
for _ in 0..<duration {
    sleep(1)
    guard let current = sample() else { fatalError("process exited") }
    resident.append(current.ri_resident_size); footprint.append(current.ri_phys_footprint)
}
let last = sample()!
let elapsed = Date().timeIntervalSince(began)
let cpuSeconds = Double((last.ri_user_time - first.ri_user_time) + (last.ri_system_time - first.ri_system_time)) / 1e9
func mib(_ bytes: UInt64) -> Double { Double(bytes) / 1_048_576 }
resident.sort(); footprint.sort()
print(String(format: "pid=%d duration=%.1fs CPU=%.3f%% RSS_median=%.1fMiB RSS_max=%.1fMiB footprint_median=%.1fMiB footprint_max=%.1fMiB", pid, elapsed, cpuSeconds / elapsed * 100, mib(resident[resident.count/2]), mib(resident.last!), mib(footprint[footprint.count/2]), mib(footprint.last!)))
