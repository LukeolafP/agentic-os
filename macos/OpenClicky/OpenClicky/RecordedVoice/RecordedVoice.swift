//
//  RecordedVoice.swift
//  OpenClicky
//
//  The lines OpenClicky says the same way every time, recorded once in its answering voice
//  (OpenAI speech, marin) and bundled, so they sound good with no key and no network: the
//  first-run tour's narration, and the notices that used to be read by the Mac's system voice
//  ("i didn't get an answer…"). Anything not recorded here is spoken the way it was before.
//
//  Agentic OS: every line is said in the Voice Agent's own voice instead. `backendAudio` (set by
//  CompanionManager) renders a line's text through the backend's /tts and it is played from
//  there; the recordings are only played when the backend could not render it.
//

import AVFoundation
import Foundation

@MainActor
final class RecordedVoice {
    enum Line: String {
        case tourHello = "tour-hello"
        case tourDictate = "tour-dictate"
        case tourDictateDone = "tour-dictate-done"
        case tourTalk = "tour-talk"
        case tourTalkDone = "tour-talk-done"
        case tourAct = "tour-act"
        case tourActDone = "tour-act-done"
        case tourAccount = "tour-account"
        case tourDone = "tour-done"
        case noticeEmptyAnswer = "notice-empty-answer"
        case noticeNoScreen = "notice-no-screen"
        case noticeScreenRecordingOff = "notice-screen-recording-off"
        case noticeNoInternet = "notice-no-internet"
        case noticeStoppedPartway = "notice-stopped-partway"
        case noticeWentWrong = "notice-went-wrong"
        case noticeRealtimeUnavailable = "notice-realtime-unavailable"
        // The one-minute Settings tour (SettingsTour.swift).
        case settingsTourIntro = "settings-tour-intro"
        case settingsTourDictation = "settings-tour-dictation"
        case settingsTourLanguage = "settings-tour-language"
        case settingsTourVoice = "settings-tour-voice"
        case settingsTourPointer = "settings-tour-pointer"
        case settingsTourWords = "settings-tour-words"
        case settingsTourShortcuts = "settings-tour-shortcuts"
        case settingsTourKeys = "settings-tour-keys"
        case settingsTourDone = "settings-tour-done"
    }

    /// The fixed sentences the app speaks, by their exact text (any case), and their recording.
    static let notices: [String: Line] = [
        "i didn't get an answer. please ask again.": .noticeEmptyAnswer,
        "i couldn't see your screen just now. please ask again.": .noticeNoScreen,
        "screen recording is off for agentic os. turn it on in system settings, privacy and security, screen recording.": .noticeScreenRecordingOff,
        "i couldn't reach agentic os. check your internet and ask again.": .noticeNoInternet,
        "the answer stopped partway. please ask again.": .noticeStoppedPartway,
        "something went wrong getting your answer. please ask again.": .noticeWentWrong,
        "realtime voice is unavailable right now.": .noticeRealtimeUnavailable,
    ]

    static func line(forSpokenText text: String) -> Line? {
        notices[text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()]
    }

    /// What each recording says (scripts/record-voice-lines.py, and the tour cards), so the Voice
    /// Agent can say it in its own voice.
    static let texts: [Line: String] = [
        .tourHello: "hi, i'm your voice agent, your pointer's new sidekick. i'll show you three things. it takes about a minute.",
        .tourDictate: "hold the dictation key, say a sentence, then let go. your words land wherever your cursor is.",
        .tourDictateDone: "that's dictation. it works in any app, wherever your cursor is.",
        .tourTalk: "your turn. hold control and option, and ask me about anything on your screen.",
        .tourTalkDone: "that's asking. i answer out loud, and i can point at things too.",
        .tourAct: "now give me a task. hold control and option, and tell me what to do.",
        .tourActDone: "on it. results show up in the island.",
        .tourAccount: "everything here runs on this mac, through petra's backend. no account needed.",
        .tourDone: "that's it. hold the dictation key to type, and control and option to ask. i'll be in your menu bar.",
        .noticeEmptyAnswer: "i didn't get an answer. please ask again.",
        .noticeNoScreen: "i couldn't see your screen just now. please ask again.",
        .noticeScreenRecordingOff: "screen recording is off for agentic os. turn it on in system settings, privacy and security, screen recording.",
        .noticeNoInternet: "i couldn't reach agentic os. check your internet and ask again.",
        .noticeStoppedPartway: "the answer stopped partway. please ask again.",
        .noticeWentWrong: "something went wrong getting your answer. please ask again.",
        .noticeRealtimeUnavailable: "realtime voice is unavailable right now.",
        .settingsTourIntro: "here's a one-minute tour of settings. everything lives in these pages, and the search box finds any setting.",
        .settingsTourDictation: "on dictation, this is the key you hold, anywhere, to type with your voice.",
        .settingsTourLanguage: "here you choose the language you speak, and a little further down, whether ai tidies up your words.",
        .settingsTourVoice: "on the agentic os page, you choose how i sound.",
        .settingsTourPointer: "here you choose when i follow your mouse. if i'm hiding, shake the mouse and i'll come back.",
        .settingsTourWords: "your words keeps everything you've dictated, so you can always find it again.",
        .settingsTourShortcuts: "hold control and option to talk to me. the rarer shortcuts are under more, at the bottom of each page.",
        .settingsTourKeys: "keys and account holds your elevenlabs key, if you want its voices. you don't need one.",
        .settingsTourDone: "that's it! you can watch this tour again from here, any time.",
    ]

    /// The Voice Agent's voice: renders a line's text to audio (CompanionManager sets it to the
    /// backend's /tts). Nil, or a throw, plays the recording instead.
    var backendAudio: ((String) async throws -> Data)?
    /// The line being rendered, so a line started after it is not overtaken by its audio.
    private var renderTask: Task<Void, Never>?
    private var lineNumber = 0

    private var player: AVAudioPlayer?
    /// Tells whoever played the current line that it ended. Held here because the player's
    /// delegate is weak.
    private var finishObserver: AudioPlayerFinishObserver?

    var isPlaying: Bool { renderTask != nil || (player?.isPlaying ?? false) }

    /// Says `line`, cutting off whatever line was playing: in the Voice Agent's voice when
    /// `backendAudio` renders its text, else from its recording. False when it is not bundled.
    /// `onFinished` runs once when the line ends: played to the end, cut off by the next line, or
    /// stopped (the companion uses it to go back to idle after a spoken notice).
    @discardableResult
    func play(_ line: Line, onFinished: (() -> Void)? = nil) -> Bool {
        guard let backendAudio, let text = Self.texts[line] else { return playRecording(line, onFinished: onFinished) }
        stopCurrentLine()
        lineNumber += 1
        let thisLine = lineNumber
        renderTask = Task { [weak self] in
            let audio = try? await backendAudio(text)
            guard let self, self.lineNumber == thisLine, !Task.isCancelled else { return }
            self.renderTask = nil
            if let audio, let newPlayer = try? AVAudioPlayer(data: audio) {
                self.start(newPlayer, onFinished: onFinished)
            } else {
                AppLog.append("recorded voice: the backend couldn't say \(line.rawValue); playing the recording")
                if !self.playRecording(line, onFinished: onFinished) { onFinished?() }
            }
        }
        return true
    }

    /// The bundled recording of `line`. False when it is not bundled.
    @discardableResult
    private func playRecording(_ line: Line, onFinished: (() -> Void)?) -> Bool {
        guard let url = Bundle.main.url(forResource: line.rawValue, withExtension: "mp3"),
              let newPlayer = try? AVAudioPlayer(contentsOf: url) else {
            AppLog.append("recorded voice: \(line.rawValue).mp3 is not in the bundle")
            return false
        }
        stopCurrentLine()
        start(newPlayer, onFinished: onFinished)
        return true
    }

    private func start(_ newPlayer: AVAudioPlayer, onFinished: (() -> Void)?) {
        newPlayer.volume = 0.85
        let newFinishObserver = AudioPlayerFinishObserver()
        newFinishObserver.onFinish = onFinished
        newPlayer.delegate = newFinishObserver
        finishObserver = newFinishObserver
        player = newPlayer
        if !newPlayer.play() { newFinishObserver.finishOnce() }
    }

    func stop() {
        stopCurrentLine()
    }

    /// A stopped AVAudioPlayer never calls its delegate, so the end is reported here.
    private func stopCurrentLine() {
        renderTask?.cancel()
        renderTask = nil
        player?.stop()
        finishObserver?.finishOnce()
        finishObserver = nil
    }
}
