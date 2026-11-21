# Unibit - Agent Instructions

<!-- This is the single source of truth for all AI coding agents. CLAUDE.md is a symlink to this file. -->
<!-- AGENTS.md spec: https://github.com/agentsmd/agents.md — supported by Claude Code, Cursor, Copilot, Gemini CLI, and others. -->

## Overview

macOS menu bar companion app. Lives entirely in the macOS status bar (no dock icon, no main window). Clicking the menu bar icon opens a custom floating panel with companion voice controls.

Two voice-conversation backends are supported, chosen by the `VoiceConversationBackend` key in `Info.plist`:

- **`agora` (default in this fork):** pressing the hotkey starts an Agora Conversational AI agent that joins a real-time voice channel. The agent runs ASR → Claude (via the Worker's OpenAI-compatible `/agent/llm` bridge) → Murf TTS (`falcon-2.1`) inside the channel. The app joins the same channel with the Agora RTC macOS SDK, so the conversation is hands-free and interruptible.
- **anything else (legacy):** push-to-talk (ctrl+option) captures voice input, transcribes it via AssemblyAI streaming, sends the transcript + a screenshot to Claude, and plays the response via Murf TTS locally.

An amber cursor overlay can fly to and point at UI elements Claude references on any connected monitor (via `[POINT:x,y:label:screenN]` tags).

While a session is live, a **Dynamic Island–style conversation pill** drops from the top-center of the cursor's screen and shows the live exchange — "listening…" while the mic is hot, then `you:` / `unibit:` once the turn completes — and retracts after the reply finishes speaking.

The agent is prompted to act as a **step-by-step guide**: it gives only the very next single action per reply (never a multi-step list), keeps replies short and action-first, and always appends a `[POINT:...]` tag for the on-screen element it references.

All API keys live on a Cloudflare Worker proxy — nothing sensitive ships in the app.

## Architecture

- **App Type**: Menu bar-only (`LSUIElement=true`), no dock icon or main window
- **Framework**: SwiftUI (macOS native) with AppKit bridging for menu bar panel and cursor overlay
- **Pattern**: MVVM with `@StateObject` / `@Published` state management
- **AI Chat**: Claude (Sonnet 4.6, fixed) via Cloudflare Worker proxy with SSE streaming
- **Speech-to-Text**: AssemblyAI real-time streaming (`u3-rt-pro` model) via websocket, with OpenAI and Apple Speech as fallbacks
- **Text-to-Speech**: Murf (`falcon-2.1` model) — inside the Agora channel for agent sessions, or via Cloudflare Worker proxy for the legacy path
- **Screen Capture**: ScreenCaptureKit (macOS 14.2+), multi-monitor support
- **Voice Input**: Push-to-talk via `AVAudioEngine` + pluggable transcription-provider layer. System-wide keyboard shortcut via listen-only CGEvent tap.
- **Element Pointing**: Claude embeds `[POINT:x,y:label:screenN]` tags in responses. The overlay parses these, maps coordinates to the correct monitor, and animates the amber cursor along a bezier arc to the target.
- **Concurrency**: `@MainActor` isolation, async/await throughout

### API Proxy (Cloudflare Worker)

The app never calls external APIs directly. All requests go through a Cloudflare Worker (`worker/src/index.ts`) that holds the real API keys as secrets.

| Route | Upstream | Purpose |
|-------|----------|---------|
| `POST /chat` | `api.anthropic.com/v1/messages` | Claude vision + streaming chat (legacy) |
| `POST /tts` | `global.api.murf.ai/v1/speech/stream` | Murf TTS audio (legacy path) |
| `POST /transcribe-token` | `streaming.assemblyai.com/v3/token` | Fetches a short-lived (480s) AssemblyAI websocket token (legacy) |
| `POST /agent/start` | `api.agora.io/.../join` | Starts an Agora Conversational AI agent; returns an RTC token for the app |
| `POST /agent/stop` | `api.agora.io/.../agents/{id}/leave` | Stops a running agent |
| `POST /agent/llm` | LiteLLM → kimi-k3 | OpenAI-compatible custom-LLM bridge called **by** the Agora agent. Attaches the latest uploaded screen frame (if <15s old) to the current turn, filters reasoning from the stream, and parses `[POINT:...]` tags out of the answer |
| `POST /agent/context` | — (Worker memory) | App uploads the cursor screen's latest screenshot while a session is live; stored as a single global frame (no auth, single-user demo) |
| `GET /agent/point` | — (Worker memory) | App polls for the latest `[POINT]` parsed from the LLM stream; returns a monotonically increasing `id` so the app only animates on new points |
| `GET /agent/reply` | — (Worker memory) | App polls for the latest clean reply text to speak locally via Murf REST (bypasses Agora's garbling Murf stream-input bridge) |
| `GET /agent/utterance` | — (Worker memory) | App polls for the latest exchange (`{ userText, replyText }`) to render in the conversation pill; `id` increments per turn |

Worker secrets: `ANTHROPIC_API_KEY`, `ASSEMBLYAI_API_KEY`, `MURF_API_KEY`, `AGORA_APP_ID`, `AGORA_APP_CERTIFICATE`, `AGORA_CUSTOMER_ID`, `AGORA_CUSTOMER_SECRET`, `AGENT_LLM_API_KEY` (shared secret Agora sends back to `/agent/llm`)
Worker vars: `MURF_VOICE_ID`

### Key Architecture Decisions

**Menu Bar Panel Pattern**: The companion panel uses `NSStatusItem` for the menu bar icon and a custom borderless `NSPanel` for the floating control panel. This gives full control over appearance (dark, rounded corners, custom shadow) and avoids the standard macOS menu/popover chrome. The panel is non-activating so it doesn't steal focus. A global event monitor auto-dismisses it on outside clicks.

**Cursor Overlay**: A full-screen transparent `NSPanel` hosts the amber cursor companion. It's non-activating, joins all Spaces, and never steals focus. The cursor position, response text, waveform, and pointing animations all render in this overlay via SwiftUI through `NSHostingView`.

**Global Push-To-Talk Shortcut**: Background push-to-talk uses a listen-only `CGEvent` tap instead of an AppKit global monitor so modifier-based shortcuts like `ctrl + option` are detected more reliably while the app is running in the background.

**Shared URLSession for AssemblyAI**: A single long-lived `URLSession` is shared across all AssemblyAI streaming sessions (owned by the provider, not the session). Creating and invalidating a URLSession per session corrupts the OS connection pool and causes "Socket is not connected" errors after a few rapid reconnections.

**Transient Cursor Mode**: When "Show Unibit" is off, pressing the hotkey fades in the cursor overlay for the duration of the interaction (recording → response → TTS → optional pointing), then fades it out automatically after 1 second of inactivity.

## Key Files

| File | Lines | Purpose |
|------|-------|---------|
| `UnibitApp.swift` | ~86 | Menu bar app entry point. Uses `@NSApplicationDelegateAdaptor` with `CompanionAppDelegate` which creates `MenuBarPanelManager` and starts `CompanionManager`. No main window — the app lives entirely in the status bar. |
| `CompanionManager.swift` | ~925 | Central state machine. Owns dictation, shortcut monitoring, screen capture, Claude API, TTS, Agora agent session lifecycle, the conversation pill, and overlay management. Tracks voice state, conversation history, and cursor visibility. Routes the hotkey to either the Agora agent session or the legacy push-to-talk → screenshot → Claude → TTS → pointing pipeline depending on `VoiceConversationBackend`. On hotkey press (Agora path) it also fires an immediate screen-context upload and presents the pill. |
| `MenuBarPanelManager.swift` | ~243 | NSStatusItem + custom NSPanel lifecycle. Creates the menu bar icon, manages the floating companion panel (show/hide/position), installs click-outside-to-dismiss monitor. |
| `CompanionPanelView.swift` | ~560 | SwiftUI panel content for the menu bar dropdown. Shows companion status, push-to-talk instructions, permissions UI, and quit button. Dark aesthetic using `DS` design system. |
| `OverlayWindow.swift` | ~787 | Full-screen transparent overlay hosting the amber cursor, response text, waveform, and spinner. Handles cursor animation, element pointing with bezier arcs, multi-monitor coordinate mapping, and fade-out transitions. |
| `ConversationPillOverlay.swift` | ~297 | Dynamic Island–style pill that drops from the top-center of the cursor's screen during an Agora turn. A non-activating `NSPanel` hosting a SwiftUI capsule; shows "listening…" then the `you:`/`unibit:` exchange. The panel's top edge stays pinned to the screen top (driven by a SwiftUI-measured `contentHeight` preference) so the bar grows downward as a wide fixed-width strip, then retracts after the reply finishes speaking. |
| `ConversationTurnPoller.swift` | ~87 | While an Agora session is live, polls `/agent/utterance` every 1s; on a new turn id, fires a callback with `{ userText, replyText }` so `CompanionManager` renders the exchange in the pill. |
| `CompanionResponseOverlay.swift` | ~217 | SwiftUI view for the response text bubble and waveform displayed next to the cursor in the overlay (legacy path). |
| `CompanionScreenCaptureUtility.swift` | ~132 | Multi-monitor screenshot capture using ScreenCaptureKit. Returns labeled image data for each connected display. |
| `BuddyDictationManager.swift` | ~866 | Push-to-talk voice pipeline (legacy path). Handles microphone capture via `AVAudioEngine`, provider-aware permission checks, keyboard/button dictation sessions, transcript finalization, shortcut parsing, contextual keyterms, and live audio-level reporting for waveform feedback. |
| `BuddyTranscriptionProvider.swift` | ~100 | Protocol surface and provider factory for voice transcription backends. Resolves provider based on `VoiceTranscriptionProvider` in Info.plist — AssemblyAI, OpenAI, or Apple Speech. |
| `AssemblyAIStreamingTranscriptionProvider.swift` | ~478 | Streaming transcription provider (legacy path). Fetches temp tokens from the Cloudflare Worker, opens an AssemblyAI v3 websocket, streams PCM16 audio, tracks turn-based transcripts, and delivers finalized text on key-up. Shares a single URLSession across all sessions. |
| `OpenAIAudioTranscriptionProvider.swift` | ~317 | Upload-based transcription provider (legacy path). Buffers push-to-talk audio locally, uploads as WAV on release, returns finalized transcript. |
| `AppleSpeechTranscriptionProvider.swift` | ~147 | Local fallback transcription provider backed by Apple's Speech framework. |
| `BuddyAudioConversionSupport.swift` | ~108 | Audio conversion helpers. Converts live mic buffers to PCM16 mono audio and builds WAV payloads for upload-based providers. |
| `GlobalPushToTalkShortcutMonitor.swift` | ~132 | System-wide push-to-talk monitor. Owns the listen-only `CGEvent` tap and publishes press/release transitions. |
| `ClaudeAPI.swift` | ~291 | Claude vision API client with streaming (SSE) and non-streaming modes (legacy path). TLS warmup optimization, image MIME detection, conversation history support. |
| `OpenAIAPI.swift` | ~142 | OpenAI GPT vision API client (legacy path). |
| `MurfTTSClient.swift` | ~83 | Murf TTS client. Sends text to the Worker proxy (`/tts`), plays back audio via `AVAudioPlayer`. Used both by the legacy path and to speak Agora agent replies locally (bypassing Agora's garbling Murf bridge). |
| `AgoraVoiceClient.swift` | ~274 | Wraps the Agora RTC engine for a voice-only conversational session. Joins the channel, publishes the mic (push-to-talk mute/unmute), and mutes the agent's remote audio track (the app speaks replies locally instead). Delegate callbacks hop to MainActor. |
| `AgoraAgentSessionClient.swift` | ~100 | Calls the Worker's `/agent/start` and `/agent/stop` to spin up and tear down Agora Conversational AI agent sessions. Returns the RTC token + channel the app joins. |
| `ScreenContextUploader.swift` | ~100 | While an Agora session is live, uploads the cursor screen's screenshot to `/agent/context` every 5s so the agent can see what's on screen. Also exposes `uploadScreenContextNow()` for an immediate frame on hotkey press. |
| `AgentPointPoller.swift` | ~101 | While an Agora session is live, polls `/agent/point` every 1s; on a new point id, fires a callback so `CompanionManager` flies the cursor to the referenced element. |
| `AgentReplyPoller.swift` | ~84 | While an Agora session is live, polls `/agent/reply` every 1s; on a new reply id, fires a callback so `CompanionManager` speaks the reply locally via Murf REST. |
| `ElementLocationDetector.swift` | ~335 | Detects UI element locations in screenshots for cursor pointing. |
| `DesignSystem.swift` | ~875 | Design system tokens — colors, corner radii, shared styles. All UI references `DS.Colors`, `DS.CornerRadius`, etc. |
| `WindowPositionManager.swift` | ~262 | Window placement logic, Screen Recording permission flow, and accessibility permission helpers. |
| `AppBundleConfiguration.swift` | ~28 | Runtime configuration reader for keys stored in the app bundle Info.plist. |
| `worker/src/index.ts` | ~1164 | Cloudflare Worker proxy. Legacy routes `/chat` (Claude), `/tts` (Murf), `/transcribe-token` (AssemblyAI), plus Agora routes: `/agent/start` + `/agent/stop` (agent lifecycle, mints RTC tokens via AccessToken2), `/agent/llm` (OpenAI-compatible custom-LLM bridge that streams Claude back to the agent in OpenAI SSE chunk format), `/agent/context` (stores the app's latest screenshot), `/agent/point` (serves the latest parsed `[POINT]`), `/agent/reply` (serves the latest clean reply text), and `/agent/utterance` (serves the latest `{ userText, replyText }` exchange). State is held in a `ScreenState` Durable Object so it's shared across all isolates. |

## Build & Run

```bash
# Open in Xcode
open Unibit.xcodeproj

# Select the Unibit scheme, set signing team, Cmd+R to build and run

# Known non-blocking warnings: Swift 6 concurrency warnings,
# deprecated onChange warning in OverlayWindow.swift. Do NOT attempt to fix these.
```

**Do NOT run `xcodebuild` from the terminal** — it invalidates TCC (Transparency, Consent, and Control) permissions and the app will need to re-request screen recording, accessibility, etc.

## Cloudflare Worker

```bash
cd worker
npm install

# Add secrets
npx wrangler secret put ANTHROPIC_API_KEY
npx wrangler secret put ASSEMBLYAI_API_KEY
npx wrangler secret put ELEVENLABS_API_KEY

# Deploy
npx wrangler deploy

# Local dev (create worker/.dev.vars with your keys)
npx wrangler dev
```

## Code Style & Conventions

### Variable and Method Naming

IMPORTANT: Follow these naming rules strictly. Clarity is the top priority.

- Be as clear and specific with variable and method names as possible
- **Optimize for clarity over concision.** A developer with zero context on the codebase should immediately understand what a variable or method does just from reading its name
- Use longer names when it improves clarity. Do NOT use single-character variable names
- Example: use `originalQuestionLastAnsweredDate` instead of `originalAnswered`
- When passing props or arguments to functions, keep the same names as the original variable. Do not shorten or abbreviate parameter names. If you have `currentCardData`, pass it as `currentCardData`, not `card` or `cardData`

### Code Clarity

- **Clear is better than clever.** Do not write functionality in fewer lines if it makes the code harder to understand
- Write more lines of code if additional lines improve readability and comprehension
- Make things so clear that someone with zero context would completely understand the variable names, method names, what things do, and why they exist
- When a variable or method name alone cannot fully explain something, add a comment explaining what is happening and why

### Swift/SwiftUI Conventions

- Use SwiftUI for all UI unless a feature is only supported in AppKit (e.g., `NSPanel` for floating windows)
- All UI state updates must be on `@MainActor`
- Use async/await for all asynchronous operations
- Comments should explain "why" not just "what", especially for non-obvious AppKit bridging
- AppKit `NSPanel`/`NSWindow` bridged into SwiftUI via `NSHostingView`
- All buttons must show a pointer cursor on hover
- For any interactive element, explicitly think through its hover behavior (cursor, visual feedback, and whether hover should communicate clickability)

### Do NOT

- Do not add features, refactor code, or make "improvements" beyond what was asked
- Do not add docstrings, comments, or type annotations to code you did not change
- Do not try to fix the known non-blocking warnings (Swift 6 concurrency, deprecated onChange)
- The project directory, scheme, and targets are named "Unibit"
- Do not run `xcodebuild` from the terminal — it invalidates TCC permissions

## Git Workflow

- Branch naming: `feature/description` or `fix/description`
- Commit messages: imperative mood, concise, explain the "why" not the "what"
- Do not force-push to main

## Self-Update Instructions

<!-- AI agents: follow these instructions to keep this file accurate. -->

When you make changes to this project that affect the information in this file, update this file to reflect those changes. Specifically:

1. **New files**: Add new source files to the "Key Files" table with their purpose and approximate line count
2. **Deleted files**: Remove entries for files that no longer exist
3. **Architecture changes**: Update the architecture section if you introduce new patterns, frameworks, or significant structural changes
4. **Build changes**: Update build commands if the build process changes
5. **New conventions**: If the user establishes a new coding convention during a session, add it to the appropriate conventions section
6. **Line count drift**: If a file's line count changes significantly (>50 lines), update the approximate count in the Key Files table

Do NOT update this file for minor edits, bug fixes, or changes that don't affect the documented architecture or conventions.
