import SwiftUI
import CoreLocation

/// Chat sheet for the local AI guide — RootView owns the detents; this view only sets the drag indicator.
struct AssistantView: View {

    @StateObject private var engine: AssistantEngine
    // Sheets inherit the root environment; used only to read a fresh location fix at send time.
    @EnvironmentObject private var app: AppState
    @State private var draft = ""
    @FocusState private var inputFocused: Bool

    init(place: Place, userLocation: CLLocation?) {
        _engine = StateObject(wrappedValue: AssistantEngine(place: place, userLocation: userLocation))
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(Theme.hairline)
            messagesArea
            if engine.messages.count <= 2 {
                quickChips
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
            inputBar
        }
        .animation(Theme.Motion.standard, value: engine.messages.count <= 2)
        .background(Theme.sheetBackground.ignoresSafeArea())
        .preferredColorScheme(.dark)
        .presentationDragIndicator(.visible)
        .onDisappear { engine.cancelStreaming() }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 12) {
            CategoryBadge(category: engine.place.category, size: 40, silhouette: .rounded)

            VStack(alignment: .leading, spacing: 2) {
                Text(engine.place.name)
                    .font(Theme.Typography.cardTitle)
                    .lineLimit(1)
                HStack(spacing: 5) {
                    Image(systemName: "sparkles")
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.accent)
                    Text("AI guide · Apple Intelligence")
                        .font(Theme.Typography.meta)
                        .foregroundStyle(Theme.accent)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(16)
    }

    // MARK: - Messages

    private var messagesArea: some View {
        GeometryReader { geo in
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 10) {
                        ForEach(engine.messages) { message in
                            AssistantMessageBubble(message: message,
                                                   containerWidth: geo.size.width)
                                .id(message.id)
                        }
                        if engine.isThinking {
                            AssistantThinkingBubble()
                        }
                        if let errorText = engine.lastErrorText {
                            AssistantErrorRow(text: errorText)
                        }
                        Color.clear.frame(height: 1).id("bottom")
                    }
                    .padding(.horizontal, 14)
                    .padding(.top, 12)
                    .padding(.bottom, 6)
                }
                .scrollDismissesKeyboard(.interactively)
                .onChange(of: engine.messages.count) {
                    scrollToBottom(proxy)
                }
                .onChange(of: engine.messages.last?.text) {
                    scrollToBottom(proxy)
                }
                .onChange(of: engine.isThinking) {
                    scrollToBottom(proxy)
                }
                .onChange(of: engine.lastErrorText) {
                    scrollToBottom(proxy)
                }
            }
        }
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy) {
        withAnimation(.easeOut(duration: 0.2)) {
            proxy.scrollTo("bottom", anchor: .bottom)
        }
    }

    // MARK: - Quick questions

    private var quickChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(AssistantPrompt.quickQuestions, id: \.self) { question in
                    Button {
                        Haptics.light()
                        engine.send(question, freshLocation: currentLocation)
                    } label: {
                        Text(question)
                            .font(Theme.Typography.meta)
                            .foregroundStyle(Theme.textPrimary)
                            .padding(.horizontal, Theme.Space.m)
                            .padding(.vertical, Theme.Space.s)
                            .glassCapsule(elevation: .none)
                            .overlay(
                                Capsule().strokeBorder(Theme.accent.opacity(0.4), lineWidth: 1)
                            )
                    }
                    .buttonStyle(.plain)
                    .disabled(engine.isThinking || !engine.isAvailable)
                    .opacity(engine.isThinking || !engine.isAvailable ? 0.4 : 1)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
        }
    }

    // MARK: - Input bar

    private var inputBar: some View {
        HStack(spacing: 10) {
            TextField("Ask about this place…", text: $draft)
                .font(Theme.Typography.body)
                .focused($inputFocused)
                .submitLabel(.send)
                .onSubmit(sendDraft)
                .onChange(of: draft) { _, newValue in
                    // Same cap the engine enforces — trimming here keeps the field honest about what will be sent.
                    if newValue.count > AssistantEngine.maxInputLength {
                        draft = String(newValue.prefix(AssistantEngine.maxInputLength))
                    }
                }
                .padding(.horizontal, Theme.Space.l)
                .frame(height: 44)
                .glassCapsule(elevation: .none)

            Button(action: sendDraft) {
                Image(systemName: "arrow.up")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 38, height: 38)
                    .background(Theme.accentGradient, in: Circle())
            }
            .buttonStyle(.plain)
            .disabled(isSendDisabled)
            .opacity(isSendDisabled ? 0.4 : 1)
            .animation(.easeOut(duration: 0.15), value: isSendDisabled)
        }
        .padding(12)
        .background(.ultraThinMaterial)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(Theme.hairline)
                .frame(height: 1)
        }
    }

    private var isSendDisabled: Bool {
        draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || engine.isThinking || !engine.isAvailable
    }

    private var currentLocation: CLLocation? {
        app.pose.pose.location
    }

    private func sendDraft() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !engine.isThinking else { return }
        Haptics.light()
        engine.send(text, freshLocation: currentLocation)
        draft = ""
    }
}

// MARK: - Message bubble

private struct AssistantMessageBubble: View {
    let message: ChatMessage
    let containerWidth: CGFloat

    private var isUser: Bool { message.role == .user }

    var body: some View {
        HStack(spacing: 0) {
            if isUser { Spacer(minLength: 0) }
            VStack(alignment: .leading, spacing: 4) {
                Text(message.text)
                    .font(Theme.Typography.body)
                    .foregroundStyle(isUser ? Color.white : Color.primary)
                    .textSelection(.enabled)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background {
                        if isUser {
                            RoundedRectangle(cornerRadius: Theme.Radius.pill, style: .continuous)
                                .fill(Theme.accentGradient)
                        } else {
                            RoundedRectangle(cornerRadius: Theme.Radius.pill, style: .continuous)
                                .fill(.ultraThinMaterial)
                                .overlay(
                                    RoundedRectangle(cornerRadius: Theme.Radius.pill, style: .continuous)
                                        .strokeBorder(Theme.hairline, lineWidth: 1)
                                )
                        }
                    }
            }
            .frame(maxWidth: containerWidth * (isUser ? 0.78 : 0.85),
                   alignment: isUser ? .trailing : .leading)
            if !isUser { Spacer(minLength: 0) }
        }
    }
}

// MARK: - Error row

/// A failed reply renders as a warning row, visibly not an answer bubble — there is no substitute responder.
private struct AssistantErrorRow: View {
    let text: String

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 11))
            Text(text)
                .font(Theme.Typography.meta)
        }
        .foregroundStyle(Theme.warning)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 6)
        .padding(.top, 2)
    }
}

// MARK: - Thinking indicator

private struct AssistantThinkingBubble: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var animating = false

    var body: some View {
        HStack(spacing: 0) {
            HStack(spacing: 5) {
                ForEach(0..<3, id: \.self) { index in
                    Circle()
                        .fill(Theme.textSecondary)
                        .frame(width: 6, height: 6)
                        .scaleEffect(animating ? 1.0 : 0.6)
                        .animation(
                            Theme.Motion.gated(
                                .easeInOut(duration: 0.45)
                                    .repeatForever(autoreverses: true)
                                    .delay(Double(index) * 0.15),
                                reduceMotion: reduceMotion),
                            value: animating
                        )
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .background {
                RoundedRectangle(cornerRadius: Theme.Radius.pill, style: .continuous)
                    .fill(.ultraThinMaterial)
                    .overlay(
                        RoundedRectangle(cornerRadius: Theme.Radius.pill, style: .continuous)
                            .strokeBorder(Theme.hairline, lineWidth: 1)
                    )
            }
            Spacer(minLength: 0)
        }
        // Reduce Motion parks the dots at full size rather than looping them forever.
        .onAppear { animating = true }
    }
}
