import Foundation
import Darwin

struct HoldError: LocalizedError {
    var message: String
    var errorDescription: String? { message }
}
/// Only idleTime is changed. Password and lock policies are never written.
enum SaverPreferences {
    static let domain = "com.apple.screensaver" as CFString
    static let key = "idleTime" as CFString
    static func read() -> Int? {
        CFPreferencesSynchronize(domain, kCFPreferencesCurrentUser, kCFPreferencesCurrentHost)
        return (CFPreferencesCopyValue(key, domain, kCFPreferencesCurrentUser, kCFPreferencesCurrentHost) as? NSNumber)?.intValue
    }
    static func write(_ value: Int?) throws {
        let object: CFPropertyList? = value.map { NSNumber(value: $0) }
        CFPreferencesSetValue(key, object, domain, kCFPreferencesCurrentUser, kCFPreferencesCurrentHost)
        guard CFPreferencesSynchronize(domain, kCFPreferencesCurrentUser, kCFPreferencesCurrentHost), read() == value else {
            throw HoldError(message: "未能写入或恢复屏保计时；请检查系统设置。")
        }
    }
}
struct SaverJournal: Codable { let original: Int?; let token: String }
enum SaverRecovery {
    static var folder: URL { FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/StayVisible") }
    static var journal: URL { folder.appendingPathComponent("restore.json") }
    static func setup() throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    }
    static func withLock<T>(_ body: () throws -> T) throws -> T {
        try setup()
        let fd = open(folder.appendingPathComponent("recovery.lock").path, O_CREAT | O_RDWR, 0o600)
        guard fd >= 0 else { throw HoldError(message: "恢复锁不可用。") }
        defer { close(fd) }
        var acquired = false
        for _ in 0..<100 {
            if flock(fd, LOCK_EX | LOCK_NB) == 0 { acquired = true; break }
            usleep(10_000)
        }
        guard acquired else { throw HoldError(message: "恢复操作正忙，请重试停止或重新打开应用。") }
        defer { flock(fd, LOCK_UN) }
        return try body()
    }
    static func restore(token: String? = nil) throws {
      try withLock {
        guard FileManager.default.fileExists(atPath: journal.path) else { return }
        let record = try JSONDecoder().decode(SaverJournal.self, from: Data(contentsOf: journal))
        guard token == nil || token == record.token else { return }
        // Preserve an intervening change made by the user or another app.
        if SaverPreferences.read() == 0 { try SaverPreferences.write(record.original) }
        try FileManager.default.removeItem(at: journal)
      }
    }
    static func backup() throws -> String {
      try withLock {
        let token = UUID().uuidString
        guard !FileManager.default.fileExists(atPath: journal.path) else { throw HoldError(message: "存在未恢复的屏保设置，请先恢复后重试。") }
        try JSONEncoder().encode(SaverJournal(original: SaverPreferences.read(), token: token)).write(to: journal, options: .atomic)
        chmod(journal.path, 0o600)
        return token
      }
    }
}
protocol SessionHolding: PowerHolding {
    var lastError: String? { get }
    var healthy: Bool { get }
}
final class SaverHold: SessionHolding {
    let power = PowerHold()
    private var guardian: Process?
    private var writer: FileHandle?
    private(set) var lastError: String?
    var healthy: Bool { guardian == nil || guardian!.isRunning }
    func acquire() throws {
        guard guardian == nil else { return }
        let token = try SaverRecovery.backup()
        let process = Process()
        let input = Pipe(), ready = Pipe()
        process.executableURL = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
        process.arguments = ["--restore-guardian", token]
        process.standardInput = input
        process.standardOutput = ready
        do {
            try process.run()
            // A one-byte handshake confirms the recovery worker is alive before mutation.
            var descriptor = pollfd(fd: ready.fileHandleForReading.fileDescriptor, events: Int16(POLLIN), revents: 0)
            guard poll(&descriptor, 1, 3000) > 0, ready.fileHandleForReading.readData(ofLength: 1) == Data([1]) else {
                throw HoldError(message: "恢复守护进程未能启动，未启用保持。")
            }
            writer = input.fileHandleForWriting; guardian = process
            try power.acquire()
            try SaverPreferences.write(0)
            lastError = nil
        } catch {
            release()
            throw error
        }
    }
    func release() {
        power.release()
        do { try SaverRecovery.restore(); lastError = nil }
        catch { lastError = error.localizedDescription }
        try? writer?.close(); writer = nil
        // Never wait on the child from the UI thread. Its token prevents it
        // from touching a later session if its exit is delayed.
        guardian = nil
    }
    func testSuspendedGuardianRelease() throws {
        guard let child = guardian, child.suspend() else { throw HoldError(message: "Test helper could not suspend guardian") }
        defer { _ = child.resume() }
        let began = ProcessInfo.processInfo.systemUptime
        release()
        assert(ProcessInfo.processInfo.systemUptime - began < 2)
        assert(lastError == nil && !FileManager.default.fileExists(atPath: SaverRecovery.journal.path))
    }
    deinit { release() }
}
func runGuardian() {
    FileHandle.standardOutput.write(Data([1]))
    // EOF also arrives after SIGKILL/crash: no privileged helper or login item required.
    _ = FileHandle.standardInput.readDataToEndOfFile()
    do { try SaverRecovery.restore(token: CommandLine.arguments.last) }
    catch { fputs("StayVisible recovery failed: \(error)\n", stderr); exit(2) }
}
func acquireInstanceLock() throws -> Int32 {
    try SaverRecovery.setup()
    let fd = open(SaverRecovery.folder.appendingPathComponent("instance.lock").path, O_CREAT | O_RDWR, 0o600)
    guard fd >= 0 else { throw HoldError(message: "无法创建实例锁。") }
    _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
    guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { close(fd); throw HoldError(message: "常亮已经在运行。") }
    return fd
}
