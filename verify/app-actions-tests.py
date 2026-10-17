#!/usr/bin/env python3
"""Exercise real row actions and quit fallback using disposable fixture apps only."""
from pathlib import Path
import subprocess, tempfile, plistlib
root = Path(__file__).resolve().parent.parent
stage = Path(tempfile.mkdtemp(prefix='slimstats-actions-'))
fixture = stage / 'SlimStatsQuitFixture.app'
(fixture / 'Contents/MacOS').mkdir(parents=True)
(fixture / 'Contents/Info.plist').write_bytes(plistlib.dumps({
    'CFBundleExecutable': 'SlimStatsQuitFixture', 'CFBundleIdentifier': 'local.slimstats.quitfixture',
    'CFBundleName': 'SlimStatsQuitFixture', 'CFBundlePackageType': 'APPL', 'LSUIElement': False
}))
(stage / 'fixture.swift').write_text(r'''
import AppKit
final class Fixture: NSObject, NSApplicationDelegate {
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        return CommandLine.arguments.contains("--refuse") ? .terminateCancel : .terminateNow
    }
}
let app = NSApplication.shared
app.setActivationPolicy(CommandLine.arguments.contains("--accessory") ? .accessory : .regular)
let delegate = Fixture()
app.delegate = delegate
let padding = NSMutableData(length: 40 * 1024 * 1024)!
memset(padding.mutableBytes, 1, padding.length)
withExtendedLifetime(padding) { app.run() }
''')
subprocess.run(['xcrun', 'swiftc', '-O', str(stage / 'fixture.swift'), '-o', str(fixture / 'Contents/MacOS/SlimStatsQuitFixture')], check=True)
# No AppKit registration: exercise the raw PID termination path independently.
(stage / 'worker.c').write_text(r'''
#include <signal.h>
#include <unistd.h>
#include <fcntl.h>
#include <stdlib.h>
int main(int argc, char **argv) {
    if (argc > 2) signal(SIGTERM, SIG_IGN);
    volatile char *memory = malloc(40 * 1024 * 1024);
    if (!memory) return 2;
    for (int i = 0; i < 40 * 1024 * 1024; i += 4096) memory[i] = 1;
    int fd = open(argv[1], O_WRONLY | O_CREAT, 0600);
    if (fd >= 0) close(fd);
    while (1) pause();
}
''')
subprocess.run(['xcrun', 'clang', '-Os', str(stage / 'worker.c'), '-o', str(stage / 'SlimStatsWorkerFixture')], check=True)
source = (root / 'main.swift').read_text().split('let application = NSApplication.shared')[0]
source += r'''
let fixtureURL = URL(fileURLWithPath: CommandLine.arguments[1])
let application = NSApplication.shared
application.setActivationPolicy(.accessory)
setbuf(stdout, nil)
let quitter = ApplicationQuitter()
var fixtureProcess: Process?
func waitFor(_ condition: () -> Bool, timeout: TimeInterval = 3) -> Bool {
    let end = Date().addingTimeInterval(timeout)
    while !condition() && Date() < end { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
    return condition()
}
func launchFixture(refuse: Bool, accessory: Bool = false) -> NSRunningApplication {
    let process = Process(); process.executableURL = fixtureURL.appendingPathComponent("Contents/MacOS/SlimStatsQuitFixture")
    process.arguments = (refuse ? ["--refuse"] : []) + (accessory ? ["--accessory"] : [])
    try! process.run(); fixtureProcess = process
    precondition(waitFor { NSRunningApplication(processIdentifier: process.processIdentifier)?.isFinishedLaunching == true })
    return NSRunningApplication(processIdentifier: process.processIdentifier)!
}
func checkQuit(_ app: NSRunningApplication, expectedForced: Bool) {
    var result: ApplicationQuitter.Result?
    quitter.close(ProcessExitTarget(identity: ProcessIdentity.capture(app.processIdentifier)!, bundlePath: fixtureURL.path), gracePeriod: 0.5) { result = $0 }
    precondition(waitFor({ result != nil }, timeout: 4))
    if expectedForced { guard case .forced = result! else { fatalError("refusing fixture was not forced") } }
    else { guard case .exited = result! else { fatalError("normal fixture did not exit normally") } }
    precondition(app.isTerminated)
    print(expectedForced ? "PASS: refusing app force-quit and exit verified" : "PASS: normal app exited and exit verified")
}
let normal = launchFixture(refuse: false)
let row = ProcessRow(process: ProcessSnapshot(name: "SlimStatsQuitFixture", rss: 40 * 1024 * 1024, bundlePath: fixtureURL.path, exitIdentity: ProcessIdentity.capture(normal.processIdentifier)))
let buttons = row.subviews.compactMap { $0 as? LightButton }
let icon = buttons.first { $0.frame.minX == 0 }!
let name = buttons.first { $0.frame.minX > 0 }!
precondition(icon.isEnabled && icon.image != nil)
var quitRequests = 0
row.onQuitApp = { _ in quitRequests += 1 }
icon.performClick(nil); precondition(icon.title == "×")
name.performClick(nil); precondition(icon.title.isEmpty && icon.image != nil && quitRequests == 0)
icon.performClick(nil); precondition(icon.title == "×" && quitRequests == 0)
icon.performClick(nil); precondition(quitRequests == 1 && icon.title.isEmpty)
precondition(!normal.isTerminated)
print("PASS: icon arms; name cancels; icon re-arms; second icon emits one quit request")
let panel = StatsPanelViewController(showProcesses: true)
panel.updateProcesses([ProcessSnapshot(name: "SlimStatsQuitFixture", rss: 40 * 1024 * 1024, bundlePath: fixtureURL.path, exitIdentity: ProcessIdentity.capture(normal.processIdentifier))])
weak var released: StatsPanelViewController?
autoreleasepool {
    let temporary = StatsPanelViewController(showProcesses: true)
    temporary.updateProcesses([]); released = temporary
}
precondition(released == nil)
print("PASS: detail controller releases without a retained cycle")
DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
    let cancel = NSApp.modalWindow?.contentView?.subviews.compactMap { $0 as? LightButton }.first { $0.title == "取消" }
    precondition(cancel != nil); cancel!.performClick(nil)
}
precondition(!QuitConfirmation(message: "关闭测试应用？", detail: "此窗口仅测试取消操作。").runModal())
precondition(!normal.isTerminated)
DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
    let confirm = NSApp.modalWindow?.contentView?.subviews.compactMap { $0 as? LightButton }.first { $0.title == "关闭应用" }
    precondition(confirm != nil); confirm!.performClick(nil)
}
precondition(QuitConfirmation(message: "关闭测试应用？", detail: "此窗口仅测试确认操作。").runModal())
print("PASS: confirmation cancel preserves app; confirmation button returns close decision")
checkQuit(normal, expectedForced: false)
let stubborn = launchFixture(refuse: true)
row.update(ProcessSnapshot(name: "SlimStatsQuitFixture", rss: 40 * 1024 * 1024,
                           bundlePath: fixtureURL.path, exitIdentity: ProcessIdentity.capture(stubborn.processIdentifier)))
precondition(icon.isEnabled)
icon.performClick(nil); precondition(icon.title == "×")
name.performClick(nil); precondition(icon.title.isEmpty)
print("PASS: existing row resolves a relaunched app with a new PID")
checkQuit(stubborn, expectedForced: true)

let accessory = launchFixture(refuse: false, accessory: true)
precondition(accessory.activationPolicy == .accessory)
let accessorySnapshot = ProcessSnapshot(name: "BackgroundFixture", rss: 40 * 1024 * 1024,
    bundlePath: fixtureURL.path, exitIdentity: ProcessIdentity.capture(accessory.processIdentifier))
let accessoryRow = ProcessRow(process: accessorySnapshot)
precondition(accessoryRow.subviews.compactMap { $0 as? LightButton }.first!.isEnabled)
let accessoryCollected = SystemMetrics.topProcesses(limit: 1000).first { sameApplicationBundle($0.bundlePath, fixtureURL.path) }
guard accessoryCollected?.exitIdentity?.pid == accessory.processIdentifier else { fatalError("accessory fixture was not collected with its main PID") }
precondition(ProcessExitTarget(identity: accessoryCollected!.exitIdentity!, bundlePath: accessoryCollected!.bundlePath).application != nil)
checkQuit(accessory, expectedForced: false)
print("PASS: accessory/background application is selectable and exits")

func worker(refuse: Bool) -> (Process, ProcessExitTarget) {
    let process = Process()
    process.executableURL = fixtureURL.deletingLastPathComponent().appendingPathComponent("SlimStatsWorkerFixture")
    let marker = fixtureURL.deletingLastPathComponent().appendingPathComponent(UUID().uuidString).path
    process.arguments = [marker] + (refuse ? ["--refuse"] : [])
    try! process.run()
    precondition(waitFor { FileManager.default.fileExists(atPath: marker) })
    let target = ProcessExitTarget(identity: ProcessIdentity.capture(process.processIdentifier)!, bundlePath: nil)
    precondition(target.application == nil && target.blockedReason == nil)
    return (process, target)
}
func checkWorker(_ target: ProcessExitTarget, process: Process, forced: Bool) {
    var result: ApplicationQuitter.Result?
    quitter.close(target, gracePeriod: 0.5) { result = $0 }
    precondition(waitFor({ result != nil }, timeout: 4))
    if forced { guard case .forced = result! else { fatalError("worker did not force-exit") } }
    else { guard case .exited = result! else { fatalError("worker did not exit on SIGTERM") } }
    precondition(waitFor { !process.isRunning })
    print(forced ? "PASS: unregistered background process forced and exit verified" : "PASS: unregistered background process terminated and exit verified")
}
let (workerProcess, workerTarget) = worker(refuse: false)
let rawRow = ProcessRow(process: ProcessSnapshot(name: "BackgroundWorker", rss: 40 * 1024 * 1024,
    bundlePath: nil, exitIdentity: workerTarget.identity))
let rawButtons = rawRow.subviews.compactMap { $0 as? LightButton }
precondition(rawButtons[0].isEnabled)
rawButtons[0].performClick(nil); precondition(rawButtons[0].title == "×")
rawButtons[1].performClick(nil); precondition(rawButtons[0].title.isEmpty && workerProcess.isRunning)
// Confirm UI for a raw process has its own explicit action title.
DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
    let confirm = NSApp.modalWindow?.contentView?.subviews.compactMap { $0 as? LightButton }.first { $0.title == "结束进程" }
    precondition(confirm != nil); confirm!.performClick(nil)
}
precondition(QuitConfirmation(message: "结束测试进程？", detail: workerTarget.confirmationDetail, confirmTitle: "结束进程").runModal())
let identity = workerTarget.identity
let stale = ProcessIdentity(pid: identity.pid, executable: identity.executable, uid: identity.uid,
    realUID: identity.realUID, startSeconds: identity.startSeconds + 1, startMicroseconds: identity.startMicroseconds)
var staleResult: ApplicationQuitter.Result?
quitter.close(ProcessExitTarget(identity: stale, bundlePath: nil)) { staleResult = $0 }
guard case .exited = staleResult! else { fatalError("stale identity was not recognized as gone") }
precondition(workerProcess.isRunning)
print("PASS: reused/stale PID identity is never signalled")
let foreign = ProcessIdentity(pid: identity.pid, executable: identity.executable, uid: 0, realUID: 0,
    startSeconds: identity.startSeconds, startMicroseconds: identity.startMicroseconds)
let foreignRow = ProcessRow(process: ProcessSnapshot(name: "ForeignFixture", rss: 40 * 1024 * 1024,
    bundlePath: nil, exitIdentity: foreign))
let foreignIcon = foreignRow.subviews.compactMap { $0 as? LightButton }.first!
precondition(!foreignIcon.isEnabled && foreignIcon.toolTip!.contains("UID 0"))
var denied: ApplicationQuitter.Result?
quitter.close(ProcessExitTarget(identity: foreign, bundlePath: nil)) { denied = $0 }
guard case .failed = denied! else { fatalError("foreign owner was not blocked") }
precondition(workerProcess.isRunning)
print("PASS: foreign-owner action is disabled with a concrete reason; no signal sent")
var selfResult: ApplicationQuitter.Result?
quitter.close(ProcessExitTarget(identity: ProcessIdentity.capture(getpid())!, bundlePath: nil)) { selfResult = $0 }
guard case .failed = selfResult! else { fatalError("self termination was not blocked") }
// Replacing the snapshot of an armed row clears selection before it can target a new process.
rawButtons[0].performClick(nil); precondition(rawButtons[0].title == "×")
rawRow.update(ProcessSnapshot(name: "BackgroundWorker", rss: 40 * 1024 * 1024,
    bundlePath: nil, exitIdentity: foreign))
precondition(rawButtons[0].title.isEmpty && !rawButtons[0].isEnabled)
let (stubbornWorker, stubbornTarget) = worker(refuse: true)
let workers = SystemMetrics.topProcesses(limit: 1000).filter { $0.exitIdentity?.executable == workerTarget.identity.executable }
precondition(workers.count == 2 && Set(workers.map(\.key)).count == 2)
precondition(Set(workers.compactMap { $0.exitIdentity?.pid }) == Set([workerProcess.processIdentifier, stubbornWorker.processIdentifier]))
print("PASS: collector includes accessory apps and keeps identical background executables separate by PID")
checkWorker(workerTarget, process: workerProcess, forced: false)
checkWorker(stubbornTarget, process: stubbornWorker, forced: true)
print("All app-action tests passed; no user apps or services were terminated")

'''
(stage / 'main.swift').write_text(source)
subprocess.run(['xcrun', 'swiftc', '-O', '-target', 'arm64-apple-macos14.0', '-framework', 'AppKit', '-framework', 'ServiceManagement', '-framework', 'IOKit', str(stage / 'main.swift'), *[str(root / f) for f in ['LightButton.swift', 'AppActions.swift', 'DeviceInfo.swift', 'DiskUsageScanner.swift', 'DiskUsageView.swift']], '-o', str(stage / 'ActionsTests')], check=True)
try:
    subprocess.run([str(stage / 'ActionsTests'), str(fixture)], check=True, timeout=40)
finally:
    # Only fixtures created under this unique temporary path are eligible for cleanup.
    subprocess.run(['pkill', '-f', str(fixture / 'Contents/MacOS/SlimStatsQuitFixture')], check=False)
    subprocess.run(['pkill', '-9', '-f', str(stage / 'SlimStatsWorkerFixture')], check=False)
