//
//  LocalHTTPTakePolisher.swift
//  Agentic OS (GTD fork of OpenClicky, 10 Nov 2026)
//
//  FreeFlow polishing: on Petra's backend on this Mac, a dictation take is cleaned up by its
//  POST /v1/freeflow, which knows where the words are going. The request carries the raw words,
//  the app in front (name, bundle id, window title, read with Accessibility), the text selected
//  there, and the style's system prompt (which the backend may ignore); the answer is
//  {"text": "<cleaned>"}, where "" means paste nothing. A failure or a timeout
//  (`TakeFormatter.localHTTPModelTimeoutSeconds`) leaves the local formatting, as for any polisher.
//
//  Only takes go to FreeFlow. Hey Clicky edits and other model calls (`polish(system:user:)`) go to
//  the polisher that would have been picked without it.
//

import AppKit
import Foundation

struct LocalHTTPTakePolisher: TakePolisher {
    /// The polisher for everything that is not a take (Hey Clicky edits, questions about history).
    let fallback: (any TakePolisher)?

    var displayName: String { "FreeFlow" }

    func polish(system: String, user: String) async throws -> String {
        guard let fallback else { throw TakePolishError.notSetUp(DictationEngineResolver.howToGetAModelSentence) }
        return try await fallback.polish(system: system, user: user)
    }

    func polishTake(system: String, take: String) async throws -> String {
        // Where the words are going, read when the take is cleaned up (the app is still in front).
        let request: URLRequest? = try await MainActor.run {
            guard let url = URL(string: "\(OpenClickyConfiguration.backendBaseURL)/v1/freeflow") else { return nil }
            let front = FrontmostAppObserver.current()
            let body: [String: Any] = [
                "raw": take,
                "appName": front.appName ?? NSNull(),
                "bundleID": front.bundleIdentifier ?? NSNull(),
                "windowTitle": front.windowTitle ?? NSNull(),
                "selectedText": SelectedTextReader.currentSelection() ?? NSNull(),
                "system": system,
            ]
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.timeoutInterval = TakeFormatter.localHTTPModelTimeoutSeconds
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            OpenClickyConfiguration.authorize(&request)
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            return request
        }
        guard let request else { throw BackendPolishError.invalidBackendURL }
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            throw TakePolishError.refused(vendor: "freeflow", status: status, message: String(decoding: data.prefix(200), as: UTF8.self))
        }
        guard let answer = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let text = answer["text"] as? String else {
            throw TakePolishError.emptyAnswer(vendor: "freeflow")
        }
        return text
    }
}
