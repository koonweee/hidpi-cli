import AppKit
import CoreGraphics
import Foundation
import MachO

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("hidpi: \(message)\n".utf8))
    exit(1)
}

func check(_ result: CGError, _ action: String) {
    if result != .success { fail("\(action) failed (CoreGraphics error \(result.rawValue)).") }
}

func choose(_ prompt: String, count: Int, cancelLabel: String = "quit") -> Int {
    while true {
        print("\(prompt) [1–\(count), q to \(cancelLabel)]: ", terminator: "")
        fflush(stdout)
        guard let input = readLine()?.trimmingCharacters(in: .whitespacesAndNewlines),
              !["q", "quit", ""].contains(input.lowercased()) else { exit(0) }
        if let index = Int(input), (1...count).contains(index) { return index - 1 }
        print("Enter a number from 1 to \(count), or q.")
    }
}

func isHiDPI(_ mode: CGDisplayMode) -> Bool {
    mode.width > 0 && mode.height > 0 &&
    mode.pixelWidth > mode.width && mode.pixelHeight > mode.height &&
    mode.isUsableForDesktopGUI()
}

func modeKey(_ mode: CGDisplayMode) -> String {
    "\(mode.width):\(mode.height):\(mode.pixelWidth):\(mode.pixelHeight):\(mode.refreshRate):\(mode.ioFlags)"
}

func describe(_ mode: CGDisplayMode) -> String {
    let rate = mode.refreshRate > 0 ? String(format: "%.2f Hz", mode.refreshRate) : "system refresh rate"
    return "\(mode.width) × \(mode.height)  |  \(rate)  |  renders \(mode.pixelWidth) × \(mode.pixelHeight)"
}

func modes(for display: CGDirectDisplayID) -> [CGDisplayMode] {
    let options = [kCGDisplayShowDuplicateLowResolutionModes as String: true] as CFDictionary
    let all = CGDisplayCopyAllDisplayModes(display, options) as? [CGDisplayMode] ?? []
    let current = CGDisplayCopyDisplayMode(display)
    var unique: [String: CGDisplayMode] = [:]
    for mode in all where isHiDPI(mode) {
        let key = modeKey(mode)
        if unique[key] == nil || mode.ioDisplayModeID == current?.ioDisplayModeID {
            unique[key] = mode
        }
    }
    return unique.values.sorted {
        if $0.width != $1.width { return $0.width < $1.width }
        if $0.height != $1.height { return $0.height < $1.height }
        if $0.refreshRate != $1.refreshRate { return $0.refreshRate > $1.refreshRate }
        return $0.ioDisplayModeID < $1.ioDisplayModeID
    }
}

struct Size: Hashable {
    let width: Int
    let height: Int
}

enum Choice {
    case native(CGDisplayMode)
    case virtual(Size, verified: Bool)

    var size: Size {
        switch self {
        case .native(let mode): return Size(width: mode.width, height: mode.height)
        case .virtual(let size, _): return size
        }
    }
}

func virtualSizes(panel: Size, native: Set<Size>) -> [Size] {
    guard panel.width > 0, panel.height > 0 else { return [] }
    let widths = Set([1280, 1440, 1600, 1680, 1920, 2048, 2304, 2560, panel.width])
    return widths.sorted().compactMap { width in
        let height = Int((Double(width) * Double(panel.height) / Double(panel.width) / 2).rounded()) * 2
        let size = Size(width: width, height: height)
        guard width >= 800, width <= min(panel.width, 2560), (600...1600).contains(height),
              !native.contains(size) else { return nil }
        return size
    }
}

func panelSize(_ display: CGDirectDisplayID) -> Size? {
    let options = [kCGDisplayShowDuplicateLowResolutionModes as String: true] as CFDictionary
    let all = (CGDisplayCopyAllDisplayModes(display, options) as? [CGDisplayMode] ?? [])
        .filter { $0.isUsableForDesktopGUI() }
    // kDisplayModeNativeFlag, defined by IOKit's IOGraphicsTypes.h.
    let native = all.filter { $0.ioFlags & 0x02000000 != 0 }
    let unscaled = all.filter { $0.width == $0.pixelWidth && $0.height == $0.pixelHeight }
    if let best = (native.isEmpty ? unscaled : native).max(by: {
        $0.pixelWidth * $0.pixelHeight < $1.pixelWidth * $1.pixelHeight
    }) {
        return Size(width: best.pixelWidth, height: best.pixelHeight)
    }
    guard let current = CGDisplayCopyDisplayMode(display) else { return nil }
    return Size(width: current.width, height: current.height)
}

func helperURL() -> URL {
    var count: UInt32 = 0
    _ = _NSGetExecutablePath(nil, &count)
    var path = [CChar](repeating: 0, count: Int(count))
    guard _NSGetExecutablePath(&path, &count) == 0 else { fail("Cannot find the helper beside this executable.") }
    return URL(fileURLWithPath: String(cString: path)).resolvingSymlinksInPath()
        .deletingLastPathComponent().appendingPathComponent("hidpi-test")
}

func verificationKey(uuid: String, os: String, size: Size) -> String {
    "\(uuid)|\(os)|virtual-v1|\(size.width)x\(size.height)@60"
}

func verifiedRecords() -> [String: Double] {
    let directory: URL
    if let override = ProcessInfo.processInfo.environment["HIDPI_STATE_DIR"], !override.isEmpty {
        directory = URL(fileURLWithPath: override, isDirectory: true)
    } else {
        directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("hidpi", isDirectory: true)
    }
    guard let data = try? Data(contentsOf: directory.appendingPathComponent("verified.json")),
          let records = try? JSONDecoder().decode([String: Double].self, from: data) else { return [:] }
    return records
}

func choices(for display: CGDirectDisplayID) -> [Choice] {
    let available = modes(for: display)
    var result = available.map { Choice.native($0) }
    guard CGDisplayIsBuiltin(display) == 0, CGDisplayIsInMirrorSet(display) == 0,
          FileManager.default.isExecutableFile(atPath: helperURL().path),
          let panel = panelSize(display) else { return result }
    let records = verifiedRecords()
    let uuid = CGDisplayCreateUUIDFromDisplayID(display).map { CFUUIDCreateString(nil, $0.takeRetainedValue()) as String }
    let nativeSizes = Set(available.map { Size(width: $0.width, height: $0.height) })
    for size in virtualSizes(panel: panel, native: nativeSizes) {
        let key = uuid.map { verificationKey(uuid: $0, os: ProcessInfo.processInfo.operatingSystemVersionString, size: size) }
        result.append(.virtual(size, verified: key.map { records[$0] != nil } ?? false))
    }
    return result.sorted {
        if $0.size.width != $1.size.width { return $0.size.width < $1.size.width }
        if $0.size.height != $1.size.height { return $0.size.height < $1.size.height }
        if case .native(let a) = $0, case .native(let b) = $1 {
            if a.refreshRate != b.refreshRate { return a.refreshRate > b.refreshRate }
            return a.ioDisplayModeID < b.ioDisplayModeID
        }
        return false
    }
}

func launchVirtual(_ size: Size, display: CGDirectDisplayID) -> Never {
    let helper = helperURL().path
    print("Virtual mode: 20-second trial; k + Enter keeps it running; Ctrl-C restores.")
    fflush(stdout)
    // Replace this process so the proven supervisor owns the terminal and signals.
    let arguments = [helper, String(size.width), String(size.height), String(display)]
    var pointers = arguments.map { strdup($0) } + [nil]
    execv(helper, &pointers)
    let message = String(cString: strerror(errno))
    for pointer in pointers { if let pointer { free(pointer) } }
    fail("Could not launch hidpi-test: \(message)")
}

func runMenuCommand(_ arguments: [String], helper: Bool = false) -> Int32 {
    let task = Process()
    task.executableURL = helper ? helperURL() : helperURL().deletingLastPathComponent().appendingPathComponent("hidpi")
    task.arguments = arguments
    task.standardInput = FileHandle.standardInput
    task.standardOutput = FileHandle.standardOutput
    task.standardError = FileHandle.standardError
    var environment = ProcessInfo.processInfo.environment
    // Foundation launches tasks in their own process groups on macOS. A child
    // reading this terminal from that background group would stop on SIGTTIN.
    // Rejoin the menu's foreground group in the child before any input occurs.
    environment["HIDPI_MENU_PROCESS_GROUP"] = String(getpgrp())
    task.environment = environment
    // Ctrl-C belongs to the active command. Its exit returns to this menu.
    signal(SIGINT, SIG_IGN)
    defer { signal(SIGINT, SIG_DFL) }
    do { try task.run(); task.waitUntilExit(); return task.terminationStatus }
    catch { print("Could not run command: \(error.localizedDescription)"); return 1 }
}

func chooseExternalDisplay() -> CGDirectDisplayID {
    var count: UInt32 = 0
    check(CGGetOnlineDisplayList(0, nil, &count), "Reading displays")
    guard count > 0 else { fail("No displays visible. Run the menu in your Mac desktop session.") }
    var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
    check(CGGetOnlineDisplayList(count, &ids, &count), "Reading displays")
    let external = ids.prefix(Int(count)).filter { CGDisplayIsBuiltin($0) == 0 && CGDisplayVendorNumber($0) != 0xF0F0 }
    guard !external.isEmpty else { fail("No external monitor found.") }
    if external.count == 1 { return external[0] }
    for (index, id) in external.enumerated() { print("  \(index + 1). \(displayName(id))") }
    return external[choose("Monitor", count: external.count)]
}

func customSize() -> Size {
    while true {
        print("Width height (e.g. 1920 1200), or q to go back: ", terminator: "")
        fflush(stdout)
        guard let line = readLine(), !["q", ""].contains(line.trimmingCharacters(in: .whitespaces).lowercased()) else { exit(0) }
        let pieces = line.split(whereSeparator: { $0.isWhitespace })
        let values = pieces.compactMap { Int($0) }
        if pieces.count == 2, values.count == 2, (800...2560).contains(values[0]), (600...1600).contains(values[1]) {
            return Size(width: values[0], height: values[1])
        }
        print("Enter two numbers: width 800–2560, height 600–1600.")
    }
}

func backgroundMenu(_ command: String) -> Never {
    print(command == "enable" ? "\nStart now and at login" : "\nStart in background")
    print("  1. Use saved resolution (default: 1920 × 1200)\n  2. Choose monitor and resolution\n  3. Enter custom size")
    let action = choose("Action", count: 3)
    if action == 0 { handleServiceCommand([command]); exit(0) }
    let display = chooseExternalDisplay()
    let size: Size
    if action == 2 { size = customSize() }
    else {
        let options = choices(for: display).filter { if case .virtual = $0 { return true }; return false }
        if options.isEmpty {
            print("No virtual suggestions available. Enter a custom size, or return and stop any active virtual session first.")
            size = customSize()
        } else {
            showModes(display, options)
            print("  \(options.count + 1). Custom size…")
            let index = choose("Resolution", count: options.count + 1)
            size = index == options.count ? customSize() : options[index].size
        }
    }
    handleServiceCommand([command, String(size.width), String(size.height), String(display)])
    exit(0)
}

func advancedMenu() -> Never {
    while true {
        print("""

        More options
          1. Choose resolution — native or foreground virtual trial
          2. Start virtual mode in background
          3. Enable virtual mode now and at login
          4. Status
          5. Stop background mode — restore now, keep login preference
          6. Disable login startup and restore
          7. Install / update background helper
          8. Uninstall background helper and clean up
          9. List native modes and virtual candidates
         10. Preview a selection without applying it
         11. Test a custom virtual resolution
         12. Help
         13. Diagnostics / self-tests
        """)
        let selected = choose("Action", count: 13, cancelLabel: "go back")
        switch selected {
        case 0: _ = runMenuCommand(["--pick"])
        case 1: _ = runMenuCommand(["--background-menu", "start"])
        case 2: _ = runMenuCommand(["--background-menu", "enable"])
        case 3: _ = runMenuCommand(["status"])
        case 4: _ = runMenuCommand(["stop"])
        case 5: _ = runMenuCommand(["disable"])
        case 6: _ = runMenuCommand(["install"])
        case 7:
            if runMenuCommand(["uninstall"]) == 0 { exit(42) }
        case 8: _ = runMenuCommand(["--list"])
        case 9: _ = runMenuCommand(["--dry-run"])
        case 10: _ = runMenuCommand(["--custom-trial"])
        case 11: _ = runMenuCommand(["--help"])
        default:
            print("  1. Resolution/candidate checks\n  2. Simulated install and lifecycle checks\n  3. Helper watchdog checks")
            switch choose("Test", count: 3) {
            case 0: _ = runMenuCommand(["--self-test"])
            case 1: _ = runMenuCommand(["--service-self-test"])
            default: _ = runMenuCommand(["--self-test"], helper: true)
            }
        }
    }
}

func mainMenu() -> Never {
    while true {
        let state = menuServiceState()
        print("""

        HiDPI
        \(state.summary)

        Start with “Change resolution”. Choose a screen size, then how to keep it.

          1. Change resolution
          2. Restore normal display and turn off login startup
          3. More options…
        """)
        switch choose("Action", count: 3) {
        case 0: _ = runMenuCommand(["--guided"])
        case 1:
            if state.installed { _ = runMenuCommand(["disable"]) }
            else { print("No background helper is installed; there is nothing to restore.") }
        default:
            if runMenuCommand(["--advanced"]) == 42 { exit(0) }
        }
    }
}

func virtualUsageMenu(_ size: Size, display: CGDirectDisplayID) -> Never {
    print("""

    \(size.width) × \(size.height)
    This size uses a helper to keep the virtual display active.

      1. Try it for 20 seconds
      2. Use it in the background until logout
      3. Use it now and whenever I log in
    """)
    let usage = choose("How long?", count: 3)
    if usage == 0 { launchVirtual(size, display: display) }
    guard let uuidRef = CGDisplayCreateUUIDFromDisplayID(display)?.takeRetainedValue() else { fail("Cannot identify this monitor.") }
    let uuid = CFUUIDCreateString(nil, uuidRef) as String
    let key = verificationKey(uuid: uuid, os: ProcessInfo.processInfo.operatingSystemVersionString, size: size)
    if verifiedRecords()[key] == nil {
        print("This size needs a quick test first. Let the 20-second countdown finish to continue with background setup.")
        let result = runMenuCommand([String(size.width), String(size.height), String(display)], helper: true)
        guard result == 0, verifiedRecords()[key] != nil else {
            print("Background setup cancelled. The test did not finish successfully.")
            exit(0)
        }
    }
    if !menuServiceState().installed {
        print("Installing the background helper…")
        guard runMenuCommand(["install"]) == 0 else { exit(1) }
    }
    // A session-only selection must also turn off an earlier login preference.
    if usage == 1 && menuServiceState().enabled {
        guard runMenuCommand(["disable"]) == 0 else { exit(1) }
    }
    handleServiceCommand([usage == 1 ? "start" : "enable", String(size.width), String(size.height), String(display)])
    exit(0)
}

// Child commands reset SIGINT inherited from the menu process.
signal(SIGINT, SIG_DFL)
if let group = ProcessInfo.processInfo.environment["HIDPI_MENU_PROCESS_GROUP"],
   let pgid = Int32(group), pgid > 1 {
    guard setpgid(0, pgid) == 0 else { fail("Cannot attach submenu to the terminal: \(String(cString: strerror(errno)))") }
    unsetenv("HIDPI_MENU_PROCESS_GROUP")
}
handleServiceCommand()
let args = Set(CommandLine.arguments.dropFirst())
if args.isEmpty || args == ["--menu"] { mainMenu() }
if args == ["--advanced"] { advancedMenu() }
if CommandLine.arguments.count == 3, CommandLine.arguments[1] == "--background-menu",
   ["start", "enable"].contains(CommandLine.arguments[2]) { backgroundMenu(CommandLine.arguments[2]) }
if args == ["--custom-trial"] {
    let display = chooseExternalDisplay()
    launchVirtual(customSize(), display: display)
}
if args == ["--self-test"] {
    let native: Set<Size> = [Size(width: 1600, height: 1000)]
    let hp = virtualSizes(panel: Size(width: 1920, height: 1200), native: native)
    precondition(hp.contains(Size(width: 1920, height: 1200)))
    precondition(hp.contains(Size(width: 1680, height: 1050)))
    precondition(!hp.contains(Size(width: 1600, height: 1000)))
    precondition(hp.allSatisfy { $0.width * 10 == $0.height * 16 })
    for panel in [Size(width: 3840, height: 2160), Size(width: 3440, height: 1440), Size(width: 1200, height: 1920)] {
        let sizes = virtualSizes(panel: panel, native: [])
        precondition(sizes.allSatisfy { $0.width <= min(panel.width, 2560) && (600...1600).contains($0.height) })
        precondition(sizes.allSatisfy { abs(Double($0.height) - Double($0.width) * Double(panel.height) / Double(panel.width)) <= 1 })
    }
    let size = Size(width: 1920, height: 1200)
    precondition(verificationKey(uuid: "A", os: "27", size: size) != verificationKey(uuid: "B", os: "27", size: size))
    precondition(verificationKey(uuid: "A", os: "27", size: size) != verificationKey(uuid: "A", os: "28", size: size))
    print("PASS: candidate aspect ratios, bounds, native deduplication, monitor/OS cache isolation")
    exit(0)
}
if args.contains("--help") || args.contains("-h") {
    print("""
    Usage: hidpi [--menu | --pick | --list | --dry-run | --custom-trial]
           hidpi install | status | stop | disable | uninstall
           hidpi start|enable [width height [display-ID]]

      (no options)  Open the main menu with all actions.
      --menu        Open the main menu.
      --pick        Go straight to the native/virtual resolution picker.
      --custom-trial Test a custom virtual resolution with automatic rollback.
      --list        Show native HiDPI modes and virtual candidates; change nothing.
      --dry-run     Try the interactive selection without applying it.
      --help        Show this help.

    Resolutions are logical desktop sizes; rendering dimensions are also shown.
    Native modes switch directly and are saved through macOS.
    Virtual candidates use the adjacent hidpi-test helper with a 20-second trial.
    Type k + Enter to keep a virtual mode running; Ctrl-C restores the old layout.
    Previously verified means it worked on this monitor and macOS version before.
    Virtual candidates are untested until activated; listing creates no displays.
    install adds a per-user helper; start runs it in the background.
    enable also restores the saved mode at login; disable stops and turns that off.
    stop restores now but preserves your login-startup preference.
    uninstall stops/restores and removes installed helper files and history.
    """)
    exit(0)
}
guard args.isSubset(of: ["--guided", "--pick", "--list", "--dry-run"]) else { fail("Unknown option. Use --help.") }
guard args.count < 2 else { fail("Choose just one of --pick, --list, or --dry-run.") }

if args == ["--guided"] {
    let state = menuServiceState()
    if state.running || state.enabled {
        print("Your existing background/login choice will be cleared before selecting a new resolution.")
        print("  1. Continue\n  2. Go back")
        if choose("Action", count: 2) == 1 { exit(0) }
        guard runMenuCommand(["disable"]) == 0 else { exit(1) }
    }
}

var count: UInt32 = 0
check(CGGetActiveDisplayList(0, nil, &count), "Reading displays")
guard count > 0 else { fail("No active displays. Run this in your logged-in Mac desktop session.") }
var displays = [CGDirectDisplayID](repeating: 0, count: Int(count))
check(CGGetActiveDisplayList(count, &displays, &count), "Reading displays")
displays = Array(displays.prefix(Int(count)))
guard !displays.isEmpty else { fail("No active displays.") }

func displayName(_ id: CGDirectDisplayID) -> String {
    let name = NSScreen.screens.first {
        ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == id
    }?.localizedName ?? "Display \(id)"
    return "\(name)\(CGDisplayIsMain(id) != 0 ? " (main)" : "") [ID \(id)]"
}

func showModes(_ display: CGDirectDisplayID, _ available: [Choice], simple: Bool = false) {
    let current = CGDisplayCopyDisplayMode(display)
    print("\n\(displayName(display))")
    if let current {
        print(simple ? "Current size: \(current.width) × \(current.height)" : "Current: \(describe(current))\(isHiDPI(current) ? " — HiDPI" : " — non-HiDPI")")
    }
    if available.isEmpty {
        print("No native HiDPI modes or virtual candidates available for this display.")
    }
    for (index, choice) in available.enumerated() {
        switch choice {
        case .native(let mode):
            let marker = mode.ioDisplayModeID == current?.ioDisplayModeID ? "  ← current" : ""
            if simple {
                let rate = mode.refreshRate > 0 ? String(format: " · %.0f Hz", mode.refreshRate) : ""
                print("  \(index + 1). \(mode.width) × \(mode.height)\(rate)\(marker)")
            } else { print("  \(index + 1). \(describe(mode))  |  Native\(marker)") }
        case .virtual(let size, let verified):
            print(simple ? "  \(index + 1). \(size.width) × \(size.height) · uses helper · \(verified ? "tested" : "needs test")" : "  \(index + 1). \(size.width) × \(size.height)  |  60 Hz  |  Virtual · \(verified ? "previously verified" : "untested")")
        }
    }
    if available.contains(where: { if case .virtual = $0 { return true }; return false }) {
        print(simple ? "For helper options, you’ll choose whether to try them or keep them in the background." : "Virtual options require the helper to stay running; each selection includes a rollback timer.")
    } else if CGDisplayIsBuiltin(display) == 0 && !FileManager.default.isExecutableFile(atPath: helperURL().path) {
        print("Virtual options unavailable: keep hidpi-test beside hidpi.")
    }
}

if args.contains("--list") {
    for display in displays { showModes(display, choices(for: display)) }
    exit(0)
}

let display: CGDirectDisplayID
if displays.count == 1 {
    display = displays[0]
} else {
    for (index, id) in displays.enumerated() { print("\(index + 1). \(displayName(id))") }
    display = displays[choose("Display", count: displays.count)]
}
let available = choices(for: display)
showModes(display, available, simple: args == ["--guided"])
guard !available.isEmpty else { exit(0) }
var guidedChoice: Choice?
if args == ["--guided"] {
    print("Larger dimensions fit more on screen; smaller dimensions make text larger.")
    if CGDisplayIsBuiltin(display) == 0 { print("  \(available.count + 1). Enter a custom size…") }
}
if args == ["--guided"] && CGDisplayIsBuiltin(display) == 0 {
    let selected = choose("Resolution", count: available.count + 1)
    if selected == available.count { virtualUsageMenu(customSize(), display: display) }
    let choice = available[selected]
    if case .virtual(let size, _) = choice { virtualUsageMenu(size, display: display) }
    // Use the selected mode below without asking twice.
    guidedChoice = choice
}
let choice = guidedChoice ?? available[choose("HiDPI resolution", count: available.count)]
if args.contains("--dry-run") {
    print("Would activate: \(choice.size.width) × \(choice.size.height). No changes made.")
    exit(0)
}
guard CGDisplayIsActive(display) != 0 else { fail("Display disconnected. Run hidpi again.") }
guard CGDisplayIsInMirrorSet(display) == 0 else {
    fail("This display is mirrored. Disable mirroring in System Settings → Displays, then retry.")
}
if case .virtual(let size, _) = choice { launchVirtual(size, display: display) }
guard case .native(let selected) = choice else { fail("Invalid selection.") }
guard modes(for: display).contains(where: { $0.ioDisplayModeID == selected.ioDisplayModeID }) else {
    fail("Available modes changed. Run hidpi again.")
}
if CGDisplayCopyDisplayMode(display)?.ioDisplayModeID == selected.ioDisplayModeID {
    print("Already active.")
    exit(0)
}

var config: CGDisplayConfigRef?
check(CGBeginDisplayConfiguration(&config), "Starting display configuration")
let configured = CGConfigureDisplayWithDisplayMode(config, display, selected, nil)
if configured != .success {
    CGCancelDisplayConfiguration(config)
    check(configured, "Selecting resolution")
}
check(CGCompleteDisplayConfiguration(config, .permanently), "Applying resolution")
guard let actual = CGDisplayCopyDisplayMode(display), isHiDPI(actual),
      actual.width == selected.width, actual.height == selected.height,
      actual.pixelWidth == selected.pixelWidth, actual.pixelHeight == selected.pixelHeight else {
    fail("macOS did not report the requested HiDPI resolution after applying it. Check Displays settings.")
}
print("Active: \(describe(actual)) — HiDPI")
