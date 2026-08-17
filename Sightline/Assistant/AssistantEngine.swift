import Foundation
import CoreLocation
import SwiftUI

/// Per-message provenance the chat surfaces: grounded answers show their tool.
enum AssistantMessageBadge: Equatable {
    case groundedSearch
    case groundedMaps

    var label: String {
        switch self {
        case .groundedSearch: return "Grounded · Google Search"
        case .groundedMaps:   return "Grounded · Google Maps"
        }
    }

    var symbolName: String { "checkmark.seal" }
}

/// Per-place guide: Gemini flash-lite streamed over SSE with a live Search/Maps tool; failures surface as an error row, never a substitute answer.
@MainActor
final class AssistantEngine: ObservableObject {

    /// Hard cap on one user message, enforced here and in the input field.
    static let maxInputLength = 2000

    /// Published: rich fields land after the sheet is up, refreshing the quick chips and every later prompt.
    @Published private(set) var place: Place
    @Published private(set) var messages: [ChatMessage] = []
    @Published private(set) var isThinking: Bool = false
    /// Non-nil after a failed reply; stays out of `messages` so error copy never enters the Gemini turn history.
    @Published private(set) var lastErrorText: String?
    @Published private(set) var badges: [UUID: AssistantMessageBadge] = [:]

    private(set) var userLocation: CLLocation?
    private var streamTask: Task<Void, Never>?
    private var detailsTask: Task<Void, Never>?

    init(place: Place, userLocation: CLLocation?) {
        self.place = place
        self.userLocation = userLocation
        self.messages = [ChatMessage(role: .assistant, text: AssistantScript.greeting(for: place))]
        loadDetails()
    }

    /// Prompt context uses details when loaded; while absent, every context line already reads "unknown" — never an invention.
    private func loadDetails() {
        detailsTask = Task { [weak self] in
            // Always ask: the service cache makes a repeat lookup free, and a past transient failure gets retried here.
            guard let id = self?.place.id,
                  let details = try? await GooglePlacesService.shared.placeDetails(id: id) else { return }
            self?.place.details = details
        }
    }

    var quickQuestions: [String] {
        AssistantScript.quickQuestions(for: place, userLocation: userLocation)
    }

    func badge(for message: ChatMessage) -> AssistantMessageBadge? {
        badges[message.id]
    }

    func send(_ text: String, freshLocation: CLLocation? = nil) {
        // The location snapshot from sheet presentation goes stale while the sheet stays up — refresh per send.
        if let freshLocation { userLocation = freshLocation }
        let trimmed = String(text.trimmingCharacters(in: .whitespacesAndNewlines)
            .prefix(Self.maxInputLength))
        guard !trimmed.isEmpty else { return }
        guard !isThinking else { return }

        finalizeStream()
        lastErrorText = nil
        messages.append(ChatMessage(role: .user, text: trimmed))
        isThinking = true

        streamTask = Task { [weak self] in
            await self?.respond(to: trimmed)
        }
    }

    /// Stops in-flight generation; call on sheet dismissal so a pending Gemini request can't land into a closed chat.
    func cancelStreaming() {
        finalizeStream()
    }

    // MARK: - Generation

    private func respond(to question: String) async {
        let grounding = AssistantPrompt.groundingTool(for: place, userLocation: userLocation)
        let instruction = AssistantPrompt.systemInstruction(for: place, userLocation: userLocation,
                                                            grounding: grounding)
        // The chat so far, greeting included — the just-appended user turn is the last entry.
        // Error copy lives in lastErrorText, not messages, so Places-derived text reaches Gemini only inside the PLACE_DATA fence.
        let turns = messages.suffix(12).map {
            GeminiService.Turn(fromUser: $0.role == .user, text: $0.text)
        }

        var raw = ""
        var index: Int?
        var grounded = false
        do {
            for try await event in GeminiService.shared.streamReply(
                systemInstruction: instruction, turns: Array(turns), grounding: grounding) {
                if Task.isCancelled { return }
                switch event {
                case .text(let delta):
                    raw += delta
                    if index == nil {
                        messages.append(ChatMessage(role: .assistant, text: ""))
                        index = messages.count - 1
                        isThinking = false
                    }
                    if let index, messages.indices.contains(index) {
                        // Sanitizing the accumulated text keeps a "**" split across two chunks from surviving.
                        messages[index].text = GeminiService.displayText(raw)
                    }
                case .grounded:
                    grounded = true
                }
                if grounded, let index, messages.indices.contains(index) {
                    badges[messages[index].id] = groundedBadge(for: grounding)
                }
            }
        } catch {
            // Partial text already on screen stays as-is; replaying a second answer would be worse.
            if index == nil, !Task.isCancelled {
                lastErrorText = ScanFailurePolicy.classify(error) == .offline
                    ? "You're offline. Reconnect to ask the guide."
                    : "The AI guide couldn't answer. Try again in a moment."
            }
        }
        if !Task.isCancelled {
            streamTask = nil
            isThinking = false
        }
    }

    private func groundedBadge(for tool: GeminiService.GroundingTool) -> AssistantMessageBadge {
        switch tool {
        case .googleSearch: return .groundedSearch
        case .googleMaps:   return .groundedMaps
        }
    }

    /// Cancels any in-flight stream; with real streaming the shown text is everything received, so nothing needs snapping.
    private func finalizeStream() {
        streamTask?.cancel()
        streamTask = nil
        isThinking = false
    }
}
