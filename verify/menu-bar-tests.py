#!/usr/bin/env python3
"""Exercise the actual launch path, status click routing and settings lifecycle."""
from pathlib import Path
import subprocess, tempfile, uuid
root = Path(__file__).resolve().parent.parent
stage = Path(tempfile.mkdtemp(prefix='slimstats-menu-'))
suite = 'local.slimstats.menutest.' + uuid.uuid4().hex
source = (root / 'main.swift').read_text()
source = source.replace('private let defaults = UserDefaults.standard', f'private let defaults = UserDefaults(suiteName: "{suite}")!')
source = source.replace('SlimStats.Memory.v2', suite)
assert source.rstrip().endswith('application.run()')
source = source[:source.rfind('application.run()')]
source += r'''
extension AppDelegate {
    func verifyMenuBarLifecycle() {
        precondition(NSApp.activationPolicy() == .accessory, "Dock must remain hidden")
        precondition(settingsWindow == nil && settings == nil, "normal launch must not create settings")
        precondition(statusItem?.button?.action == #selector(statusClicked(_:)))
        precondition(statusItem?.menu == nil, "automatic menu must not consume both mouse buttons")
        let button = statusItem!.button!
        let old = NSEvent.EventTypeMask(rawValue: UInt64(button.sendAction(on: [])))
        button.sendAction(on: old)
        precondition(old.contains(.leftMouseUp) && old.contains(.rightMouseUp))
        func mouse(_ type: NSEvent.EventType, _ modifiers: NSEvent.ModifierFlags = []) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: .zero, modifierFlags: modifiers,
                timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 0)!
        }
        precondition(menuForStatusClick(mouse(.leftMouseUp)) === detailMenu)
        precondition(menuForStatusClick(nil) === detailMenu)
        let right = menuForStatusClick(mouse(.rightMouseUp))
        precondition(right === statusContextMenu)
        precondition(menuForStatusClick(mouse(.leftMouseUp, .control)) === right)
        precondition(right.items.first?.title == "设置…" && right.items.last?.title == "退出 SlimStats")
        precondition(right.delegate == nil && panel == nil, "right click must not allocate details or sample rankings")
        print("PASS: accessory launch has no settings; both mouse buttons route separately; right menu stays lightweight")
        let item = right.items.first!
        precondition(NSApp.sendAction(item.action!, to: item.target, from: item))
        precondition(settingsWindow?.isVisible == true)
        precondition(NSApp.activationPolicy() == .accessory, "opening settings must not add Dock icon")
        print("PASS: context-menu Settings opens the real settings controller without a Dock icon")
        settingsWindow?.close()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            precondition(self.settingsWindow == nil && self.settings == nil)
            precondition(self.statusItem != nil && NSApp.activationPolicy() == .accessory)
            self.menuWillOpen(self.detailMenu)
            precondition(self.panel != nil && self.detailVisible)
            self.menuDidClose(self.detailMenu)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                precondition(self.panel == nil && !self.detailVisible)
                print("PASS: closing settings releases its controller; left details still create and release normally")
                self.defaults.removePersistentDomain(forName: TEST_SUITE)
                NSApp.terminate(nil)
            }
        }
    }
}
DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { delegate.verifyMenuBarLifecycle() }
application.run()
'''.replace('TEST_SUITE', f'"{suite}"')
(stage / 'main.swift').write_text(source)
extra = ['LightButton.swift', 'AppActions.swift', 'DeviceInfo.swift', 'DiskUsageScanner.swift', 'DiskUsageView.swift']
subprocess.run(['xcrun', 'swiftc', '-Osize', '-whole-module-optimization', '-target', 'arm64-apple-macos14.0', '-framework', 'AppKit', '-framework', 'ServiceManagement', '-framework', 'IOKit', str(stage / 'main.swift'), *[str(root / x) for x in extra], '-o', str(stage / 'SlimStatsMenuTest')], check=True)
subprocess.run([str(stage / 'SlimStatsMenuTest')], check=True, timeout=15)
