//
//  AgenticOS.swift
//  Agentic OS (GTD fork of OpenClicky, 7 Nov 2026)
//
//  What makes this OpenClicky the Agentic OS program:
//
//  - Services: opening the program makes sure everything the OS needs is running. The dashboards
//    and the JARVIS bridge are launchd agents (com.gettruckdrivers.*), kicked if they are down;
//    Petra's voice backend (~/Coding/jarvis/clicky/server.mjs, where ⌃⌥ and every model call go)
//    runs as this program's own child process and stops when it quits.
//  - The window: the OS dashboard (http://localhost:50000) in the program's own window, with a
//    Dock icon while it is open. The same OS still opens in Obsidian (the GTD Rubric plugin) and
//    at localhost.
//  - Hands: AgenticOSHands.swift, the Clicky agent's mouse and keyboard.
//

import AppKit
import WebKit

enum AgenticOS {
    static let dashboardURL = URL(string: "http://localhost:50000")!
    static let jarvis = NSString(string: "~/Coding/jarvis").expandingTildeInPath
    static let node = "/opt/homebrew/bin/node"

    /// launchd agents the OS is made of, with the address that says each is up
    static let services: [(label: String, health: String)] = [
        ("com.gettruckdrivers.jarvis-bridge", "http://127.0.0.1:8790/health"),
        ("com.gettruckdrivers.agentic-os", "http://127.0.0.1:50000/"),
        ("com.gettruckdrivers.second-brain", "http://127.0.0.1:5211/"),
        ("com.gettruckdrivers.rubric-console", "http://127.0.0.1:5050/"),
    ]

    private static var voiceBackend: Process?
    private static var windowController: AgenticOSWindowController?

    @MainActor static func start(companion: CompanionManager) {
        AgenticOSHands.shared.start(companion: companion)
        Task.detached { await startServices() }
        // the program opens on the OS, unless it was started at login
        if !CommandLine.arguments.contains("--background") { showWindow() }
    }

    @MainActor static func stop() {
        voiceBackend?.terminate()
        voiceBackend = nil
    }

    /// The vault's rule (CLAUDE.md, Opening links and files): Google links open in Chrome, every
    /// other link opens in Obsidian's web viewer, never the default browser.
    static func openOutside(_ url: URL) {
        let host = url.host ?? ""
        if host.hasSuffix("google.com") || host.hasSuffix("googleusercontent.com") {
            let chrome = URL(fileURLWithPath: "/Applications/Google Chrome.app")
            NSWorkspace.shared.open([url], withApplicationAt: chrome, configuration: NSWorkspace.OpenConfiguration())
            return
        }
        var parts = URLComponents(string: "obsidian://web-open")!
        parts.queryItems = [URLQueryItem(name: "url", value: url.absoluteString)]
        if let obsidian = parts.url { NSWorkspace.shared.open(obsidian) }
    }

    @MainActor static func showWindow() {
        if windowController == nil { windowController = AgenticOSWindowController() }
        windowController?.show()
    }

    // MARK: services

    private static func isUp(_ address: String) async -> Bool {
        guard let url = URL(string: address) else { return false }
        var request = URLRequest(url: url)
        request.timeoutInterval = 2
        guard let (_, response) = try? await URLSession.shared.data(for: request) else { return false }
        return ((response as? HTTPURLResponse)?.statusCode ?? 0) < 500
    }

    private static func startServices() async {
        for service in services where !(await isUp(service.health)) {
            AppLog.append("agentic os: \(service.label) is down; starting it")
            let kick = Process()
            kick.executableURL = URL(fileURLWithPath: "/bin/launchctl")
            kick.arguments = ["kickstart", "gui/\(getuid())/\(service.label)"]
            try? kick.run()
            kick.waitUntilExit()
        }
        if await isUp("http://127.0.0.1:8793/health") {
            AppLog.append("agentic os: Petra's voice backend already running")
            return
        }
        await MainActor.run { startVoiceBackend() }
    }

    @MainActor private static func startVoiceBackend() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: node)
        process.arguments = ["clicky/server.mjs"]
        process.currentDirectoryURL = URL(fileURLWithPath: jarvis)
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = "/opt/homebrew/bin:\(NSHomeDirectory())/.local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        process.environment = environment
        let log = URL(fileURLWithPath: "\(jarvis)/clicky/clicky.err.log")
        if !FileManager.default.fileExists(atPath: log.path) { FileManager.default.createFile(atPath: log.path, contents: nil) }
        if let handle = try? FileHandle(forWritingTo: log) { handle.seekToEndOfFile(); process.standardError = handle }
        process.standardOutput = FileHandle.nullDevice
        process.terminationHandler = { finished in
            Task { @MainActor in
                AppLog.append("agentic os: voice backend stopped (\(finished.terminationStatus))")
                // keep it running while the program is open
                if voiceBackend === finished {
                    voiceBackend = nil
                    try? await Task.sleep(nanoseconds: 3_000_000_000)
                    startVoiceBackend()
                }
            }
        }
        do {
            try process.run()
            voiceBackend = process
            AppLog.append("agentic os: started Petra's voice backend (pid \(process.processIdentifier))")
        } catch {
            AppLog.append("agentic os: could not start the voice backend: \(error.localizedDescription)")
        }
    }
}

/// The OS dashboard in the program's own window.
final class AgenticOSWindowController: NSObject, NSWindowDelegate, WKNavigationDelegate, WKUIDelegate {
    private let window: NSWindow
    private let webView: WKWebView

    override init() {
        let configuration = WKWebViewConfiguration()
        configuration.preferences.setValue(true, forKey: "developerExtrasEnabled")
        configuration.mediaTypesRequiringUserActionForPlayback = []
        webView = WKWebView(frame: .zero, configuration: configuration)
        webView.allowsMagnification = true
        let frame = NSScreen.main.map { $0.visibleFrame.insetBy(dx: $0.visibleFrame.width * 0.06, dy: $0.visibleFrame.height * 0.06) }
            ?? NSRect(x: 0, y: 0, width: 1400, height: 900)
        window = NSWindow(contentRect: frame, styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                          backing: .buffered, defer: false)
        super.init()
        window.title = "Agentic OS"
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.setFrameAutosaveName("AgenticOSWindow")
        window.contentView = webView
        window.delegate = self
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.load(URLRequest(url: AgenticOS.dashboardURL))
    }

    func show() {
        NSApp.setActivationPolicy(.regular)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ notification: Notification) {
        // back to a menu-bar program once the window is closed
        NSApp.setActivationPolicy(.accessory)
    }

    // the dashboards may still be starting: try again until they answer
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        webView.loadHTMLString("""
            <body style="margin:0;height:100vh;display:grid;place-items:center;background:#0B1638;color:#C3D2FF;font:16px -apple-system">
            <div>Starting the Agentic OS…</div></body>
            """, baseURL: nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak webView] in
            webView?.load(URLRequest(url: AgenticOS.dashboardURL))
        }
    }

    // pages the OS opens in a new window open in this one's place, except outside links
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let url = navigationAction.request.url {
            if url.host == "localhost" || url.host == "127.0.0.1" { webView.load(URLRequest(url: url)) }
            else { AgenticOS.openOutside(url) }
        }
        return nil
    }

    // the microphone for Petra's chat voice: allowed for the OS's own pages
    func webView(_ webView: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin, initiatedByFrame frame: WKFrameInfo,
                 type: WKMediaCaptureType, decisionHandler: @escaping (WKPermissionDecision) -> Void) {
        decisionHandler(origin.host == "localhost" || origin.host == "127.0.0.1" ? .grant : .prompt)
    }
}
