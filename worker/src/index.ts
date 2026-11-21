/**
 * Unibit Proxy Worker
 *
 * Proxies requests to Claude, Murf, and the Agora Conversational AI Engine so
 * the app never ships with raw API keys. Keys are stored as Cloudflare secrets.
 *
 * Routes:
 *   POST /chat             → Anthropic Messages API (streaming) [legacy direct path]
 *   POST /tts              → Murf TTS streaming API
 *   POST /transcribe-token → AssemblyAI temp token [legacy direct path]
 *   POST /agent/start      → Start an Agora Conversational AI agent + return RTC token
 *   POST /agent/stop       → Stop a running Agora Conversational AI agent
 *   POST /agent/llm        → OpenAI-compatible custom LLM bridge (called BY Agora) → Claude
 *   POST /agent/context    → App uploads the latest screenshot; stored for LLM turns
 *   GET  /agent/point      → App polls for the latest [POINT:...] parsed from the LLM
 */

interface Env {
  // Anthropic / Claude
  ANTHROPIC_API_KEY: string;
  // Murf TTS
  MURF_API_KEY: string;
  // AssemblyAI (legacy direct-push-to-talk path)
  ASSEMBLYAI_API_KEY: string;
  // Agora Conversational AI
  AGORA_APP_ID: string;
  AGORA_APP_CERTIFICATE: string;
  AGORA_CUSTOMER_ID: string;
  AGORA_CUSTOMER_SECRET: string;
  // Worker vars (non-sensitive)
  MURF_VOICE_ID: string;
  AGENT_LLM_API_KEY: string; // shared secret Agora sends back to /agent/llm
  // Durable Object holding the shared screen-context frame + latest point.
  SCREEN_STATE: DurableObjectNamespace;
}

const AGENT_UID = 0; // agent gets a random RTC uid
const AGENT_IDLE_TIMEOUT_SECONDS = 120;

// ---------------------------------------------------------------------------
// Screen-context + pointing state.
//
// Module-level variables do NOT work here: each request (the app's 1s /point
// polls, the 5s /context upload, and Agora's /llm turn) can run on a different
// Cloudflare isolate, and module state is per-isolate — the LLM-turn isolate
// never saw the uploaded frame. A Durable Object gives us ONE strongly-
// consistent instance that every route talks to, so the frame the app uploads
// is the same frame /agent/llm reads.
// ---------------------------------------------------------------------------

/// The latest screenshot the app uploaded. Attached to an LLM turn only when
/// it's fresh (see SCREEN_FRAME_MAX_AGE_MS), so general questions that arrive
/// after the frame goes stale don't waste image tokens.
interface StoredScreenFrame {
  imageBase64: string;
  label: string;
  screenshotWidth: number;
  screenshotHeight: number;
  displayWidth: number;
  displayHeight: number;
  capturedAtMs: number;
}

/// The latest [POINT:x,y:label] parsed from the LLM's streamed answer. The app
/// polls /agent/point and animates when `id` changes, so id is monotonically
/// increasing to dedupe.
interface StoredPoint {
  id: number;
  x: number;
  y: number;
  label: string | null;
  screenshotWidth: number;
  screenshotHeight: number;
  displayWidth: number;
  displayHeight: number;
  createdAtMs: number;
}

/// The latest clean LLM reply, stashed so the app can fetch + speak it locally
/// via Murf REST (bypassing Agora's garbling Murf stream-input bridge). `id`
/// increments per reply so the app only speaks each reply once.
interface StoredReply {
  id: number;
  text: string;
  createdAtMs: number;
}

/// One conversation exchange (what the user said + what Unibit replied), stashed
/// so the app's on-screen conversation pill can show the latest turn. The user's
/// transcript only passes through /agent/llm (the agent does ASR in-channel), so
/// this is the single place both sides of the exchange are visible together.
/// `id` increments per utterance so the app only renders each exchange once.
interface StoredUtterance {
  id: number;
  userText: string;
  replyText: string;
  createdAtMs: number;
}

const SCREEN_FRAME_MAX_AGE_MS = 15_000;

/// Durable Object holding the latest screen frame + latest point. A single
/// named instance ("global") serves all requests — single-user demo.
export class ScreenState implements DurableObject {
  private state: DurableObjectState;

  constructor(state: DurableObjectState) {
    this.state = state;
  }

  async fetch(request: Request): Promise<Response> {
    const url = new URL(request.url);

    // Store a new screen frame.
    if (request.method === "POST" && url.pathname === "/frame") {
      const frame = (await request.json()) as StoredScreenFrame;
      await this.state.storage.put("screenFrame", frame);
      return new Response("{}");
    }

    // Read the current screen frame (null if none stored).
    if (request.method === "GET" && url.pathname === "/frame") {
      const frame = (await this.state.storage.get<StoredScreenFrame>("screenFrame")) ?? null;
      return Response.json(frame);
    }

    // Store a new point (id is incremented inside storage via a transaction so
    // concurrent writes can't double-assign an id).
    if (request.method === "POST" && url.pathname === "/point") {
      const point = (await request.json()) as Omit<StoredPoint, "id">;
      const stored = await this.state.storage.transaction(async () => {
        const currentId = (await this.state.storage.get<number>("pointIdCounter")) ?? 0;
        const newId = currentId + 1;
        const withId: StoredPoint = { id: newId, ...point };
        await this.state.storage.put("pointIdCounter", newId);
        await this.state.storage.put("latestPoint", withId);
        return withId;
      });
      return Response.json(stored);
    }

    // Read the latest point ({ id: 0 } when none yet, so the app can poll safely).
    if (request.method === "GET" && url.pathname === "/point") {
      const point =
        (await this.state.storage.get<StoredPoint>("latestPoint")) ?? ({ id: 0 } as { id: number });
      return Response.json(point);
    }

    // Store a new reply (id increments via a transaction, like points).
    if (request.method === "POST" && url.pathname === "/reply") {
      const reply = (await request.json()) as { text: string };
      const stored = await this.state.storage.transaction(async () => {
        const currentId = (await this.state.storage.get<number>("replyIdCounter")) ?? 0;
        const newId = currentId + 1;
        const withId: StoredReply = { id: newId, text: reply.text, createdAtMs: Date.now() };
        await this.state.storage.put("replyIdCounter", newId);
        await this.state.storage.put("latestReply", withId);
        return withId;
      });
      return Response.json(stored);
    }

    // Read the latest reply ({ id: 0 } when none yet, so the app can poll safely).
    if (request.method === "GET" && url.pathname === "/reply") {
      const reply =
        (await this.state.storage.get<StoredReply>("latestReply")) ?? ({ id: 0 } as { id: number });
      return Response.json(reply);
    }

    // Store a new utterance (user transcript + agent reply), id incremented via
    // a transaction like points/replies.
    if (request.method === "POST" && url.pathname === "/utterance") {
      const utterance = (await request.json()) as { userText: string; replyText: string };
      const stored = await this.state.storage.transaction(async () => {
        const currentId = (await this.state.storage.get<number>("utteranceIdCounter")) ?? 0;
        const newId = currentId + 1;
        const withId: StoredUtterance = {
          id: newId,
          userText: utterance.userText,
          replyText: utterance.replyText,
          createdAtMs: Date.now(),
        };
        await this.state.storage.put("utteranceIdCounter", newId);
        await this.state.storage.put("latestUtterance", withId);
        return withId;
      });
      return Response.json(stored);
    }

    // Read the latest utterance ({ id: 0 } when none yet, so the app can poll safely).
    if (request.method === "GET" && url.pathname === "/utterance") {
      const utterance =
        (await this.state.storage.get<StoredUtterance>("latestUtterance")) ??
        ({ id: 0 } as { id: number });
      return Response.json(utterance);
    }

    return new Response("Not found", { status: 404 });
  }
}

/// Returns the single global ScreenState stub every route talks to.
function screenStateStub(env: Env): DurableObjectStub {
  const id = env.SCREEN_STATE.idFromName("global");
  return env.SCREEN_STATE.get(id);
}

/// Fetches the current screen frame from the Durable Object (null if none).
async function getScreenFrame(env: Env): Promise<StoredScreenFrame | null> {
  const response = await screenStateStub(env).fetch("https://screen-state/frame");
  if (!response.ok) return null;
  const text = await response.text();
  return text ? (JSON.parse(text) as StoredScreenFrame) : null;
}

export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    const url = new URL(request.url);

    // /agent/point, /agent/reply, and /agent/utterance are the app's polling
    // endpoints and must accept GET. All other routes remain POST-only.
    if (
      request.method === "GET" &&
      (url.pathname === "/agent/point" ||
        url.pathname === "/agent/reply" ||
        url.pathname === "/agent/utterance")
    ) {
      try {
        if (url.pathname === "/agent/point") return await handleAgentPoint(env);
        if (url.pathname === "/agent/reply") return await handleAgentReply(env);
        return await handleAgentUtterance(env);
      } catch (error) {
        console.error(`[${url.pathname}] Unhandled error:`, error);
        return new Response(JSON.stringify({ error: String(error) }), {
          status: 500,
          headers: { "content-type": "application/json" },
        });
      }
    }

    if (request.method !== "POST") {
      return new Response("Method not allowed", { status: 405 });
    }

    try {
      if (url.pathname === "/chat") {
        return await handleChat(request, env);
      }
      if (url.pathname === "/tts") {
        return await handleTTS(request, env);
      }
      if (url.pathname === "/transcribe-token") {
        return await handleTranscribeToken(env);
      }
      if (url.pathname === "/agent/start") {
        return await handleAgentStart(request, env);
      }
      if (url.pathname === "/agent/stop") {
        return await handleAgentStop(request, env);
      }
      if (url.pathname === "/agent/llm") {
        return await handleAgentLLM(request, env);
      }
      if (url.pathname === "/agent/context") {
        return await handleAgentContext(request, env);
      }
    } catch (error) {
      console.error(`[${url.pathname}] Unhandled error:`, error);
      return new Response(JSON.stringify({ error: String(error) }), {
        status: 500,
        headers: { "content-type": "application/json" },
      });
    }

    return new Response("Not found", { status: 404 });
  },
};

// ---------------------------------------------------------------------------
// Legacy: direct Claude vision chat (kept for non-agent use)
// ---------------------------------------------------------------------------

async function handleChat(request: Request, env: Env): Promise<Response> {
  const body = await request.text();

  const response = await fetch("https://api.anthropic.com/v1/messages", {
    method: "POST",
    headers: {
      "x-api-key": env.ANTHROPIC_API_KEY,
      "anthropic-version": "2023-06-01",
      "content-type": "application/json",
    },
    body,
  });

  if (!response.ok) {
    const errorBody = await response.text();
    console.error(`[/chat] Anthropic API error ${response.status}: ${errorBody}`);
    return new Response(errorBody, {
      status: response.status,
      headers: { "content-type": "application/json" },
    });
  }

  return new Response(response.body, {
    status: response.status,
    headers: {
      "content-type": response.headers.get("content-type") || "text/event-stream",
      "cache-control": "no-cache",
    },
  });
}

// ---------------------------------------------------------------------------
// Murf TTS (streaming) — used by the app when not running a full agent session
// ---------------------------------------------------------------------------

async function handleTTS(request: Request, env: Env): Promise<Response> {
  const { text, voiceId, locale, model, sampleRate, format, rate, pitch } =
    (await request.json()) as {
      text: string;
      voiceId?: string;
      locale?: string;
      model?: string;
      sampleRate?: number;
      format?: string;
      rate?: number;
      pitch?: number;
    };

  const response = await fetch("https://global.api.murf.ai/v1/speech/stream", {
    method: "POST",
    headers: {
      "api-key": env.MURF_API_KEY,
      "content-type": "application/json",
    },
    body: JSON.stringify({
      text,
      voiceId: voiceId || env.MURF_VOICE_ID,
      locale: locale || "en-US",
      model: model || "falcon-2.1",
      sampleRate: sampleRate || 24000,
      format: format || "MP3",
      rate: rate ?? 0,
      pitch: pitch ?? 0,
    }),
  });

  if (!response.ok) {
    const errorBody = await response.text();
    console.error(`[/tts] Murf API error ${response.status}: ${errorBody}`);
    return new Response(errorBody, {
      status: response.status,
      headers: { "content-type": "application/json" },
    });
  }

  return new Response(response.body, {
    status: response.status,
    headers: {
      "content-type": response.headers.get("content-type") || "audio/mpeg",
    },
  });
}

// ---------------------------------------------------------------------------
// Legacy: AssemblyAI temp token (used by the old direct-push-to-talk path)
// ---------------------------------------------------------------------------

async function handleTranscribeToken(env: Env): Promise<Response> {
  const response = await fetch(
    "https://streaming.assemblyai.com/v3/token?expires_in_seconds=480",
    {
      method: "GET",
      headers: { authorization: env.ASSEMBLYAI_API_KEY },
    }
  );

  if (!response.ok) {
    const errorBody = await response.text();
    console.error(`[/transcribe-token] AssemblyAI token error ${response.status}: ${errorBody}`);
    return new Response(errorBody, {
      status: response.status,
      headers: { "content-type": "application/json" },
    });
  }

  const data = await response.text();
  return new Response(data, {
    status: 200,
    headers: { "content-type": "application/json" },
  });
}

// ---------------------------------------------------------------------------
// Agora Conversational AI: start an agent
// ---------------------------------------------------------------------------
//
// The app calls this to spin up an agent that joins the given channel. The
// agent uses AssemblyAI for ASR, this Worker's /agent/llm endpoint as a custom
// OpenAI-compatible LLM (which forwards to Claude), and Murf for TTS.
//
// Request body: { channel, uid }
// Response:     { agentId, channel, uid, rtcToken, appId }
// ---------------------------------------------------------------------------

async function handleAgentStart(request: Request, env: Env): Promise<Response> {
  const { channel, uid } = (await request.json()) as {
    channel: string;
    uid: number;
  };

  if (!channel || typeof uid !== "number") {
    return new Response(
      JSON.stringify({ error: "channel (string) and uid (number) are required" }),
      { status: 400, headers: { "content-type": "application/json" } }
    );
  }

  // The app joins with a token bound to ITS uid.
  const userRtcToken = await generateAgoraRtcToken(
    env.AGORA_APP_ID,
    env.AGORA_APP_CERTIFICATE,
    channel,
    uid
  );

  // The agent joins with a SEPARATE token bound to the agent's uid (0 = the
  // agent picks a random rtc uid, and the token is minted for uid 0 to match).
  // Reusing the user's token here makes Agora reject the agent's join, since a
  // Token007 is bound to a specific uid.
  const agentRtcToken = await generateAgoraRtcToken(
    env.AGORA_APP_ID,
    env.AGORA_APP_CERTIFICATE,
    channel,
    AGENT_UID
  );

  const agentName = `unibit-${crypto.randomUUID()}`;
  const llmUrl = `${new URL(request.url).origin}/agent/llm`;

  const joinBody = {
    name: agentName,
    properties: {
      channel,
      token: agentRtcToken,
      agent_rtc_uid: String(AGENT_UID),
      remote_rtc_uids: [String(uid)],
      enable_string_uid: false,
      idle_timeout: AGENT_IDLE_TIMEOUT_SECONDS,
      // Use Agora's built-in ASR (ares) — no third-party key or websocket
      // config needed, so it works out of the box. (The previous AssemblyAI
      // vendor config produced empty transcripts.)
      asr: {
        language: "en-US",
      },
      llm: {
        url: llmUrl,
        api_key: env.AGENT_LLM_API_KEY,
        style: "openai",
        system_messages: [
          {
            role: "system",
            content: [
              "You are Unibit, an on-screen guide that walks the user through tasks ONE STEP AT A TIME. Your replies are spoken aloud via TTS and shown on screen, and a small amber cursor flies to point at the exact UI element you mention. A screenshot of the user's screen may be attached, labeled with its pixel dimensions.",
              "",
              "Core rule — ONE STEP ONLY: never give a multi-step list or a sequence of instructions. Give ONLY the very next single action the user should take, then STOP. The user will ask \"what's next\" for the following step. A one-sentence reply is ideal. Multi-step instructions are useless here because the user drives the pace — so never front-load steps two, three, four.",
              "",
              "Keep it SHORT and action-first: say the action in as few words as possible (\"click the share button\", not \"the next thing you'll want to do is locate and click on the share button\"). No preamble, no filler, no sign-off questions.",
              "",
              "ALWAYS POINT: every reply that references something on screen MUST end with a point tag for the element to click or look at. Pointing is the whole product — if you're telling them where to click, you must also point there. Never describe a location in words without pointing at it.",
              "",
              "To point, append a coordinate tag at the VERY END of your response, after all spoken text: [POINT:x,y:label] where x,y are integer PIXEL coordinates in the attached screenshot's coordinate space (origin 0,0 is the TOP-LEFT corner, x increases right, y increases down), and label is a short 1-3 word description of the element (like \"search bar\" or \"save button\").",
              "",
              "Use [POINT:none] ONLY when the reply genuinely has nothing to do with anything on screen — a pure general-knowledge or chit-chat question with no element to indicate. If there's any relevant element visible, point at it.",
              "",
              "Examples: \"click the color inspector, top right of the toolbar. [POINT:1100,42:color inspector]\" · \"open the source control menu up top. [POINT:285,11:source control]\" · \"html is the skeleton of every web page. [POINT:none]\"",
            ].join("\n"),
          },
        ],
        max_history: 10,
        greeting_message: "Hey, I'm here. What can I help you with?",
        failure_message: "Sorry, I hit an error. Try again?",
        params: { model: "claude-sonnet-4-6" },
      },
      // Agora REQUIRES a tts config (omitting it fails agent creation with
      // "tts.addon not found"). Agora's Murf stream-input bridge garbles
      // multi-sentence replies, so the app does NOT play the agent's audio —
      // it mutes the agent's remote audio track and instead speaks the clean
      // reply text locally via Murf REST (see /agent/reply). This Murf config
      // exists only so the agent is valid; its audio is never heard.
      tts: {
        vendor: "murf",
        params: {
          api_key: env.MURF_API_KEY,
          base_url: "wss://global.api.murf.ai/v1/speech/stream-input",
          voiceId: env.MURF_VOICE_ID,
          locale: "en-US",
          rate: 0,
          pitch: 0,
          model: "falcon-2.1",
          sample_rate: 24000,
        },
      },
    },
  };

  const basicAuth = btoa(`${env.AGORA_CUSTOMER_ID}:${env.AGORA_CUSTOMER_SECRET}`);
  const agoraResponse = await fetch(
    `https://api.agora.io/api/conversational-ai-agent/v2/projects/${env.AGORA_APP_ID}/join`,
    {
      method: "POST",
      headers: {
        Authorization: `Basic ${basicAuth}`,
        "content-type": "application/json",
      },
      body: JSON.stringify(joinBody),
    }
  );

  const agoraText = await agoraResponse.text();
  if (!agoraResponse.ok) {
    console.error(`[/agent/start] Agora join error ${agoraResponse.status}: ${agoraText}`);
    return new Response(agoraText, {
      status: agoraResponse.status,
      headers: { "content-type": "application/json" },
    });
  }

  const agoraData = JSON.parse(agoraText) as { agent_id?: string };

  return new Response(
    JSON.stringify({
      agentId: agoraData.agent_id ?? agentName,
      channel,
      uid,
      rtcToken: userRtcToken,
      appId: env.AGORA_APP_ID,
    }),
    { status: 200, headers: { "content-type": "application/json" } }
  );
}

// ---------------------------------------------------------------------------
// Agora Conversational AI: stop an agent
// ---------------------------------------------------------------------------
//
// Request body: { agentId }
// ---------------------------------------------------------------------------

async function handleAgentStop(request: Request, env: Env): Promise<Response> {
  const { agentId } = (await request.json()) as { agentId: string };

  if (!agentId) {
    return new Response(JSON.stringify({ error: "agentId is required" }), {
      status: 400,
      headers: { "content-type": "application/json" },
    });
  }

  const basicAuth = btoa(`${env.AGORA_CUSTOMER_ID}:${env.AGORA_CUSTOMER_SECRET}`);
  const agoraResponse = await fetch(
    `https://api.agora.io/api/conversational-ai-agent/v2/projects/${env.AGORA_APP_ID}/agents/${agentId}/leave`,
    {
      method: "POST",
      headers: {
        Authorization: `Basic ${basicAuth}`,
        "content-type": "application/json",
      },
    }
  );

  const agoraText = await agoraResponse.text();
  if (!agoraResponse.ok) {
    console.error(`[/agent/stop] Agora leave error ${agoraResponse.status}: ${agoraText}`);
    return new Response(agoraText, {
      status: agoraResponse.status,
      headers: { "content-type": "application/json" },
    });
  }

  return new Response(agoraText || "{}", {
    status: 200,
    headers: { "content-type": "application/json" },
  });
}

// ---------------------------------------------------------------------------
// Screen context: the app uploads its latest screenshot here on a timer while
// an Agora session is live. /agent/llm attaches it to the current LLM turn so
// the model can see the user's screen. No auth — single-user demo.
//
// Request body: { imageBase64, label, screenshotWidth, screenshotHeight,
//                 displayWidth, displayHeight }
// ---------------------------------------------------------------------------

async function handleAgentContext(request: Request, env: Env): Promise<Response> {
  const body = (await request.json()) as {
    imageBase64?: string;
    label?: string;
    screenshotWidth?: number;
    screenshotHeight?: number;
    displayWidth?: number;
    displayHeight?: number;
  };

  if (!body.imageBase64 || typeof body.screenshotWidth !== "number" || typeof body.screenshotHeight !== "number") {
    return new Response(
      JSON.stringify({ error: "imageBase64, screenshotWidth, and screenshotHeight are required" }),
      { status: 400, headers: { "content-type": "application/json" } }
    );
  }

  const frame: StoredScreenFrame = {
    imageBase64: body.imageBase64,
    label: body.label ?? "user's screen",
    screenshotWidth: body.screenshotWidth,
    screenshotHeight: body.screenshotHeight,
    displayWidth: body.displayWidth ?? body.screenshotWidth,
    displayHeight: body.displayHeight ?? body.screenshotHeight,
    capturedAtMs: Date.now(),
  };

  await screenStateStub(env).fetch("https://screen-state/frame", {
    method: "POST",
    body: JSON.stringify(frame),
  });

  console.log(
    `[/agent/context] stored frame: ${body.screenshotWidth}x${body.screenshotHeight}, ` +
    `${body.imageBase64.length} base64 chars, label="${body.label}"`
  );

  return new Response("{}", { status: 200, headers: { "content-type": "application/json" } });
}

// ---------------------------------------------------------------------------
// Pointing: the app polls this for the latest [POINT:...] tag parsed out of
// the LLM's answer stream. `id` increments on each new point so the app only
// animates when it sees a new one.
// ---------------------------------------------------------------------------

async function handleAgentPoint(env: Env): Promise<Response> {
  const response = await screenStateStub(env).fetch("https://screen-state/point");
  const pointText = await response.text();
  return new Response(pointText || JSON.stringify({ id: 0 }), {
    status: 200,
    headers: { "content-type": "application/json", "cache-control": "no-store" },
  });
}

// ---------------------------------------------------------------------------
// Reply text: the app polls this for the latest clean LLM reply so it can
// speak it locally via Murf REST. `id` increments on each new reply so the app
// only synthesizes each reply once.
// ---------------------------------------------------------------------------

async function handleAgentReply(env: Env): Promise<Response> {
  const response = await screenStateStub(env).fetch("https://screen-state/reply");
  const replyText = await response.text();
  return new Response(replyText || JSON.stringify({ id: 0 }), {
    status: 200,
    headers: { "content-type": "application/json", "cache-control": "no-store" },
  });
}

// ---------------------------------------------------------------------------
// Latest conversation exchange (user transcript + Unibit reply): the app polls
// this to render the on-screen conversation pill. `id` increments per exchange
// so the pill only renders each turn once.
// ---------------------------------------------------------------------------

async function handleAgentUtterance(env: Env): Promise<Response> {
  const response = await screenStateStub(env).fetch("https://screen-state/utterance");
  const utteranceText = await response.text();
  return new Response(utteranceText || JSON.stringify({ id: 0 }), {
    status: 200,
    headers: { "content-type": "application/json", "cache-control": "no-store" },
  });
}

// ---------------------------------------------------------------------------
// Custom LLM bridge (OpenAI-compatible) — called BY the Agora agent
// ---------------------------------------------------------------------------
//
// The Agora Conversational AI Engine POSTs an OpenAI Chat Completions request
// here on each conversation turn. We forward it to a LiteLLM proxy (which is
// OpenAI-compatible) and stream the response straight back to Agora, so Agora
// can feed the text to Murf TTS. No format translation needed — both sides
// already speak the OpenAI Chat Completions SSE protocol.
//
// Auth: Agora sends `Authorization: Bearer <AGENT_LLM_API_KEY>`.
// ---------------------------------------------------------------------------

/// The LiteLLM proxy the agent's LLM calls are forwarded to.
/// Must be HTTPS on a standard port — Cloudflare Workers block plain-HTTP
/// fetches to non-standard ports (error 1003).
const LITELLM_BASE_URL = "https://litellm.ai.karetech.co/v1";
const LITELLM_API_KEY = "sk-demo";
/// Model override — Agora sends its configured model, but we pin to the one
/// LiteLLM actually serves so a mismatched agent config can't break the call.
const LITELLM_MODEL = "global.moonshotai.kimi-k3";

/// JSON.stringify replacer that redacts image base64 payloads so the LLM-input
/// log line stays readable instead of dumping hundreds of KB of base64.
function redactImageBase64ForLogging(_key: string, value: unknown): unknown {
  if (typeof value === "string" && value.startsWith("data:image/") && value.length > 200) {
    return `[image data redacted — ${value.length} chars]`;
  }
  return value;
}

/// If a fresh uploaded screen frame exists, rewrites the last user message's
/// content into OpenAI's multi-part array form (text + image_url) so the vision
/// model sees the user's screen alongside the transcript. Mutates in place.
/// Returns true when a frame was attached (for logging).
function attachScreenFrameToLatestUserMessage(
  openAIRequest: { messages?: Array<{ role: string; content: unknown }> },
  frame: StoredScreenFrame | null
): boolean {
  if (!frame || Date.now() - frame.capturedAtMs > SCREEN_FRAME_MAX_AGE_MS) return false;

  const messages = openAIRequest.messages;
  if (!messages || messages.length === 0) return false;

  // Find the last user message — that's the transcript for the current turn.
  for (let messageIndex = messages.length - 1; messageIndex >= 0; messageIndex--) {
    const message = messages[messageIndex];
    if (message.role !== "user") continue;

    const originalText = typeof message.content === "string" ? message.content : "";
    const dimensionInfo = `[attached: user's screen — ${frame.label} (image dimensions: ${frame.screenshotWidth}x${frame.screenshotHeight} pixels)]`;
    // An empty transcript (Agora sometimes sends a turn with no user text) would
    // leave the text part blank, which some vision models handle poorly — give
    // the image a descriptive lead-in so the model knows the screen is attached.
    const textPart = originalText.trim().length > 0
      ? `${originalText}\n\n${dimensionInfo}`
      : `The user's current screen is attached. ${dimensionInfo}`;

    message.content = [
      { type: "text", text: textPart },
      { type: "image_url", image_url: { url: `data:image/jpeg;base64,${frame.imageBase64}` } },
    ];
    return true;
  }
  return false;
}

/// Extracts the plain-text transcript of the last user message (the current
/// turn) before any screenshot is attached. Used to stash the utterance so the
/// app's conversation pill can show what the user said. Returns "" when the
/// turn has no user text (e.g. the agent's greeting turn).
function extractLatestUserTranscriptText(
  openAIRequest: { messages?: Array<{ role: string; content: unknown }> }
): string {
  const messages = openAIRequest.messages;
  if (!messages || messages.length === 0) return "";
  for (let messageIndex = messages.length - 1; messageIndex >= 0; messageIndex--) {
    const message = messages[messageIndex];
    if (message.role !== "user") continue;
    return typeof message.content === "string" ? message.content.trim() : "";
  }
  return "";
}

async function handleAgentLLM(request: Request, env: Env): Promise<Response> {
  const authHeader = request.headers.get("authorization") ?? "";
  const expected = `Bearer ${env.AGENT_LLM_API_KEY}`;
  if (authHeader !== expected) {
    return new Response(JSON.stringify({ error: "unauthorized" }), {
      status: 401,
      headers: { "content-type": "application/json" },
    });
  }

  const openAIRequest = (await request.json()) as {
    model?: string;
    messages?: Array<{ role: string; content: unknown }>;
    stream?: boolean;
  };

  // Capture the user's spoken transcript BEFORE the screenshot attach rewrites
  // the message content into multi-part form. This is what the pill shows as
  // "you: …" for the current exchange.
  const latestUserTranscriptText = extractLatestUserTranscriptText(openAIRequest);

  // Attach the latest uploaded screenshot to the current turn so the model can
  // see the user's screen — but only when the frame is fresh (<15s old), so
  // general questions asked after the frame goes stale don't waste image tokens.
  // The frame lives in the Durable Object so it's shared across all isolates.
  const screenFrame = await getScreenFrame(env);
  const frameAttached = attachScreenFrameToLatestUserMessage(openAIRequest, screenFrame);

  // Log whether the frame made it in, so "the agent isn't seeing the screen"
  // is debuggable from the Worker logs alone.
  console.log(
    `[/agent/llm] turn: frame attached = ${frameAttached}, frame age ms = ${
      screenFrame ? Date.now() - screenFrame.capturedAtMs : "no frame"
    }`
  );

  // Log the exact LLM input Agora sends us each turn (system prompt + history
  // + latest user transcript) so we can debug the agent's behavior. The image
  // base64 is huge, so redact it before logging.
  console.log("[/agent/llm] LLM input:", JSON.stringify(openAIRequest, redactImageBase64ForLogging));

  // Forward to LiteLLM, forcing streaming + the correct model. Everything else
  // (messages, system prompt, history) passes through unchanged since LiteLLM
  // is OpenAI-compatible.
  const liteLLMBody = {
    ...openAIRequest,
    model: LITELLM_MODEL,
    stream: true,
  };

  const liteLLMResponse = await fetch(`${LITELLM_BASE_URL}/chat/completions`, {
    method: "POST",
    headers: {
      Authorization: `Bearer ${LITELLM_API_KEY}`,
      "content-type": "application/json",
    },
    body: JSON.stringify(liteLLMBody),
  });

  if (!liteLLMResponse.ok) {
    const errorBody = await liteLLMResponse.text();
    console.error(`[/agent/llm] LiteLLM error ${liteLLMResponse.status}: ${errorBody}`);
    return new Response(errorBody, {
      status: liteLLMResponse.status,
      headers: { "content-type": "application/json" },
    });
  }

  // kimi-k3 streams its chain-of-thought in `reasoning_content` deltas BEFORE
  // the actual answer in `content`. Agora's engine feeds BOTH to Murf, so the
  // agent would speak its thinking aloud. We filter the stream here and re-emit
  // a clean OpenAI SSE stream containing ONLY the `content` deltas.
  const { readable, writable } = new TransformStream();
  const writer = writable.getWriter();

  filterReasoningFromStream(liteLLMResponse, writer, env, latestUserTranscriptText).catch((error) => {
    console.error("[/agent/llm] stream filter error:", error);
  });

  return new Response(readable, {
    status: 200,
    headers: {
      "content-type": "text/event-stream",
      "cache-control": "no-cache",
    },
  });
}

/// Matches the same [POINT:x,y:label(:screenN)] tag the app parses. Anchored to
/// the end of the response — the system prompt tells the model to append it last.
const POINT_TAG_REGEX = /\[POINT:(?:none|(\d+)\s*,\s*(\d+)(?::([^\]:\s][^\]:]*?))?(?::screen(\d+))?)\]\s*$/;

/// Reads the OpenAI SSE stream from LiteLLM, accumulates the ENTIRE answer, and
/// emits it to Agora as ONE complete SSE chunk (then a stop chunk + [DONE]).
///
/// Why buffer instead of streaming through: Agora's TTS pipeline garbles
/// incrementally-streamed text from this endpoint (verified across many
/// chunking strategies — tiny deltas, clause chunks, sentence chunks all
/// produced the same "starts then skips" audio). Sending the full answer as a
/// single chunk makes Agora synthesize it in one clean pass, like a
/// non-streaming completion. Costs a little latency (we wait for the whole
/// answer) but guarantees smooth speech.
///
/// Also: drops `reasoning_content` so the chain-of-thought is never spoken,
/// strips the trailing [POINT:...] tag from the spoken text, and stashes the
/// parsed point in the ScreenState Durable Object for the app to poll.
async function filterReasoningFromStream(
  liteLLMResponse: Response,
  writer: WritableStreamDefaultWriter,
  env: Env,
  latestUserTranscriptText: string
): Promise<void> {
  const reader = liteLLMResponse.body?.getReader();
  const encoder = new TextEncoder();
  if (!reader) {
    await writer.write(encoder.encode("data: [DONE]\n\n"));
    await writer.close();
    return;
  }

  const decoder = new TextDecoder();
  let buffer = "";
  const streamStartMs = Date.now();

  /// The full accumulated answer text (reasoning excluded).
  let fullSpokenContent = "";

  const writeChunk = async (delta: Record<string, unknown>, finishReason: string | null) => {
    const chunk = {
      id: `chatcmpl-${crypto.randomUUID()}`,
      object: "chat.completion.chunk",
      created: Math.floor(Date.now() / 1000),
      model: LITELLM_MODEL,
      choices: [{ index: 0, delta, finish_reason: finishReason }],
    };
    await writer.write(encoder.encode(`data: ${JSON.stringify(chunk)}\n\n`));
  };

  /// After the stream ends: strip the [POINT] tag from the answer, stash any
  /// parsed point in the Durable Object, then emit the whole clean answer as
  /// one chunk so Agora TTS synthesizes it in a single pass.
  const emitFullAnswerAndCapturePoint = async () => {
    let spokenText = fullSpokenContent;
    const pointMatch = fullSpokenContent.match(POINT_TAG_REGEX);
    if (pointMatch) {
      // ALWAYS strip the tag ([POINT:none] included) so Murf never speaks it.
      spokenText = fullSpokenContent.replace(POINT_TAG_REGEX, "").trimEnd();

      // Only stash a point when the tag has coordinates (not [POINT:none]).
      if (pointMatch[1] !== undefined && pointMatch[2] !== undefined) {
        const frame = await getScreenFrame(env);
        const pointToStore = {
          x: parseInt(pointMatch[1], 10),
          y: parseInt(pointMatch[2], 10),
          label: pointMatch[3]?.trim() ?? null,
          screenshotWidth: frame?.screenshotWidth ?? 0,
          screenshotHeight: frame?.screenshotHeight ?? 0,
          displayWidth: frame?.displayWidth ?? 0,
          displayHeight: frame?.displayHeight ?? 0,
          createdAtMs: Date.now(),
        };
        const storeResponse = await screenStateStub(env).fetch("https://screen-state/point", {
          method: "POST",
          body: JSON.stringify(pointToStore),
        });
        const storedPoint = await storeResponse.text();
        console.log("[/agent/llm] captured point:", storedPoint);
      }
    }

    if (spokenText.length > 0) {
      // Stash the clean reply so the app can fetch + speak it locally via Murf
      // REST, bypassing Agora's garbling Murf stream-input bridge entirely.
      const storeReplyResponse = await screenStateStub(env).fetch("https://screen-state/reply", {
        method: "POST",
        body: JSON.stringify({ text: spokenText }),
      });
      const storedReply = await storeReplyResponse.text();
      console.log("[/agent/llm] stored reply:", storedReply);

      // Stash the full exchange (user transcript + reply) so the app's
      // conversation pill can render both sides of the turn. Skip the agent's
      // greeting turn, which arrives with an empty user transcript.
      if (latestUserTranscriptText.length > 0) {
        const storeUtteranceResponse = await screenStateStub(env).fetch("https://screen-state/utterance", {
          method: "POST",
          body: JSON.stringify({ userText: latestUserTranscriptText, replyText: spokenText }),
        });
        const storedUtterance = await storeUtteranceResponse.text();
        console.log("[/agent/llm] stored utterance:", storedUtterance);
      }

      // Single complete chunk: role first, then the full content, then stop.
      await writeChunk({ role: "assistant", content: spokenText }, null);
    }
  };

  try {
    while (true) {
      const { done, value } = await reader.read();
      if (done) break;
      buffer += decoder.decode(value, { stream: true });

      let eventBoundary: number;
      while ((eventBoundary = buffer.indexOf("\n\n")) !== -1) {
        const rawEvent = buffer.slice(0, eventBoundary);
        buffer = buffer.slice(eventBoundary + 2);

        const dataText = rawEvent
          .split("\n")
          .filter((line) => line.startsWith("data:"))
          .map((line) => line.slice(5).trim())
          .join("\n");
        if (!dataText || dataText === "[DONE]") continue;

        let parsed: { choices?: Array<{ delta?: Record<string, unknown>; finish_reason?: string | null }> };
        try {
          parsed = JSON.parse(dataText);
        } catch {
          continue;
        }

        const choice = parsed.choices?.[0];
        const delta = choice?.delta ?? {};

        // Accumulate ONLY spoken content. Drop reasoning_content / thinking_blocks /
        // provider_specific_fields so Agora's TTS never reads the chain-of-thought.
        if (typeof delta.content === "string" && delta.content.length > 0) {
          fullSpokenContent += delta.content;
        }
      }
    }

    await emitFullAnswerAndCapturePoint();
    await writeChunk({}, "stop");
    await writer.write(encoder.encode("data: [DONE]\n\n"));

    console.log(
      `[/agent/llm] buffered full answer: ${fullSpokenContent.length} chars in ${Date.now() - streamStartMs}ms`
    );
  } finally {
    await writer.close().catch(() => {});
  }
}

// ---------------------------------------------------------------------------
// Agora RTC token generation (AccessToken2, service RTC)
// ---------------------------------------------------------------------------
//
// Faithful port of Agora's official Node.js reference implementation
// (AgoraIO/Tools → AccessToken2.js / RtcTokenBuilder2.js). Token007 structure:
//
//   signing = HMAC(HMAC(uint32(issueTs), appCert), uint32(salt))   ← 2-step key
//   signing_info = putString(appId) + issueTs + expire + salt
//                  + serviceCount + service.pack()...
//   signature = HMAC(signing, signing_info)
//   content = putString(signature) + signing_info
//   token = "007" + base64(zlib.deflate(content))
//
// The RTC service packs its privileges as a tree-map and the uid as a STRING.
// A PUBLISHER token needs join + publish-audio/video/data privileges.
// ---------------------------------------------------------------------------

// pako is a direct port of zlib and produces byte-identical deflate output to
// Node's zlib.deflateSync, which Agora's token verification requires. (fflate
// uses a different compression strategy and yields different bytes.)
import { deflate as deflateSync } from "pako";

const RTC_TOKEN_VERSION = "007";
const RTC_SERVICE_TYPE = 1;
const PRIVILEGE_JOIN_CHANNEL = 1;
const PRIVILEGE_PUBLISH_AUDIO = 2;
const PRIVILEGE_PUBLISH_VIDEO = 3;
const PRIVILEGE_PUBLISH_DATA = 4;
const TOKEN_EXPIRE_SECONDS = 24 * 60 * 60; // 24h

async function generateAgoraRtcToken(
  appId: string,
  appCertificate: string,
  channelName: string,
  uid: number
): Promise<string> {
  const issueTs = Math.floor(Date.now() / 1000);
  const expire = issueTs + TOKEN_EXPIRE_SECONDS;
  // Salt range per the reference: (1, 99999999)
  const salt = Math.floor(Math.random() * 99999999) + 1;

  // --- signing key derivation (2-step, key FIRST) ---
  //   step1 = HMAC(key = uint32(issueTs), message = appCertificate)
  //   signingKey = HMAC(key = uint32(salt), message = step1)
  const step1 = await hmacSha256(packUint32(issueTs), stringToBytes(appCertificate));
  const signingKey = await hmacSha256(packUint32(salt), step1);

  // --- RTC service payload ---
  const servicePayload = concatBytes([
    packUint16(RTC_SERVICE_TYPE),
    packTreeMapUInt32({
      [PRIVILEGE_JOIN_CHANNEL]: expire,
      [PRIVILEGE_PUBLISH_AUDIO]: expire,
      [PRIVILEGE_PUBLISH_VIDEO]: expire,
      [PRIVILEGE_PUBLISH_DATA]: expire,
    }),
    packString(channelName),
    packString(String(uid)), // uid is packed as a string
  ]);

  // --- signing_info ---
  const signingInfo = concatBytes([
    packString(appId),
    packUint32(issueTs),
    packUint32(expire),
    packUint32(salt),
    packUint16(1), // service count
    servicePayload,
  ]);

  const signature = await hmacSha256(signingKey, signingInfo);

  // --- content = putString(signature) + signing_info, then deflate + base64 ---
  const content = concatBytes([packBytes(signature), signingInfo]);
  const compressed = deflateSync(content);
  return RTC_TOKEN_VERSION + base64Encode(compressed);
}

async function hmacSha256(keyBytes: Uint8Array, data: Uint8Array): Promise<Uint8Array> {
  const key = await crypto.subtle.importKey(
    "raw",
    keyBytes as BufferSource,
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign"]
  );
  const signature = await crypto.subtle.sign("HMAC", key, data as BufferSource);
  return new Uint8Array(signature);
}

// --- packing helpers (little-endian, matching Agora's reference implementation) ---

function packUint16(value: number): Uint8Array {
  const bytes = new Uint8Array(2);
  bytes[0] = value & 0xff;
  bytes[1] = (value >> 8) & 0xff;
  return bytes;
}

function packUint32(value: number): Uint8Array {
  const bytes = new Uint8Array(4);
  bytes[0] = value & 0xff;
  bytes[1] = (value >> 8) & 0xff;
  bytes[2] = (value >> 16) & 0xff;
  bytes[3] = (value >> 24) & 0xff;
  return bytes;
}

function packBytes(bytes: Uint8Array): Uint8Array {
  const out = new Uint8Array(2 + bytes.length);
  out.set(packUint16(bytes.length), 0);
  out.set(bytes, 2);
  return out;
}

function packString(value: string): Uint8Array {
  return packBytes(stringToBytes(value));
}

/// Packs a privilege map as a tree-map: uint16 count, then for each entry a
/// uint16 privilege id + uint32 expiry, in ascending key order.
function packTreeMapUInt32(map: Record<number, number>): Uint8Array {
  const keys = Object.keys(map)
    .map(Number)
    .sort((a, b) => a - b);
  const parts: Uint8Array[] = [packUint16(keys.length)];
  for (const key of keys) {
    parts.push(packUint16(key));
    parts.push(packUint32(map[key]));
  }
  return concatBytes(parts);
}

function stringToBytes(value: string): Uint8Array {
  return new TextEncoder().encode(value);
}

function concatBytes(parts: Uint8Array[]): Uint8Array {
  const totalLength = parts.reduce((sum, part) => sum + part.length, 0);
  const out = new Uint8Array(totalLength);
  let offset = 0;
  for (const part of parts) {
    out.set(part, offset);
    offset += part.length;
  }
  return out;
}

function base64Encode(bytes: Uint8Array): string {
  let binary = "";
  for (let i = 0; i < bytes.length; i++) binary += String.fromCharCode(bytes[i]);
  return btoa(binary);
}
