import Foundation
import CoreGraphics
import Darwin

private let serviceLabel = "local.hidpi.helper"
private var launchctlForTest: (([String]) -> (Int32, String))?
private struct ServicePaths {
    let home: URL
    var root: URL { home.appendingPathComponent("Library/Application Support/hidpi", isDirectory: true) }
    var agent: URL { home.appendingPathComponent("Library/LaunchAgents/\(serviceLabel).plist") }
    var shortcut: URL { home.appendingPathComponent(".local/bin/hidpi") }
    var marker: URL { root.appendingPathComponent("installation.json") }
    var cli: URL { root.appendingPathComponent("hidpi") }
    var helper: URL { root.appendingPathComponent("hidpi-test") }
    var config: URL { root.appendingPathComponent("mode.json") }
    var status: URL { root.appendingPathComponent("service-status.json") }
    var log: URL { root.appendingPathComponent("service.log") }
}
private struct ServiceMode: Codable {
    let width: Int
    let height: Int
    let uuid: String
}
private func jsonObject(_ url: URL) -> [String: Any] {
    guard let data = try? Data(contentsOf: url), let object = try? JSONSerialization.jsonObject(with: data) else { return [:] }
    return object as? [String: Any] ?? [:]
}
private func plistObject(_ url: URL) -> [String: Any] {
    guard let data = try? Data(contentsOf: url), let object = try? PropertyListSerialization.propertyList(from: data, format: nil) else { return [:] }
    return object as? [String: Any] ?? [:]
}
private func checkedWrite(_ object: [String: Any], to url: URL) throws {
    try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]).write(to: url, options: .atomic)
}
private func agentContents(_ paths: ServicePaths, mode: ServiceMode?, enabled: Bool) -> [String: Any] {
    let arguments = mode.map { [paths.helper.path, "--service", String($0.width), String($0.height), $0.uuid] }
        ?? [paths.helper.path, "--help"]
    return ["Label": serviceLabel, "ProgramArguments": arguments,
            "RunAtLoad": enabled, "KeepAlive": false, "LimitLoadToSessionType": "Aqua",
            "ExitTimeOut": 30, "ProcessType": "Interactive",
            "EnvironmentVariables": ["HIDPI_STATE_DIR": paths.root.path],
            "StandardOutPath": paths.log.path, "StandardErrorPath": paths.log.path]
}
private func writeAgent(_ paths: ServicePaths, mode: ServiceMode?, enabled: Bool) throws {
    try FileManager.default.createDirectory(at: paths.agent.deletingLastPathComponent(), withIntermediateDirectories: true)
    let data = try PropertyListSerialization.data(fromPropertyList: agentContents(paths, mode: mode, enabled: enabled), format: .xml, options: 0)
    try data.write(to: paths.agent, options: .atomic)
}
private func launchctl(_ arguments: [String]) -> (Int32, String) {
    if let fake = launchctlForTest { return fake(arguments) }
    return capturedCommand("/bin/launchctl", arguments, timeout: 10)
}
private func capturedCommand(_ executable: String, _ arguments: [String], timeout: TimeInterval) -> (Int32, String) {
    let task = Process()
    task.executableURL = URL(fileURLWithPath: executable)
    task.arguments = arguments
    let pipe = Pipe()
    task.standardOutput = pipe
    task.standardError = pipe
    do { try task.run() } catch { return (1, error.localizedDescription) }
    try? pipe.fileHandleForWriting.close()
    let fd = pipe.fileHandleForReading.fileDescriptor
    _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
    var data = Data()
    let deadline = ProcessInfo.processInfo.systemUptime + timeout
    func drain() {
        var buffer = [UInt8](repeating: 0, count: 8192)
        // Bound each drain pass as well as retained output, even for noisy children.
        for _ in 0..<32 {
            let count = read(fd, &buffer, buffer.count)
            if count <= 0 { break }
            if data.count < 1_048_576 { data.append(contentsOf: buffer.prefix(min(count, 1_048_576 - data.count))) }
        }
    }
    while task.isRunning && ProcessInfo.processInfo.systemUptime < deadline {
        drain()
        Thread.sleep(forTimeInterval: 0.02)
    }
    let timedOut = task.isRunning
    if timedOut {
        // Foundation gives the child its own process group; stop descendants too.
        kill(-task.processIdentifier, SIGKILL)
        kill(task.processIdentifier, SIGKILL)
        let until = ProcessInfo.processInfo.systemUptime + 1
        while task.isRunning && ProcessInfo.processInfo.systemUptime < until { Thread.sleep(forTimeInterval: 0.01) }
    }
    drain()
    let output = String(data: data, encoding: .utf8) ?? ""
    return timedOut ? (124, output + "\nCommand timed out: \(executable)") : (task.terminationStatus, output)
}
private var job: String { "gui/\(getuid())/\(serviceLabel)" }
private var domain: String { "gui/\(getuid())" }
private func runningPID(_ description: String) -> Int32? {
    for line in description.components(separatedBy: .newlines) {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("pid = "), let pid = Int32(trimmed.dropFirst(6)), pid > 1 { return pid }
    }
    return nil
}
private func loadMode(_ paths: ServicePaths) -> ServiceMode? {
    guard let data = try? Data(contentsOf: paths.config) else { return nil }
    return try? JSONDecoder().decode(ServiceMode.self, from: data)
}
private func livePhase(_ status: [String: Any], pid: Int32?) -> String {
    guard let pid else { return "stopped" }
    guard (status["pid"] as? NSNumber)?.int32Value == pid else { return "starting" }
    return status["phase"] as? String ?? "starting"
}

func menuServiceState() -> (installed: Bool, running: Bool, enabled: Bool, summary: String) {
    let paths = ServicePaths(home: FileManager.default.homeDirectoryForCurrentUser)
    let installed = jsonObject(paths.marker)["owner"] as? String == serviceLabel
    let enabled = plistObject(paths.agent)["RunAtLoad"] as? Bool ?? false
    let pid = runningPID(launchctl(["print", job]).1)
    let running = pid != nil
    let phase = livePhase(jsonObject(paths.status), pid: pid)
    let mode = loadMode(paths)
    let description = phase == "running" ? "Background mode: \(mode.map { "\($0.width) × \($0.height)" } ?? "active")" : "Background mode: \(running ? phase : "off")"
    return (installed, running, enabled, description + " · Restore at login: \(enabled ? "on" : "off")")
}
private func requireManaged(_ paths: ServicePaths) {
    guard jsonObject(paths.marker)["owner"] as? String == serviceLabel else { fail("Not installed. Run hidpi install first.") }
}
private func stopService(_ paths: ServicePaths) {
    if jsonObject(paths.status)["phase"] as? String == "restore-failed" {
        fail("A previous restoration was incomplete. Check Displays settings and \(paths.log.path); installed files were retained.")
    }
    let state = launchctl(["print", job])
    if state.0 == 124 { fail(state.1) }
    if [3, 113].contains(state.0) { print("Background helper is not loaded."); return }
    if state.0 != 0 { fail("Cannot determine whether the helper is running: \(state.1)") }
    if runningPID(state.1) != nil {
        let sent = launchctl(["kill", "SIGTERM", job])
        guard sent.0 == 0 else { fail("Could not request graceful shutdown: \(sent.1)") }
        let deadline = Date().addingTimeInterval(30)
        while Date() < deadline {
            let current = launchctl(["print", job])
            if current.0 != 0 || runningPID(current.1) == nil { break }
            Thread.sleep(forTimeInterval: 0.2)
        }
        if runningPID(launchctl(["print", job]).1) != nil {
            fail("Helper has not finished restoring. Files were retained. Check \(paths.log.path).")
        }
        let phase = jsonObject(paths.status)["phase"] as? String ?? "unknown"
        guard ["stopped", "failed-restored", "failed"].contains(phase) else {
            fail("Helper exited, but restoration was not confirmed (\(phase)). Files were retained. Check \(paths.log.path).")
        }
    }
    let removed = launchctl(["bootout", job])
    if removed.0 != 0 && launchctl(["print", job]).0 == 0 { fail("Could not unload helper: \(removed.1)") }
    print("Background helper stopped.")
}
private func installService(_ paths: ServicePaths) throws {
    let fm = FileManager.default
    let source = helperURL().deletingLastPathComponent()
    let managed = jsonObject(paths.marker)["owner"] as? String == serviceLabel
    // Atomic replacement leaves a running process's executable mapping intact.
    // Updating binaries must not stop the user's current display session.
    for path in [paths.root, paths.agent] {
        if (try? path.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true {
            fail("Refusing to replace a symlink at \(path.path).")
        }
    }
    if !managed && [paths.cli, paths.helper, paths.agent].contains(where: { fm.fileExists(atPath: $0.path) }) {
        fail("Existing files at the installation location are not marked as ours; leaving them untouched.")
    }
    try fm.createDirectory(at: paths.root, withIntermediateDirectories: true)
    for name in ["hidpi", "hidpi-test", "hidpi-test-LICENSE.txt", "LICENSE", "THIRD_PARTY_NOTICES.md"] {
        let from = source.appendingPathComponent(name), to = paths.root.appendingPathComponent(name)
        if from.standardizedFileURL == to.standardizedFileURL { continue }
        let data = try Data(contentsOf: from)
        try data.write(to: to, options: .atomic)
        if ["hidpi", "hidpi-test"].contains(name) { try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: to.path) }
    }
    try checkedWrite(["owner": serviceLabel, "version": 1], to: paths.marker)
    if !fm.fileExists(atPath: paths.agent.path) { try writeAgent(paths, mode: nil, enabled: false) }
    try fm.createDirectory(at: paths.shortcut.deletingLastPathComponent(), withIntermediateDirectories: true)
    if !fm.fileExists(atPath: paths.shortcut.path) && (try? fm.destinationOfSymbolicLink(atPath: paths.shortcut.path)) == nil {
        try fm.createSymbolicLink(at: paths.shortcut, withDestinationURL: paths.cli)
    } else if (try? fm.destinationOfSymbolicLink(atPath: paths.shortcut.path)) != paths.cli.path {
        print("Existing \(paths.shortcut.path) left untouched. Use the installed executable directly.")
    }
    print("Installed: \(paths.cli.path)")
    print("Shortcut: \(paths.shortcut.path)")
    print("Installation preserves the current display session and login preference. Updated helper code is used on its next start.")
}
private func resolveMode(_ values: [String], paths: ServicePaths) -> ServiceMode {
    if values.isEmpty, let mode = loadMode(paths) { return mode }
    guard values.isEmpty || values.count == 2 || values.count == 3 else { fail("Usage: hidpi start|enable [width height [display-ID]]") }
    let width = values.isEmpty ? 1920 : Int(values[0]) ?? 0
    let height = values.isEmpty ? 1200 : Int(values[1]) ?? 0
    guard (800...2560).contains(width), (600...1600).contains(height) else { fail("Virtual sizes must be 800–2560 wide and 600–1600 high.") }
    var count: UInt32 = 0
    check(CGGetOnlineDisplayList(0, nil, &count), "Reading displays")
    guard count > 0 else { fail("Run start/enable in Terminal in your graphical desktop session.") }
    var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
    check(CGGetOnlineDisplayList(count, &ids, &count), "Reading displays")
    let external = ids.prefix(Int(count)).filter { CGDisplayIsBuiltin($0) == 0 && CGDisplayVendorNumber($0) != 0xF0F0 }
    let selected: CGDirectDisplayID
    if values.count == 3 {
        guard let id = UInt32(values[2]), external.contains(id) else { fail("Choose an external display ID from hidpi --list.") }
        selected = id
    } else if external.count == 1 { selected = external[0] }
    else {
        guard !external.isEmpty else { fail("No external monitor found.") }
        fail("Multiple monitors connected. Specify width height display-ID, using hidpi --list.")
    }
    guard let uuid = CGDisplayCreateUUIDFromDisplayID(selected)?.takeRetainedValue() else { fail("Cannot identify this monitor.") }
    return ServiceMode(width: width, height: height, uuid: CFUUIDCreateString(nil, uuid) as String)
}
private func startService(_ paths: ServicePaths, mode: ServiceMode, enabled: Bool) throws {
    let key = verificationKey(uuid: mode.uuid, os: ProcessInfo.processInfo.operatingSystemVersionString,
                              size: Size(width: mode.width, height: mode.height))
    guard jsonObject(paths.root.appendingPathComponent("verified.json"))[key] != nil else {
        fail("Test \(mode.width) × \(mode.height) once using the foreground hidpi menu first. Background startup requires a mode verified on this monitor and macOS version.")
    }
    stopService(paths)
    try JSONEncoder().encode(mode).write(to: paths.config, options: .atomic)
    try writeAgent(paths, mode: mode, enabled: enabled)
    try? FileManager.default.removeItem(at: paths.status)
    // Explicit starts reset the log. Login starts append their short status output.
    try Data().write(to: paths.log, options: .atomic)
    print("Starting background HiDPI…")
    fflush(stdout)
    let loaded = launchctl(["bootstrap", domain, paths.agent.path])
    guard loaded.0 == 0 else { fail("Could not load LaunchAgent: \(loaded.1)") }
    if !enabled {
        let start = launchctl(["kickstart", job])
        guard start.0 == 0 else { fail("Could not start helper: \(start.1)") }
    }
    let deadline = Date().addingTimeInterval(50)
    var progressAt = Date().addingTimeInterval(5)
    while Date() < deadline {
        let status = jsonObject(paths.status)
        let phase = status["phase"] as? String
        let query = launchctl(["print", job])
        if query.0 == 124 { fail(query.1) }
        let pid = runningPID(query.1)
        if livePhase(status, pid: pid) == "running" {
            print("Background HiDPI active: \(mode.width) × \(mode.height). Login startup: \(enabled ? "enabled" : "disabled").")
            return
        }
        if let phase, ["failed", "restore-failed", "failed-restored", "stopped"].contains(phase) {
            fail("Background startup ended (\(phase)). See \(paths.log.path).")
        }
        if phase != nil && pid == nil {
            fail("Background helper exited before startup completed. See \(paths.log.path).")
        }
        if Date() >= progressAt {
            print("Still starting: \(phase ?? "waiting for launchd")…")
            fflush(stdout)
            progressAt = Date().addingTimeInterval(5)
        }
        Thread.sleep(forTimeInterval: 0.2)
    }
    fail("Startup is still pending. Run hidpi status; logs: \(paths.log.path).")
}
private func uninstallService(_ paths: ServicePaths) throws {
    requireManaged(paths)
    stopService(paths)
    let fm = FileManager.default
    if (try? fm.destinationOfSymbolicLink(atPath: paths.shortcut.path)) == paths.cli.path { try fm.removeItem(at: paths.shortcut) }
    let owned = ["hidpi", "hidpi-test", "hidpi-test-LICENSE.txt", "LICENSE", "THIRD_PARTY_NOTICES.md", "verified.json", "mode.json", "service-status.json", "service.log", "installation.json", "management.lock"]
    for url in [paths.agent] + owned.map({ paths.root.appendingPathComponent($0) }) {
        if fm.fileExists(atPath: url.path) { try fm.removeItem(at: url) }
    }
    if (try? fm.contentsOfDirectory(atPath: paths.root.path).isEmpty) == true { try fm.removeItem(at: paths.root) }
    print("Uninstalled helper, login agent, shortcut, history, and logs. Source/output copies were retained.")
}

func handleServiceCommand(_ arguments: [String] = Array(CommandLine.arguments.dropFirst())) {
    guard let command = arguments.first,
          ["install", "uninstall", "start", "stop", "enable", "disable", "status", "--service-self-test"].contains(command) else { return }
    let values = Array(arguments.dropFirst())
    let paths = ServicePaths(home: FileManager.default.homeDirectoryForCurrentUser)
    if !["start", "enable"].contains(command) && !values.isEmpty { fail("\(command) takes no arguments.") }
    do {
        if command == "--service-self-test" {
            let fixture = ServicePaths(home: URL(fileURLWithPath: "/tmp/hidpi fixture"))
            let mode = ServiceMode(width: 1920, height: 1200, uuid: "example")
            let disabled = agentContents(fixture, mode: mode, enabled: false)
            let enabled = agentContents(fixture, mode: mode, enabled: true)
            precondition(disabled["RunAtLoad"] as? Bool == false && enabled["RunAtLoad"] as? Bool == true)
            precondition(enabled["KeepAlive"] as? Bool == false)
            precondition((enabled["ProgramArguments"] as? [String]) == [fixture.helper.path, "--service", "1920", "1200", "example"])
            precondition(runningPID("state = running\n\tpid = 2345\n") == 2345)
            precondition(runningPID("state = not running\n") == nil)
            let data = try PropertyListSerialization.data(fromPropertyList: enabled, format: .xml, options: 0)
            _ = try PropertyListSerialization.propertyList(from: data, format: nil)
            let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("hidpi-test-\(UUID().uuidString)")
            let paths = ServicePaths(home: temporary)
            defer { try? FileManager.default.removeItem(at: temporary); launchctlForTest = nil }
            var loaded = false, running = false
            launchctlForTest = { args in
                switch args.first {
                case "print": return loaded ? (0, running ? "state = running\n pid = 12345\n" : "state = not running\n") : (113, "not loaded")
                case "bootstrap":
                    loaded = true
                    running = plistObject(paths.agent)["RunAtLoad"] as? Bool == true
                    if running { try! checkedWrite(["phase": "running", "pid": 12345], to: paths.status) }
                case "kickstart": running = true; try! checkedWrite(["phase": "running", "pid": 12345], to: paths.status)
                case "kill": running = false; try! checkedWrite(["phase": "stopped"], to: paths.status)
                case "bootout": loaded = false; running = false
                default: return (1, "unexpected command")
                }
                return (0, "")
            }
            try installService(paths)
            precondition(FileManager.default.isExecutableFile(atPath: paths.cli.path))
            precondition(FileManager.default.fileExists(atPath: paths.root.appendingPathComponent("LICENSE").path))
            precondition(FileManager.default.fileExists(atPath: paths.root.appendingPathComponent("THIRD_PARTY_NOTICES.md").path))
            precondition(plistObject(paths.agent)["RunAtLoad"] as? Bool == false)
            let key = verificationKey(uuid: mode.uuid, os: ProcessInfo.processInfo.operatingSystemVersionString, size: Size(width: mode.width, height: mode.height))
            try checkedWrite([key: Date().timeIntervalSince1970], to: paths.root.appendingPathComponent("verified.json"))
            try startService(paths, mode: mode, enabled: false)
            precondition(running && plistObject(paths.agent)["RunAtLoad"] as? Bool == false)
            stopService(paths)
            try startService(paths, mode: mode, enabled: true)
            precondition(running && plistObject(paths.agent)["RunAtLoad"] as? Bool == true)
            try installService(paths)
            precondition(running && loaded, "Updating must preserve a running helper")
            precondition(plistObject(paths.agent)["RunAtLoad"] as? Bool == true)
            precondition(livePhase(["pid": 12344, "phase": "running"], pid: 12345) == "starting")
            precondition(livePhase(["pid": 12345, "phase": "running"], pid: nil) == "stopped")
            precondition(livePhase(["pid": 12345, "phase": "running"], pid: 12345) == "running")
            let started = ProcessInfo.processInfo.systemUptime
            precondition(capturedCommand("/bin/sleep", ["5"], timeout: 0.1).0 == 124)
            precondition(ProcessInfo.processInfo.systemUptime - started < 2)
            try writeAgent(paths, mode: mode, enabled: false)
            stopService(paths)
            let unrelated = paths.root.appendingPathComponent("keep-me.txt")
            try Data("user file".utf8).write(to: unrelated)
            try uninstallService(paths)
            precondition(!FileManager.default.fileExists(atPath: paths.helper.path))
            precondition(!FileManager.default.fileExists(atPath: paths.agent.path))
            precondition(FileManager.default.fileExists(atPath: unrelated.path))
            print("PASS: install/start/stop/enable/disable/uninstall with simulated launchd; user-file preservation; plist policy")
            exit(0)
        }
        if command == "status" {
            let installed = jsonObject(paths.marker)["owner"] as? String == serviceLabel
            let auto = plistObject(paths.agent)["RunAtLoad"] as? Bool ?? false
            let state = launchctl(["print", job])
            let pid = runningPID(state.1)
            print("Installed: \(installed ? "yes" : "no"). Login startup: \(auto ? "enabled" : "disabled").")
            print("Helper: \(pid.map { "PID \($0), " + livePhase(jsonObject(paths.status), pid: $0) } ?? "stopped").")
            if let mode = loadMode(paths) { print("Saved mode: \(mode.width) × \(mode.height).") }
            if installed { print("Log: \(paths.log.path)") }
            exit(0)
        }
        if command == "install" {
            if (try? paths.root.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true {
                fail("Refusing a symlinked installation directory.")
            }
            try FileManager.default.createDirectory(at: paths.root, withIntermediateDirectories: true)
        } else { requireManaged(paths) }
        let lock = open(paths.root.appendingPathComponent("management.lock").path, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
        guard lock >= 0, flock(lock, LOCK_EX | LOCK_NB) == 0 else { fail("Another hidpi management command is running.") }
        if command == "install" { try installService(paths); exit(0) }
        requireManaged(paths)
        switch command {
        case "uninstall": try uninstallService(paths)
        case "stop": stopService(paths)
        case "disable":
            try writeAgent(paths, mode: loadMode(paths), enabled: false)
            stopService(paths)
            print("Login startup disabled.")
        case "start", "enable":
            let mode = resolveMode(values, paths: paths)
            let enabled = command == "enable" || plistObject(paths.agent)["RunAtLoad"] as? Bool == true
            try startService(paths, mode: mode, enabled: enabled)
        default: break
        }
    } catch { fail(error.localizedDescription) }
    exit(0)
}
