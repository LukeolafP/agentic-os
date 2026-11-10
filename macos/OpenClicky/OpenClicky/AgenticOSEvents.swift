//
//  AgenticOSEvents.swift
//  Agentic OS (GTD fork of OpenClicky, 10 Nov 2026)
//
//  The Voice Agent can speak first. Petra's backend sends events on GET /events (Server-Sent
//  Events, one `data: {json}` line each); this file keeps that stream open (reconnecting with
//  backoff when it drops) and acts on them:
//
//    say   {id, text, listen}  the text shows in the island and is spoken in the answers' voice
//                              (backend /tts); with listen, the microphone opens for one ⌃⌥ turn
//                              right after, without a key press, and ends on 1.2 s of silence (8 s
//                              with nothing heard ends it quietly). Empty text with listen: only the
//                              listening turn. POST /events/said {id} once it has been said.
//    stop                      stops the announcement (and any answer) at once.
//    point {x, y, label}       flies the pointer there (global points, main display top-left 0,0).
//    clear                     hides the pointer.
//
//  An announcement waits for the person: it is spoken once nothing else is listening, thinking or
//  speaking. ⌃⌥ during one stops it and listens (CompanionManager.handleShortcutTransition).
//

import AppKit
import Foundation

/// Reads GET /events and hands each event to the announcer on the main actor.
nonisolated final class AgenticOSEventStream: @unchecked Sendable {
    static let shared = AgenticOSEventStream()

    private var task: Task<Void, Never>?
    private let session: URLSession = {
        let configuration = URLSessionConfiguration.default
        // The stream is quiet between events; a long idle allowance, and a reconnect when it lapses.
        configuration.timeoutIntervalForRequest = 15 * 60
        configuration.timeoutIntervalForResource = 7 * 24 * 3600
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: configuration)
    }()

    @MainActor func start(companion: CompanionManager) {
        VoiceAgentAnnouncer.shared.companion = companion
        guard task == nil else { return }
        task = Task.detached(priority: .utility) { [weak self] in await self?.run() }
    }

    @MainActor func stop() {
        task?.cancel()
        task = nil
    }

    private func run() async {
        var backoff: Double = 1
        var wasConnected = true   // so the first failure is logged
        while !Task.isCancelled {
            let request: URLRequest? = await MainActor.run {
                guard let url = URL(string: "\(OpenClickyConfiguration.backendBaseURL)/events") else { return nil }
                var request = URLRequest(url: url)
                request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
                OpenClickyConfiguration.authorize(&request)
                return request
            }
            do {
                guard let request else { throw URLError(.badURL) }
                let (bytes, response) = try await session.bytes(for: request)
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                guard status == 200 else { throw URLError(.badServerResponse, userInfo: [NSLocalizedDescriptionKey: "HTTP \(status)"]) }
                AppLog.append("voice agent: events connected")
                wasConnected = true
                backoff = 1
                // `lines` drops the blank line between events, so each `data:` line is one event.
                for try await line in bytes.lines {
                    guard line.hasPrefix("data:") else { continue }
                    let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                    guard let data = payload.data(using: .utf8),
                          let event = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { continue }
                    await MainActor.run { VoiceAgentAnnouncer.shared.handle(event) }
                }
                AppLog.append("voice agent: events stream ended; reconnecting")
            } catch {
                if Task.isCancelled { return }
                if wasConnected { AppLog.append("voice agent: events unavailable (\(error.localizedDescription)); retrying") }
                wasConnected = false
            }
            try? await Task.sleep(for: .seconds(backoff))
            backoff = min(backoff * 2, 30)
        }
    }
}

/// Speaks announcements one at a time, then opens the microphone when asked.
@MainActor
final class VoiceAgentAnnouncer {
    static let shared = VoiceAgentAnnouncer()

    struct Announcement {
        let id: String
        let text: String
        let listen: Bool
    }

    weak var companion: CompanionManager?
    private var queue: [Announcement] = []
    private var announcementTask: Task<Void, Never>?
    private var listenMonitor: Task<Void, Never>?
    /// True while the announcer itself presses ⌃⌥, so that press is not taken for a barge-in.
    private var isOpeningTheMicrophone = false

    /// Ends the listening turn this long after the last sound once something was heard.
    static let silenceToEnd: TimeInterval = 1.2
    /// Ends it quietly if nothing at all was heard by then.
    static let nothingHeardLimit: TimeInterval = 8
    /// The microphone level (BuddyDictationManager's RMS × 10) that counts as speech.
    static let speechLevel: CGFloat = 0.12

    func handle(_ event: [String: Any]) {
        switch event["type"] as? String {
        case "say":
            let announcement = Announcement(
                id: (event["id"] as? String) ?? (event["id"] as? NSNumber)?.stringValue ?? UUID().uuidString,
                text: ((event["text"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
                listen: (event["listen"] as? Bool) ?? false)
            AppLog.append("voice agent: say \(announcement.id) (\(announcement.text.count) chars\(announcement.listen ? ", then listen" : ""))")
            queue.append(announcement)
            playNextIfIdle()
        case "stop":
            AppLog.append("voice agent: stop")
            stopAll()
            companion?.stopSpeaking()
        case "point":
            guard let companion, let x = (event["x"] as? NSNumber)?.doubleValue, let y = (event["y"] as? NSNumber)?.doubleValue else { return }
            // Global points with the main display's top-left at 0,0, as AgenticOSHands takes them.
            let mainHeight = NSScreen.screens.first?.frame.height ?? 0
            let appKitPoint = CGPoint(x: x, y: mainHeight - y)
            let screen = NSScreen.screens.first(where: { $0.frame.contains(appKitPoint) }) ?? NSScreen.main
            companion.pointAt(screenLocation: appKitPoint, displayFrame: screen?.frame ?? .zero, label: event["label"] as? String)
        case "clear":
            companion?.clearDetectedElementLocation()
        default:
            break
        }
    }

    /// ⌃⌥ was pressed: an announcement being spoken (or waiting) stops, and the person's own
    /// press takes over the microphone.
    func talkPressed() {
        guard !isOpeningTheMicrophone else { return }
        if announcementTask != nil || listenMonitor != nil { AppLog.append("voice agent: ⌃⌥ barge-in") }
        stopAll()
    }

    private func stopAll() {
        let stopped = queue
        queue.removeAll()
        announcementTask?.cancel()
        announcementTask = nil
        listenMonitor?.cancel()
        listenMonitor = nil
        companion?.announcementText = nil
        for announcement in stopped { Self.reportSaid(announcement.id) }
    }

    private func playNextIfIdle() {
        guard announcementTask == nil, !queue.isEmpty, let companion else { return }
        let announcement = queue.removeFirst()
        announcementTask = Task { [weak self] in
            await self?.play(announcement, companion: companion)
            guard let self, !Task.isCancelled else { return }
            self.announcementTask = nil
            self.playNextIfIdle()
        }
    }

    private func play(_ announcement: Announcement, companion: CompanionManager) async {
        // Wait for the person and the answer in progress (two minutes at most).
        let waitStarted = Date()
        while !isQuiet(companion) {
            if Date().timeIntervalSince(waitStarted) > 120 {
                AppLog.append("voice agent: \(announcement.id) dropped, the Mac stayed busy")
                Self.reportSaid(announcement.id)
                return
            }
            try? await Task.sleep(for: .milliseconds(250))
            if Task.isCancelled { return }
        }
        var spokeToTheEnd = true
        if !announcement.text.isEmpty {
            companion.announcementText = announcement.text
            spokeToTheEnd = await companion.speakWholeReply(announcement.text)
            companion.announcementText = nil
            if Task.isCancelled {
                // A barge-in: ⌃⌥ is already listening.
                Self.reportSaid(announcement.id)
                return
            }
            if companion.voiceState == .responding { companion.voiceState = .idle }
        }
        Self.reportSaid(announcement.id)
        // The island's stop button silences it without asking anything.
        guard announcement.listen, spokeToTheEnd else { return }
        openMicrophoneForOneTurn(companion)
    }

    private func isQuiet(_ companion: CompanionManager) -> Bool {
        companion.voiceState == .idle && !companion.isAskInFlight
            && !companion.buddyDictationManager.isDictationInProgress
            && !companion.dictationTakeController.isTakeInProgress
    }

    /// One ⌃⌥ turn without the key: pressed now, released on silence.
    private func openMicrophoneForOneTurn(_ companion: CompanionManager) {
        guard isQuiet(companion), companion.hasMicrophonePermission else { return }
        AppLog.append("voice agent: listening for the answer")
        isOpeningTheMicrophone = true
        companion.handleShortcutTransition(.pressed)
        isOpeningTheMicrophone = false
        listenMonitor?.cancel()
        listenMonitor = Task { [weak self] in
            let started = Date()
            var lastSoundAt: Date?
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(100))
                guard !Task.isCancelled else { return }
                let now = Date()
                // Gone from listening (an error, esc, or the person's own ⌃⌥): nothing to end.
                if (companion.voiceState == .idle || companion.voiceState == .responding) && now.timeIntervalSince(started) > 2 { break }
                if companion.currentAudioPowerLevel > Self.speechLevel || (lastSoundAt == nil && companion.askHeardWordsSincePress) {
                    lastSoundAt = now
                }
                if let lastSoundAt {
                    if now.timeIntervalSince(lastSoundAt) >= Self.silenceToEnd {
                        AppLog.append("voice agent: heard an answer, sending")
                        companion.handleShortcutTransition(.released)
                        break
                    }
                } else if now.timeIntervalSince(started) >= Self.nothingHeardLimit {
                    AppLog.append("voice agent: nothing heard in \(Int(Self.nothingHeardLimit)) s; stopped listening")
                    if !companion.stopAskLane(from: "voice agent, nothing heard", caption: nil) {
                        companion.handleShortcutTransition(.released)
                    }
                    break
                }
            }
            self?.listenMonitor = nil
        }
    }

    /// POST /events/said {id}.
    private static func reportSaid(_ id: String) {
        guard let url = URL(string: "\(OpenClickyConfiguration.backendBaseURL)/events/said") else { return }
        var request = URLRequest(url: url, timeoutInterval: 5)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        OpenClickyConfiguration.authorize(&request)
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["id": id])
        URLSession.shared.dataTask(with: request) { _, response, error in
            if let error { AppLog.append("voice agent: /events/said failed: \(error.localizedDescription)") }
            else if let status = (response as? HTTPURLResponse)?.statusCode, !(200...299).contains(status) {
                AppLog.append("voice agent: /events/said HTTP \(status)")
            }
        }.resume()
    }
}
