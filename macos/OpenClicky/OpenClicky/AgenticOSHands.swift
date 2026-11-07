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
    private let actions: Set<String> = ["move", "click", "drag", "scroll", "type", "key"]

    private func run(_ command: String, _ request: [String: Any]) throws -> [String: Any] {
        if actions.contains(command) {
            if !AXIsProcessTrusted() { throw Failure("Agentic OS has no Accessibility permission: System Settings → Privacy & Security → Accessibility → turn on Agentic OS") }
            if let since = request["since"] as? Double, stoppedAt > since { throw Failure("stopped: Luke pressed Esc") }
        }
        let label = (request["label"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        switch command {
        case "status":
            return ["screen": CGPreflightScreenCaptureAccess(), "accessibility": AXIsProcessTrusted(), "displays": displays(), "busy": busyWho, "app": "Agentic OS"]
        case "displays":
            return ["displays": displays()]
        case "busy":
            setBusy((request["on"] as? Bool) ?? false, (request["who"] as? String) ?? "Clicky agent")
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
        DispatchQueue.main.async { MainActor.assumeIsolated {
            self.companion?.agentActivityText = on ? "\(who) is using your Mac · Esc stops it" : nil
            if !on { self.companion?.clearDetectedElementLocation() }
        } }
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
            return ["index": index, "x": bounds.origin.x, "y": bounds.origin.y, "width": bounds.width, "height": bounds.height,
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
        let pointsWidth = info["width"] as! Double, pointsHeight = info["height"] as! Double
        let scale = min(1.0, maxWidth / pointsWidth)
        let width = Int((pointsWidth * scale).rounded()), height = Int((pointsHeight * scale).rounded())
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { throw Failure("resize failed") }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let small = context.makeImage(),
              let jpeg = NSBitmapImageRep(cgImage: small).representation(using: .jpeg, properties: [.compressionFactor: 0.72]) else { throw Failure("encode failed") }
        return ["image": jpeg.base64EncodedString(), "width": width, "height": height, "scale": scale,
                "originX": info["x"]!, "originY": info["y"]!, "display": display, "displays": list]
    }

    // MARK: the keyboard

    private func typeText(_ text: String) {
        let units = Array(text.utf16)
        var index = 0
        while index < units.count {
            let chunk = Array(units[index..<min(index + 16, units.count)])
            if chunk.count >= 1 && (chunk[0] == 10 || chunk[0] == 13) { tap(36, []); index += 1; continue }
            if let newline = chunk.firstIndex(where: { $0 == 10 || $0 == 13 }) {
                sendUnicode(Array(chunk[0..<newline])); index += newline; continue
            }
            sendUnicode(chunk); index += chunk.count
        }
    }
    private func sendUnicode(_ chunk: [UniChar]) {
        var characters = chunk
        for down in [true, false] {
            guard let event = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: down) else { continue }
            event.keyboardSetUnicodeString(stringLength: characters.count, unicodeString: &characters)
            event.post(tap: .cghidEventTap)
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
    private func pressKeys(_ combo: String) throws {
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
            tap(key, flags)
            usleep(80_000)
        }
    }
    private func tap(_ key: CGKeyCode, _ flags: CGEventFlags) {
        ownKeyAt = Date().timeIntervalSince1970
        for down in [true, false] {
            guard let event = CGEvent(keyboardEventSource: nil, virtualKey: key, keyDown: down) else { continue }
            event.flags = flags
            event.post(tap: .cghidEventTap)
            usleep(20_000)
        }
    }
}
