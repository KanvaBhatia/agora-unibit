//
//  CompanionManager.swift
//  Unibit
//
//  Central state manager for the companion voice mode. Owns the push-to-talk
//  pipeline (dictation manager + global shortcut monitor + overlay) and
//  exposes observable voice state for the panel UI.
//

import AVFoundation
import Combine
import Foundation
import ScreenCaptureKit
import SwiftUI

enum CompanionVoiceState {
    case idle
    case listening
    case processing
    case responding
}

@MainActor
final class CompanionManager: ObservableObject {
    @Published private(set) var voiceState: CompanionVoiceState = .idle
    @Published private(set) var lastTranscript: String?
    @Published private(set) var currentAudioPowerLevel: CGFloat = 0
    @Published private(set) var hasAccessibilityPermission = false
    @Published private(set) var hasScreenRecordingPermission = false
    @Published private(set) var hasMicrophonePermission = false
    @Published private(set) var hasScreenContentPermission = false

    /// Screen location (global AppKit coords) of a detected UI element the
    /// buddy should fly to and point at. Parsed from Claude's response;
    /// observed by BlueCursorView to trigger the flight animation.
    @Published var detectedElementScreenLocation: CGPoint?
    /// The display frame (global AppKit coords) of the screen the detected
    /// element is on, so BlueCursorView knows which screen overlay should animate.
    @Published var detectedElementDisplayFrame: CGRect?
    /// Custom speech bubble text for the pointing animation. When set,
    /// BlueCursorView uses this instead of a random pointer phrase.
    @Published var detectedElementBubbleText: String?

    let buddyDictationManager = BuddyDictationManager()
    let globalPushToTalkShortcutMonitor = GlobalPushToTalkShortcutMonitor()
    let overlayWindowManager = OverlayWindowManager()
    // Response text is now displayed inline on the cursor overlay via
    // streamingResponseText, so no separate response overlay manager is needed.

    /// Base URL for the Cloudflare Worker proxy. All API requests route
    /// through this so keys never ship in the app binary.
    private static let workerBaseURL = "https://clicky-proxy.kanvabht.workers.dev"

    private lazy var claudeAPI: ClaudeAPI = {
        return ClaudeAPI(proxyURL: "\(Self.workerBaseURL)/chat", model: selectedModel)
    }()

    private lazy var murfTTSClient: MurfTTSClient = {
        return MurfTTSClient(proxyURL: "\(Self.workerBaseURL)/tts")
    }()

    // MARK: - Agora conversational agent session

    /// Which voice-conversation backend to use, read from the app bundle's
    /// Info.plist `VoiceConversationBackend` key. "agora" routes the hotkey to
    /// an Agora Conversational AI agent (AssemblyAI ASR → Claude via the Worker
    /// → Murf TTS) over a real-time channel. Anything else keeps the legacy
    /// direct-push-to-talk pipeline.
    private static var usesAgoraConversationBackend: Bool {
        AppBundleConfiguration.stringValue(forKey: "VoiceConversationBackend") == "agora"
    }

    private lazy var agoraVoiceClient = AgoraVoiceClient()
    private lazy var agoraAgentSessionClient = AgoraAgentSessionClient(workerBaseURL: Self.workerBaseURL)
    /// Uploads the cursor screen to the Worker while an agent session is live so
    /// the agent can see what's on screen.
    private lazy var screenContextUploader = ScreenContextUploader(workerBaseURL: Self.workerBaseURL)
    /// Polls the Worker for [POINT:...] tags parsed out of the agent's answers so
    /// the cursor can fly to referenced elements.
    private lazy var agentPointPoller = AgentPointPoller(workerBaseURL: Self.workerBaseURL)
    /// Polls the Worker for the agent's reply text and speaks it locally via Murf
    /// REST. The agent publishes no audio (Agora's Murf stream-input bridge
    /// garbles it), so this is the only voice the user hears.
    private lazy var agentReplyPoller = AgentReplyPoller(workerBaseURL: Self.workerBaseURL)
    /// Polls the Worker for the latest conversation exchange (user transcript +
    /// reply) so the on-screen pill can render both sides of the turn.
    private lazy var conversationTurnPoller = ConversationTurnPoller(workerBaseURL: Self.workerBaseURL)
    /// The Dynamic Island–style pill that shows the live exchange at the top of
    /// the screen while a conversation turn is in progress.
    private lazy var conversationPillOverlay = ConversationPillOverlayManager()

    /// The currently active agent session, if any. Nil when no conversation is live.
    private var activeAgoraAgentSession: AgoraAgentSessionClient.AgentSession?
    /// Task that owns starting/stopping the agent session so rapid hotkey
    /// presses don't spin up duplicate agents.
    private var agoraSessionTask: Task<Void, Never>?

    /// Conversation history so Claude remembers prior exchanges within a session.
    /// Each entry is the user's transcript and Claude's response.
    private var conversationHistory: [(userTranscript: String, assistantResponse: String)] = []

    /// The currently running AI response task, if any. Cancelled when the user
    /// speaks again so a new response can begin immediately.
    private var currentResponseTask: Task<Void, Never>?

    private var shortcutTransitionCancellable: AnyCancellable?
    private var voiceStateCancellable: AnyCancellable?
    private var audioPowerCancellable: AnyCancellable?
    private var accessibilityCheckTimer: Timer?
    private var pendingKeyboardShortcutStartTask: Task<Void, Never>?
    /// Scheduled hide for transient cursor mode — cancelled if the user
    /// speaks again before the delay elapses.
    private var transientHideTask: Task<Void, Never>?

    /// True when all three required permissions (accessibility, screen recording,
    /// microphone) are granted. Used by the panel to show a single "all good" state.
    var allPermissionsGranted: Bool {
        hasAccessibilityPermission && hasScreenRecordingPermission && hasMicrophonePermission && hasScreenContentPermission
    }

    /// Whether the blue cursor overlay is currently visible on screen.
    /// Used by the panel to show accurate status text ("Active" vs "Ready").
    @Published private(set) var isOverlayVisible: Bool = false

    /// The Claude model used for voice responses. Fixed since the Agora agent
    /// pipeline owns model selection — no picker in the UI.
    let selectedModel: String = "claude-sonnet-4-6"

    /// User preference for whether the Unibit cursor should be shown.
    /// When toggled off, the overlay is hidden and push-to-talk is disabled.
    /// Persisted to UserDefaults so the choice survives app restarts.
    @Published var isUnibitCursorEnabled: Bool = UserDefaults.standard.object(forKey: "isUnibitCursorEnabled") == nil
        ? true
        : UserDefaults.standard.bool(forKey: "isUnibitCursorEnabled")

    func setUnibitCursorEnabled(_ enabled: Bool) {
        isUnibitCursorEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: "isUnibitCursorEnabled")
        transientHideTask?.cancel()
        transientHideTask = nil

        if enabled {
            overlayWindowManager.hasShownOverlayBefore = true
            overlayWindowManager.showOverlay(onScreens: NSScreen.screens, companionManager: self)
            isOverlayVisible = true
        } else {
            overlayWindowManager.hideOverlay()
            isOverlayVisible = false
        }
    }

    /// Whether the user has completed onboarding at least once. Persisted
    /// to UserDefaults so the Start button only appears on first launch.
    var hasCompletedOnboarding: Bool {
        get { UserDefaults.standard.bool(forKey: "hasCompletedOnboarding") }
        set { UserDefaults.standard.set(newValue, forKey: "hasCompletedOnboarding") }
    }

    func start() {
        refreshAllPermissions()
        print("🔑 Unibit start — accessibility: \(hasAccessibilityPermission), screen: \(hasScreenRecordingPermission), mic: \(hasMicrophonePermission), screenContent: \(hasScreenContentPermission), onboarded: \(hasCompletedOnboarding)")
        startPermissionPolling()
        bindVoiceStateObservation()
        bindAudioPowerLevel()
        bindShortcutTransitions()
        // Eagerly touch the Claude API so its TLS warmup handshake completes
        // well before the onboarding demo fires at ~40s into the video.
        _ = claudeAPI

        // If the user already completed onboarding AND all permissions are
        // still granted, show the cursor overlay immediately. If permissions
        // were revoked (e.g. signing change), don't show the cursor — the
        // panel will show the permissions UI instead.
        if hasCompletedOnboarding && allPermissionsGranted && isUnibitCursorEnabled {
            overlayWindowManager.hasShownOverlayBefore = true
            overlayWindowManager.showOverlay(onScreens: NSScreen.screens, companionManager: self)
            isOverlayVisible = true
        }
    }

    /// Called by the panel's Start button on first launch. Marks onboarding
    /// complete and shows the cursor overlay (with the welcome animation).
    func triggerOnboarding() {
        // Post notification so the panel manager can dismiss the panel
        NotificationCenter.default.post(name: .unibitDismissPanel, object: nil)

        // Mark onboarding as completed so the Start button won't appear
        // again on future launches — the cursor will auto-show instead
        hasCompletedOnboarding = true

        // Show the overlay for the first time — isFirstAppearance triggers
        // the welcome animation
        overlayWindowManager.showOverlay(onScreens: NSScreen.screens, companionManager: self)
        isOverlayVisible = true
    }

    func clearDetectedElementLocation() {
        detectedElementScreenLocation = nil
        detectedElementDisplayFrame = nil
        detectedElementBubbleText = nil
    }

    func stop() {
        globalPushToTalkShortcutMonitor.stop()
        buddyDictationManager.cancelCurrentDictation()
        overlayWindowManager.hideOverlay()
        transientHideTask?.cancel()

        // Tear down any live Agora conversation so the agent stops billing.
        endAgoraConversationSession()
        agoraSessionTask?.cancel()
        agoraSessionTask = nil

        currentResponseTask?.cancel()
        currentResponseTask = nil
        shortcutTransitionCancellable?.cancel()
        voiceStateCancellable?.cancel()
        audioPowerCancellable?.cancel()
        accessibilityCheckTimer?.invalidate()
        accessibilityCheckTimer = nil
    }

    func refreshAllPermissions() {
        let previouslyHadAccessibility = hasAccessibilityPermission
        let previouslyHadScreenRecording = hasScreenRecordingPermission
        let previouslyHadMicrophone = hasMicrophonePermission
        let previouslyHadAll = allPermissionsGranted

        let currentlyHasAccessibility = WindowPositionManager.hasAccessibilityPermission()
        hasAccessibilityPermission = currentlyHasAccessibility

        if currentlyHasAccessibility {
            globalPushToTalkShortcutMonitor.start()
        } else {
            globalPushToTalkShortcutMonitor.stop()
        }

        hasScreenRecordingPermission = WindowPositionManager.hasScreenRecordingPermission()

        let micAuthStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        hasMicrophonePermission = micAuthStatus == .authorized

        // Debug: log permission state on changes
        if previouslyHadAccessibility != hasAccessibilityPermission
            || previouslyHadScreenRecording != hasScreenRecordingPermission
            || previouslyHadMicrophone != hasMicrophonePermission {
            print("🔑 Permissions — accessibility: \(hasAccessibilityPermission), screen: \(hasScreenRecordingPermission), mic: \(hasMicrophonePermission), screenContent: \(hasScreenContentPermission)")
        }

        // Track individual permission grants as they happen
        if !previouslyHadAccessibility && hasAccessibilityPermission {
        }
        if !previouslyHadScreenRecording && hasScreenRecordingPermission {
        }
        if !previouslyHadMicrophone && hasMicrophonePermission {
        }
        // Screen content permission is persisted — once the user has approved the
        // SCShareableContent picker, we don't need to re-check it.
        if !hasScreenContentPermission {
            hasScreenContentPermission = UserDefaults.standard.bool(forKey: "hasScreenContentPermission")
        }

        if !previouslyHadAll && allPermissionsGranted {
        }
    }

    /// Triggers the macOS screen content picker by performing a dummy
    /// screenshot capture. Once the user approves, we persist the grant
    /// so they're never asked again during onboarding.
    @Published private(set) var isRequestingScreenContent = false

    func requestScreenContentPermission() {
        guard !isRequestingScreenContent else { return }
        isRequestingScreenContent = true
        Task {
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                guard let display = content.displays.first else {
                    await MainActor.run { isRequestingScreenContent = false }
                    return
                }
                let filter = SCContentFilter(display: display, excludingWindows: [])
                let config = SCStreamConfiguration()
                config.width = 320
                config.height = 240
                let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
                // Verify the capture actually returned real content — a 0x0 or
                // fully-empty image means the user denied the prompt.
                let didCapture = image.width > 0 && image.height > 0
                print("🔑 Screen content capture result — width: \(image.width), height: \(image.height), didCapture: \(didCapture)")
                await MainActor.run {
                    isRequestingScreenContent = false
                    guard didCapture else { return }
                    hasScreenContentPermission = true
                    UserDefaults.standard.set(true, forKey: "hasScreenContentPermission")

                    // If onboarding was already completed, show the cursor overlay now
                    if hasCompletedOnboarding && allPermissionsGranted && !isOverlayVisible && isUnibitCursorEnabled {
                        overlayWindowManager.hasShownOverlayBefore = true
                        overlayWindowManager.showOverlay(onScreens: NSScreen.screens, companionManager: self)
                        isOverlayVisible = true
                    }
                }
            } catch {
                print("⚠️ Screen content permission request failed: \(error)")
                await MainActor.run { isRequestingScreenContent = false }
            }
        }
    }

    // MARK: - Private

    /// Triggers the system microphone prompt if the user has never been asked.
    /// Once granted/denied the status sticks and polling picks it up.
    private func promptForMicrophoneIfNotDetermined() {
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined else { return }
        AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
            Task { @MainActor [weak self] in
                self?.hasMicrophonePermission = granted
            }
        }
    }

    /// Polls all permissions frequently so the UI updates live after the
    /// user grants them in System Settings. Screen Recording is the exception —
    /// macOS requires an app restart for that one to take effect.
    private func startPermissionPolling() {
        accessibilityCheckTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refreshAllPermissions()
            }
        }
    }

    private func bindAudioPowerLevel() {
        audioPowerCancellable = buddyDictationManager.$currentAudioPowerLevel
            .receive(on: DispatchQueue.main)
            .sink { [weak self] powerLevel in
                self?.currentAudioPowerLevel = powerLevel
            }
    }

    private func bindVoiceStateObservation() {
        voiceStateCancellable = buddyDictationManager.$isRecordingFromKeyboardShortcut
            .combineLatest(
                buddyDictationManager.$isFinalizingTranscript,
                buddyDictationManager.$isPreparingToRecord
            )
            .receive(on: DispatchQueue.main)
            .sink { [weak self] isRecording, isFinalizing, isPreparing in
                guard let self else { return }
                // Don't override .responding — the AI response pipeline
                // manages that state directly until streaming finishes.
                guard self.voiceState != .responding else { return }

                if isFinalizing {
                    self.voiceState = .processing
                } else if isRecording {
                    self.voiceState = .listening
                } else if isPreparing {
                    self.voiceState = .processing
                } else {
                    self.voiceState = .idle
                    // If the user pressed and released the hotkey without
                    // saying anything, no response task runs — schedule the
                    // transient hide here so the overlay doesn't get stuck.
                    // Only do this when no response is in flight, otherwise
                    // the brief idle gap between recording and processing
                    // would prematurely hide the overlay.
                    if self.currentResponseTask == nil {
                        self.scheduleTransientHideIfNeeded()
                    }
                }
            }
    }

    private func bindShortcutTransitions() {
        shortcutTransitionCancellable = globalPushToTalkShortcutMonitor
            .shortcutTransitionPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] transition in
                self?.handleShortcutTransition(transition)
            }
    }

    private func handleShortcutTransition(_ transition: BuddyPushToTalkShortcut.ShortcutTransition) {
        switch transition {
        case .pressed:
            guard !buddyDictationManager.isDictationInProgress else { return }

            // Cancel any pending transient hide so the overlay stays visible
            transientHideTask?.cancel()
            transientHideTask = nil

            // If the cursor is hidden, bring it back transiently for this interaction
            if !isUnibitCursorEnabled && !isOverlayVisible {
                overlayWindowManager.hasShownOverlayBefore = true
                overlayWindowManager.showOverlay(onScreens: NSScreen.screens, companionManager: self)
                isOverlayVisible = true
            }

            // Dismiss the menu bar panel so it doesn't cover the screen
            NotificationCenter.default.post(name: .unibitDismissPanel, object: nil)

            // Cancel any in-progress response and TTS from a previous utterance
            currentResponseTask?.cancel()
            murfTTSClient.stopPlayback()
            clearDetectedElementLocation()

            // Agora path: pressing the hotkey starts (or joins) a conversational
            // agent session instead of a one-shot push-to-talk transcription.
            if Self.usesAgoraConversationBackend {
                startAgoraConversationSessionIfNeeded()
                // Push-to-talk: unmute the mic while the key is held so the agent
                // only hears the user when they intend to talk.
                agoraVoiceClient.setMicrophoneMuted(false)
                voiceState = .listening
                // Capture a fresh frame the instant the user starts talking so
                // the agent's very next turn sees the current screen, not one up
                // to 5s stale from the periodic uploader.
                screenContextUploader.uploadScreenContextNow()
                // Drop the conversation pill down so the user can see the live
                // exchange as they speak.
                conversationPillOverlay.presentListening()
                return
            }

            pendingKeyboardShortcutStartTask?.cancel()
            pendingKeyboardShortcutStartTask = Task {
                await buddyDictationManager.startPushToTalkFromKeyboardShortcut(
                    currentDraftText: "",
                    updateDraftText: { _ in
                        // Partial transcripts are hidden (waveform-only UI)
                    },
                    submitDraftText: { [weak self] finalTranscript in
                        self?.lastTranscript = finalTranscript
                        print("🗣️ Companion received transcript: \(finalTranscript)")
                        self?.sendTranscriptToClaudeWithScreenshot(transcript: finalTranscript)
                    }
                )
            }
        case .released:

            // Agora path: releasing the key mutes the mic again (push-to-talk)
            // but keeps the session live — the agent stays in the channel until
            // it idles out or the user ends it.
            if Self.usesAgoraConversationBackend {
                agoraVoiceClient.setMicrophoneMuted(true)
                voiceState = .idle
                // Stop the "listening…" cue; the pill stays up while the agent
                // thinks and then fills in the exchange when the turn arrives.
                conversationPillOverlay.endListening()
                scheduleTransientHideIfNeeded()
                return
            }

            // Cancel the pending start task in case the user released the shortcut
            // before the async startPushToTalk had a chance to begin recording.
            // Without this, a quick press-and-release drops the release event and
            // leaves the waveform overlay stuck on screen indefinitely.
            pendingKeyboardShortcutStartTask?.cancel()
            pendingKeyboardShortcutStartTask = nil
            buddyDictationManager.stopPushToTalkFromKeyboardShortcut()
        case .none:
            break
        }
    }

    // MARK: - Companion Prompt

    private static let companionVoiceResponseSystemPrompt = """
    you're unibit, a friendly always-on companion that lives in the user's menu bar. the user just spoke to you via push-to-talk and you can see their screen(s). your reply will be spoken aloud via text-to-speech, so write the way you'd actually talk. this is an ongoing conversation — you remember everything they've said before.

    rules:
    - default to one or two sentences. be direct and dense. BUT if the user asks you to explain more, go deeper, or elaborate, then go all out — give a thorough, detailed explanation with no length limit.
    - all lowercase, casual, warm. no emojis.
    - write for the ear, not the eye. short sentences. no lists, bullet points, markdown, or formatting — just natural speech.
    - don't use abbreviations or symbols that sound weird read aloud. write "for example" not "e.g.", spell out small numbers.
    - if the user's question relates to what's on their screen, reference specific things you see.
    - if the screenshot doesn't seem relevant to their question, just answer the question directly.
    - you can help with anything — coding, writing, general knowledge, brainstorming.
    - never say "simply" or "just".
    - don't read out code verbatim. describe what the code does or what needs to change conversationally.
    - focus on giving a thorough, useful explanation. don't end with simple yes/no questions like "want me to explain more?" or "should i show you?" — those are dead ends that force the user to just say yes.
    - instead, when it fits naturally, end by planting a seed — mention something bigger or more ambitious they could try, a related concept that goes deeper, or a next-level technique that builds on what you just explained. make it something worth coming back for, not a question they'd just nod to. it's okay to not end with anything extra if the answer is complete on its own.
    - if you receive multiple screen images, the one labeled "primary focus" is where the cursor is — prioritize that one but reference others if relevant.

    element pointing:
    you have a small amber triangle cursor that can fly to and point at things on screen. use it whenever pointing would genuinely help the user — if they're asking how to do something, looking for a menu, trying to find a button, or need help navigating an app, point at the relevant element. err on the side of pointing rather than not pointing, because it makes your help way more useful and concrete.

    don't point at things when it would be pointless — like if the user asks a general knowledge question, or the conversation has nothing to do with what's on screen, or you'd just be pointing at something obvious they're already looking at. but if there's a specific UI element, menu, button, or area on screen that's relevant to what you're helping with, point at it.

    when you point, append a coordinate tag at the very end of your response, AFTER your spoken text. the screenshot images are labeled with their pixel dimensions. use those dimensions as the coordinate space. the origin (0,0) is the top-left corner of the image. x increases rightward, y increases downward.

    format: [POINT:x,y:label] where x,y are integer pixel coordinates in the screenshot's coordinate space, and label is a short 1-3 word description of the element (like "search bar" or "save button"). if the element is on the cursor's screen you can omit the screen number. if the element is on a DIFFERENT screen, append :screenN where N is the screen number from the image label (e.g. :screen2). this is important — without the screen number, the cursor will point at the wrong place.

    if pointing wouldn't help, append [POINT:none].

    examples:
    - user asks how to color grade in final cut: "you'll want to open the color inspector — it's right up in the top right area of the toolbar. click that and you'll get all the color wheels and curves. [POINT:1100,42:color inspector]"
    - user asks what html is: "html stands for hypertext markup language, it's basically the skeleton of every web page. curious how it connects to the css you're looking at? [POINT:none]"
    - user asks how to commit in xcode: "see that source control menu up top? click that and hit commit, or you can use command option c as a shortcut. [POINT:285,11:source control]"
    - element is on screen 2 (not where cursor is): "that's over on your other monitor — see the terminal window? [POINT:400,300:terminal:screen2]"
    """

    // MARK: - Agora Conversation Session

    /// Starts an Agora conversational agent session if one isn't already live.
    /// The Worker spins up the agent (AssemblyAI ASR → Claude → Murf TTS) and
    /// returns an RTC token; the app then joins the same channel so the agent
    /// hears the user's microphone and speaks back over the channel.
    private func startAgoraConversationSessionIfNeeded() {
        // Already live — nothing to do.
        guard activeAgoraAgentSession == nil, agoraSessionTask == nil else { return }

        agoraSessionTask = Task {
            voiceState = .processing
            print("🤖 Agora: starting agent session…")
            do {
                let session = try await agoraAgentSessionClient.startAgentSession()
                guard !Task.isCancelled else { return }

                activeAgoraAgentSession = session
                print("🤖 Agora: agent started (id \(session.agentId)), joining channel \(session.channel)…")

                agoraVoiceClient.onAgentJoined = { [weak self] in
                    Task { @MainActor [weak self] in
                        guard let self else { return }
                        print("🤖 Agora: agent is live — hold the shortcut to talk")
                        // Don't stomp .listening if the user is still holding the
                        // shortcut from the press that started the session. If
                        // they already released, the release handler set .idle.
                        if self.voiceState == .processing {
                            self.voiceState = .idle
                        }
                        // The agent greets the user; the mic stays muted until
                        // the user holds the shortcut to talk (push-to-talk).
                        self.scheduleTransientHideIfNeeded()
                    }
                }
                agoraVoiceClient.onAgentLeft = { [weak self] in
                    Task { @MainActor [weak self] in
                        print("🤖 Agora: agent left the channel")
                        self?.endAgoraConversationSession()
                    }
                }

                agoraVoiceClient.initializeEngine(appId: session.appId)
                agoraVoiceClient.joinChannel(
                    rtcToken: session.rtcToken,
                    channelName: session.channel,
                    localUserUid: session.uid
                )

                // Give the agent eyes and hands: upload the cursor screen so it
                // can see what's on screen, and poll for [POINT] tags so the
                // cursor can fly to elements it references.
                screenContextUploader.startUploadingScreenContext()
                agentPointPoller.startPollingForPoints { [weak self] point in
                    self?.handleAgentPoint(point)
                }
                // The agent publishes no audio (the Worker omits Agora-side TTS),
                // so speak its replies locally via Murf REST — the clean path.
                agentReplyPoller.startPollingForReplies { [weak self] reply in
                    self?.speakAgentReplyText(reply.text)
                }
                // Render each exchange in the conversation pill as it completes.
                conversationTurnPoller.startPollingForTurns { [weak self] turn in
                    self?.conversationPillOverlay.showExchange(
                        userText: turn.userText,
                        replyText: turn.replyText
                    )
                }
            } catch {
                if !Task.isCancelled {
                    print("⚠️ Agora session start failed: \(error.localizedDescription)")
                    speakCreditsErrorFallback()
                }
            }
            agoraSessionTask = nil
        }
    }

    /// Tears down the live agent session: leaves the channel and stops the
    /// agent so it doesn't keep billing. Safe to call when no session is live.
    private func endAgoraConversationSession() {
        let agentIdToStop = activeAgoraAgentSession?.agentId
        activeAgoraAgentSession = nil
        agoraVoiceClient.leaveChannel()
        screenContextUploader.stopUploadingScreenContext()
        agentPointPoller.stopPollingForPoints()
        agentReplyPoller.stopPollingForReplies()
        conversationTurnPoller.stopPollingForTurns()
        conversationPillOverlay.hideImmediately()
        if let agentIdToStop {
            Task {
                await agoraAgentSessionClient.stopAgentSession(agentId: agentIdToStop)
            }
        }
    }

    /// Handles a new [POINT] tag from the Agora agent's answer. Converts the
    /// coordinate (screenshot pixel space on the cursor's screen) to AppKit
    /// global coords and sets the detected-element state so the overlay flies
    /// the cursor to the target — identical to the legacy Claude path.
    private func handleAgentPoint(_ point: AgentPointPoller.AgentPoint) {
        // The uploaded frame was captured on the cursor's screen, so resolve that
        // screen's frame at poll time to get the origin for global coords.
        guard let cursorScreenFrame = cursorScreenFrameForPointConversion() else { return }

        let globalLocation = Self.globalScreenLocation(
            forPointCoordinate: point.coordinate,
            screenshotWidthInPixels: point.screenshotWidthInPixels,
            screenshotHeightInPixels: point.screenshotHeightInPixels,
            displayWidthInPoints: point.displayWidthInPoints,
            displayHeightInPoints: point.displayHeightInPoints,
            displayFrame: cursorScreenFrame
        )

        detectedElementBubbleText = point.label
        detectedElementScreenLocation = globalLocation
        detectedElementDisplayFrame = cursorScreenFrame
        print("🎯 Agent pointing: (\(Int(point.coordinate.x)), \(Int(point.coordinate.y))) → \"\(point.label ?? "element")\"")
    }

    /// Speaks an agent reply fetched from the Worker, using the clean Murf REST
    /// path (the same client the legacy push-to-talk path uses). Runs async so a
    /// slow Murf response doesn't block the reply poller's next tick.
    private func speakAgentReplyText(_ replyText: String) {
        Task { @MainActor in
            do {
                print("🗣️ Speaking agent reply locally (\(replyText.count) chars)")
                try await murfTTSClient.speakText(replyText)
                // speakText returns right after playback STARTS, so wait for the
                // audio to finish before retracting the pill (otherwise it would
                // vanish while Unibit is mid-sentence).
                await waitForAgentReplyPlaybackToFinishThenHidePill()
            } catch {
                print("⚠️ Local Murf TTS for agent reply failed: \(error.localizedDescription)")
            }
        }
    }

    /// Polls Murf playback state until the agent's reply finishes speaking, then
    /// schedules the conversation pill to retract after a short beat.
    private func waitForAgentReplyPlaybackToFinishThenHidePill() async {
        // Poll playback state — MurfTTSClient has no completion delegate, so a
        // light poll is the simplest way to know when the reply is done.
        while murfTTSClient.isPlaying {
            try? await Task.sleep(nanoseconds: 150_000_000)
            if Task.isCancelled { return }
        }
        conversationPillOverlay.scheduleHideAfterReply()
    }

    /// Returns the frame (in AppKit coords) of the screen currently containing
    /// the cursor — the same screen the uploaded context frame was captured on.
    private func cursorScreenFrameForPointConversion() -> CGRect? {
        let mouseLocation = NSEvent.mouseLocation
        if let cursorScreen = NSScreen.screens.first(where: { $0.frame.contains(mouseLocation) }) {
            return cursorScreen.frame
        }
        return NSScreen.main?.frame
    }

    // MARK: - AI Response Pipeline

    /// Captures a screenshot, sends it along with the transcript to Claude,
    /// and plays the response aloud via Murf TTS. The cursor stays in
    /// the spinner/processing state until TTS audio begins playing.
    /// Claude's response may include a [POINT:x,y:label] tag which triggers
    /// the buddy to fly to that element on screen.
    private func sendTranscriptToClaudeWithScreenshot(transcript: String) {
        currentResponseTask?.cancel()
        murfTTSClient.stopPlayback()

        currentResponseTask = Task {
            // Stay in processing (spinner) state — no streaming text displayed
            voiceState = .processing

            do {
                // Capture all connected screens so the AI has full context
                let screenCaptures = try await CompanionScreenCaptureUtility.captureAllScreensAsJPEG()

                guard !Task.isCancelled else { return }

                // Build image labels with the actual screenshot pixel dimensions
                // so Claude's coordinate space matches the image it sees. We
                // scale from screenshot pixels to display points ourselves.
                let labeledImages = screenCaptures.map { capture in
                    let dimensionInfo = " (image dimensions: \(capture.screenshotWidthInPixels)x\(capture.screenshotHeightInPixels) pixels)"
                    return (data: capture.imageData, label: capture.label + dimensionInfo)
                }

                // Pass conversation history so Claude remembers prior exchanges
                let historyForAPI = conversationHistory.map { entry in
                    (userPlaceholder: entry.userTranscript, assistantResponse: entry.assistantResponse)
                }

                let (fullResponseText, _) = try await claudeAPI.analyzeImageStreaming(
                    images: labeledImages,
                    systemPrompt: Self.companionVoiceResponseSystemPrompt,
                    conversationHistory: historyForAPI,
                    userPrompt: transcript,
                    onTextChunk: { _ in
                        // No streaming text display — spinner stays until TTS plays
                    }
                )

                guard !Task.isCancelled else { return }

                // Parse the [POINT:...] tag from Claude's response
                let parseResult = Self.parsePointingCoordinates(from: fullResponseText)
                let spokenText = parseResult.spokenText

                // Handle element pointing if Claude returned coordinates.
                // Switch to idle BEFORE setting the location so the triangle
                // becomes visible and can fly to the target. Without this, the
                // spinner hides the triangle and the flight animation is invisible.
                let hasPointCoordinate = parseResult.coordinate != nil
                if hasPointCoordinate {
                    voiceState = .idle
                }

                // Pick the screen capture matching Claude's screen number,
                // falling back to the cursor screen if not specified.
                let targetScreenCapture: CompanionScreenCapture? = {
                    if let screenNumber = parseResult.screenNumber,
                       screenNumber >= 1 && screenNumber <= screenCaptures.count {
                        return screenCaptures[screenNumber - 1]
                    }
                    return screenCaptures.first(where: { $0.isCursorScreen })
                }()

                if let pointCoordinate = parseResult.coordinate,
                   let targetScreenCapture {
                    let globalLocation = Self.globalScreenLocation(
                        forPointCoordinate: pointCoordinate,
                        screenshotWidthInPixels: targetScreenCapture.screenshotWidthInPixels,
                        screenshotHeightInPixels: targetScreenCapture.screenshotHeightInPixels,
                        displayWidthInPoints: targetScreenCapture.displayWidthInPoints,
                        displayHeightInPoints: targetScreenCapture.displayHeightInPoints,
                        displayFrame: targetScreenCapture.displayFrame
                    )

                    detectedElementScreenLocation = globalLocation
                    detectedElementDisplayFrame = targetScreenCapture.displayFrame
                    print("🎯 Element pointing: (\(Int(pointCoordinate.x)), \(Int(pointCoordinate.y))) → \"\(parseResult.elementLabel ?? "element")\"")
                } else {
                    print("🎯 Element pointing: \(parseResult.elementLabel ?? "no element")")
                }

                // Save this exchange to conversation history (with the point tag
                // stripped so it doesn't confuse future context)
                conversationHistory.append((
                    userTranscript: transcript,
                    assistantResponse: spokenText
                ))

                // Keep only the last 10 exchanges to avoid unbounded context growth
                if conversationHistory.count > 10 {
                    conversationHistory.removeFirst(conversationHistory.count - 10)
                }

                print("🧠 Conversation history: \(conversationHistory.count) exchanges")


                // Play the response via TTS. Keep the spinner (processing state)
                // until the audio actually starts playing, then switch to responding.
                if !spokenText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    do {
                        try await murfTTSClient.speakText(spokenText)
                        // speakText returns after player.play() — audio is now playing
                        voiceState = .responding
                    } catch {
                        print("⚠️ Murf TTS error: \(error)")
                        speakCreditsErrorFallback()
                    }
                }
            } catch is CancellationError {
                // User spoke again — response was interrupted
            } catch {
                print("⚠️ Companion response error: \(error)")
                speakCreditsErrorFallback()
            }

            if !Task.isCancelled {
                voiceState = .idle
                scheduleTransientHideIfNeeded()
            }
        }
    }

    /// If the cursor is in transient mode (user toggled "Show Unibit" off),
    /// waits for TTS playback and any pointing animation to finish, then
    /// fades out the overlay after a 1-second pause. Cancelled automatically
    /// if the user starts another push-to-talk interaction.
    private func scheduleTransientHideIfNeeded() {
        guard !isUnibitCursorEnabled && isOverlayVisible else { return }

        transientHideTask?.cancel()
        transientHideTask = Task {
            // Wait for TTS audio to finish playing
            while murfTTSClient.isPlaying {
                try? await Task.sleep(nanoseconds: 200_000_000)
                guard !Task.isCancelled else { return }
            }

            // Wait for pointing animation to finish (location is cleared
            // when the buddy flies back to the cursor)
            while detectedElementScreenLocation != nil {
                try? await Task.sleep(nanoseconds: 200_000_000)
                guard !Task.isCancelled else { return }
            }

            // Pause 1s after everything finishes, then fade out
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            guard !Task.isCancelled else { return }
            overlayWindowManager.fadeOutAndHideOverlay()
            isOverlayVisible = false
        }
    }

    /// Speaks a hardcoded error message using macOS system TTS when API
    /// credits run out. Uses NSSpeechSynthesizer so it works even when
    /// Murf is down.
    private func speakCreditsErrorFallback() {
        let utterance = "Something went wrong reaching the server. Please try again in a moment."
        let synthesizer = NSSpeechSynthesizer()
        synthesizer.startSpeaking(utterance)
        voiceState = .responding
    }

    // MARK: - Point Tag Parsing

    /// Result of parsing a [POINT:...] tag from Claude's response.
    struct PointingParseResult {
        /// The response text with the [POINT:...] tag removed — this is what gets spoken.
        let spokenText: String
        /// The parsed pixel coordinate, or nil if Claude said "none" or no tag was found.
        let coordinate: CGPoint?
        /// Short label describing the element (e.g. "run button"), or "none".
        let elementLabel: String?
        /// Which screen the coordinate refers to (1-based), or nil to default to cursor screen.
        let screenNumber: Int?
    }

    /// Parses a [POINT:x,y:label:screenN] or [POINT:none] tag from the end of Claude's response.
    /// Returns the spoken text (tag removed) and the optional coordinate + label + screen number.
    static func parsePointingCoordinates(from responseText: String) -> PointingParseResult {
        // Match [POINT:none] or [POINT:123,456:label] or [POINT:123,456:label:screen2]
        let pattern = #"\[POINT:(?:none|(\d+)\s*,\s*(\d+)(?::([^\]:\s][^\]:]*?))?(?::screen(\d+))?)\]\s*$"#

        guard let regex = try? NSRegularExpression(pattern: pattern, options: []),
              let match = regex.firstMatch(in: responseText, range: NSRange(responseText.startIndex..., in: responseText)) else {
            // No tag found at all
            return PointingParseResult(spokenText: responseText, coordinate: nil, elementLabel: nil, screenNumber: nil)
        }

        // Remove the tag from the spoken text
        let tagRange = Range(match.range, in: responseText)!
        let spokenText = String(responseText[..<tagRange.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)

        // Check if it's [POINT:none]
        guard match.numberOfRanges >= 3,
              let xRange = Range(match.range(at: 1), in: responseText),
              let yRange = Range(match.range(at: 2), in: responseText),
              let x = Double(responseText[xRange]),
              let y = Double(responseText[yRange]) else {
            return PointingParseResult(spokenText: spokenText, coordinate: nil, elementLabel: "none", screenNumber: nil)
        }

        var elementLabel: String? = nil
        if match.numberOfRanges >= 4, let labelRange = Range(match.range(at: 3), in: responseText) {
            elementLabel = String(responseText[labelRange]).trimmingCharacters(in: .whitespaces)
        }

        var screenNumber: Int? = nil
        if match.numberOfRanges >= 5, let screenRange = Range(match.range(at: 4), in: responseText) {
            screenNumber = Int(responseText[screenRange])
        }

        return PointingParseResult(
            spokenText: spokenText,
            coordinate: CGPoint(x: x, y: y),
            elementLabel: elementLabel,
            screenNumber: screenNumber
        )
    }

    /// Converts a point coordinate from screenshot pixel space (top-left origin,
    /// e.g. 1280x831) to AppKit global screen coordinates (bottom-left origin).
    /// Shared by the legacy Claude path and the Agora agent's point poller so
    /// both fly the cursor to exactly the same place for a given [POINT] tag.
    static func globalScreenLocation(
        forPointCoordinate pointCoordinate: CGPoint,
        screenshotWidthInPixels: Int,
        screenshotHeightInPixels: Int,
        displayWidthInPoints: Int,
        displayHeightInPoints: Int,
        displayFrame: CGRect
    ) -> CGPoint {
        let screenshotWidth = CGFloat(screenshotWidthInPixels)
        let screenshotHeight = CGFloat(screenshotHeightInPixels)
        let displayWidth = CGFloat(displayWidthInPoints)
        let displayHeight = CGFloat(displayHeightInPoints)

        // Clamp to screenshot coordinate space
        let clampedX = max(0, min(pointCoordinate.x, screenshotWidth))
        let clampedY = max(0, min(pointCoordinate.y, screenshotHeight))

        // Scale from screenshot pixels to display points
        let displayLocalX = clampedX * (displayWidth / screenshotWidth)
        let displayLocalY = clampedY * (displayHeight / screenshotHeight)

        // Convert from top-left origin (screenshot) to bottom-left origin (AppKit)
        let appKitY = displayHeight - displayLocalY

        // Convert display-local coords to global screen coords
        return CGPoint(
            x: displayLocalX + displayFrame.origin.x,
            y: appKitY + displayFrame.origin.y
        )
    }
}
