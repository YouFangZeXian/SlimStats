#!/usr/bin/env python3
"""Build a temporary copy with timed UI lifecycle probes; never terminates user apps."""
from pathlib import Path
import subprocess, tempfile, sys, json
root = Path(__file__).resolve().parent.parent
stage = Path(tempfile.mkdtemp(prefix='slimstats-profile-'))
source = (root / 'main.swift').read_text()
source = source[:source.index('let application = NSApplication.shared')]
# The probe is a temporary executable: use the resources from the latest real build.
resources = json.dumps(str(root / 'SlimStats.app/Contents/Resources'))
source = source.replace('DeviceArtwork.load(model: device.model)', f'DeviceArtwork.load(model: device.model, resources: URL(fileURLWithPath: {resources}))')
source += r'''
extension AppDelegate {
    func probe(_ phase: String) {
        var usage = rusage_info_current()
        let rc = withUnsafeMutablePointer(to: &usage) { ptr in
            ptr.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(getpid(), RUSAGE_INFO_CURRENT, $0)
            }
        }
        guard rc == 0 else { return }
        print(String(format: "%@ RSS=%.1f MiB footprint=%.1f MiB", phase,
                     Double(usage.ri_resident_size) / 1048576, Double(usage.ri_phys_footprint) / 1048576))
        fflush(stdout)
    }
    func beginProbe() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { self.probe("menu-only"); self.showSettings() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
            self.probe("dashboard"); self.settingsWindow?.close()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 7) {
            self.probe("dashboard-closed"); self.menuWillOpen(self.detailMenu)
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 650), styleMask: [.titled], backing: .buffered, defer: false)
            window.title = "SlimStats UI memory probe"; window.contentViewController = self.panel
            window.center(); window.makeKeyAndOrderFront(nil)
            self.probeWindow = window
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 11) {
            self.probe("detail-with-ranking"); self.probeWindow?.orderOut(nil)
            self.probeWindow?.contentViewController = nil; self.probeWindow = nil
            self.menuDidClose(self.detailMenu)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 14) { self.probe("all-closed"); NSApp.terminate(nil) }
    }
}
var application = NSApplication.shared
application.setActivationPolicy(.regular)
let delegate = AppDelegate()
application.delegate = delegate
delegate.beginProbe()
application.run()
'''
if '--full' in sys.argv:
    source = source.replace('self.probe("all-closed"); NSApp.terminate(nil)', 'self.probe("all-closed"); self.showSettings(); self.settings?.probeSelect(0)')
    source = source.replace('    func beginProbe() {', '''    func beginProbe() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 17) { self.probe("dashboard-reopened"); self.settings?.probeSelect(1) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 20) { self.probe("memory-page"); self.settings?.probeSelect(2) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 23) { self.probe("disk-page-idle"); self.settings?.probeSelect(3) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 26) { self.probe("general-page"); self.settingsWindow?.close() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 29) { self.probe("all-pages-closed"); NSApp.terminate(nil) }
    ''')
    source += '\nextension SettingsViewController { func probeSelect(_ page: Int) { showPage(page) } }\n'
# A temporary property exists only in this generated probe, never in the shipped app.
source = source.replace('private var statusItem: NSStatusItem?', 'var probeWindow: NSWindow?\n    private var statusItem: NSStatusItem?')
(stage / 'main.swift').write_text(source)
extra = [root / name for name in ['DeviceInfo.swift', 'DiskUsageScanner.swift', 'DiskUsageView.swift', 'AppActions.swift', 'LightButton.swift'] if (root / name).exists()]
subprocess.run(['xcrun', 'swiftc', '-Osize', '-whole-module-optimization', '-target', 'arm64-apple-macos14.0', '-framework', 'AppKit', '-framework', 'ServiceManagement', '-framework', 'IOKit', str(stage / 'main.swift'), *map(str, extra), '-o', str(stage / 'SlimStatsProbe')], check=True)
subprocess.run([str(stage / 'SlimStatsProbe'), '--menu-only'], check=True)
