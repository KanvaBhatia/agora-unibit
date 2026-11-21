//
//  AgentPointPoller.swift
//  Unibit
//
//  While an Agora conversational session is live, polls the Worker for the
//  latest [POINT:x,y:label] tag parsed out of the agent's answer stream. When a
//  new point arrives (its id increments), fires a callback so the app can fly
//  the cursor to the target element. Polling is used because Agora's data-stream
//  transcripts aren't enabled in this project.
//

import Foundation

@MainActor
final class AgentPointPoller {
    /// A parsed point returned by GET /agent/point.
    struct AgentPoint {
        let id: Int
        let coordinate: CGPoint
        let label: String?
        let screenshotWidthInPixels: Int
        let screenshotHeightInPixels: Int
        let displayWidthInPoints: Int
        let displayHeightInPoints: Int
    }

    private let workerBaseURL: String
    private let session: URLSession
    private var pollTimer: Timer?
    /// The highest point id we've already delivered — only newer ids fire the callback.
    private var lastDeliveredPointId = 0

    private static let pollIntervalSeconds: TimeInterval = 1.0

    init(workerBaseURL: String) {
        self.workerBaseURL = workerBaseURL
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 10
        self.session = URLSession(configuration: configuration)
    }

    /// Starts polling. `onNewPoint` fires on the main actor each time the Worker
    /// reports a point with an id we haven't delivered yet.
    func startPollingForPoints(onNewPoint: @escaping @MainActor (AgentPoint) -> Void) {
        stopPollingForPoints()
        lastDeliveredPointId = 0
        pollTimer = Timer.scheduledTimer(
            withTimeInterval: Self.pollIntervalSeconds,
            repeats: true
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.pollOnce(onNewPoint: onNewPoint)
            }
        }
        print("🎯 Agent point poller started (every \(Int(Self.pollIntervalSeconds))s)")
    }

    /// Stops polling. Called when the Agora session ends.
    func stopPollingForPoints() {
        pollTimer?.invalidate()
        pollTimer = nil
    }

    private func pollOnce(onNewPoint: @escaping @MainActor (AgentPoint) -> Void) async {
        do {
            let (data, response) = try await session.data(from: URL(string: "\(workerBaseURL)/agent/point")!)
            guard let httpResponse = response as? HTTPURLResponse,
                  (200...299).contains(httpResponse.statusCode) else { return }

            guard let decoded = try? JSONDecoder().decode(PointResponse.self, from: data),
                  decoded.id > lastDeliveredPointId else { return }

            lastDeliveredPointId = decoded.id

            let point = AgentPoint(
                id: decoded.id,
                coordinate: CGPoint(x: decoded.x, y: decoded.y),
                label: decoded.label,
                screenshotWidthInPixels: decoded.screenshotWidth,
                screenshotHeightInPixels: decoded.screenshotHeight,
                displayWidthInPoints: decoded.displayWidth,
                displayHeightInPoints: decoded.displayHeight
            )
            onNewPoint(point)
        } catch {
            // Polling is best-effort — a dropped tick just means a slightly
            // later animation. The next tick retries.
        }
    }

    private struct PointResponse: Decodable {
        let id: Int
        let x: Double
        let y: Double
        let label: String?
        let screenshotWidth: Int
        let screenshotHeight: Int
        let displayWidth: Int
        let displayHeight: Int
    }
}
