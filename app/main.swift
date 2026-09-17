import AppKit
import ServiceManagement

enum State {
    case off
    case bootstrapping(Int)
    case connected
    case failed(String)
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let defaults = UserDefaults.standard

    private let statusLine = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let toggleItem = NSMenuItem(title: "", action: #selector(toggle), keyEquivalent: "")
    private let portItem = NSMenuItem(title: "", action: #selector(changePort), keyEquivalent: "")
    private let copyItem = NSMenuItem(title: "", action: #selector(copyAddress), keyEquivalent: "")
    private let loginItem = NSMenuItem(title: "Launch at Login", action: #selector(toggleLogin), keyEquivalent: "")
    private let quitItem = NSMenuItem(title: "Quit Shallot", action: #selector(NSApplication.terminate), keyEquivalent: "q")

    private var child: Process?
    private var childStdin: Pipe?  // The child exits when this closes, so it cannot outlive us.
    private var lastError: String?
    private var stopping = false
    private var restarting = false
    private var state = State.off { didSet { render() } }

    private var port: Int { defaults.integer(forKey: "port") }

    func applicationDidFinishLaunching(_ notification: Notification) {
        defaults.register(defaults: ["port": 9050])

        let menu = NSMenu()
        menu.delegate = self
        menu.items = [statusLine, toggleItem, .separator(), portItem, copyItem,
                      .separator(), loginItem, .separator(), quitItem]
        for item in [toggleItem, portItem, copyItem, loginItem] { item.target = self }
        statusItem.menu = menu

        render()
        if defaults.bool(forKey: "on") { start() }
    }

    func applicationWillTerminate(_ notification: Notification) {
        child?.terminate()
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        render()
    }

    // MARK: - Child process

    private func start() {
        let process = Process()
        let stdin = Pipe(), stdout = Pipe()
        process.executableURL = Bundle.main.url(forResource: "shallot-tor", withExtension: nil)
        process.arguments = [String(port)]
        process.standardInput = stdin
        process.standardOutput = stdout
        do {
            try process.run()
        } catch {
            state = .failed(error.localizedDescription)
            return
        }
        child = process
        childStdin = stdin
        lastError = nil
        stopping = false
        state = .bootstrapping(0)
        Thread.detachNewThread { self.read(stdout.fileHandleForReading, of: process) }
    }

    private func stop() {
        stopping = true
        child?.terminate()
    }

    /// Runs on its own thread: every line reaches the main thread, in order, before the exit does.
    private func read(_ output: FileHandle, of process: Process) {
        var buffer = Data()
        while case let chunk = output.availableData, !chunk.isEmpty {
            buffer.append(chunk)
            while let newline = buffer.firstIndex(of: 0x0A) {
                let line = String(decoding: buffer[..<newline], as: UTF8.self)
                buffer.removeSubrange(...newline)
                DispatchQueue.main.async { self.handle(line: line) }
            }
        }
        process.waitUntilExit()
        DispatchQueue.main.async { self.childExited(status: process.terminationStatus) }
    }

    private func handle(line: String) {
        let parts = line.split(separator: " ", maxSplits: 1)
        switch parts.first {
        case "bootstrap": state = .bootstrapping(parts.count > 1 ? Int(parts[1]) ?? 0 : 0)
        case "ready": state = .connected
        case "error": lastError = parts.count > 1 ? String(parts[1]) : nil
        default: break
        }
    }

    private func childExited(status: Int32) {
        child = nil
        childStdin = nil
        if restarting {
            restarting = false
            start()
        } else if stopping {
            state = .off
        } else {
            state = .failed(lastError ?? "exited with status \(status)")
        }
    }

    // MARK: - Menu

    private func render() {
        let symbol: String, text: String
        switch state {
        case .off: (symbol, text) = ("circle.slash", "Off")
        case .bootstrapping(let percent): (symbol, text) = ("circle.dotted", "Bootstrapping… \(percent)%")
        case .connected: (symbol, text) = ("circle.circle.fill", "Connected")
        case .failed(let message): (symbol, text) = ("exclamationmark.circle", "Failed: \(message)")
        }
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Shallot: \(text)")
        image?.isTemplate = true
        statusItem.button?.image = image

        statusLine.title = text
        toggleItem.title = child == nil ? "Turn On" : "Turn Off"
        portItem.title = "Port: \(port)…"
        copyItem.title = "Copy 127.0.0.1:\(port)"
        loginItem.state = SMAppService.mainApp.status == .enabled ? .on : .off
    }

    @objc private func toggle() {
        defaults.set(child == nil, forKey: "on")
        if child == nil { start() } else { stop() }
    }

    @objc private func changePort() {
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 200, height: 24))
        field.stringValue = String(port)
        let alert = NSAlert()
        alert.messageText = "SOCKS port"
        alert.informativeText = "Shallot listens on 127.0.0.1. Choose a port from 1024 to 65535."
        alert.accessoryView = field
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field

        NSApp.activate(ignoringOtherApps: true)
        while alert.runModal() == .alertFirstButtonReturn {
            guard let newPort = Int(field.stringValue), (1024...65535).contains(newPort) else {
                NSSound.beep()
                continue
            }
            if newPort != port {
                defaults.set(newPort, forKey: "port")
                if child != nil {
                    restarting = true
                    stop()
                }
            }
            break
        }
        render()
    }

    @objc private func copyAddress() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString("127.0.0.1:\(port)", forType: .string)
    }

    @objc private func toggleLogin() {
        let service = SMAppService.mainApp
        do {
            if service.status == .enabled { try service.unregister() } else { try service.register() }
        } catch {
            NSAlert(error: error).runModal()
        }
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
