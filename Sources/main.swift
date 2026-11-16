import AppKit
import IOKit.pwr_mgt

struct DurationChoice {
    let title: String
    let seconds: Int
    static let all: [DurationChoice] = [
        .init(title: "30 分钟", seconds: 1800),
        .init(title: "1 小时", seconds: 3600),
        .init(title: "2 小时", seconds: 7200),
        .init(title: "3 小时", seconds: 10800),
        .init(title: "6 小时", seconds: 21600),
        .init(title: "12 小时", seconds: 43200),
        .init(title: "直到手动停止", seconds: 0)
    ]
}
protocol PowerHolding: AnyObject {
    func acquire() throws
    func release()
}
struct PowerError: LocalizedError {
    let code: IOReturn
    var errorDescription: String? { "系统未接受保持常亮请求（\(code)）。" }
}
final class PowerHold: PowerHolding {
    private var id: IOPMAssertionID = 0
    func acquire() throws {
        guard id == 0 else { return }
        var next: IOPMAssertionID = 0
        let result = IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn), "StayVisible: user-enabled remote management session" as CFString, &next)
        guard result == kIOReturnSuccess else { throw PowerError(code: result) }
        id = next
    }
    func release() {
        if id != 0 { IOPMAssertionRelease(id); id = 0 }
    }
    deinit { release() }
}
final class Session {
    private let power: PowerHolding
    private(set) var active = false
    private(set) var deadline: Date?
    private var expiresAtUptime: TimeInterval?
    var remainingSeconds: TimeInterval? { expiresAtUptime.map { max(0, $0 - ProcessInfo.processInfo.systemUptime) } }
    init(power: PowerHolding) { self.power = power }
    func start(seconds: TimeInterval?, now: Date = Date(), uptime: TimeInterval = ProcessInfo.processInfo.systemUptime) throws {
        try power.acquire()
        active = true
        deadline = seconds.map { now.addingTimeInterval($0) }
        expiresAtUptime = seconds.map { uptime + $0 }
    }
    func stop() { power.release(); active = false; deadline = nil; expiresAtUptime = nil }
    func tick(uptime: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        if let expiresAtUptime, uptime >= expiresAtUptime { stop() }
    }
}
struct StatusPresentation {
    let title: String
    let symbol: String
    let canStop: Bool
    init(active: Bool, remaining: TimeInterval?, error: String?) {
        if error != nil {
            title = "恢复失败 · 请重试停止"
            symbol = "exclamationmark.triangle.fill"
            canStop = true
        } else if active {
            title = remaining.map { "已开启 · 剩余 \(max(1, Int(ceil($0 / 60)))) 分钟" } ?? "已开启 · 直到手动停止"
            symbol = "sun.max.fill"
            canStop = true
        } else {
            title = "常亮 · 已关闭"
            symbol = "sun.max"
            canStop = false
        }
    }
}
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    let hold = SaverHold()
    lazy var session = Session(power: hold)
    var status: NSStatusItem!
    var timer: Timer?
    var observers: [NSObjectProtocol] = []
    var statusLine = NSMenuItem()
    var stopItem = NSMenuItem()
    var startedBefore = false
    var panel: NSWindow?
    var panelStatus: NSTextField?
    var durationPicker: NSPopUpButton?
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        status = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let menu = NSMenu(); menu.delegate = self
        statusLine = NSMenuItem(title: "常亮 · 已关闭", action: nil, keyEquivalent: "")
        menu.addItem(statusLine)
        menu.addItem(.separator())
        for choice in DurationChoice.all {
            let item = NSMenuItem(title: choice.seconds == 0 ? "保持至手动停止" : "保持 " + choice.title, action: #selector(start(_:)), keyEquivalent: "")
            item.target = self; item.tag = choice.seconds; menu.addItem(item)
        }
        stopItem = NSMenuItem(title: "停止保持", action: #selector(stop), keyEquivalent: "")
        stopItem.target = self; menu.addItem(stopItem)
        menu.addItem(.separator())
        let info = NSMenuItem(title: "作用与边界…", action: #selector(showInfo), keyEquivalent: "")
        info.target = self; menu.addItem(info)
        let quit = NSMenuItem(title: "退出常亮", action: #selector(quitApp), keyEquivalent: "q")
        quit.target = self; menu.addItem(quit)
        let show = NSMenuItem(title: "打开面板…", action: #selector(showPanel), keyEquivalent: "")
        show.target = self; menu.insertItem(show, at: 1)
        status.menu = menu
        timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in self?.session.tick(); if self?.hold.healthy == false { self?.stop() }; self?.refresh() }
        RunLoop.main.add(timer!, forMode: .common)
        // Explicit sleep or switching away from this login session ends the hold.
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.sessionDidResignActiveNotification] {
            observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in self?.stop() })
        }
        refresh()
        showPanel()
    }
    @objc func showPanel() {
        if let panel { panel.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true); return }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 360, height: 235), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "常亮"; window.isReleasedWhenClosed = false
        let view = window.contentView!
        let title = NSTextField(labelWithString: "让远程工作，不被空闲打断。")
        title.font = .systemFont(ofSize: 17, weight: .semibold); title.frame = NSRect(x: 24, y: 178, width: 320, height: 25); view.addSubview(title)
        let state = NSTextField(labelWithString: "已关闭")
        state.frame = NSRect(x: 24, y: 145, width: 312, height: 22); view.addSubview(state); panelStatus = state
        let picker = NSPopUpButton(frame: NSRect(x: 22, y: 101, width: 178, height: 28))
        picker.addItems(withTitles: DurationChoice.all.map { $0.title }); picker.selectItem(at: 1); view.addSubview(picker); durationPicker = picker
        let start = NSButton(title: "开启", target: self, action: #selector(startFromPanel)); start.bezelStyle = .rounded; start.frame = NSRect(x: 210, y: 99, width: 62, height: 32); view.addSubview(start)
        let stop = NSButton(title: "停止", target: self, action: #selector(stop)); stop.bezelStyle = .rounded; stop.frame = NSRect(x: 276, y: 99, width: 62, height: 32); view.addSubview(stop)
        let note = NSTextField(wrappingLabelWithString: "临时暂停屏保和自动灭屏。到时恢复。\n手动锁屏与密码保护不变。")
        note.font = .systemFont(ofSize: 12); note.textColor = .secondaryLabelColor; note.frame = NSRect(x: 24, y: 33, width: 312, height: 45); view.addSubview(note)
        panel = window; window.center(); window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true); refresh()
    }
    @objc func startFromPanel() {
        let item = NSMenuItem(); item.tag = DurationChoice.all[durationPicker?.indexOfSelectedItem ?? 1].seconds; start(item)
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { showPanel(); return true }
    func menuWillOpen(_ menu: NSMenu) { session.tick(); refresh() }
    @objc func start(_ sender: NSMenuItem) {
        if !startedBefore {
            let alert = NSAlert()
            alert.messageText = "在可信环境中保持屏幕常亮"
            alert.informativeText = "开启期间，屏幕不会因空闲而关闭，机器不会因空闲而睡眠。这也会延后由灭屏触发的自动锁定，旁人可能看到或操作你的桌面。\n\n同时临时暂停自动屏保，停止或退出后恢复。密码与手动锁屏保留；不绕过组织管理策略。"
            alert.addButton(withTitle: "开启"); alert.addButton(withTitle: "取消")
            NSApp.activate(ignoringOtherApps: true)
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            startedBefore = true
        }
        do { try session.start(seconds: sender.tag == 0 ? nil : Double(sender.tag)) }
        catch { let alert = NSAlert(error: error); alert.runModal() }
        refresh()
    }
    @objc func stop() { session.stop(); refresh() }
    func refresh() {
        guard status != nil else { return }
        let on = session.active
        let display = StatusPresentation(active: on, remaining: session.remainingSeconds, error: hold.lastError)
        status.button?.image = NSImage(systemSymbolName: display.symbol, accessibilityDescription: display.title)
        status.button?.title = hold.lastError != nil ? " 待恢复" : (on ? " 常亮" : "")
        status.button?.toolTip = hold.lastError ?? (on ? "屏幕保持常亮；点击可停止" : "常亮已关闭；点击选择时长")
        statusLine.title = display.title
        panelStatus?.stringValue = display.title
        panelStatus?.textColor = hold.lastError == nil ? .labelColor : .systemOrange
        stopItem.isEnabled = display.canStop
    }
    @objc func showInfo() {
        let alert = NSAlert()
        alert.messageText = "常亮"
        alert.informativeText = "一个开关，临时保持屏幕与系统清醒。\n\n• 停止、到时或退出即释放请求。\n• 重新打开默认关闭，不自动启动。\n• 临时暂停自动屏保并保存原计时；停止后恢复。\n• 不模拟键鼠，不申请辅助功能；不能解锁或阻止手动锁屏与管理策略。\n\n电脑无人看管时，请停止或手动锁屏。"
        NSApp.activate(ignoringOtherApps: true); alert.runModal()
    }
    @objc func quitApp() { session.stop(); NSApp.terminate(nil) }
    func applicationWillTerminate(_ notification: Notification) {
        session.stop(); timer?.invalidate()
        observers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }
    }
}
func selfTest() {
    assert(DurationChoice.all.map { $0.seconds } == [1800, 3600, 7200, 10800, 21600, 43200, 0])
    assert(Set(DurationChoice.all.map { $0.title }).count == 7)
    final class Mock: PowerHolding {
        var held = false; var fail = false
        func acquire() throws { if fail { throw PowerError(code: -1) }; held = true }
        func release() { held = false }
    }
    let p = Mock(); let s = Session(power: p); let t = Date(timeIntervalSince1970: 100)
    assert(!s.active && !p.held)
    try! s.start(seconds: 10, now: t, uptime: 100); assert(s.active && p.held)
    s.tick(uptime: 109); assert(s.active)
    s.tick(uptime: 110); assert(!s.active && !p.held)
    try! s.start(seconds: 20, now: t, uptime: 100); try! s.start(seconds: 5, now: t, uptime: 100)
    s.tick(uptime: 105); assert(!s.active)
    try! s.start(seconds: nil, now: t, uptime: 100); s.tick(uptime: 99999); assert(s.active)
    s.stop(); s.stop(); assert(!s.active && !p.held && s.deadline == nil)
    // Wall-clock jumps have no influence on monotonic expiration.
    try! s.start(seconds: 10, now: t.addingTimeInterval(-86400), uptime: 100)
    s.tick(uptime: 109); assert(s.active)
    s.tick(uptime: 110); assert(!s.active)
    try! s.start(seconds: 10, now: t.addingTimeInterval(86400), uptime: 100)
    s.tick(uptime: 110); assert(!s.active)
    for choice in DurationChoice.all where choice.seconds > 0 {
        try! s.start(seconds: Double(choice.seconds), now: t, uptime: 100)
        s.tick(uptime: 100 + Double(choice.seconds) - 1); assert(s.active)
        s.tick(uptime: 100 + Double(choice.seconds)); assert(!s.active)
    }
    p.fail = true
    do { try s.start(seconds: 10); assertionFailure("Expected failure") } catch { assert(!s.active && !p.held) }
    let failedRestore = StatusPresentation(active: false, remaining: nil, error: "mock failure")
    assert(failedRestore.title.contains("恢复失败") && failedRestore.canStop && failedRestore.symbol == "exclamationmark.triangle.fill")
    let off = StatusPresentation(active: false, remaining: nil, error: nil)
    assert(off.title == "常亮 · 已关闭" && !off.canStop)
    print("PASS: 7 duration choices including 3/6/12 hours; monotonic expiry despite wall-clock jumps; recovery-error display/retry; default-off, start, expiry, duration replacement, indefinite, repeated stop, acquisition failure. No real assertions created.")
}
if CommandLine.arguments.contains("--restore-guardian") { runGuardian() }
else if CommandLine.arguments.contains("--test-lock-holder") {
    try SaverRecovery.withLock { FileHandle.standardOutput.write(Data([1])); Thread.sleep(forTimeInterval: 3) }
}
else if CommandLine.arguments.contains("--guardian-stall-test") {
    let lock = try acquireInstanceLock(); defer { close(lock) }
    try SaverRecovery.restore()
    let before = SaverPreferences.read()
    let hold = SaverHold(); try hold.acquire()
    try hold.testSuspendedGuardianRelease()
    assert(SaverPreferences.read() == before)
    print("PASS: suspended guardian cannot hang release; settings restored")
}
else if CommandLine.arguments.contains("--fault-test") {
    let lock = try acquireInstanceLock(); defer { close(lock) }
    try SaverRecovery.restore()
    let before = SaverPreferences.read()
    let hold = SaverHold(); try hold.acquire()
    let child = Process(); let ready = Pipe()
    child.executableURL = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
    child.arguments = ["--test-lock-holder"]; child.standardOutput = ready
    try child.run(); assert(ready.fileHandleForReading.readData(ofLength: 1) == Data([1]))
    let began = ProcessInfo.processInfo.systemUptime
    hold.release()
    assert(ProcessInfo.processInfo.systemUptime - began < 2)
    assert(hold.lastError != nil && FileManager.default.fileExists(atPath: SaverRecovery.journal.path))
    let state = StatusPresentation(active: false, remaining: nil, error: hold.lastError)
    assert(state.canStop && state.title.contains("恢复失败"))
    child.waitUntilExit() // CLI-only fixture: never executed on an app UI thread.
    hold.release()
    assert(hold.lastError == nil && SaverPreferences.read() == before)
    print("PASS: busy recovery lock returns bounded error, retains journal, shows retry, then restores")
}
else if CommandLine.arguments.contains("--self-test") { selfTest() }
else if CommandLine.arguments.contains("--integration-test") || CommandLine.arguments.contains("--crash-test") {
    let lock = try acquireInstanceLock(); defer { close(lock) }
    try SaverRecovery.restore()
    let before = SaverPreferences.read()
    let hold = SaverHold(); let testSession = Session(power: hold); try testSession.start(seconds: 2)
    assert(SaverPreferences.read() == 0)
    print("ACTIVE; original=\(String(describing: before))"); fflush(stdout)
    if CommandLine.arguments.contains("--crash-test") { kill(getpid(), SIGKILL) }
    Thread.sleep(forTimeInterval: 2)
    testSession.tick()
    assert(!testSession.active)
    assert(SaverPreferences.read() == before && hold.lastError == nil)
    print("PASS: real assertion + screensaver pause + exact restore")
}
else {
    let lock: Int32
    do { lock = try acquireInstanceLock(); try SaverRecovery.restore() }
    catch { let alert = NSAlert(error: error); alert.runModal(); exit(1) }
    defer { close(lock) }
    let app = NSApplication.shared
    let delegate = AppDelegate(); app.delegate = delegate
    app.run()
}
