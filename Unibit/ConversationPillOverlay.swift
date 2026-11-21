//
//  ConversationPillOverlay.swift
//  Unibit
//
//  A Dynamic Island–style pill that drops from the top-center of the cursor's
//  screen while an Agora conversation turn is live. Shows the live exchange —
//  what the user said and what Unibit replied — then retracts after the reply
//  finishes speaking. Uses the same non-activating NSPanel pattern as
//  CompanionResponseOverlayManager so it floats above all apps without
//  stealing focus.
//

import AppKit
import Combine
import SwiftUI

// MARK: - View Model

@MainActor
final class ConversationPillViewModel: ObservableObject {
    /// What the user said on the current turn (from the agent's ASR transcript).
    @Published var userText: String = ""
    /// What Unibit replied on the current turn.
    @Published var replyText: String = ""
    /// Whether the pill is currently shown (drives the slide/fade animation).
    @Published var isPresented: Bool = false
    /// Whether the mic is live (user is holding the hotkey) — shows a "Listening…" state.
    @Published var isListening: Bool = false
    /// The measured height of the pill's content, reported up from SwiftUI so the
    /// panel can size itself to fit while staying pinned to the top edge.
    @Published var contentHeight: CGFloat = 44
}

// MARK: - Overlay Manager

@MainActor
final class ConversationPillOverlayManager {
    let viewModel = ConversationPillViewModel()
    private var pillPanel: NSPanel?
    private var hostingView: NSHostingView<ConversationPillView>?
    private var autoHideWorkItem: DispatchWorkItem?
    /// Fires when the pill's content height changes so the panel can grow/shrink
    /// while staying pinned to the top edge.
    private var contentHeightCancellable: AnyCancellable?

    /// The pill's fixed width — wide and bar-like, pinned to the top edge rather
    /// than hugging its (variable) content width.
    private let pillWidth: CGFloat = 600
    /// Distance from the top edge of the screen to the top of the pill.
    private let topEdgeInset: CGFloat = 14

    /// Drops the pill down and marks it as listening (user is holding the hotkey).
    func presentListening() {
        autoHideWorkItem?.cancel()
        autoHideWorkItem = nil
        // Start a fresh exchange: clear the previous turn's text.
        viewModel.userText = ""
        viewModel.replyText = ""
        viewModel.isListening = true
        presentPanel()
    }

    /// Marks listening as over (user released the hotkey) while the agent thinks.
    func endListening() {
        viewModel.isListening = false
    }

    /// Updates the pill with the latest exchange from the worker.
    func showExchange(userText: String, replyText: String) {
        autoHideWorkItem?.cancel()
        autoHideWorkItem = nil
        viewModel.isListening = false
        viewModel.userText = userText
        viewModel.replyText = replyText
        presentPanel()
    }

    /// Retracts the pill after a short delay, giving the user a beat to read the
    /// tail of the reply. Called when Unibit's reply finishes speaking.
    func scheduleHideAfterReply(afterSeconds delay: TimeInterval = 1.0) {
        autoHideWorkItem?.cancel()
        let hideWork = DispatchWorkItem { [weak self] in
            self?.hidePanel()
        }
        autoHideWorkItem = hideWork
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: hideWork)
    }

    /// Immediately retracts and clears the pill (e.g. when the session ends).
    func hideImmediately() {
        autoHideWorkItem?.cancel()
        autoHideWorkItem = nil
        viewModel.isPresented = false
        pillPanel?.orderOut(nil)
    }

    // MARK: - Private

    private func presentPanel() {
        createPanelIfNeeded()
        updatePanelFrame(animated: false)
        pillPanel?.orderFrontRegardless()
        // Animate the drop-in only on the first presentation of this turn.
        if !viewModel.isPresented {
            viewModel.isPresented = true
        }
    }

    private func createPanelIfNeeded() {
        if pillPanel != nil { return }

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: pillWidth, height: 60),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.isExcludedFromWindowsMenu = true

        let hostingView = NSHostingView(
            rootView: ConversationPillView(viewModel: viewModel, pillWidth: pillWidth)
        )
        // The content is top-aligned, so the panel's height tracks the content
        // and the SwiftUI view must be allowed to size to that height.
        hostingView.autoresizingMask = [.width]
        panel.contentView = hostingView
        self.hostingView = hostingView

        // Re-pin the panel to the top edge whenever the content height changes
        // (listening → exchange → taller reply), so the bar grows downward from
        // a fixed top anchor instead of drifting toward the middle of the screen.
        contentHeightCancellable = viewModel.$contentHeight
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.updatePanelFrame(animated: true)
            }

        pillPanel = panel
    }

    /// Pins the panel's TOP edge to the top of the cursor's screen and sizes the
    /// panel to the content height. The top edge is the fixed anchor: x centers
    /// horizontally, y is derived from (screenTop - inset - height) so the bar
    /// always hangs from the top of the screen no matter how tall the content is.
    private func updatePanelFrame(animated: Bool) {
        guard let pillPanel else { return }

        let mouseLocation = NSEvent.mouseLocation
        let targetScreen = NSScreen.screens.first(where: { $0.frame.contains(mouseLocation) })
            ?? NSScreen.main
        guard let screenFrame = targetScreen?.frame else { return }

        let contentHeight = max(viewModel.contentHeight, 44)
        let originX = screenFrame.midX - pillWidth / 2
        // AppKit Y increases upward, so the screen's TOP edge is maxY. Anchor the
        // panel's top to (maxY - inset); origin.y is the panel's bottom-left, so
        // subtract the full content height to drop the top edge into place.
        let originY = screenFrame.maxY - topEdgeInset - contentHeight
        let targetFrame = NSRect(x: originX, y: originY, width: pillWidth, height: contentHeight)

        if animated {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.25
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                pillPanel.animator().setFrame(targetFrame, display: true)
            }
        } else {
            pillPanel.setFrame(targetFrame, display: true)
        }
    }

    private func hidePanel() {
        viewModel.isPresented = false
        // Let the SwiftUI slide/fade-out animation play before removing the panel.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            self?.pillPanel?.orderOut(nil)
        }
    }
}

// MARK: - SwiftUI View

/// Preference key that carries the pill content's measured height up to the
/// manager so the panel can size itself to fit the content.
private struct PillContentHeightPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = 44
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

private struct ConversationPillView: View {
    @ObservedObject var viewModel: ConversationPillViewModel
    /// The panel's fixed width. The root view pins itself to this width so the
    /// capsule is always a wide top-bar instead of collapsing to the text width.
    let pillWidth: CGFloat

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if viewModel.isListening && viewModel.userText.isEmpty {
                listeningRow
            }
            if !viewModel.userText.isEmpty {
                exchangeRow(label: "you", text: viewModel.userText, isUser: true)
            }
            if !viewModel.replyText.isEmpty {
                exchangeRow(label: "unibit", text: viewModel.replyText, isUser: false)
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        // Pin the root to the panel's exact width so the capsule spans the full
        // bar no matter how short the text is.
        .frame(width: pillWidth, alignment: .leading)
        .background(
            GeometryReader { geometry in
                Capsule(style: .continuous)
                    .fill(DS.Colors.surface1.opacity(0.96))
                    .overlay(
                        Capsule(style: .continuous)
                            .stroke(DS.Colors.borderSubtle.opacity(0.6), lineWidth: 0.8)
                    )
                    .shadow(color: Color.black.opacity(0.4), radius: 20, x: 0, y: 10)
                    // Report the capsule's actual height up to the manager.
                    .preference(key: PillContentHeightPreferenceKey.self, value: geometry.size.height)
            }
        )
        .onPreferenceChange(PillContentHeightPreferenceKey.self) { measuredHeight in
            viewModel.contentHeight = measuredHeight
        }
        // Drop down from the top edge of the screen, with a spring, and fade.
        .offset(y: viewModel.isPresented ? 0 : -120)
        .opacity(viewModel.isPresented ? 1 : 0)
        .animation(.spring(response: 0.45, dampingFraction: 0.8), value: viewModel.isPresented)
        .animation(.easeInOut(duration: 0.2), value: viewModel.isListening)
    }

    private var listeningRow: some View {
        HStack(spacing: 8) {
            ListeningDotsView()
            Text("listening…")
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(DS.Colors.textSecondary)
        }
    }

    private func exchangeRow(label: String, text: String, isUser: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(isUser ? DS.Colors.textTertiary : DS.Colors.accentText)
                .frame(width: 44, alignment: .trailing)
            Text(text)
                .font(.system(size: 13, weight: .regular))
                .foregroundColor(DS.Colors.textPrimary)
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

// MARK: - Listening indicator

/// Three amber dots that pulse in sequence while the mic is live — a compact,
/// calm "we hear you" cue that fits the pill.
private struct ListeningDotsView: View {
    @State private var animating = false

    var body: some View {
        HStack(spacing: 4) {
            ForEach(0..<3, id: \.self) { dotIndex in
                Circle()
                    .fill(DS.Colors.accentText)
                    .frame(width: 5, height: 5)
                    .scaleEffect(animating ? 1 : 0.5)
                    .opacity(animating ? 1 : 0.4)
                    .animation(
                        .easeInOut(duration: 0.6)
                            .repeatForever(autoreverses: true)
                            .delay(Double(dotIndex) * 0.18),
                        value: animating
                    )
            }
        }
        .onAppear { animating = true }
    }
}
