// Knob Agent: a menu-bar app that turns the knob's keys (F13, F16–F20) into
// shortcuts for whichever app is in front, and serves the configurator page
// on http://127.0.0.1:8850.

import Cocoa
import Network
import ServiceManagement
import UserNotifications

// MARK: - Config

struct Action: Codable {
    var type: String            // "key", "scroll", "media", "none"
    var key: String?
    var mods: [String]?
    var dx: Int?
    var dy: Int?
    var media: String?
    var label: String?
}

struct Profile: Codable {
    var id: String
    var name: String
    var bundleIds: [String]
    var enabled: Bool?
    var actions: [String: Action]
}

struct Config: Codable {
    var version: Int
    var defaultProfile: Profile
    var profiles: [Profile]
}

// KNOB_AGENT_PORT and --no-prompt exist for testing a second copy beside the real one.
let port: UInt16 = UInt16(ProcessInfo.processInfo.environment["KNOB_AGENT_PORT"] ?? "") ?? 8850
let promptForAccess = !CommandLine.arguments.contains("--no-prompt")
let catchKnob = !CommandLine.arguments.contains("--no-tap") // a test copy can serve the page without catching keys
let allowedHosts: Set<String> = ["127.0.0.1:\(port)", "localhost:\(port)"]
let allowedOrigins: Set<String> = ["http://127.0.0.1:\(port)", "http://localhost:\(port)"]

// The knob's keys, as macOS virtual key codes. F14 and F15 are not used: macOS turns them into
// screen-brightness keys before any app or event tap sees them. With only six usable spare
// F-keys, the top knob's left turn sends F13 with all four modifiers held.
let hyperFlags: CGEventFlags = [.maskControl, .maskAlternate, .maskShift, .maskCommand]

func knobControl(keyCode: Int64, flags: CGEventFlags) -> String? {
    switch keyCode {
    case 105: return flags.contains(hyperFlags) ? "topLeft" : "bottomLeft" // ⌃⌥⇧⌘F13 / F13
    case 90: return "bottomRight" // F20
    case 106: return "topRight"   // F16
    case 64: return "topPress"    // F17
    case 79: return "pressLeft"   // F18
    case 80: return "pressRight"  // F19
    default: return nil
    }
}

// macOS virtual key codes (US layout positions).
let keyCodes: [String: CGKeyCode] = [
    "a": 0x00, "s": 0x01, "d": 0x02, "f": 0x03, "h": 0x04, "g": 0x05, "z": 0x06, "x": 0x07,
    "c": 0x08, "v": 0x09, "b": 0x0B, "q": 0x0C, "w": 0x0D, "e": 0x0E, "r": 0x0F, "y": 0x10,
    "t": 0x11, "1": 0x12, "2": 0x13, "3": 0x14, "4": 0x15, "6": 0x16, "5": 0x17, "=": 0x18,
    "9": 0x19, "7": 0x1A, "-": 0x1B, "8": 0x1C, "0": 0x1D, "]": 0x1E, "o": 0x1F, "u": 0x20,
    "[": 0x21, "i": 0x22, "p": 0x23, "return": 0x24, "l": 0x25, "j": 0x26, "'": 0x27, "k": 0x28,
    ";": 0x29, "\\": 0x2A, ",": 0x2B, "/": 0x2C, "n": 0x2D, "m": 0x2E, ".": 0x2F, "tab": 0x30,
    "space": 0x31, "`": 0x32, "delete": 0x33, "escape": 0x35,
    "f1": 0x7A, "f2": 0x78, "f3": 0x63, "f4": 0x76, "f5": 0x60, "f6": 0x61, "f7": 0x62,
    "f8": 0x64, "f9": 0x65, "f10": 0x6D, "f11": 0x67, "f12": 0x6F,
    "home": 0x73, "pageup": 0x74, "forwarddelete": 0x75, "end": 0x77, "pagedown": 0x79,
    "left": 0x7B, "right": 0x7C, "down": 0x7D, "up": 0x7E,
]

// NX_KEYTYPE_* codes for system media keys.
let mediaCodes: [String: Int] = [
    "volumeUp": 0, "volumeDown": 1, "brightnessUp": 2, "brightnessDown": 3,
    "mute": 7, "playPause": 16, "next": 17, "previous": 18,
]

let ourEventTag: Int64 = 0x4B4E4F42 // marks events we post, so the tap ignores them

// MARK: - App

var agent: Agent!

final class Agent: NSObject, NSApplicationDelegate, NSMenuDelegate {
    var config: Config!
    var presets: Config!
    var tap: CFMachPort?
    var listening = false        // configuration mode: report knob events, don't act on them
    var paused = false
    var serverError: String?
    var recentApps: [[String: String]] = []
    var installedApps: [[String: String]] = []
    var server: HTTPServer?
    var statusItem: NSStatusItem!
    let eventSource = CGEventSource(stateID: .privateState)

    var supportDir: URL {
        if let dir = ProcessInfo.processInfo.environment["KNOB_AGENT_DATA"] { return URL(fileURLWithPath: dir, isDirectory: true) }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Knob Agent", isDirectory: true)
    }
    var configURL: URL { supportDir.appendingPathComponent("config.json") }
    var webDir: URL { Bundle.main.resourceURL!.appendingPathComponent("web", isDirectory: true) }

    func applicationDidFinishLaunching(_ note: Notification) {
        loadConfig()
        setUpStatusItem()
        startServer()
        requestPermissionsAndTap()
        scanInstalledApps()
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(appActivated(_:)),
            name: NSWorkspace.didActivateApplicationNotification, object: nil)
        if let front = NSWorkspace.shared.frontmostApplication { noteApp(front) }
        startBatteryPolling()
    }

    // MARK: Battery

    var battery: Int?
    var batteryDeviceName: String?
    var warnedAt = 101   // lowest threshold already notified; reset once the knob is charged

    func startBatteryPolling() {
        readBattery()
        Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in self?.readBattery() }
    }

    func readBattery() {
        DispatchQueue.global(qos: .utility).async {
            var found: (String, Int)?
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/sbin/system_profiler")
            p.arguments = ["SPBluetoothDataType", "-json"]
            let pipe = Pipe()
            p.standardOutput = pipe
            p.standardError = FileHandle.nullDevice
            if (try? p.run()) != nil {
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                p.waitUntilExit()
                found = Agent.knobBattery(in: data)
            }
            DispatchQueue.main.async { self.updateBattery(found) }
        }
    }

    /// The knob's name and battery level, if it's connected over Bluetooth. Over Bluetooth it
    /// presents itself with Apple's vendor ID 0x05AC and product ID 0x022C, named MINI_KEYBOARD.
    static func knobBattery(in data: Data) -> (String, Int)? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let controllers = root["SPBluetoothDataType"] as? [[String: Any]] else { return nil }
        for ctl in controllers {
            for entry in ctl["device_connected"] as? [[String: Any]] ?? [] {
                for (name, value) in entry {
                    guard let info = value as? [String: Any] else { continue }
                    let ids = ((info["device_vendorID"] as? String)?.lowercased(), (info["device_productID"] as? String)?.lowercased())
                    let isKnob = name.uppercased().contains("MINI_KEYBOARD") || (ids.0 == "0x05ac" && ids.1 == "0x022c")
                    guard isKnob, let level = info["device_batteryLevelMain"] as? String,
                          let pct = Int(level.trimmingCharacters(in: CharacterSet(charactersIn: "% "))) else { continue }
                    return (name, pct)
                }
            }
        }
        return nil
    }

    func updateBattery(_ found: (String, Int)?) {
        let changed = found?.1 != battery
        battery = found?.1
        batteryDeviceName = found?.0
        updateStatusTitle()
        if changed {
            server?.broadcast(["type": "battery", "level": battery.map { $0 as Any } ?? NSNull(),
                               "device": batteryDeviceName.map { $0 as Any } ?? NSNull()])
        }
        guard let level = battery else { return }
        if level >= 30 { warnedAt = 101 }
        if let threshold = [10, 20].first(where: { level <= $0 }), warnedAt > threshold {
            warnedAt = threshold
            notifyLowBattery(level)
        }
    }

    func notifyLowBattery(_ level: Int) {
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = "Knob battery low: \(level)%"
            content.body = "Charge it with the USB-C cable. With the lights off, a charge lasts much longer."
            center.add(UNNotificationRequest(identifier: "knob-battery", content: content, trigger: nil))
        }
    }

    func updateStatusTitle() {
        guard let button = statusItem?.button, button.image != nil else { return }
        if let b = battery, b <= 20 {
            button.title = " \(b)%"
            button.imagePosition = .imageLeading
        } else {
            button.title = ""
        }
    }

    // MARK: Config

    func loadConfig() {
        let presetsURL = webDir.appendingPathComponent("presets.json")
        do {
            presets = try JSONDecoder().decode(Config.self, from: Data(contentsOf: presetsURL))
        } catch {
            NSLog("Knob Agent: presets.json unreadable: \(error)")
            presets = Config(version: 1, defaultProfile: Profile(id: "default", name: "Everything else", bundleIds: [], enabled: true, actions: [:]), profiles: [])
        }
        if let data = try? Data(contentsOf: configURL),
           let saved = try? JSONDecoder().decode(Config.self, from: data) {
            config = saved
        } else {
            config = presets
        }
    }

    func saveConfig() throws {
        try FileManager.default.createDirectory(at: supportDir, withIntermediateDirectories: true)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(config).write(to: configURL, options: .atomic)
    }

    func profile(for bundleId: String?) -> Profile? {
        guard let b = bundleId?.lowercased() else { return nil }
        return config.profiles.first { p in
            p.enabled != false && p.bundleIds.contains { !$0.isEmpty && b.hasPrefix($0.lowercased()) }
        }
    }

    // MARK: Knob events

    func handle(control: String) {
        let front = NSWorkspace.shared.frontmostApplication
        let prof = profile(for: front?.bundleIdentifier)
        server?.broadcast(["type": "knob", "control": control, "profile": prof?.id ?? "default"])
        if listening || paused { return }
        guard let action = prof?.actions[control] ?? config.defaultProfile.actions[control] else { return }
        perform(action)
    }

    func perform(_ a: Action) {
        switch a.type {
        case "key":
            guard let name = a.key?.lowercased(), let code = keyCodes[name] else { return }
            var flags: CGEventFlags = []
            for m in a.mods ?? [] {
                switch m {
                case "cmd": flags.insert(.maskCommand)
                case "shift": flags.insert(.maskShift)
                case "alt": flags.insert(.maskAlternate)
                case "ctrl": flags.insert(.maskControl)
                default: break
                }
            }
            for down in [true, false] {
                guard let e = CGEvent(keyboardEventSource: eventSource, virtualKey: code, keyDown: down) else { continue }
                e.flags = flags
                e.setIntegerValueField(.eventSourceUserData, value: ourEventTag)
                e.post(tap: .cghidEventTap)
            }
        case "scroll":
            guard let e = CGEvent(scrollWheelEvent2Source: eventSource, units: .line, wheelCount: 2,
                                  wheel1: Int32(a.dy ?? 0), wheel2: Int32(a.dx ?? 0), wheel3: 0) else { return }
            e.flags = [] // never inherit the modifiers the knob holds for ⌃⌥⇧⌘F13
            e.setIntegerValueField(.eventSourceUserData, value: ourEventTag)
            e.post(tap: .cghidEventTap)
        case "media":
            guard let name = a.media, let code = mediaCodes[name] else { return }
            for down in [true, false] {
                let state = down ? 0xA : 0xB
                let ev = NSEvent.otherEvent(
                    with: .systemDefined, location: .zero,
                    modifierFlags: NSEvent.ModifierFlags(rawValue: UInt(state << 8)),
                    timestamp: 0, windowNumber: 0, context: nil, subtype: 8,
                    data1: (code << 16) | (state << 8), data2: -1)
                ev?.cgEvent?.post(tap: .cghidEventTap)
            }
        default:
            break
        }
    }

    // MARK: Permissions and the event tap

    func requestPermissionsAndTap() {
        guard promptForAccess else { tryCreateTap(); return }
        if !AXIsProcessTrusted() {
            let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(opts)
        }
        if !CGPreflightListenEventAccess() { _ = CGRequestListenEventAccess() }
        if !CGPreflightPostEventAccess() { _ = CGRequestPostEventAccess() }
        tryCreateTap()
    }

    func tryCreateTap() {
        if tap != nil || !catchKnob { return }
        let mask = (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.keyUp.rawValue)
        tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                eventsOfInterest: CGEventMask(mask), callback: tapCallback, userInfo: nil)
        if let tap {
            let src = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
            CFRunLoopAddSource(CFRunLoopGetMain(), src, .commonModes)
            CGEvent.tapEnable(tap: tap, enable: true)
            NSLog("Knob Agent: listening for the knob")
        } else {
            // Not allowed yet: try again until the user grants access in System Settings.
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in self?.tryCreateTap() }
        }
    }

    // MARK: Apps

    @objc func appActivated(_ note: Notification) {
        if let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication { noteApp(app) }
    }

    func noteApp(_ app: NSRunningApplication) {
        guard let id = app.bundleIdentifier, id != Bundle.main.bundleIdentifier else { return }
        let entry = ["bundleId": id, "name": app.localizedName ?? id]
        recentApps.removeAll { $0["bundleId"] == id }
        recentApps.insert(entry, at: 0)
        if recentApps.count > 12 { recentApps.removeLast() }
        server?.broadcast(["type": "app", "bundleId": id, "name": entry["name"]!, "profile": profile(for: id)?.id ?? "default"])
    }

    func scanInstalledApps() {
        DispatchQueue.global(qos: .utility).async {
            var found: [String: String] = [:]
            let fm = FileManager.default
            let roots = [URL(fileURLWithPath: "/Applications"),
                         fm.homeDirectoryForCurrentUser.appendingPathComponent("Applications")]
            func visit(_ dir: URL, depth: Int) {
                guard let items = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { return }
                for url in items {
                    if url.pathExtension == "app" {
                        if let b = Bundle(url: url), let id = b.bundleIdentifier {
                            found[id] = url.deletingPathExtension().lastPathComponent
                        }
                    } else if depth < 2 {
                        visit(url, depth: depth + 1)
                    }
                }
            }
            roots.forEach { visit($0, depth: 0) }
            let list = found.map { ["bundleId": $0.key, "name": $0.value] }
                .sorted { $0["name"]!.localizedCaseInsensitiveCompare($1["name"]!) == .orderedAscending }
            DispatchQueue.main.async { self.installedApps = list }
        }
    }

    // MARK: Server

    func startServer() {
        do {
            let s = try HTTPServer(port: port)
            server = s
            s.start { [weak self] state in
                guard let self else { return }
                if case .failed(let err) = state {
                    // Usually the port is still held by something else (or not yet released): keep trying.
                    self.serverError = "Port \(port) is busy (\(err.localizedDescription)). Retrying…"
                    NSLog("Knob Agent: \(self.serverError ?? "")")
                    s.listener.cancel()
                    if self.server === s { self.server = nil }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                        if self?.server == nil { self?.startServer() }
                    }
                } else if case .ready = state {
                    self.serverError = nil
                    NSLog("Knob Agent: page at http://127.0.0.1:\(port)/")
                }
            }
        } catch {
            serverError = "Couldn't start the page server: \(error.localizedDescription)"
        }
    }

    func stateJSON() -> [String: Any] {
        let enc = JSONEncoder()
        let cfg = (try? JSONSerialization.jsonObject(with: enc.encode(config))) ?? [:]
        let pre = (try? JSONSerialization.jsonObject(with: enc.encode(presets))) ?? [:]
        let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? ""
        return [
            "config": cfg,
            "presets": pre,
            "recentApps": recentApps,
            "installedApps": installedApps,
            "frontmost": front,
            "trusted": AXIsProcessTrusted(),
            "tapActive": tap != nil,
            "paused": paused,
            "listening": listening,
            "loginItem": SMAppService.mainApp.status == .enabled,
            "battery": battery.map { $0 as Any } ?? NSNull(),
            "batteryDevice": batteryDeviceName.map { $0 as Any } ?? NSNull(),
        ]
    }

    func handleAPI(_ req: Request) -> (Int, Data, String) {
        func json(_ obj: Any, _ status: Int = 200) -> (Int, Data, String) {
            ((status), (try? JSONSerialization.data(withJSONObject: obj)) ?? Data("{}".utf8), "application/json")
        }
        switch (req.method, req.path) {
        case ("GET", "/api/state"):
            return json(stateJSON())
        case ("PUT", "/api/config"):
            do {
                config = try JSONDecoder().decode(Config.self, from: req.body)
                try saveConfig()
                return json(["ok": true])
            } catch {
                return json(["ok": false, "error": "\(error)"], 400)
            }
        case ("POST", "/api/reset"):
            config = presets
            try? saveConfig()
            return json(stateJSON())
        case ("POST", "/api/listen"):
            let on = (try? JSONSerialization.jsonObject(with: req.body) as? [String: Any])?["on"] as? Bool ?? false
            listening = on
            return json(["listening": listening])
        case ("POST", "/api/login"):
            let on = (try? JSONSerialization.jsonObject(with: req.body) as? [String: Any])?["on"] as? Bool ?? false
            do {
                if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                return json(["loginItem": SMAppService.mainApp.status == .enabled])
            } catch {
                return json(["error": error.localizedDescription, "loginItem": SMAppService.mainApp.status == .enabled], 400)
            }
        default:
            return json(["error": "not found"], 404)
        }
    }

    func sseClosed(remaining: Int) {
        if remaining == 0 { listening = false } // the page went away: leave configuration mode
    }

    // MARK: Menu bar

    func setUpStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let img = NSImage(systemSymbolName: "dial.medium", accessibilityDescription: "Knob Agent") {
            img.isTemplate = true
            statusItem.button?.image = img
        } else {
            statusItem.button?.title = "◎"
        }
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let front = NSWorkspace.shared.frontmostApplication
        let prof = profile(for: front?.bundleIdentifier)
        func info(_ s: String) { let i = NSMenuItem(title: s, action: nil, keyEquivalent: ""); i.isEnabled = false; menu.addItem(i) }
        if let err = serverError { info(err) }
        if tap == nil {
            menu.addItem(withTitle: "Allow Knob Agent in Accessibility…", action: #selector(openAccessibility), keyEquivalent: "").target = self
        } else {
            info(paused ? "Paused" : "Knob profile: \(prof?.name ?? config.defaultProfile.name)")
        }
        info(battery.map { "Knob battery: \($0)%" } ?? "Knob battery: shown when connected over Bluetooth")
        readBattery() // refresh for next time the menu opens
        menu.addItem(.separator())
        menu.addItem(withTitle: "Open configurator…", action: #selector(openPage), keyEquivalent: ",").target = self
        let pause = menu.addItem(withTitle: "Pause", action: #selector(togglePause), keyEquivalent: "")
        pause.target = self
        pause.state = paused ? .on : .off
        let login = menu.addItem(withTitle: "Open at login", action: #selector(toggleLogin), keyEquivalent: "")
        login.target = self
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Knob Agent", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
    }

    @objc func openPage() { NSWorkspace.shared.open(URL(string: "http://127.0.0.1:\(port)/")!) }
    @objc func togglePause() { paused.toggle() }
    @objc func openAccessibility() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_Accessibility")!)
    }
    @objc func toggleLogin() {
        do {
            if SMAppService.mainApp.status == .enabled { try SMAppService.mainApp.unregister() }
            else { try SMAppService.mainApp.register() }
        } catch {
            NSLog("Knob Agent: login item change failed: \(error)")
        }
    }
}

let tapCallback: CGEventTapCallBack = { _, type, event, _ in
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        if let tap = agent.tap { CGEvent.tapEnable(tap: tap, enable: true) }
        return Unmanaged.passUnretained(event)
    }
    guard type == .keyDown || type == .keyUp,
          event.getIntegerValueField(.eventSourceUserData) != ourEventTag,
          let control = knobControl(keyCode: event.getIntegerValueField(.keyboardEventKeycode), flags: event.flags)
    else { return Unmanaged.passUnretained(event) }
    if type == .keyDown && event.getIntegerValueField(.keyboardEventAutorepeat) == 0 {
        agent.handle(control: control)
    }
    return nil // swallow the knob's F-key
}

// MARK: - A small HTTP server (localhost only)

struct Request {
    var method: String
    var path: String
    var headers: [String: String]
    var body: Data

    static func parse(_ buf: Data) -> Request? {
        guard let end = buf.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        guard let head = String(data: buf[buf.startIndex..<end.lowerBound], encoding: .utf8) else { return nil }
        var lines = head.components(separatedBy: "\r\n")
        let first = lines.removeFirst().split(separator: " ")
        guard first.count >= 2 else { return nil }
        var headers: [String: String] = [:]
        for l in lines {
            guard let colon = l.firstIndex(of: ":") else { continue }
            headers[l[..<colon].lowercased()] = l[l.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        let length = Int(headers["content-length"] ?? "0") ?? 0
        let body = buf[end.upperBound...]
        guard body.count >= length else { return nil }
        let rawPath = String(first[1])
        let path = rawPath.split(separator: "?", maxSplits: 1).first.map(String.init) ?? rawPath
        return Request(method: String(first[0]), path: path, headers: headers, body: Data(body.prefix(length)))
    }
}

final class HTTPServer {
    let listener: NWListener
    var sseClients: [ObjectIdentifier: NWConnection] = [:]

    init(port: UInt16) throws {
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        params.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!)
        listener = try NWListener(using: params)
    }

    func start(_ onState: @escaping (NWListener.State) -> Void) {
        listener.stateUpdateHandler = onState
        listener.newConnectionHandler = { [weak self] c in
            c.start(queue: .main)
            self?.read(c, Data())
        }
        listener.start(queue: .main)
    }

    func read(_ c: NWConnection, _ buffer: Data) {
        c.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, done, error in
            guard let self else { return }
            var buf = buffer
            if let data { buf.append(data) }
            if let req = Request.parse(buf) { self.route(req, c); return }
            if done || error != nil || buf.count > 4_000_000 { c.cancel(); return }
            self.read(c, buf)
        }
    }

    func route(_ req: Request, _ c: NWConnection) {
        // Only answer requests addressed to this machine by name, and only accept
        // changes from this page itself: other websites can't reach the agent.
        guard allowedHosts.contains(req.headers["host"] ?? "") else { return reply(c, 403, Data("Forbidden".utf8), "text/plain") }
        if req.method != "GET" {
            guard allowedOrigins.contains(req.headers["origin"] ?? ""),
                  (req.headers["content-type"] ?? "").hasPrefix("application/json")
            else { return reply(c, 403, Data("Forbidden".utf8), "text/plain") }
        }
        if req.method == "GET" && req.path == "/api/events" { return openEventStream(c) }
        if req.path.hasPrefix("/api/") {
            let (status, body, type) = agent.handleAPI(req)
            return reply(c, status, body, type)
        }
        let files = ["/": ("index.html", "text/html; charset=utf-8"),
                     "/index.html": ("index.html", "text/html; charset=utf-8"),
                     "/presets.json": ("presets.json", "application/json")]
        guard req.method == "GET", let (name, type) = files[req.path],
              let data = try? Data(contentsOf: agent.webDir.appendingPathComponent(name))
        else { return reply(c, 404, Data("Not found".utf8), "text/plain") }
        reply(c, 200, data, type)
    }

    func reply(_ c: NWConnection, _ status: Int, _ body: Data, _ type: String) {
        let reason = [200: "OK", 400: "Bad Request", 403: "Forbidden", 404: "Not Found"][status] ?? "OK"
        var head = "HTTP/1.1 \(status) \(reason)\r\nContent-Type: \(type)\r\nContent-Length: \(body.count)\r\n"
        head += "Cache-Control: no-store\r\nX-Content-Type-Options: nosniff\r\nConnection: close\r\n\r\n"
        var out = Data(head.utf8)
        out.append(body)
        c.send(content: out, completion: .contentProcessed { _ in c.cancel() })
    }

    func openEventStream(_ c: NWConnection) {
        let head = "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nCache-Control: no-store\r\nConnection: keep-alive\r\n\r\n: hello\n\n"
        c.send(content: Data(head.utf8), completion: .contentProcessed { _ in })
        let id = ObjectIdentifier(c)
        sseClients[id] = c
        let drop = { [weak self] in
            guard let self, self.sseClients.removeValue(forKey: id) != nil else { return }
            c.cancel()
            agent.sseClosed(remaining: self.sseClients.count)
        }
        c.stateUpdateHandler = { state in
            switch state { case .failed, .cancelled: drop(); default: break }
        }
        func watch() {
            c.receive(minimumIncompleteLength: 1, maximumLength: 1024) { _, _, done, error in
                if done || error != nil { drop() } else { watch() }
            }
        }
        watch()
    }

    func broadcast(_ obj: [String: Any]) {
        guard !sseClients.isEmpty, let data = try? JSONSerialization.data(withJSONObject: obj),
              let text = String(data: data, encoding: .utf8) else { return }
        let msg = Data("data: \(text)\n\n".utf8)
        for c in sseClients.values { c.send(content: msg, completion: .contentProcessed { _ in }) }
    }
}

// MARK: - Main

let app = NSApplication.shared
agent = Agent()
app.delegate = agent
app.setActivationPolicy(.accessory)
app.run()
