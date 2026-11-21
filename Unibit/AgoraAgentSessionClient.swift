//
//  AgoraAgentSessionClient.swift
//  Unibit
//
//  Talks to the Cloudflare Worker to start and stop Agora Conversational AI
//  agent sessions. The Worker holds the Agora REST credentials and mints the
//  RTC token the app needs to join the same channel as the agent.
//

import Foundation

@MainActor
final class AgoraAgentSessionClient {
    private let workerBaseURL: String
    private let session: URLSession

    /// Details needed to join the agent's channel, returned by /agent/start.
    struct AgentSession {
        let agentId: String
        let channel: String
        let uid: UInt
        let rtcToken: String
        let appId: String
    }

    init(workerBaseURL: String) {
        self.workerBaseURL = workerBaseURL

        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 30
        self.session = URLSession(configuration: configuration)
    }

    /// Starts an agent in a fresh channel and returns everything the app needs
    /// to join as the remote user the agent listens to.
    func startAgentSession() async throws -> AgentSession {
        // Unique channel + uid per session so concurrent runs never collide.
        let channel = "unibit-\(UUID().uuidString.prefix(8))"
        let uid = UInt.random(in: 1000...UInt(Int32.max))

        var request = URLRequest(url: URL(string: "\(workerBaseURL)/agent/start")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // uid must be a JSON number — the Worker validates typeof uid === "number".
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "channel": channel,
            "uid": uid,
        ])

        let (data, response) = try await session.data(for: request)
        try Self.throwIfNotOK(response, data: data)

        let decoded = try JSONDecoder().decode(StartResponse.self, from: data)
        return AgentSession(
            agentId: decoded.agentId,
            channel: decoded.channel,
            uid: uid,
            rtcToken: decoded.rtcToken,
            appId: decoded.appId
        )
    }

    /// Stops a running agent so it leaves the channel and stops billing.
    func stopAgentSession(agentId: String) async {
        var request = URLRequest(url: URL(string: "\(workerBaseURL)/agent/stop")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONEncoder().encode(["agentId": agentId])

        do {
            let (_, response) = try await session.data(for: request)
            if let httpResponse = response as? HTTPURLResponse, !(200...299).contains(httpResponse.statusCode) {
                print("⚠️ Agora agent stop returned \(httpResponse.statusCode)")
            }
        } catch {
            // Best-effort — the agent will also time out on its own.
            print("⚠️ Agora agent stop failed: \(error.localizedDescription)")
        }
    }

    private static func throwIfNotOK(_ response: URLResponse, data: Data) throws {
        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
            let errorBody = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw NSError(
                domain: "AgoraAgentSession",
                code: statusCode,
                userInfo: [NSLocalizedDescriptionKey: "Agent session error (\(statusCode)): \(errorBody)"]
            )
        }
    }

    private struct StartResponse: Decodable {
        let agentId: String
        let channel: String
        let rtcToken: String
        let appId: String
    }
}
