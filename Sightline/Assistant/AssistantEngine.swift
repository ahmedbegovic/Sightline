import Foundation
import CoreLocation
import FoundationModels
import SwiftUI

/// Per-place guide on Apple's on-device model. The session keeps the conversation; failures surface as an error row, never a substitute answer.
@MainActor
final class AssistantEngine: ObservableObject {

    /// Hard cap on one user message, enforced here and in the input field.
    static let maxInputLength = 2000

    /// Published: Google fields land after the sheet is up and feed the session's instructions.
    @Published private(set) var place: Place
    @Published private(set) var messages: [ChatMessage] = []
    @Published private(set) var isThinking: Bool = false
    /// Non-nil after a failed reply, or up front when the model can't run on this device.
    @Published private(set) var lastErrorText: String?

    private(set) var userLocation: CLLocation?
    private let model = SystemLanguageModel.default
    // ponytail: instructions are frozen when the session starts; details landing after the first question are not seen. Rebuild with the transcript if that matters.
    private var session: LanguageModelSession?
    private var streamTask: Task<Void, Never>?

    init(place: Place, userLocation: CLLocation?) {
        self.place = place
        self.userLocation = userLocation
        self.messages = [ChatMessage(role: .assistant, text: AssistantPrompt.greeting)]
        self.lastErrorText = Self.unavailableText(model.availability)
        loadDetails()
    }

    var isAvailable: Bool { model.availability == .available }

    private func loadDetails() {
        guard place.isLocated, place.details == nil else { return }
        Task { [weak self] in
            // The service cache makes this free when the card already fetched it.
            guard let place = self?.place,
                  let details = try? await GooglePlacesService.shared.details(for: place) else { return }
            self?.place.details = details
        }
    }

    func send(_ text: String, freshLocation: CLLocation? = nil) {
        if let freshLocation { userLocation = freshLocation }
        let trimmed = String(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(Self.maxInputLength))
        guard !trimmed.isEmpty, !isThinking else { return }
        if let unavailable = Self.unavailableText(model.availability) {
            lastErrorText = unavailable
            return
        }

        lastErrorText = nil
        messages.append(ChatMessage(role: .user, text: trimmed))
        isThinking = true
        streamTask = Task { [weak self] in await self?.respond(to: trimmed) }
    }

    /// Stops in-flight generation; call on sheet dismissal so a pending reply can't land into a closed chat.
    func cancelStreaming() {
        streamTask?.cancel()
        streamTask = nil
        isThinking = false
    }

    // MARK: - Generation

    private func respond(to question: String) async {
        let startsSession = session == nil
        let photo = place.snapshot.flatMap { model.capabilities.contains(.vision) ? $0 : nil }
        let session = self.session ?? LanguageModelSession(
            model: model,
            instructions: AssistantPrompt.instructions(for: place, userLocation: userLocation,
                                                       hasPhoto: photo != nil))
        self.session = session

        var index: Int?
        do {
            // The camera frame rides along once; the session transcript carries it for later turns.
            let stream: LanguageModelSession.ResponseStream<String>
            if startsSession, let photo {
                stream = session.streamResponse {
                    Attachment(photo)
                    question
                }
            } else {
                stream = session.streamResponse(to: question)
            }
            for try await snapshot in stream {
                if Task.isCancelled { return }
                if index == nil {
                    messages.append(ChatMessage(role: .assistant, text: ""))
                    index = messages.count - 1
                    isThinking = false
                }
                if let index, messages.indices.contains(index) {
                    messages[index].text = AssistantPrompt.displayText(snapshot.content)
                }
            }
        } catch {
            // A full context window can't recover; the next question starts a fresh session.
            if case .contextSizeExceeded = error as? LanguageModelError { self.session = nil }
            // Partial text already on screen stays as-is.
            if index == nil, !Task.isCancelled { lastErrorText = Self.errorText(error) }
        }
        if !Task.isCancelled {
            streamTask = nil
            isThinking = false
        }
    }

    // MARK: - Copy

    static func unavailableText(_ availability: SystemLanguageModel.Availability) -> String? {
        switch availability {
        case .available:
            return nil
        case .unavailable(let reason):
            switch reason {
            case .deviceNotEligible: return "This device can't run Apple Intelligence, so the AI guide is off."
            case .appleIntelligenceNotEnabled: return "Turn on Apple Intelligence in Settings to use the AI guide."
            case .modelNotReady: return "The on-device model is still downloading. Try again soon."
            @unknown default: return "The AI guide isn't available right now."
            }
        }
    }

    static func errorText(_ error: Error) -> String {
        if case .assetsUnavailable = error as? SystemLanguageModel.Error {
            return "The on-device model is still downloading. Try again soon."
        }
        switch error as? LanguageModelError {
        case .guardrailViolation, .refusal:
            return "I can't help with that one. Try asking another way."
        case .contextSizeExceeded:
            return "This chat got too long, so the next question starts fresh."
        case .rateLimited:
            return "The guide is busy. Try again in a moment."
        case .unsupportedLanguageOrLocale:
            return "The guide doesn't support this language yet."
        default:
            return "The AI guide couldn't answer. Try again in a moment."
        }
    }
}
