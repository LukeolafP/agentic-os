//
//  SettingsClickyPage.swift
//  OpenClicky
//
//  Settings → Voice Agent's rows: when the pointer shows (one picker), draw to explain, the
//  language the Voice Agent speaks and listens in, hands-free, and which inbox email requests use.
//  Agentic OS (10 Nov 2026): the answer source and Claude model, agent mode and its workspace, the
//  speech voice rows (Kokoro and the Mac voice with them) and fast voice went; the backend on this
//  Mac answers and speaks (Settings → Agentic OS picks its voice).
//

import AppKit
import Combine
import AVFoundation
import SwiftUI

extension SettingsCatalog {
    /// Who answers, the pointer, and agent mode.
    func clickyItems() -> [SettingsItem] {
        [
            SettingsItem(
                id: "clicky.drawToExplain",
                title: DrawToExplainRow.title, detail: DrawToExplainRow.detail,
                keywords: ["draw", "drawing", "3d", "diagram", "explain", "teach", "stage", "picture", "sketch", "model"],
                view: AnyView(DrawToExplainRow(settings: settings))),
            SettingsItem(
                id: "clicky.onThisMac",
                title: OnThisMacRow.title, detail: OnThisMacRow.detail,
                keywords: ["apple intelligence", "on device", "local", "private", "offline", "this mac", "credits", "quick actions", "open app", "volume", "rewrite"],
                view: AnyView(OnThisMacRow(settings: settings))),
            SettingsItem(
                id: "clicky.pointer",
                title: "Show the pointer", detail: "It flies to what the Voice Agent means.",
                keywords: ["pointer", "cursor", "buddy", "orange", "visible", "hide", "always", "while the mouse moves", "after a shake", "shake", "while i talk"],
                view: AnyView(PointerShowsRow(companionManager: companionManager))),
        ]
    }

    /// The language Clicky speaks and listens in, who speaks the answers (Kokoro
    /// and the Mac voice with their own rows), and fast voice with hands-free.
    func voiceItems() -> [SettingsItem] {
        var items: [SettingsItem] = [
            SettingsItem(
                id: "clicky.language",
                title: "Language", detail: "The Voice Agent speaks and listens in this.",
                keywords: ["language", "english", "hindi", "tamil", "spanish", "french", "speak", "reply", "listen"],
                view: AnyView(ReplyLanguageRow(settings: settings))),
        ]
        // Hands-free works on every lane that can answer: instantly with fast voice, otherwise
        // the standard lane hears each turn on this Mac once the person stops talking.
        if OpenClickyConfiguration.isConfigured {
            let detail = "Hands-free: just talk, no keys. The Voice Agent answers once you stop talking."
            items.append(SettingsItem(
                id: "clicky.alwaysListening",
                title: "Always listening", detail: detail,
                keywords: ["hands-free", "hands free", "always on", "listening"],
                view: AnyView(CompanionSwitchRow(
                    title: "Always listening", detail: detail,
                    publisher: companionManager.$isAlwaysListening.eraseToAnyPublisher(),
                    initialValue: companionManager.isAlwaysListening,
                    set: { [companionManager] in companionManager.setAlwaysListening($0) }))))
        }
        // "Check my email" and "draft an email": which inbox they go to.
        items += [
            SettingsItem(
                id: "clicky.emailApp",
                title: "Email", detail: "Which inbox “check my email” and “draft an email” use.",
                keywords: ["email", "mail", "gmail", "inbox", "draft", "apple mail"],
                view: AnyView(EmailAppRow())),
            SettingsItem(
                id: "clicky.emailNeverSent",
                title: EmailAppRow.footerText, keywords: ["send", "email"],
                chrome: .footer,
                view: AnyView(Text(EmailAppRow.footerText).font(SettingsLook.caption).foregroundStyle(.secondary))),
        ]
        return items
    }
}

/// Which inbox "check my email" and "draft an email" use: automatic (Apple Mail when it has
/// accounts here, else Gmail), Apple Mail, or Gmail. `emailApp` in shell.json.
struct EmailAppRow: View {
    static let footerText = "Nothing is ever sent by voice."
    @ObservedObject private var shellSettingsRevision = ShellSettingsRevision.shared

    /// The picker's tag for a saved setting; anything unknown shows as automatic.
    static func tag(forSetting setting: String?) -> String {
        guard let setting, EmailApp(rawValue: setting) != nil else { return "auto" }
        return setting
    }

    /// The setting a picked tag saves; automatic saves nothing.
    static func settingValue(forTag tag: String) -> String? {
        EmailApp(rawValue: tag)?.rawValue
    }

    var body: some View {
        let _ = shellSettingsRevision.revision
        SettingsRow(title: "Email", detail: "Which inbox “check my email” and “draft an email” use. Automatic is Apple Mail when it’s set up, else Gmail.") {
            Picker("", selection: Binding(
                get: { Self.tag(forSetting: OpenClickyConfiguration.settings.emailApp) },
                set: { tag in
                    OpenClickyConfiguration.update { $0.emailApp = Self.settingValue(forTag: tag) }
                    ShellSettingsRevision.shared.noteChanged()
                }
            )) {
                Text("Automatic").tag("auto")
                Text("Apple Mail").tag("mail")
                Text("Gmail").tag("gmail")
            }
            .labelsHidden().fixedSize()
            .pointerCursor()
        }
    }
}

/// A switch for one of the companion's own settings. It follows the one published value instead
/// of observing the whole companion manager, which republishes on every audio level.
private struct CompanionSwitchRow: View {
    let title: String
    let detail: String
    let publisher: AnyPublisher<Bool, Never>
    let set: (Bool) -> Void
    @State private var isOn: Bool

    init(title: String, detail: String, publisher: AnyPublisher<Bool, Never>, initialValue: Bool, set: @escaping (Bool) -> Void) {
        self.title = title
        self.detail = detail
        self.publisher = publisher
        self.set = set
        _isOn = State(initialValue: initialValue)
    }

    var body: some View {
        SettingsRow(title: title, detail: detail) {
            SettingsSwitch(isOn: Binding(get: { isOn }, set: { set($0) }))
        }
        .onReceive(publisher) { isOn = $0 }
    }
}

/// When the pointer shows, as one picker: only while you talk (the old switch off), or with the
/// pointer on, always, while the mouse moves, or after a shake. Two settings underneath:
/// `isClickyCursorEnabled` and `pointerPresence`.
enum PointerShowsChoice: String, CaseIterable, Identifiable {
    case whileTalking, always, whileMoving, onShake
    var id: String { rawValue }

    var title: String {
        switch self {
        case .whileTalking: return "While I talk"
        case .always: return "Always"
        case .whileMoving: return "While the mouse moves"
        case .onShake: return "After a shake"
        }
    }

    /// The pointer's line under the picker.
    var detail: String {
        switch self {
        case .whileTalking: return "Appears when you ask and leaves once the Voice Agent is done."
        case .always: return "Follows the mouse everywhere."
        case .whileMoving: return "Fades a few seconds after the mouse rests."
        case .onShake: return "Hidden until you shake, or until the Voice Agent needs it."
        }
    }

    init(isPointerShown: Bool, presence: PointerPresence) {
        guard isPointerShown else { self = .whileTalking; return }
        switch presence {
        case .always: self = .always
        case .whileMoving: self = .whileMoving
        case .onShake: self = .onShake
        }
    }

    /// The presence this choice sets; nil for "while I talk", which only turns the pointer off
    /// and leaves the presence as it was for when it comes back on.
    var presence: PointerPresence? {
        switch self {
        case .whileTalking: return nil
        case .always: return .always
        case .whileMoving: return .whileMoving
        case .onShake: return .onShake
        }
    }
}

/// Follows the two settings on its own instead of observing the whole companion manager, which
/// republishes on every audio level.
private struct PointerShowsRow: View {
    let companionManager: CompanionManager
    @State private var presence: PointerPresence
    @State private var isPointerShown: Bool

    init(companionManager: CompanionManager) {
        self.companionManager = companionManager
        _presence = State(initialValue: companionManager.pointerPresence)
        _isPointerShown = State(initialValue: companionManager.isClickyCursorEnabled)
    }

    private var choice: PointerShowsChoice { PointerShowsChoice(isPointerShown: isPointerShown, presence: presence) }

    var body: some View {
        SettingsRow(title: "Show the pointer", detail: choice.detail) {
            Picker("", selection: Binding(get: { choice }, set: { newChoice in
                companionManager.setClickyCursorEnabled(newChoice != .whileTalking)
                if let newPresence = newChoice.presence { companionManager.setPointerPresence(newPresence) }
            })) {
                ForEach(PointerShowsChoice.allCases) { option in Text(option.title).tag(option) }
            }
            .labelsHidden()
            .fixedSize()
            .pointerCursor()
            .accessibilityLabel("Show the pointer")
        }
        .onReceive(companionManager.$pointerPresence) { presence = $0 }
        .onReceive(companionManager.$isClickyCursorEnabled) { isPointerShown = $0 }
    }
}

/// Settings → Clicky: draw to explain. A question a picture or a 3D model answers is drawn on the
/// screen while Clicky talks (the drawing stage); off, every question is answered in words.
struct DrawToExplainRow: View {
    @ObservedObject var settings: DictationSettings

    static let title = "Draw to explain"
    static let detail = "When a picture or a 3D model explains it better, the Voice Agent draws on your screen while it talks. Ask \"how does a jet engine work?\" to see it."

    var body: some View {
        SettingsRow(title: Self.title, detail: Self.detail) {
            SettingsToggle(settings: settings, keyPath: \.drawToExplain)
        }
    }
}

/// Settings → Clicky → Answers: the local ask rung's switch. The detail says what the rung does and,
/// when Apple's model is not available on this Mac, why not (the switch is then disabled); a
/// person whose ⌃⌥ goes to the Realtime lane is told it does not apply to them. Read when drawn,
/// as the "Answers come from" row reads the credentials.
struct OnThisMacRow: View {
    @ObservedObject var settings: DictationSettings

    static let title = "Simple requests stay on this Mac"
    static let detail = "Opening apps and websites, folders, volume, playback and rewrites are understood by Apple Intelligence on this Mac: no screenshot is sent and no answer credits are used."
    static let realtimeNote = "Not used while your OpenAI key answers out loud."

    var body: some View {
        let unavailableReason = LocalAskModelAvailability.unavailableReason()
        let goesToRealtime = OpenClickyConfiguration.isConfigured && AccountCapabilities.current().usesRealtime
        SettingsRow(title: Self.title, detail: Self.detailShown(unavailableReason: unavailableReason, goesToRealtime: goesToRealtime)) {
            SettingsToggle(settings: settings, keyPath: \.answerSimpleRequestsOnThisMac)
                .disabled(unavailableReason != nil)
        }
    }

    static func detailShown(unavailableReason: String?, goesToRealtime: Bool) -> String {
        if let unavailableReason { return "Not available: \(unavailableReason)." }
        return goesToRealtime ? detail + " " + realtimeNote : detail
    }
}

/// The one language OpenClicky speaks and listens in (`language` in shell.json).
private struct ReplyLanguageRow: View {
    @ObservedObject var settings: DictationSettings
    @State private var languageCode = ReplyLanguage.currentCode

    var body: some View {
        SettingsRow(title: "Language", detail: "The Voice Agent speaks and listens in this. Dictation has its own, on the Dictation page.") {
            Picker("", selection: Binding(
                get: { languageCode },
                set: { chosenCode in
                    languageCode = chosenCode
                    OpenClickyConfiguration.update { $0.language = chosenCode }
                }
            )) {
                ForEach(ReplyLanguage.choices(region: settings.region, currentCode: languageCode)) { choice in Text(choice.name).tag(choice.code) }
            }
            .labelsHidden().fixedSize()
            .pointerCursor()
        }
    }
}

