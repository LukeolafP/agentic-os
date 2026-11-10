//
//  SettingsAgenticOSPage.swift
//  Agentic OS (GTD fork of OpenClicky, 10 Nov 2026)
//
//  Settings → Agentic OS: the Voice Agent's voice. The voices come from Petra's backend on this
//  Mac (GET /voices: Petra on this Mac, and the ElevenLabs voices once a key is saved); the one
//  picked is `voiceAgentVoice` in ~/.openclicky/shell.json, which the backend reads on every /tts
//  call. The ElevenLabs key is the same `elevenLabsApiKey` the Keys page saves. The app's own voice
//  (Settings → Voice Agent → Voice) stays on Automatic, which on the local backend is its /tts, so
//  the voice picked here is the one that speaks.
//

import AppKit
import AVFoundation
import Combine
import SwiftUI

extension SettingsCatalog {
    func agenticOSItems() -> [SettingsItem] {
        [
            SettingsItem(
                id: "agenticos.voice",
                title: "Voice Agent’s voice", detail: "Who speaks the Voice Agent’s answers and announcements.",
                keywords: ["voice", "petra", "voxtral", "elevenlabs", "eleven labs", "tts", "speech", "speaker", "voice agent"],
                view: AnyView(VoiceAgentVoiceRow())),
            SettingsItem(
                id: "agenticos.sample",
                title: "Play sample", detail: "Says a line in the voice picked above.",
                keywords: ["preview", "sample", "listen", "test", "voice"],
                view: AnyView(VoiceAgentSampleRow())),
            SettingsItem(
                id: "agenticos.defaultVoice",
                title: "Default voice", detail: "Petra, made on this Mac by Voxtral. Free and offline.",
                keywords: ["default", "petra", "reset", "voice"],
                view: AnyView(VoiceAgentDefaultRow())),
            SettingsItem(
                id: "agenticos.elevenLabsKey",
                title: "ElevenLabs API key", detail: "Its voices join the list above.",
                keywords: ["elevenlabs", "eleven labs", "key", "api", "voice"],
                view: AnyView(VoiceAgentElevenLabsKeyRow())),
            SettingsItem(
                id: "agenticos.voiceNote",
                title: VoiceAgentVoices.footnote, keywords: ["voice", "backend"],
                chrome: .footer,
                view: AnyView(SettingsFootnote(text: VoiceAgentVoices.footnote))),
        ]
    }
}

/// The backend's voice list, the one picked, and the sample player. One for the window, so the
/// rows share a single fetch.
@MainActor
final class VoiceAgentVoices: ObservableObject {
    static let shared = VoiceAgentVoices()
    static let defaultVoiceID = "petra"
    static let footnote = "Voices come from Petra’s backend on this Mac. Answers use this voice while Settings → Voice Agent → Voice is Automatic or the free voice."

    struct Voice: Identifiable, Hashable {
        let id: String
        let name: String
        let provider: String
    }

    @Published private(set) var voices: [Voice] = []
    @Published private(set) var status: String?
    @Published private(set) var isLoading = false
    @Published private(set) var isPlaying = false
    @Published private(set) var selected: String = OpenClickyConfiguration.settings.voiceAgentVoice
    private var player: AVAudioPlayer?

    /// GET /voices. A failure keeps the last list and says why.
    func refresh() {
        guard !isLoading, let url = URL(string: "\(OpenClickyConfiguration.backendBaseURL)/voices") else { return }
        isLoading = true
        Task {
            defer { isLoading = false }
            var request = URLRequest(url: url, timeoutInterval: 10)
            OpenClickyConfiguration.authorize(&request)
            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                guard (200...299).contains(status),
                      let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let list = object["voices"] as? [[String: Any]] else {
                    self.status = "The backend has no voice list (HTTP \(status)). Is Petra’s backend up to date?"
                    AppLog.append("voice agent: GET /voices failed (HTTP \(status))")
                    return
                }
                voices = list.compactMap { entry in
                    guard let id = entry["id"] as? String, !id.isEmpty else { return nil }
                    return Voice(id: id, name: (entry["name"] as? String) ?? id, provider: (entry["provider"] as? String) ?? "")
                }
                // shell.json is the truth; the backend's "selected" only fills in when the app has none.
                if let backendSelected = object["selected"] as? String, !backendSelected.isEmpty,
                   OpenClickyConfiguration.settings.voiceAgentVoice.isEmpty {
                    selected = backendSelected
                } else {
                    selected = OpenClickyConfiguration.settings.voiceAgentVoice
                }
                self.status = nil
            } catch {
                self.status = "Couldn’t reach Petra’s backend: \(error.localizedDescription)"
                AppLog.append("voice agent: GET /voices failed: \(error.localizedDescription)")
            }
        }
    }

    func select(_ voiceID: String) {
        selected = voiceID
        OpenClickyConfiguration.update { $0.voiceAgentVoice = voiceID }
        ShellSettingsRevision.shared.noteChanged()
        AppLog.append("voice agent: voice → \(voiceID)")
    }

    /// POST /tts with a line and plays what comes back (wav or mp3).
    func playSample() {
        guard !isPlaying, let url = URL(string: "\(OpenClickyConfiguration.backendBaseURL)/tts") else { return }
        isPlaying = true
        Task {
            defer { isPlaying = false }
            var request = URLRequest(url: url, timeoutInterval: 30)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            OpenClickyConfiguration.authorize(&request)
            request.httpBody = try? JSONSerialization.data(withJSONObject: ["text": "Hi Luke, this is your voice agent."])
            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                guard (200...299).contains(status) else {
                    self.status = "The backend couldn’t speak (HTTP \(status))."
                    return
                }
                player = try AVAudioPlayer(data: data)
                player?.play()
                self.status = nil
            } catch {
                self.status = "The sample didn’t play: \(error.localizedDescription)"
            }
        }
    }

    /// The name for an id, also when the list hasn't loaded or no longer has it.
    func name(for voiceID: String) -> String {
        voices.first { $0.id == voiceID }?.name ?? (voiceID == Self.defaultVoiceID ? "Petra" : voiceID)
    }
}

private struct VoiceAgentVoiceRow: View {
    @ObservedObject private var model = VoiceAgentVoices.shared

    var body: some View {
        // The picked voice stays listed even when the backend no longer offers it.
        let listed = model.voices.contains { $0.id == model.selected } || model.selected.isEmpty
            ? model.voices
            : model.voices + [VoiceAgentVoices.Voice(id: model.selected, name: model.name(for: model.selected), provider: "")]
        SettingsRow(title: "Voice Agent’s voice", detail: model.status ?? "Who speaks the Voice Agent’s answers and announcements.") {
            HStack(spacing: 8) {
                Picker("", selection: Binding(get: { model.selected }, set: { model.select($0) })) {
                    ForEach(listed) { Text($0.name).tag($0.id) }
                }
                .labelsHidden()
                .frame(maxWidth: 240)
                .disabled(listed.isEmpty)
                .pointerCursor()
                Button(model.isLoading ? "Refreshing…" : "Refresh Voices") { model.refresh() }
                    .fixedSize()
                    .disabled(model.isLoading)
                    .pointerCursor(isEnabled: !model.isLoading)
            }
        }
        .onAppear { if model.voices.isEmpty { model.refresh() } }
    }
}

private struct VoiceAgentSampleRow: View {
    @ObservedObject private var model = VoiceAgentVoices.shared

    var body: some View {
        SettingsRow(title: "Play sample", detail: "Says “Hi Luke, this is your voice agent.” in \(model.name(for: model.selected)).") {
            Button(model.isPlaying ? "Playing…" : "Play Sample") { model.playSample() }
                .fixedSize()
                .disabled(model.isPlaying)
                .pointerCursor(isEnabled: !model.isPlaying)
        }
    }
}

private struct VoiceAgentDefaultRow: View {
    @ObservedObject private var model = VoiceAgentVoices.shared

    var body: some View {
        let isDefault = model.selected == VoiceAgentVoices.defaultVoiceID
        SettingsRow(title: "Default voice", detail: isDefault ? "Petra, made on this Mac by Voxtral. Free and offline. In use." : "Petra, made on this Mac by Voxtral. Free and offline.") {
            Button("Use Petra") { model.select(VoiceAgentVoices.defaultVoiceID) }
                .fixedSize()
                .disabled(isDefault)
                .pointerCursor(isEnabled: !isDefault)
        }
    }
}

/// `elevenLabsApiKey` in shell.json: saving it asks the backend for its voices again.
private struct VoiceAgentElevenLabsKeyRow: View {
    @ObservedObject private var shellSettingsRevision = ShellSettingsRevision.shared
    @State private var newKey = ""

    var body: some View {
        let _ = shellSettingsRevision.revision
        let saved = OpenClickyConfiguration.settings.elevenLabsApiKey?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let trimmed = newKey.trimmingCharacters(in: .whitespacesAndNewlines)
        SettingsRow(title: "ElevenLabs API key",
                    detail: saved.isEmpty ? "Its voices join the list above." : "Saved ••••\(saved.suffix(4)). Its voices are in the list above.") {
            HStack(spacing: 8) {
                SecureField("", text: $newKey, prompt: Text(saved.isEmpty ? "sk_…" : "Replace key"))
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 150)
                    .onSubmit { save(trimmed) }
                    .accessibilityLabel("ElevenLabs API key")
                Button("Save") { save(trimmed) }
                    .fixedSize()
                    .disabled(trimmed.isEmpty)
                    .pointerCursor(isEnabled: !trimmed.isEmpty)
                if !saved.isEmpty {
                    Button("Remove") { save(nil) }
                        .fixedSize()
                        .pointerCursor()
                }
            }
        }
    }

    private func save(_ key: String?) {
        if let key, key.isEmpty { return }
        OpenClickyConfiguration.update { $0.elevenLabsApiKey = key }
        ShellSettingsRevision.shared.noteChanged()
        newKey = ""
        // A removed key takes its voices with it; the backend falls back to Petra.
        if key == nil, VoiceAgentVoices.shared.selected.hasPrefix("elevenlabs:") {
            VoiceAgentVoices.shared.select(VoiceAgentVoices.defaultVoiceID)
        }
        VoiceAgentVoices.shared.refresh()
    }
}
