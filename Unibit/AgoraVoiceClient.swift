//
//  AgoraVoiceClient.swift
//  Unibit
//
//  Thin wrapper around the Agora RTC engine for a voice-only conversational
//  session. Joins an Agora channel, publishes the microphone, and tracks the
//  conversational AI agent's presence. The agent's own audio is MUTED (Agora's
//  Murf stream-input bridge garbles it); the app speaks the agent's replies
//  locally via Murf REST instead. The heavy lifting (ASR → Claude) runs inside
//  the Agora Conversational AI agent, which the Worker starts via REST.
//
//  The Agora RTC SDK callbacks arrive on internal threads, so all delegate
//  methods hop to the MainActor before touching observable state.
//

import AgoraRtcKit
import Foundation
import Combine

// MARK: - TEMP DEBUG: raw incoming-agent-audio recorder
//
// Captures the PCM audio the Agora SDK is about to play (onPlaybackAudioFrame)
// and writes it to /tmp/agora-agent-capture.wav. Used to isolate whether the
// TTS garble is present in the audio as-delivered to the Mac, or introduced
// during playback. Remove once diagnosed.
final class AgentAudioDebugger: NSObject, AgoraAudioFrameDelegate {
    static let shared = AgentAudioDebugger()
    private var pcmData = Data()
    private let captureURL = URL(fileURLWithPath: "/tmp/agora-agent-capture.pcm")
    private var frameCount = 0

    func attach(engine: AgoraRtcEngineKit) {
        // Reset the capture file on each new engine attach.
        pcmData = Data()
        frameCount = 0
        try? pcmData.write(to: captureURL)
        engine.setAudioFrameDelegate(self)
        print("🐛 AgentAudioDebugger attached — capturing to \(captureURL.path)")
    }

    /// REQUIRED: tells the SDK which audio-frame positions to observe. Without
    /// this the SDK fires no callbacks (the cause of the 0-byte capture). We
    /// want .playback — the mixed remote audio that plays to the speakers.
    func getObservedAudioFramePosition() -> AgoraAudioFramePosition {
        return .playback
    }

    /// REQUIRED: the audio format for the playback callback. 24kHz mono, 60ms
    /// per call (960 samples) — matches conversational voice.
    func getPlaybackAudioParams() -> AgoraAudioParams {
        let params = AgoraAudioParams()
        params.sampleRate = 24000
        params.channel = 1
        params.mode = AgoraAudioRawFrameOperationMode.readOnly
        params.samplesPerCall = 960
        return params
    }

    func onPlaybackAudioFrame(_ frame: AgoraAudioFrame, channelId: String) -> Bool {
        if let buffer = frame.buffer {
            let bytes = Int(frame.samplesPerChannel * frame.channels * 2)
            pcmData.append(Data(bytes: buffer, count: bytes))
            frameCount += 1
            if frameCount % 50 == 0 {
                print("🐛 captured \(frameCount) frames, \(pcmData.count) bytes")
            }
        }
        return true
    }

    /// Flush captured PCM to the capture file. Call after a session.
    func flushToWav() {
        try? pcmData.write(to: captureURL)
        print("🐛 AgentAudioDebugger captured \(pcmData.count) bytes (\(frameCount) frames) to \(captureURL.path)")
    }
}

@MainActor
final class AgoraVoiceClient: NSObject {
    /// Whether the local user is currently joined to a channel.
    @Published private(set) var isJoinedToChannel = false
    /// Whether the remote agent's audio is currently publishing (speaking).
    @Published private(set) var isAgentSpeaking = false

    /// Called when the conversational AI agent joins the channel (good signal
    /// that the session is live and the agent is about to greet the user).
    var onAgentJoined: (() -> Void)?
    /// Called when the agent leaves or the channel drops.
    var onAgentLeft: (() -> Void)?

    private var agoraRtcEngine: AgoraRtcEngineKit?
    private var agentRtcUid: UInt?

    /// Creates the RTC engine for the given Agora App ID. Kept alive for the
    /// lifetime of the client so joining/leaving is fast.
    func initializeEngine(appId: String) {
        guard agoraRtcEngine == nil else { return }
        agoraRtcEngine = AgoraRtcEngineKit.sharedEngine(withAppId: appId, delegate: self)
        // Voice-only: no video.
        //
        // Audio profile: MUSIC_HIGH_QUALITY + DEFAULT scenario. The DEFAULT
        // *profile* applies aggressive echo cancellation optimized for two-way
        // human calls — which suppresses/distorts the agent's incoming TTS audio
        // whenever the mic is (or was recently) live, producing garbled, choppy
        // playback that "skips ahead". MUSIC_HIGH_QUALITY keeps full-fidelity
        // playback of the remote audio. We deliberately keep the DEFAULT
        // *scenario* (not .aiClient) because that scenario changed the mic
        // encoding and the agent's ASR couldn't transcribe it.
        agoraRtcEngine?.setAudioProfile(.musicHighQuality, scenario: .default)
        agoraRtcEngine?.disableVideo()

        // TEMP DEBUG: capture the raw incoming agent audio to a WAV file so we
        // can hear exactly what the Mac receives (to isolate whether the garble
        // is introduced before or after playback).
        AgentAudioDebugger.shared.attach(engine: agoraRtcEngine!)
    }

    /// Joins the channel and starts publishing the microphone. The agent
    /// (started separately by the Worker) joins the same channel and subscribes
    /// to this user's audio.
    func joinChannel(rtcToken: String, channelName: String, localUserUid: UInt) {
        guard let agoraRtcEngine else {
            print("⚠️ AgoraVoiceClient: engine not initialized")
            return
        }

        let mediaOptions = AgoraRtcChannelMediaOptions()
        mediaOptions.channelProfile = .communication
        mediaOptions.clientRoleType = .broadcaster
        mediaOptions.publishMicrophoneTrack = true
        mediaOptions.autoSubscribeAudio = true

        let result = agoraRtcEngine.joinChannel(
            byToken: rtcToken,
            channelId: channelName,
            uid: localUserUid,
            mediaOptions: mediaOptions,
            joinSuccess: nil
        )
        // 0 means the call was accepted; any other value is an error code and
        // didJoinChannel will never fire. Log it so a silent join failure is visible.
        if result != 0 {
            print("⚠️ Agora: joinChannel returned error code \(result)")
        } else {
            print("🎙️ Agora: joinChannel call accepted, waiting to connect…")
        }

        // Start muted: this session is push-to-talk, so the mic only goes live
        // while the user is holding the shortcut. muteLocalAudioStream keeps the
        // channel join intact — it just stops mic audio from reaching the agent.
        agoraRtcEngine.muteLocalAudioStream(true)
    }

    /// Temporarily mutes/unmutes the microphone without leaving the channel.
    func setMicrophoneMuted(_ muted: Bool) {
        agoraRtcEngine?.muteLocalAudioStream(muted)
    }

    /// Leaves the channel. The engine is kept alive so a new session can start
    /// quickly; call `tearDownEngine()` only when the client is being discarded.
    func leaveChannel() {
        agoraRtcEngine?.leaveChannel()
        // TEMP DEBUG: flush the captured agent audio when the session ends.
        AgentAudioDebugger.shared.flushToWav()
        Task { @MainActor in
            self.isJoinedToChannel = false
            self.isAgentSpeaking = false
            self.agentRtcUid = nil
        }
    }

    /// Destroys the RTC engine and frees SDK resources.
    func tearDownEngine() {
        leaveChannel()
        AgoraRtcEngineKit.destroy()
        agoraRtcEngine = nil
    }
}

// MARK: - AgoraRtcEngineDelegate

extension AgoraVoiceClient: AgoraRtcEngineDelegate {
    nonisolated func rtcEngine(
        _ engine: AgoraRtcEngineKit,
        didJoinChannel channel: String,
        withUid uid: UInt,
        elapsed: Int
    ) {
        Task { @MainActor in
            self.isJoinedToChannel = true
            print("🎙️ Agora: joined channel \(channel) as uid \(uid)")
        }
    }

    nonisolated func rtcEngine(
        _ engine: AgoraRtcEngineKit,
        connectionChangedTo state: AgoraConnectionState,
        reason: AgoraConnectionChangedReason
    ) {
        Task { @MainActor in
            print("🎙️ Agora: connection state → \(state.rawValue) (reason \(reason.rawValue))")
        }
    }

    nonisolated func rtcEngine(_ engine: AgoraRtcEngineKit, didOccurError errorCode: AgoraErrorCode) {
        Task { @MainActor in
            print("⚠️ Agora: SDK error \(errorCode.rawValue)")
        }
    }

    nonisolated func rtcEngine(
        _ engine: AgoraRtcEngineKit,
        didAudioPublishStateChange channel: String,
        oldState: AgoraStreamPublishState,
        newState: AgoraStreamPublishState,
        elapseSinceLastState: Int
    ) {
        Task { @MainActor in
            // .published (2) means the mic audio is actually flowing to the channel.
            print("🎙️ Agora: audio publish state \(oldState.rawValue) → \(newState.rawValue)")
        }
    }

    nonisolated func rtcEngine(_ engine: AgoraRtcEngineKit, didJoinedOfUid uid: UInt, elapsed: Int) {
        Task { @MainActor in
            // The first remote user is the conversational AI agent.
            if self.agentRtcUid == nil {
                self.agentRtcUid = uid
                print("🤖 Agora: agent joined (uid \(uid))")
                // Agora's Murf stream-input bridge garbles the agent's audio, so
                // we never play it: mute the agent's remote audio track and speak
                // the clean reply text locally via Murf REST (AgentReplyPoller).
                engine.muteRemoteAudioStream(uid, mute: true)
                self.onAgentJoined?()
            }
        }
    }

    nonisolated func rtcEngine(
        _ engine: AgoraRtcEngineKit,
        didOfflineOfUid uid: UInt,
        reason: AgoraUserOfflineReason
    ) {
        Task { @MainActor in
            if uid == self.agentRtcUid {
                print("🤖 Agora: agent left (reason \(reason.rawValue))")
                self.agentRtcUid = nil
                self.isAgentSpeaking = false
                self.onAgentLeft?()
            }
        }
    }

    nonisolated func rtcEngine(
        _ engine: AgoraRtcEngineKit,
        didAudioRouteChanged routing: AgoraAudioOutputRouting
    ) {
        // No-op — we always play through the system default output.
    }

    nonisolated func rtcEngine(
        _ engine: AgoraRtcEngineKit,
        remoteAudioStateChangedOfUid uid: UInt,
        state: AgoraAudioRemoteState,
        reason: AgoraAudioRemoteReason,
        elapsed: Int
    ) {
        Task { @MainActor in
            guard uid == self.agentRtcUid else { return }
            // .decoding means we're receiving & playing the agent's audio.
            self.isAgentSpeaking = (state == .decoding)
        }
    }
}
