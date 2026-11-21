//
//  AgentReplyPoller.swift
//  Unibit
//
//  While an Agora conversational session is live, polls the Worker for the
//  latest clean LLM reply text and speaks it locally via Murf REST. This
//  bypasses Agora's Murf stream-input bridge, which segments the reply into
//  separate TTS utterances and audibly garbles multi-sentence answers. The
//  agent itself publishes no audio (the Worker omits `tts`), so the only voice
//  the user hears is the one synthesized here. `id` increments per reply so
//  each reply is spoken exactly once.
//

import Foundation

@MainActor
final class AgentReplyPoller {
    /// A reply returned by GET /agent/reply.
    struct AgentReply {
        let id: Int
        let text: String
    }

    private let workerBaseURL: String
    private let session: URLSession
    private var pollTimer: Timer?
    /// The highest reply id we've already spoken — only newer ids fire the callback.
    private var lastSpokenReplyId = 0

    private static let pollIntervalSeconds: TimeInterval = 1.0

    init(workerBaseURL: String) {
        self.workerBaseURL = workerBaseURL
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 10
        self.session = URLSession(configuration: configuration)
    }

    /// Starts polling. `onNewReply` fires on the main actor each time the Worker
    /// reports a reply with an id we haven't spoken yet.
    func startPollingForReplies(onNewReply: @escaping @MainActor (AgentReply) -> Void) {
        stopPollingForReplies()
        lastSpokenReplyId = 0
        pollTimer = Timer.scheduledTimer(
            withTimeInterval: Self.pollIntervalSeconds,
            repeats: true
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.pollOnce(onNewReply: onNewReply)
            }
        }
        print("🗣️ Agent reply poller started (every \(Int(Self.pollIntervalSeconds))s)")
    }

    /// Stops polling. Called when the Agora session ends.
    func stopPollingForReplies() {
        pollTimer?.invalidate()
        pollTimer = nil
    }

    private func pollOnce(onNewReply: @escaping @MainActor (AgentReply) -> Void) async {
        do {
            let (data, response) = try await session.data(from: URL(string: "\(workerBaseURL)/agent/reply")!)
            guard let httpResponse = response as? HTTPURLResponse,
                  (200...299).contains(httpResponse.statusCode) else { return }

            guard let decoded = try? JSONDecoder().decode(ReplyResponse.self, from: data),
                  decoded.id > lastSpokenReplyId,
                  let text = decoded.text,
                  !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }

            lastSpokenReplyId = decoded.id
            onNewReply(AgentReply(id: decoded.id, text: text))
        } catch {
            // Polling is best-effort — a dropped tick just means a slightly
            // later utterance. The next tick retries.
        }
    }

    private struct ReplyResponse: Decodable {
        let id: Int
        let text: String?
    }
}
