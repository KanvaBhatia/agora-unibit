# Unibit

Unibit is a macOS menu bar voice companion. It lives in your status bar, sees your screen when you ask it to, talks back over a real-time voice channel, and can fly its little amber cursor across your monitors to point at UI elements it references.

Press and hold **Control + Option** to talk. Release to stop. That's the whole interface.

## How it works

Pressing the hotkey starts an [Agora Conversational AI agent](https://docs.agora.io/en/ai/get-started/quickstart) that joins a real-time voice channel. The agent runs ASR → Claude (via the Worker's OpenAI-compatible `/agent/llm` bridge) → Murf TTS (`falcon-2.1`), all inside the channel. The app joins the same channel with the Agora RTC macOS SDK so the conversation is hands-free and interruptible.

While a session is live:

- A **Dynamic Island–style pill** drops from the top-center of your screen and shows the live exchange — "listening…" while you hold the hotkey, then `you:` / `unibit:` once the agent replies. It retracts a moment after Unibit finishes speaking.
- The app **uploads a screenshot of the cursor's screen** so the agent can see what you see — one frame the instant you press the hotkey (so it's never stale), then every 5 seconds.
- The agent acts as a **step-by-step guide**: it gives only the very next action per reply (never a multi-step list), keeps replies short, and always points. The app polls for `[POINT:x,y:label]` tags parsed out of the agent's answers and flies the amber cursor to whatever it references — across any connected monitor.

The agent's replies are spoken **locally** via Murf REST (Agora's in-channel Murf bridge garbles multi-sentence audio), so the voice you hear is clean.

All API keys live on a Cloudflare Worker proxy — nothing sensitive ships in the app.

A legacy direct push-to-talk path (AssemblyAI streaming → Claude SSE → local Murf TTS) is still in the codebase and can be selected via the `VoiceConversationBackend` key in `Info.plist`.

## Prerequisites

- macOS 14.2+ (for ScreenCaptureKit)
- Xcode 15+
- Node.js 18+ (for the Cloudflare Worker)
- A [Cloudflare](https://cloudflare.com) account (free tier works)
- API keys for: [Anthropic](https://console.anthropic.com), [AssemblyAI](https://www.assemblyai.com), [Murf](https://murf.ai/api)
- An [Agora](https://console.agora.io) account with Conversational AI enabled (App ID, App Certificate, Customer ID + Customer Secret)

## 1. Set up the Cloudflare Worker

The Worker is a tiny proxy that holds your API keys. The app talks to the Worker, the Worker talks to the APIs. This way your keys never ship in the app binary.

```bash
cd worker
npm install
```

Add your secrets. Wrangler will prompt you to paste each one:

```bash
npx wrangler secret put ANTHROPIC_API_KEY
npx wrangler secret put ASSEMBLYAI_API_KEY
npx wrangler secret put MURF_API_KEY
npx wrangler secret put AGORA_APP_ID
npx wrangler secret put AGORA_APP_CERTIFICATE
npx wrangler secret put AGORA_CUSTOMER_ID
npx wrangler secret put AGORA_CUSTOMER_SECRET
npx wrangler secret put AGENT_LLM_API_KEY
```

`AGENT_LLM_API_KEY` is a shared secret you make up — the Agora agent sends it back to the Worker's `/agent/llm` endpoint so only Agora can call it. Generate one with `openssl rand -hex 32`.

For the Murf voice ID, open `wrangler.toml` and set it there (it's not sensitive):

```toml
[vars]
MURF_VOICE_ID = "Gordon"
```

Deploy:

```bash
npx wrangler deploy
```

It'll give you a URL like `https://unibit-proxy.your-subdomain.workers.dev`. Copy that.

## 2. Run the Worker locally (optional, for development)

```bash
cd worker
npx wrangler dev
```

This starts a local server (usually `http://localhost:8787`). You'll need a `.dev.vars` file in `worker/` with your keys:

```
ANTHROPIC_API_KEY=sk-ant-...
ASSEMBLYAI_API_KEY=...
MURF_API_KEY=...
MURF_VOICE_ID=Gordon
AGORA_APP_ID=...
AGORA_APP_CERTIFICATE=...
AGORA_CUSTOMER_ID=...
AGORA_CUSTOMER_SECRET=...
AGENT_LLM_API_KEY=<openssl rand -hex 32>
```

> **Note:** The Agora agent calls the Worker's `/agent/llm` endpoint over the public internet, so for the full agent path you need the **deployed** Worker URL (not `localhost`). For local Worker dev you can use a tunnel like `ngrok http 8787` and set that as the base URL.

## 3. Point the app at your Worker

The app has the Worker URL hardcoded in two places. Search for `clicky-proxy` and replace with your Worker URL:

```bash
grep -r "clicky-proxy" Unibit/
```

- `CompanionManager.swift` — Claude chat + TTS + Agora agent session
- `AssemblyAIStreamingTranscriptionProvider.swift` — AssemblyAI token endpoint (legacy path)

## 4. Open in Xcode and run

```bash
open Unibit.xcodeproj
```

In Xcode:
1. Select the `Unibit` scheme
2. Set your signing team under Signing & Capabilities
3. Hit **Cmd + R** to build and run

> **Important:** always build and run from Xcode, never `xcodebuild` from the terminal. Building from the CLI invalidates the app's TCC (privacy) permissions and it'll re-prompt for screen recording, accessibility, etc.

The app appears in your menu bar (not the dock). Click the icon to open the panel, grant the permissions it asks for, hit Start, and you're good.

### Permissions the app needs

- **Microphone** — for push-to-talk voice capture
- **Accessibility** — for the global keyboard shortcut (Control + Option)
- **Screen Recording** — for taking screenshots when you use the hotkey
- **Screen Content** — for ScreenCaptureKit access

## Architecture

**Menu bar app** (no dock icon) with three floating `NSPanel` windows: one for the control panel dropdown, one for the full-screen transparent cursor overlay, and one for the Dynamic Island–style conversation pill at the top of the screen.

Two voice backends are supported, selected by the `VoiceConversationBackend` key in `Info.plist`:

- **`agora` (default):** pressing the hotkey starts an Agora Conversational AI agent. The agent runs ASR → Claude (via the Worker's `/agent/llm` bridge) → Murf TTS inside the channel. The app joins the same channel with the Agora RTC SDK, mutes the agent's (garbled) remote audio, and speaks replies locally via Murf REST.
- **anything else (legacy):** push-to-talk streams audio over a websocket to AssemblyAI, sends the transcript + screenshot to Claude via streaming SSE, and plays the response through Murf TTS locally.

Either way, Claude can embed `[POINT:x,y:label:screenN]` tags to make the cursor fly to specific UI elements across multiple monitors. All APIs are proxied through the Cloudflare Worker so no keys ship in the app.

### Worker routes

| Route | Purpose |
|-------|---------|
| `POST /chat` | Claude vision + streaming (legacy path) |
| `POST /tts` | Murf TTS audio |
| `POST /transcribe-token` | AssemblyAI websocket token (legacy path) |
| `POST /agent/start` · `/agent/stop` | Spin up / tear down the Agora agent; mints the app's RTC token |
| `POST /agent/llm` | OpenAI-compatible custom-LLM bridge the agent calls; attaches the latest screen frame, filters reasoning, parses `[POINT]`, and stashes the reply + exchange |
| `POST /agent/context` | Stores the app's latest screenshot (single global frame) |
| `GET /agent/point` | Latest parsed `[POINT]` for the cursor (id-deduped) |
| `GET /agent/reply` | Latest clean reply text for local TTS (id-deduped) |
| `GET /agent/utterance` | Latest `{ userText, replyText }` exchange for the pill (id-deduped) |

## Project structure

```
Unibit/          # Swift source
  UnibitApp.swift             # Menu bar app entry point
  CompanionManager.swift      # Central state machine + Agora session lifecycle
  CompanionPanelView.swift    # Menu bar panel UI
  OverlayWindow.swift         # Amber cursor overlay
  ConversationPillOverlay.swift # Top-of-screen conversation pill
  ConversationTurnPoller.swift  # Polls /agent/utterance for the pill
  AgoraVoiceClient.swift      # Agora RTC engine wrapper (join/leave, mic, agent audio)
  AgoraAgentSessionClient.swift # Starts/stops agents via the Worker
  ScreenContextUploader.swift # Periodic + on-hotkey screenshot upload
  AgentPointPoller.swift      # Polls /agent/point for cursor pointing
  AgentReplyPoller.swift      # Polls /agent/reply for local TTS
  MurfTTSClient.swift         # Murf text-to-speech playback
  ClaudeAPI.swift             # Claude streaming client (legacy path)
  AssemblyAI*.swift           # Real-time transcription (legacy path)
  BuddyDictation*.swift       # Push-to-talk pipeline (legacy path)
worker/                  # Cloudflare Worker proxy
  src/index.ts              # All routes (see table above)
AGENTS.md                # Full architecture doc (CLAUDE.md is a symlink to it)
```

## License

MIT. See `LICENSE`.
