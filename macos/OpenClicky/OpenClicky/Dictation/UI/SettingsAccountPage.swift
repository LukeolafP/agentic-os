//
//  SettingsAccountPage.swift
//  OpenClicky
//
//  Settings → Keys: the ElevenLabs key (testable). Agentic OS (10 Nov 2026): the account, the
//  free allowance, the backend host and token, the other provider keys and the Claude Code and
//  Codex plan rows were taken out; the backend on this Mac answers everything and needs no account.
//

import AppKit
import SwiftUI

extension SettingsCatalog {
    /// Agentic OS: no account, no allowance, no backend host or token rows; the local backend
    /// needs none of them.
    func accountItems() -> [SettingsItem] { [] }

    /// Agentic OS: the one key the app still takes, ElevenLabs, whose voices the backend offers
    /// on the Agentic OS page. Every other provider key went with the hosted service.
    func keysItems() -> [SettingsItem] {
        [
            SettingsItem(
                id: "account.keys",
                title: "Your keys", detail: "An ElevenLabs key brings its voices to the Agentic OS page.",
                keywords: ["api key", "own key", "provider", "add key", "elevenlabs", "voice", "test"],
                view: AnyView(ProviderKeysList())),
            SettingsItem(
                id: "account.keysNote",
                title: "Where keys go", detail: "Your ElevenLabs key is stored in ~/.openclicky/shell.json and read by the backend on this Mac.",
                keywords: ["shell.json"],
                chrome: .footer,
                view: AnyView(SettingsFootnote(text: "Your ElevenLabs key is stored in ~/.openclicky/shell.json and read by the backend on this Mac."))),
        ]
    }
}

// MARK: - your keys

/// A provider a key can be saved for: where it lives in shell.json and how its row reads.
/// Not private: the Spotify row's mapping is unit-tested. Agentic OS offers only `offered`.
enum KeyProvider: String, CaseIterable, Identifiable {
    case openAI, anthropic, openRouter, gemini, groq, mistral, xai, sarvam, elevenLabs, googleCloud, amazonPolly, spotify

    /// Agentic OS: the keys the page takes.
    static let offered: [KeyProvider] = [.elevenLabs]

    var id: String { rawValue }

    var title: String {
        switch self {
        case .openAI: return "OpenAI"
        case .anthropic: return "Anthropic (Claude)"
        case .openRouter: return "OpenRouter"
        case .gemini: return "Google Gemini"
        case .groq: return "Groq"
        case .mistral: return "Mistral"
        case .xai: return "xAI (Grok)"
        case .sarvam: return "Sarvam"
        case .elevenLabs: return "ElevenLabs"
        case .googleCloud: return "Google Cloud voice"
        case .amazonPolly: return "Amazon Polly"
        case .spotify: return "Spotify"
        }
    }

    var detail: String {
        switch self {
        case .openAI: return "Answers, fast voice and hands-free."
        case .anthropic: return "Claude answers your questions about the screen."
        case .openRouter: return "One key for Claude, GPT, Gemini, Llama and more."
        case .gemini: return "Answers and a voice. From Google AI Studio."
        case .groq: return "Very fast answers on open models."
        case .mistral: return "Mistral’s own models."
        case .xai: return "Grok, from xAI."
        case .sarvam: return "Speaks answers in a natural voice (Bulbul), and the Sarvam dictation engine for Indian languages."
        case .elevenLabs: return "Speaks answers in ElevenLabs’ voice, on your own ElevenLabs account."
        case .googleCloud: return "Speaks answers. A Google Cloud API key with the Text-to-Speech API switched on; an AI Studio key won’t do."
        case .amazonPolly: return "Speaks answers in Amazon’s neural voices. Paste access key ID:secret key, then :region if it isn’t us-east-1."
        case .spotify: return "Finds the song you asked for. Paste client id:client secret from developer.spotify.com; without it Agentic OS’s own lookup is used."
        }
    }

    var placeholder: String {
        switch self {
        case .openAI: return "sk-…"
        case .anthropic: return "sk-ant-…"
        case .openRouter: return "sk-or-…"
        case .gemini: return "AIza…"
        case .groq: return "gsk_…"
        case .mistral: return "Mistral key"
        case .xai: return "xai-…"
        case .sarvam: return "Sarvam key"
        case .elevenLabs: return "sk_…"
        case .googleCloud: return "AIza…"
        case .amazonPolly: return "AKIA…:secret"
        case .spotify: return "id:secret"
        }
    }

    var keyPath: WritableKeyPath<OpenClickyShellSettings, String?> {
        switch self {
        case .openAI: return \.openaiApiKey
        case .anthropic: return \.anthropicApiKey
        case .openRouter: return \.openRouterApiKey
        case .gemini: return \.geminiApiKey
        case .groq: return \.groqApiKey
        case .mistral: return \.mistralApiKey
        case .xai: return \.xaiApiKey
        case .sarvam: return \.sarvamKey
        case .elevenLabs: return \.elevenLabsApiKey
        case .googleCloud: return \.googleCloudApiKey
        case .amazonPolly: return \.amazonPollyCredentials
        case .spotify: return \.spotifyCredentials
        }
    }

    /// The source this key answers questions as; the voice-only keys answer nothing.
    var answerSource: AnswerSource? {
        switch self {
        case .openAI: return .openAI
        case .anthropic: return .anthropic
        case .openRouter: return .openRouter
        case .gemini: return .gemini
        case .groq: return .groq
        case .mistral: return .mistral
        case .xai: return .xai
        case .sarvam, .elevenLabs, .googleCloud, .amazonPolly, .spotify: return nil
        }
    }

    /// The voice this key speaks answers in, for its Test button.
    var speechVoice: SpeechVoiceChoice? {
        switch self {
        case .sarvam: return .sarvam
        case .elevenLabs: return .elevenLabs
        case .googleCloud: return .google
        case .amazonPolly: return .polly
        default: return nil
        }
    }

    var savedKey: String? {
        let key = (OpenClickyConfiguration.settings[keyPath: keyPath] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return key.isEmpty ? nil : key
    }
}

/// Your keys: one row per saved key (Test, Remove) and an "Add a key" row whose menu holds the
/// providers without one, so the list stays short however many providers there are.
private struct ProviderKeysList: View {
    @ObservedObject private var shellSettingsRevision = ShellSettingsRevision.shared
    @State private var newProvider: KeyProvider = .elevenLabs
    @State private var newKey = ""
    @State private var addStatus: String?
    /// What the last Test or Save said, per provider.
    @State private var rowStatus: [KeyProvider: String] = [:]
    @State private var checking: Set<KeyProvider> = []
    @State private var pendingRemoval: KeyProvider?
    @ObservedObject private var dictationSettings = DictationSettings.shared

    var body: some View {
        let _ = shellSettingsRevision.revision
        let saved = KeyProvider.offered.filter { $0.savedKey != nil }
        let unsaved = KeyProvider.offered.filter { $0.savedKey == nil }
        // A group, not a stack: the form draws each key as its own row, with its separators.
        Group {
            ForEach(saved) { provider in savedRow(provider) }
            Group {
                if unsaved.isEmpty {
                    SettingsRow(title: "Every provider has a key", detail: addStatus) { EmptyView() }
                } else {
                    addRow(unsaved)
                }
            }
            .onAppear { if !unsaved.contains(newProvider), let first = unsaved.first { newProvider = first } }
            .confirmationDialog("Remove the \(pendingRemoval?.title ?? "") key?", isPresented: Binding(
                get: { pendingRemoval != nil }, set: { if !$0 { pendingRemoval = nil } })) {
                Button("Remove", role: .destructive) { if let pendingRemoval { remove(pendingRemoval) } }
            } message: {
                Text("It’s deleted from ~/.openclicky/shell.json. Keep a copy if you’ll need it again.")
            }
        }
    }

    private func savedRow(_ provider: KeyProvider) -> some View {
        let masked = "••••" + String((provider.savedKey ?? "").suffix(4))
        return SettingsRow(title: provider.title, detail: rowStatus[provider] ?? "\(provider.detail) \(masked)") {
            HStack(spacing: 8) {
                Button(checking.contains(provider) ? "Testing…" : "Test") { test(provider) }
                    .disabled(checking.contains(provider))
                    .help(provider.speechVoice == nil ? "Ask it what colour a red square is" : "Have it say a word")
                    .pointerCursor(isEnabled: !checking.contains(provider))
                Button("Remove") { pendingRemoval = provider }
                    .pointerCursor()
            }
        }
    }

    private func addRow(_ unsaved: [KeyProvider]) -> some View {
        SettingsRow(title: "Add a key", detail: addStatus ?? newProvider.detail) {
            HStack(spacing: 8) {
                Picker("Provider", selection: $newProvider) {
                    ForEach(unsaved) { Text($0.title).tag($0) }
                }
                .labelsHidden()
                .fixedSize()
                .onChange(of: newProvider) { _, _ in addStatus = nil }
                .pointerCursor()
                SecureField("", text: $newKey, prompt: Text(newProvider.placeholder))
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 130)
                    .onSubmit(add)
                    .accessibilityLabel("\(newProvider.title) key")
                Button("Add", action: add)
                    .fixedSize()
                    .disabled(newKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .pointerCursor(isEnabled: !(newKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty))
            }
            .layoutPriority(1)
        }
    }

    private func add() {
        let provider = newProvider
        let trimmed = newKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        save(trimmed, for: provider)
        newKey = ""
        addStatus = nil
        if let next = KeyProvider.offered.first(where: { $0.savedKey == nil }) { newProvider = next }
        // Find out straight away whether it works.
        test(provider)
    }

    private func remove(_ provider: KeyProvider) {
        save(nil, for: provider)
        rowStatus[provider] = nil
        addStatus = "\(provider.title) key removed."
        newProvider = provider
    }

    private func save(_ key: String?, for provider: KeyProvider) {
        OpenClickyConfiguration.update { $0[keyPath: provider.keyPath] = key }
        // A changed key is a changed credential: a live realtime session reconnects with it.
        NotificationCenter.default.post(name: OpenClickyConfiguration.credentialsChangedNotification, object: nil)
        ShellSettingsRevision.shared.noteChanged()
    }

    private func test(_ provider: KeyProvider) {
        guard provider.savedKey != nil else { return }
        checking.insert(provider)
        rowStatus[provider] = "Checking…"
        Task {
            let sentence: String
            if let source = provider.answerSource {
                sentence = await AnswerSourceCheck.run(source, credentials: ProviderRouter.currentCredentials(),
                                                       modelOverrides: OpenClickyConfiguration.settings.answerModels ?? [:]).sentence
            } else if let voice = provider.speechVoice {
                // A voice key is checked by having it say one word.
                do {
                    _ = try await CloudVoiceSpeaker.audio(for: "ok", voice: voice)
                    sentence = "✓ Works. It can speak your answers."
                } catch {
                    sentence = error.localizedDescription
                }
            } else if provider == .spotify {
                // Spotify credentials are checked by looking one song up.
                let route = MusicLookupRoute.route(credentials: provider.savedKey, backendURL: nil)
                let tracks = await MusicLookup(route: route).search("test")
                sentence = tracks.first.map { "✓ Works. Found \($0.name)." } ?? "✗ Spotify refused the credentials."
            } else {
                sentence = "Saved."
            }
            rowStatus[provider] = sentence
            checking.remove(provider)
        }
    }
}

