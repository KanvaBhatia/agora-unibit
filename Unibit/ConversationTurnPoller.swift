//
//  ConversationTurnPoller.swift
//  Unibit
//
//  While an Agora conversational session is live, polls the Worker for the
//  latest conversation exchange (what the user said + what Unibit replied) so
//  the on-screen conversation pill can render both sides of the turn. The agent
//  does ASR in-channel, so the app never sees the user's own transcript directly
//  — this poll is how the pill learns what was said. `id` increments per
//  exchange so each turn is rendered exactly once.
//

import Foundation

@MainActor
final class ConversationTurnPoller {
    /// An exchange returned by GET /agent/utterance.
    struct ConversationTurn {
        let id: Int
        let userText: String
        let replyText: String
    }

    private let workerBaseURL: String
    private let session: URLSession
    private var pollTimer: Timer?
    /// The highest turn id we've already shown — only newer ids fire the callback.
    private var lastShownTurnId = 0

    private static let pollIntervalSeconds: TimeInterval = 1.0

    init(workerBaseURL: String) {
        self.workerBaseURL = workerBaseURL
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 10
        self.session = URLSession(configuration: configuration)
    }

    /// Starts polling. `onNewTurn` fires on the main actor each time the Worker
    /// reports an exchange with an id we haven't shown yet.
    func startPollingForTurns(onNewTurn: @escaping @MainActor (ConversationTurn) -> Void) {
        stopPollingForTurns()
        lastShownTurnId = 0
        pollTimer = Timer.scheduledTimer(
            withTimeInterval: Self.pollIntervalSeconds,
            repeats: true
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.pollOnce(onNewTurn: onNewTurn)
            }
        }
        print("💬 Conversation turn poller started (every \(Int(Self.pollIntervalSeconds))s)")
    }

    /// Stops polling. Called when the Agora session ends.
    func stopPollingForTurns() {
        pollTimer?.invalidate()
        pollTimer = nil
    }

    private func pollOnce(onNewTurn: @escaping @MainActor (ConversationTurn) -> Void) async {
        do {
            let (data, response) = try await session.data(from: URL(string: "\(workerBaseURL)/agent/utterance")!)
            guard let httpResponse = response as? HTTPURLResponse,
                  (200...299).contains(httpResponse.statusCode) else { return }

            guard let decoded = try? JSONDecoder().decode(TurnResponse.self, from: data),
                  decoded.id > lastShownTurnId else { return }

            lastShownTurnId = decoded.id
            onNewTurn(ConversationTurn(
                id: decoded.id,
                userText: decoded.userText ?? "",
                replyText: decoded.replyText ?? ""
            ))
        } catch {
            // Polling is best-effort — a dropped tick just means a slightly
            // later render. The next tick retries.
        }
    }

    private struct TurnResponse: Decodable {
        let id: Int
        let userText: String?
        let replyText: String?
    }
}
