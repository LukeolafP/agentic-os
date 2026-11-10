//
//  AgenticOSHands.swift
//  Agentic OS (GTD fork of OpenClicky, 7 Nov 2026)
//
//  The Clicky agent's hands. Petra's Clicky agents (and any manager that calls one) run in the
//  JARVIS bridge and use this Mac through the `computer` tools in ~/Coding/jarvis/bridge/
//  computer.mjs, which talk to this server on 127.0.0.1:8795: one JSON request per line, one
//  JSON reply per line.
//
//    status | displays | screenshot {display, maxWidth} | cursor | busy {on, who}
//    move {x,y,label} | click {x,y,button,count,label} | drag {x,y,toX,toY,label}
//    scroll {x,y,dx,dy} | type {text} | key {keys: "cmd+shift+k"}
//
//    Background hands (11 Nov 2026), inside one app window without the real mouse, outlined in cyan:
//    target {app, window} | target {clear} | window_tree {maxItems} | press {i} | set_value {i, value}
//    focus {i} | keys_to_app {keys} | type_to_app {text} | click_to_app {x, y, button, count}
//    mark {x, y, label}
//
//  Coordinates are global screen points, top-left of the main display at 0,0. Before each click,
//  drag or move the companion's own pointer flies to the spot with the label in its bubble, so
//  Luke sees where the agent is going; then the real mouse acts. The island says which agent is
//  working. Esc anywhere stops it: the next action is refused with "stopped".
//
//  It lives in the app so the app's own Accessibility and Screen Recording grants cover it.
//

import AppKit
import Network
import ApplicationServices

nonisolated final class AgenticOSHands: @unchecked Sendable {
    static let shared = AgenticOSHands()
    static let port: UInt16 = 8795

    private weak var companion: CompanionManager?
    private var listener: NWListener?
    private var stoppedAt: Double = 0
    private var busyWho = ""
    private var ownKeyAt: Double = 0
    private var escMonitor: Any?

    /// Background hands: the window the agent works in, and the elements of its last window_tree.
    private struct Target {
        let pid: pid_t
        let app: String
        let window: AXUIElement
        let title: String
    }
    private let targetLock = NSLock()
    private var target: Target?
    private var elements: [AXUIElement] = []
    private var followTimer: DispatchSourceTimer?
    /// False after `busy {on:false}` or a window that went away: the outline stays hidden until the next `target`.
    private var outlineShown = false

    @MainActor func start(companion: CompanionManager) {
        self.companion = companion
        escMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.keyCode == 53, !self.busyWho.isEmpty,
                  Date().timeIntervalSince1970 - self.ownKeyAt > 0.6 else { return }
            self.stoppedAt = Date().timeIntervalSince1970
            self.setBusy(false, "")
            AppLog.append("clicky agent: stopped with Esc")
        }
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: Self.port)!)
        parameters.allowLocalEndpointReuse = true
        guard let listener = try? NWListener(using: parameters) else {
            AppLog.append("clicky agent: could not listen on \(Self.port)")
            return
        }
        listener.newConnectionHandler = { [weak self] connection in self?.serve(connection) }
        listener.start(queue: .global(qos: .userInitiated))
        self.listener = listener
        AppLog.append("clicky agent: hands listening on 127.0.0.1:\(Self.port)")
    }

    // MARK: the socket

    private func serve(_ connection: NWConnection) {
        connection.start(queue: .global(qos: .userInitiated))
        var buffer = Data()
        func readMore() {
            connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { data, _, done, error in
                if let data { buffer.append(data) }
                while let newline = buffer.firstIndex(of: 10) {
                    let line = buffer.subdata(in: buffer.startIndex..<newline)
                    buffer.removeSubrange(buffer.startIndex...newline)
                    var reply = self.handle(line)
                    reply.append(10)
                    connection.send(content: reply, completion: .contentProcessed { _ in })
                }
                if done || error != nil { connection.cancel() } else { readMore() }
            }
        }
        readMore()
    }

    private struct Failure: Error { let message: String; init(_ message: String) { self.message = message } }

    private func handle(_ line: Data) -> Data {
        var out: [String: Any]
        do {
            guard let request = try JSONSerialization.jsonObject(with: line) as? [String: Any],
                  let command = request["cmd"] as? String else { throw Failure("bad request") }
            out = try run(command, request)
            out["ok"] = true
        } catch let failure as Failure {
            out = ["ok": false, "error": failure.message]
        } catch {
            out = ["ok": false, "error": "\(error)"]
        }
        out["stoppedAt"] = stoppedAt
        return (try? JSONSerialization.data(withJSONObject: out)) ?? Data("{\"ok\":false}".utf8)
    }

    private func number(_ request: [String: Any], _ key: String, _ fallback: Double? = nil) throws -> Double {
        if let value = request[key] as? Double { return value }
        if let value = request[key] as? Int { return Double(value) }
        if let fallback { return fallback }
        throw Failure("missing \(key)")
    }
    private let actions: Set<String> = ["move", "click", "drag", "scroll", "type", "key",
                                        "target", "window_tree", "press", "set_value", "focus", "keys_to_app", "type_to_app", "click_to_app"]

    private func run(_ command: String, _ request: [String: Any]) throws -> [String: Any] {
        if actions.contains(command) {
            if !AXIsProcessTrusted() { throw Failure("Agentic OS has no Accessibility permission: System Settings → Privacy & Security → Accessibility → turn on Agentic OS") }
            if let since = request["since"] as? Double, stoppedAt > since { throw Failure("stopped: Luke pressed Esc") }
        }
        let label = (request["label"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        switch command {
        case "status":
            return ["screen": CGPreflightScreenCaptureAccess(), "accessibility": AXIsProcessTrusted(), "displays": displays(), "busy": busyWho, "app": "Agentic OS",
                    "target": targetDescription() ?? NSNull()]
        case "displays":
            return ["displays": displays()]
        case "busy":
            setBusy((request["on"] as? Bool) ?? false, (request["who"] as? String) ?? "Screen agent")
            return [:]
        case "cursor":
            let location = CGEvent(source: nil)?.location ?? .zero
            return ["x": location.x, "y": location.y]
        case "screenshot":
            return try screenshot(display: Int(try number(request, "display", 0)), maxWidth: try number(request, "maxWidth", 1440))
        case "move":
            let point = try self.point(request)
            fly(to: point, label: label)
            post(.mouseMoved, point, .left)
            return [:]
        case "click":
            let point = try self.point(request)
            let button: CGMouseButton = (request["button"] as? String) == "right" ? .right : .left
            let count = Int(try number(request, "count", 1))
            fly(to: point, label: label)
            post(.mouseMoved, point, button)
            usleep(60_000)
            for clickNumber in 1...max(1, min(count, 3)) {
                post(button == .right ? .rightMouseDown : .leftMouseDown, point, button, clicks: clickNumber); usleep(30_000)
                post(button == .right ? .rightMouseUp : .leftMouseUp, point, button, clicks: clickNumber); usleep(60_000)
            }
            return [:]
        case "drag":
            let from = try self.point(request)
            let to = CGPoint(x: try number(request, "toX"), y: try number(request, "toY"))
            fly(to: from, label: label)
            post(.mouseMoved, from, .left); usleep(80_000)
            post(.leftMouseDown, from, .left); usleep(120_000)
            let steps = 24
            for step in 1...steps {
                let t = Double(step) / Double(steps)
                post(.leftMouseDragged, CGPoint(x: from.x + (to.x - from.x) * t, y: from.y + (to.y - from.y) * t), .left)
                usleep(16_000)
            }
            usleep(150_000)
            post(.leftMouseUp, to, .left)
            fly(to: to, label: nil)
            return [:]
        case "scroll":
            let point = try self.point(request)
            post(.mouseMoved, point, .left); usleep(40_000)
            let dy = Int32(try number(request, "dy", 0)), dx = Int32(try number(request, "dx", 0))
            CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 2, wheel1: dy, wheel2: dx, wheel3: 0)?.post(tap: .cghidEventTap)
            return [:]
        case "type":
            guard let text = request["text"] as? String else { throw Failure("missing text") }
            typeText(text)
            return [:]
        case "key":
            guard let keys = request["keys"] as? String else { throw Failure("missing keys") }
            try pressKeys(keys)
            return [:]
        // Background hands: inside the target window, without the real mouse.
        case "target":
            if (request["clear"] as? Bool) == true { clearTarget(); return [:] }
            guard let app = request["app"] as? String, !app.isEmpty else { throw Failure("missing app") }
            return try setTarget(app: app, windowTitle: request["window"] as? String)
        case "window_tree":
            return try windowTree(maxItems: Int(try number(request, "maxItems", 400)))
        case "press":
            let element = try element(request)
            try press(element)
            if let frame = frame(of: element) { mark(CGPoint(x: frame.midX, y: frame.midY), label: label ?? title(of: element)) }
            return ["frame": frameJSON(frame(of: element))]
        case "set_value":
            let element = try element(request)
            guard let value = request["value"] as? String else { throw Failure("missing value") }
            AXUIElementSetAttributeValue(element, kAXFocusedAttribute as CFString, kCFBooleanTrue)
            let result = AXUIElementSetAttributeValue(element, kAXValueAttribute as CFString, value as CFString)
            guard result == .success else { throw Failure("couldn't set the value (AXError \(result.rawValue))") }
            return ["value": valueString(of: element) ?? ""]
        case "focus":
            let element = try element(request)
            let result = AXUIElementSetAttributeValue(element, kAXFocusedAttribute as CFString, kCFBooleanTrue)
            guard result == .success else { throw Failure("couldn't focus it (AXError \(result.rawValue))") }
            return [:]
        case "keys_to_app":
            guard let keys = request["keys"] as? String else { throw Failure("missing keys") }
            try pressKeys(keys, pid: try targetPID())
            return [:]
        case "type_to_app":
            guard let text = request["text"] as? String else { throw Failure("missing text") }
            typeText(text, pid: try targetPID())
            return [:]
        case "click_to_app":
            let point = try self.point(request)
            let button: CGMouseButton = (request["button"] as? String) == "right" ? .right : .left
            let count = max(1, min(Int(try number(request, "count", 1)), 3))
            try clickInApp(at: point, button: button, count: count, pid: try targetPID())
            mark(point, label: label)
            return [:]
        case "mark":
            mark(try self.point(request), label: label)
            return [:]
        default:
            throw Failure("unknown command \(command)")
        }
    }

    // MARK: the companion's pointer and island

    /// Flies the companion's pointer to a global point (top-left origin) and waits for it to land.
    private func fly(to point: CGPoint, label: String?) {
        DispatchQueue.main.sync { MainActor.assumeIsolated {
            guard let companion = self.companion else { return }
            let mainHeight = NSScreen.screens.first?.frame.height ?? 0
            let appKitPoint = CGPoint(x: point.x, y: mainHeight - point.y)
            let screen = NSScreen.screens.first(where: { $0.frame.contains(appKitPoint) }) ?? NSScreen.main
            companion.pointAt(screenLocation: appKitPoint, displayFrame: screen?.frame ?? .zero, label: label)
        } }
        usleep(520_000)
    }

    private func setBusy(_ on: Bool, _ who: String) {
        busyWho = on ? who : ""
        if !on { outlineShown = false }
        DispatchQueue.main.async { MainActor.assumeIsolated {
            self.companion?.agentActivityText = on ? "\(who) is using your Mac · Esc stops it" : nil
            if !on {
                self.companion?.clearDetectedElementLocation()
                AgenticOSOutline.shared.hide()
            } else if self.target != nil {
                AgenticOSOutline.shared.setLabel(who)
            }
        } }
    }

    // MARK: background hands: the target window

    private func targetPID() throws -> pid_t {
        guard let target else { throw Failure("no target app") }
        return target.pid
    }

    private func targetDescription() -> [String: Any]? {
        guard let target else { return nil }
        return ["app": target.app, "window": target.title, "frame": frameJSON(frame(of: target.window)), "pid": Int(target.pid)]
    }

    private func frameJSON(_ frame: CGRect?) -> Any {
        guard let frame else { return NSNull() }
        return ["x": Double(frame.minX), "y": Double(frame.minY), "w": Double(frame.width), "h": Double(frame.height)]
    }

    /// Finds the app (opening it when it is not running), picks its window, outlines it.
    private func setTarget(app name: String, windowTitle: String?) throws -> [String: Any] {
        func running() -> NSRunningApplication? {
            let wanted = name.lowercased()
            return NSWorkspace.shared.runningApplications.first {
                $0.bundleIdentifier?.lowercased() == wanted || $0.localizedName?.lowercased() == wanted
            } ?? NSWorkspace.shared.runningApplications.first {
                ($0.localizedName?.lowercased().hasPrefix(wanted) ?? false) && $0.activationPolicy == .regular
            }
        }
        var app = DispatchQueue.main.sync { MainActor.assumeIsolated { running() } }
        if app == nil {
            let open = Process()
            open.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            open.arguments = ["-a", name, "--background"]
            try? open.run(); open.waitUntilExit()
            let deadline = Date().addingTimeInterval(8)
            while app == nil, Date() < deadline {
                usleep(250_000)
                app = DispatchQueue.main.sync { MainActor.assumeIsolated { running() } }
            }
        }
        guard let app else { throw Failure("no app called \(name)") }
        let pid = app.processIdentifier
        let appName = app.localizedName ?? name
        // Chromium and Electron apps only build their web tree once asked.
        DispatchQueue.main.sync { MainActor.assumeIsolated { ChromiumAccessibility.wake(app) } }
        let application = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(application, 2)
        var window: AXUIElement?
        let deadline = Date().addingTimeInterval(windowTitle == nil ? 3 : 8)
        repeat {
            window = pickWindow(of: application, titled: windowTitle)
            if window == nil { usleep(300_000) }
        } while window == nil && Date() < deadline
        guard let window else { throw Failure(windowTitle.map { "\(appName) has no window titled \"\($0)\"" } ?? "\(appName) has no window") }
        AXUIElementSetMessagingTimeout(window, 2)
        let title = string(of: window, kAXTitleAttribute) ?? ""
        targetLock.lock()
        target = Target(pid: pid, app: appName, window: window, title: title)
        elements = []
        targetLock.unlock()
        outlineShown = true
        let frame = frame(of: window)
        showOutline(frame)
        startFollowing()
        AppLog.append("screen agent: target \(appName) · \(title)")
        return ["pid": Int(pid), "app": appName, "window": title, "frame": frameJSON(frame)]
    }

    private func pickWindow(of application: AXUIElement, titled wanted: String?) -> AXUIElement? {
        var windows: [AXUIElement] = []
        if let list = copy(application, kAXWindowsAttribute) as? [AXUIElement] { windows = list }
        if let focused = copy(application, kAXFocusedWindowAttribute), CFGetTypeID(focused) == AXUIElementGetTypeID() {
            windows.insert(focused as! AXUIElement, at: 0)
        }
        if let wanted, !wanted.isEmpty {
            let needle = wanted.lowercased()
            return windows.first { (string(of: $0, kAXTitleAttribute) ?? "").lowercased().contains(needle) }
        }
        // The front window: the focused one, else the first standard window with a size.
        return windows.first { (frame(of: $0)?.width ?? 0) > 0 } ?? windows.first
    }

    private func clearTarget() {
        followTimer?.cancel()
        followTimer = nil
        targetLock.lock()
        target = nil
        elements = []
        targetLock.unlock()
        outlineShown = false
        DispatchQueue.main.async { MainActor.assumeIsolated { AgenticOSOutline.shared.hide() } }
        AppLog.append("screen agent: target cleared")
    }

    private func showOutline(_ frame: CGRect?) {
        let label = busyWho.isEmpty ? "Screen agent · \(target?.app ?? "")" : busyWho
        DispatchQueue.main.async { MainActor.assumeIsolated {
            if let frame { AgenticOSOutline.shared.show(frame: frame, label: label) } else { AgenticOSOutline.shared.hide() }
        } }
    }

    /// Every 100 ms, on its own queue: the window's frame goes to the outline; a window that is
    /// gone hides it.
    private func startFollowing() {
        followTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
        timer.schedule(deadline: .now() + .milliseconds(100), repeating: .milliseconds(100))
        timer.setEventHandler { [weak self] in
            guard let self, let target = self.target else { return }
            guard self.outlineShown else { return }
            if let frame = self.frame(of: target.window), frame.width > 0 {
                if frame != AgenticOSOutlineFrameCache.last {
                    AgenticOSOutlineFrameCache.last = frame
                    self.showOutline(frame)
                }
            } else {
                self.outlineShown = false
                AgenticOSOutlineFrameCache.last = nil
                self.showOutline(nil)
                AppLog.append("screen agent: the target window is gone")
            }
        }
        AgenticOSOutlineFrameCache.last = nil
        timer.resume()
        followTimer = timer
    }

    private func mark(_ point: CGPoint, label: String?) {
        DispatchQueue.main.async { MainActor.assumeIsolated { AgenticOSOutline.shared.pulse(at: point, label: label) } }
    }

    // MARK: background hands: the window's tree

    private static let roleNames: [String: String] = [
        kAXButtonRole: "button", "AXLink": "link",
        kAXTextFieldRole: "field", kAXTextAreaRole: "field", "AXSearchField": "field", kAXComboBoxRole: "field",
        kAXCheckBoxRole: "checkbox", kAXRadioButtonRole: "radio",
        kAXMenuRole: "menu", kAXMenuItemRole: "menu", kAXMenuBarItemRole: "menu", kAXMenuButtonRole: "menubutton",
        kAXPopUpButtonRole: "popup", kAXTabGroupRole: "tab", kAXListRole: "list", kAXRowRole: "row", kAXCellRole: "cell",
        kAXTableRole: "table", kAXOutlineRole: "outline", kAXSliderRole: "slider", kAXIncrementorRole: "slider",
        kAXImageRole: "image", kAXStaticTextRole: "text", kAXGroupRole: "group", kAXScrollAreaRole: "scroll",
        kAXToolbarRole: "toolbar", kAXWindowRole: "window",
    ]
    private static let actionNames: [String: String] = [
        kAXPressAction: "press", "AXOpen": "open", kAXConfirmAction: "confirm", kAXShowMenuAction: "show-menu",
        kAXIncrementAction: "increment", kAXDecrementAction: "decrement",
    ]
    /// Containers that are only listed when they have a title of their own.
    private static let quietRoles: Set<String> = ["group", "other", "scroll", "list", "table", "outline", "toolbar", "row", "cell"]

    private func windowTree(maxItems: Int) throws -> [String: Any] {
        guard let target else { throw Failure("no target app") }
        var items: [[String: Any]] = []
        var found: [AXUIElement] = []
        var visited = 0
        // Depth first; a quiet container with no title is left out, its children still listed.
        func visit(_ element: AXUIElement) {
            guard items.count < maxItems, visited < 6000 else { return }
            visited += 1
            AXUIElementSetMessagingTimeout(element, 2)
            let role = roleName(of: element)
            let title = self.title(of: element) ?? ""
            let frame = frame(of: element)
            let listed = !(Self.quietRoles.contains(role) && title.isEmpty) && (frame?.width ?? 0) > 0 && (frame?.height ?? 0) > 0
            if listed {
                var item: [String: Any] = [
                    "i": found.count, "role": role, "title": String(title.prefix(200)), "frame": frameJSON(frame),
                    "enabled": (copy(element, kAXEnabledAttribute) as? Bool) ?? true,
                    "focused": (copy(element, kAXFocusedAttribute) as? Bool) ?? false,
                    "actions": actions(of: element),
                ]
                item["value"] = ["field", "checkbox", "radio", "slider", "popup", "tab"].contains(role) ? (valueString(of: element) ?? "") : ""
                items.append(item)
                found.append(element)
            }
            for child in children(of: element) { visit(child) }
        }
        visit(target.window)
        targetLock.lock()
        elements = found
        targetLock.unlock()
        return ["items": items, "count": items.count, "window": target.title]
    }

    private func element(_ request: [String: Any]) throws -> AXUIElement {
        let index = Int(try number(request, "i"))
        targetLock.lock(); defer { targetLock.unlock() }
        guard target != nil else { throw Failure("no target app") }
        guard index >= 0, index < elements.count else { throw Failure(elements.isEmpty ? "no window_tree yet" : "no element \(index); the tree has \(elements.count)") }
        return elements[index]
    }

    private func press(_ element: AXUIElement) throws {
        let available = actions(of: element)
        let name = ["press", "open", "confirm"].first { available.contains($0) } ?? "press"
        let axName = Self.actionNames.first { $0.value == name }?.key ?? kAXPressAction
        let result = AXUIElementPerformAction(element, axName as CFString)
        guard result == .success else { throw Failure("\(name) failed (AXError \(result.rawValue))") }
    }

    private func copy(_ element: AXUIElement, _ attribute: String) -> AnyObject? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value
    }
    private func string(of element: AXUIElement, _ attribute: String) -> String? {
        let value = copy(element, attribute)
        if let text = value as? String { return text.isEmpty ? nil : text }
        if let text = value as? NSAttributedString { return text.string.isEmpty ? nil : text.string }
        return nil
    }
    private func title(of element: AXUIElement) -> String? {
        string(of: element, kAXTitleAttribute) ?? string(of: element, kAXDescriptionAttribute)
            ?? string(of: element, kAXHelpAttribute) ?? (roleName(of: element) == "text" ? string(of: element, kAXValueAttribute) : nil)
    }
    private func roleName(of element: AXUIElement) -> String {
        if (string(of: element, kAXSubroleAttribute) ?? "") == "AXTabButton" { return "tab" }
        guard let role = string(of: element, kAXRoleAttribute) else { return "other" }
        return Self.roleNames[role] ?? "other"
    }
    private func valueString(of element: AXUIElement) -> String? {
        guard let value = copy(element, kAXValueAttribute) else { return nil }
        let text: String
        if let string = value as? String { text = string }
        else if let number = value as? NSNumber { text = number.stringValue }
        else if let attributed = value as? NSAttributedString { text = attributed.string }
        else { text = "\(value)" }
        return String(text.prefix(200))
    }
    private func actions(of element: AXUIElement) -> [String] {
        var names: CFArray?
        guard AXUIElementCopyActionNames(element, &names) == .success, let list = names as? [String] else { return [] }
        return list.compactMap { Self.actionNames[$0] }
    }
    private func children(of element: AXUIElement) -> [AXUIElement] {
        (copy(element, kAXChildrenAttribute) as? [AXUIElement]) ?? []
    }
    /// The element's frame in global top-left points (what AX reports).
    private func frame(of element: AXUIElement) -> CGRect? {
        guard let positionValue = copy(element, kAXPositionAttribute), let sizeValue = copy(element, kAXSizeAttribute) else { return nil }
        var position = CGPoint.zero, size = CGSize.zero
        guard AXValueGetValue(positionValue as! AXValue, .cgPoint, &position), AXValueGetValue(sizeValue as! AXValue, .cgSize, &size) else { return nil }
        return CGRect(origin: position, size: size)
    }

    // MARK: background hands: events to the app

    /// A click posted to the app's process at a global point: the real cursor stays where it is.
    private func clickInApp(at point: CGPoint, button: CGMouseButton, count: Int, pid: pid_t) throws {
        let windowNumber = windowNumber(of: pid, containing: point)
        func send(_ type: CGEventType, clicks: Int) {
            guard let event = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: point, mouseButton: button) else { return }
            event.setIntegerValueField(.mouseEventClickState, value: Int64(clicks))
            if let windowNumber {
                event.setIntegerValueField(.mouseEventWindowUnderMousePointer, value: Int64(windowNumber))
                event.setIntegerValueField(.mouseEventWindowUnderMousePointerThatCanHandleThisEvent, value: Int64(windowNumber))
            }
            event.postToPid(pid)
        }
        send(.mouseMoved, clicks: 0)
        usleep(30_000)
        for clickNumber in 1...count {
            send(button == .right ? .rightMouseDown : .leftMouseDown, clicks: clickNumber); usleep(30_000)
            send(button == .right ? .rightMouseUp : .leftMouseUp, clicks: clickNumber); usleep(60_000)
        }
    }

    /// The on-screen window of `pid` under `point` (global top-left points), by the window server's list.
    private func windowNumber(of pid: pid_t, containing point: CGPoint) -> Int? {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return nil }
        let own = list.filter { ($0[kCGWindowOwnerPID as String] as? Int) == Int(pid) && ($0[kCGWindowLayer as String] as? Int) == 0 }
        let containing = own.first { entry in
            guard let bounds = entry[kCGWindowBounds as String] as? [String: Double] else { return false }
            return CGRect(x: bounds["X"] ?? 0, y: bounds["Y"] ?? 0, width: bounds["Width"] ?? 0, height: bounds["Height"] ?? 0).contains(point)
        }
        return (containing ?? own.first)?[kCGWindowNumber as String] as? Int
    }

    private func point(_ request: [String: Any]) throws -> CGPoint { CGPoint(x: try number(request, "x"), y: try number(request, "y")) }
    private func post(_ type: CGEventType, _ point: CGPoint, _ button: CGMouseButton, clicks: Int = 1) {
        guard let event = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: point, mouseButton: button) else { return }
        if clicks > 1 { event.setIntegerValueField(.mouseEventClickState, value: Int64(clicks)) }
        event.post(tap: .cghidEventTap)
    }

    // MARK: the screen

    private func displays() -> [[String: Any]] {
        var ids = [CGDirectDisplayID](repeating: 0, count: 16)
        var count: UInt32 = 0
        CGGetActiveDisplayList(16, &ids, &count)
        let mouse = CGEvent(source: nil)?.location ?? .zero
        return (0..<Int(count)).map { index in
            let bounds = CGDisplayBounds(ids[index])
            // plain Doubles: a CGFloat boxed as Any does not cast to Double, and the crash took the app with it
            return ["index": index, "x": Double(bounds.origin.x), "y": Double(bounds.origin.y), "width": Double(bounds.width), "height": Double(bounds.height),
                    "main": CGDisplayIsMain(ids[index]) != 0, "hasCursor": bounds.contains(mouse)]
        }
    }

    private func screenshot(display: Int, maxWidth: Double) throws -> [String: Any] {
        if !CGPreflightScreenCaptureAccess() { throw Failure("Agentic OS has no Screen Recording permission: System Settings → Privacy & Security → Screen & System Audio Recording → turn on Agentic OS") }
        let list = displays()
        guard display >= 0, display < list.count else { throw Failure("no display \(display); there are \(list.count)") }
        let info = list[display]
        let file = NSTemporaryDirectory() + "agentic-os-screen-\(UUID().uuidString).png"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        process.arguments = ["-x", "-C", "-D", String(display + 1), "-t", "png", file]
        try process.run(); process.waitUntilExit()
        defer { try? FileManager.default.removeItem(atPath: file) }
        guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: file) as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { throw Failure("screenshot failed") }
        let pointsWidth = (info["width"] as? Double) ?? Double(CGDisplayBounds(CGMainDisplayID()).width)
        let pointsHeight = (info["height"] as? Double) ?? Double(CGDisplayBounds(CGMainDisplayID()).height)
        let scale = min(1.0, maxWidth / pointsWidth)
        let width = Int((pointsWidth * scale).rounded()), height = Int((pointsHeight * scale).rounded())
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { throw Failure("resize failed") }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let small = context.makeImage(),
              let jpeg = NSBitmapImageRep(cgImage: small).representation(using: .jpeg, properties: [.compressionFactor: 0.72]) else { throw Failure("encode failed") }
        // a 48x30 grey thumbnail, so the Voice Agent can tell in a millisecond whether the view changed
        var thumb = Data()
        if let small = CGContext(data: nil, width: 48, height: 30, bitsPerComponent: 8, bytesPerRow: 48,
                                 space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) {
            small.interpolationQuality = .medium
            small.draw(image, in: CGRect(x: 0, y: 0, width: 48, height: 30))
            if let bytes = small.data { thumb = Data(bytes: bytes, count: 48 * 30) }
        }
        let front = NSWorkspace.shared.frontmostApplication
        return ["image": jpeg.base64EncodedString(), "width": width, "height": height, "scale": scale,
                "originX": info["x"]!, "originY": info["y"]!, "display": display, "displays": list,
                "thumb": thumb.base64EncodedString(), "frontApp": front?.localizedName ?? "", "frontBundle": front?.bundleIdentifier ?? ""]
    }

    // MARK: the keyboard

    private func typeText(_ text: String, pid: pid_t? = nil) {
        let units = Array(text.utf16)
        var index = 0
        while index < units.count {
            let chunk = Array(units[index..<min(index + 16, units.count)])
            if chunk.count >= 1 && (chunk[0] == 10 || chunk[0] == 13) { tap(36, [], pid: pid); index += 1; continue }
            if let newline = chunk.firstIndex(where: { $0 == 10 || $0 == 13 }) {
                sendUnicode(Array(chunk[0..<newline]), pid: pid); index += newline; continue
            }
            sendUnicode(chunk, pid: pid); index += chunk.count
        }
    }
    private func sendUnicode(_ chunk: [UniChar], pid: pid_t? = nil) {
        var characters = chunk
        for down in [true, false] {
            guard let event = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: down) else { continue }
            event.keyboardSetUnicodeString(stringLength: characters.count, unicodeString: &characters)
            deliver(event, to: pid)
            usleep(8_000)
        }
        usleep(12_000)
    }

    private let keyCodes: [String: CGKeyCode] = [
        "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9, "b": 11, "q": 12, "w": 13, "e": 14, "r": 15,
        "y": 16, "t": 17, "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23, "=": 24, "9": 25, "7": 26, "-": 27, "8": 28, "0": 29,
        "]": 30, "o": 31, "u": 32, "[": 33, "i": 34, "p": 35, "return": 36, "enter": 36, "l": 37, "j": 38, "'": 39, "k": 40, ";": 41,
        "\\": 42, ",": 43, "/": 44, "n": 45, "m": 46, ".": 47, "tab": 48, "space": 49, "`": 50, "delete": 51, "backspace": 51,
        "escape": 53, "esc": 53, "forwarddelete": 117, "home": 115, "end": 119, "pageup": 116, "pagedown": 121,
        "left": 123, "right": 124, "down": 125, "up": 126,
        "f1": 122, "f2": 120, "f3": 99, "f4": 118, "f5": 96, "f6": 97, "f7": 98, "f8": 100, "f9": 101, "f10": 109, "f11": 103, "f12": 111,
    ]
    private func pressKeys(_ combo: String, pid: pid_t? = nil) throws {
        for step in combo.split(separator: " ") {
            var flags: CGEventFlags = []
            var key: CGKeyCode?
            for part in step.lowercased().split(separator: "+").map(String.init) {
                switch part {
                case "cmd", "command", "⌘": flags.insert(.maskCommand)
                case "shift", "⇧": flags.insert(.maskShift)
                case "opt", "option", "alt", "⌥": flags.insert(.maskAlternate)
                case "ctrl", "control", "⌃": flags.insert(.maskControl)
                case "fn": flags.insert(.maskSecondaryFn)
                default:
                    guard let code = keyCodes[part] else { throw Failure("unknown key \(part)") }
                    key = code
                }
            }
            guard let key else { throw Failure("no key in \(step)") }
            tap(key, flags, pid: pid)
            usleep(80_000)
        }
    }
    private func tap(_ key: CGKeyCode, _ flags: CGEventFlags, pid: pid_t? = nil) {
        ownKeyAt = Date().timeIntervalSince1970
        for down in [true, false] {
            guard let event = CGEvent(keyboardEventSource: nil, virtualKey: key, keyDown: down) else { continue }
            event.flags = flags
            deliver(event, to: pid)
            usleep(20_000)
        }
    }
    /// To the app's process when the background hands have a target, else to the HID tap like a real key.
    private func deliver(_ event: CGEvent, to pid: pid_t?) {
        if let pid { event.postToPid(pid) } else { event.post(tap: .cghidEventTap) }
    }
}

/// The last frame the outline was given, so the follow timer only redraws on a change.
private enum AgenticOSOutlineFrameCache {
    nonisolated(unsafe) static var last: CGRect?
}
