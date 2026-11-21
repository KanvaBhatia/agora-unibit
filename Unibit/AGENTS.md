# AGENTS.md - Unibit (Main App Target)

This directory holds the Swift source for the macOS app target. For the full
architecture, key-files table, build/run steps, and coding conventions, see the
**root `AGENTS.md`** (`../AGENTS.md`) — it is the single source of truth for all
agents working in this repo (`CLAUDE.md` is a symlink to it).

## Quick orientation

- **Entry point** — `UnibitApp.swift`: menu bar-only app (`LSUIElement`), creates
  `MenuBarPanelManager` and `CompanionManager`. No dock icon, no main window.
- **Central state machine** — `CompanionManager.swift`: routes the hotkey to the
  Agora agent session (default) or the legacy push-to-talk pipeline, and owns the
  conversation pill, screen-context upload, point/reply/turn pollers, and TTS.
- **Two UI overlay windows** (both non-activating `NSPanel`s):
  - `OverlayWindow.swift` — full-screen transparent overlay hosting the amber
    companion cursor, response text, and pointing animations.
  - `ConversationPillOverlay.swift` — the Dynamic Island–style pill that drops
    from the top-center during an Agora turn.
- **Voice backends** — `AgoraVoiceClient.swift` + `AgoraAgentSessionClient.swift`
  (agent path); `BuddyDictationManager.swift` + the `*TranscriptionProvider.swift`
  files (legacy path).

## Conventions specific to this target

- SwiftUI for all UI; AppKit `NSPanel` bridged via `NSHostingView` for floating
  windows. All state updates on `@MainActor`; async/await throughout.
- New `.swift` files added to this directory are picked up automatically — the
  Xcode project uses file-system-synchronized groups, so no project-file edits
  are needed when adding a source file.
- **Do NOT run `xcodebuild` from the terminal** — it invalidates TCC permissions.
  Build and run from Xcode (Cmd+R).
