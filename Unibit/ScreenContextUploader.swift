//
//  ScreenContextUploader.swift
//  Unibit
//
//  While an Agora conversational session is live, uploads a screenshot of the
//  cursor's screen to the Worker every few seconds. The Worker stores the
//  latest frame and attaches it to the current LLM turn so the agent can see
//  the user's screen ("what's on my screen?"). Stops when the session ends.
//

import Foundation

@MainActor
final class ScreenContextUploader {
    private let workerBaseURL: String
    private let session: URLSession
    private var uploadTimer: Timer?

    /// How often to re-capture and upload the cursor screen.
    private static let uploadIntervalSeconds: TimeInterval = 5.0

    init(workerBaseURL: String) {
        self.workerBaseURL = workerBaseURL
        let configuration = URLSessionConfiguration.default
        // Screenshot JPEGs can be a few hundred KB — give uploads room.
        configuration.timeoutIntervalForRequest = 30
        self.session = URLSession(configuration: configuration)
    }

    /// Starts the periodic upload timer. Fires once immediately so the very
    /// first LLM turn already has a frame to see.
    func startUploadingScreenContext() {
        stopUploadingScreenContext()
        uploadTimer = Timer.scheduledTimer(
            withTimeInterval: Self.uploadIntervalSeconds,
            repeats: true
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.captureAndUploadCursorScreen()
            }
        }
        Task { @MainActor in
            await captureAndUploadCursorScreen()
        }
        print("📸 Screen context uploader started (every \(Int(Self.uploadIntervalSeconds))s)")
    }

    /// Stops uploading. Called when the Agora session ends.
    func stopUploadingScreenContext() {
        uploadTimer?.invalidate()
        uploadTimer = nil
    }

    /// Captures and uploads a frame right now, outside the periodic timer. Called
    /// on hotkey press so the agent always has the latest screen context the
    /// moment the user starts speaking — not up to 5s stale from the last tick.
    /// No-op if no session is live (the uploader only runs while a session is up).
    func uploadScreenContextNow() {
        Task { @MainActor in
            await captureAndUploadCursorScreen()
        }
    }

    /// Captures the cursor's screen and POSTs it to the Worker. Errors are
    /// logged and swallowed — the next timer tick retries.
    private func captureAndUploadCursorScreen() async {
        do {
            let screenCaptures = try await CompanionScreenCaptureUtility.captureAllScreensAsJPEG()
            // The Worker only attaches one image per turn (the cursor screen) to
            // keep the payload small and latency low.
            guard let cursorScreenCapture = screenCaptures.first(where: { $0.isCursorScreen })
                    ?? screenCaptures.first else { return }

            let dimensionInfo = " (image dimensions: \(cursorScreenCapture.screenshotWidthInPixels)x\(cursorScreenCapture.screenshotHeightInPixels) pixels)"

            var request = URLRequest(url: URL(string: "\(workerBaseURL)/agent/context")!)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: [
                "imageBase64": cursorScreenCapture.imageData.base64EncodedString(),
                "label": cursorScreenCapture.label + dimensionInfo,
                "screenshotWidth": cursorScreenCapture.screenshotWidthInPixels,
                "screenshotHeight": cursorScreenCapture.screenshotHeightInPixels,
                "displayWidth": cursorScreenCapture.displayWidthInPoints,
                "displayHeight": cursorScreenCapture.displayHeightInPoints,
            ])

            let (_, response) = try await session.data(for: request)
            if let httpResponse = response as? HTTPURLResponse {
                if (200...299).contains(httpResponse.statusCode) {
                    print("📸 Screen context uploaded: \(cursorScreenCapture.screenshotWidthInPixels)x\(cursorScreenCapture.screenshotHeightInPixels), \(cursorScreenCapture.imageData.count / 1024) KB")
                } else {
                    print("⚠️ Screen context upload returned \(httpResponse.statusCode)")
                }
            }
        } catch {
            print("⚠️ Screen context upload failed: \(error.localizedDescription)")
        }
    }
}
