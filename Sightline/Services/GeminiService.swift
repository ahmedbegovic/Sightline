import Foundation
import CoreLocation

/// Thin Gemini API client for assistant replies — flash-lite tier, SSE streaming; every failure throws so the caller can fall back honestly.
final class GeminiService {

    static let shared = GeminiService()

    struct APIError: LocalizedError {
        let message: String
        var status: Int = 0
        var errorDescription: String? { message }
    }

    /// One chat turn as the API wants it; `fromUser: false` maps to the "model" role.
    struct Turn {
        let fromUser: Bool
        let text: String
    }

    /// The one grounding tool for this conversation — the API refuses Search and Maps in the same request (verified 2026-08-16), so the caller picks per place kind.
    enum GroundingTool {
        /// Live place data (hours, busy times, offerings); the coordinate anchors "near me" lookups.
        case googleMaps(userCoordinate: CLLocationCoordinate2D?)
        /// Live web facts (history, events, tickets, programmes).
        case googleSearch
    }

    /// Incremental stream output; text deltas are raw model text — display cleanup happens on the accumulated string.
    enum StreamEvent {
        case text(String)
        /// Emitted at most once, when the response first carries grounding attributions.
        case grounded
    }

    /// 2.5-flash-lite is closed to keys created after its retirement (verified 2026-08-16); 3.5 is the current flash-lite generation on this key.
    private static let model = "gemini-3.5-flash-lite"

    /// A key route to Gemini; the bundle-restricted Cloud key must send the bundle-id header, the AI Studio key must not.
    private struct KeyRoute {
        let key: String
        let sendsBundleID: Bool
    }

    /// Cloud key first (usage bills to the Sightline project's trial credits once the Generative Language API is enabled there), AI Studio key second (works the day its prepay plan is funded). Whichever the user unblocks first starts answering; both failing surfaces as the chat's error row.
    private static let keyRoutes = [
        KeyRoute(key: Secrets.googleAPIKey, sendsBundleID: true),
        KeyRoute(key: Secrets.geminiAPIKey, sendsBundleID: false),
    ]

    private let session: URLSession

    // Injectable session is a test seam only; production always uses the configured default.
    init(session: URLSession? = nil) {
        if let session {
            self.session = session
        } else {
            let config = URLSessionConfiguration.default
            // Short idle timeout so a dead connection reaches the error row fast instead of stacking two full waits.
            config.timeoutIntervalForRequest = 8
            // An actively streaming reply may legitimately run long; only a stalled one should die.
            config.timeoutIntervalForResource = 60
            self.session = URLSession(configuration: config)
        }
    }

    /// Network states where trying the second key rides the same dead network — fail now and let the error row say so.
    static func isOffline(_ error: Error) -> Bool {
        guard let urlError = error as? URLError else { return false }
        switch urlError.code {
        case .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed,
             .internationalRoamingOff, .cannotFindHost, .cannotConnectToHost, .timedOut:
            return true
        default:
            return false
        }
    }

    /// Applied to the accumulated text, not per delta, so a "**" split across two chunks still dies; the chat renders raw text.
    static func displayText(_ raw: String) -> String {
        raw.replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "**", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Streams the model's reply; the returned stream throws when no route produced any text.
    func streamReply(systemInstruction: String, turns: [Turn],
                     grounding: GroundingTool) -> AsyncThrowingStream<StreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await self.streamAcrossRoutes(systemInstruction: systemInstruction,
                                                      turns: turns, grounding: grounding,
                                                      continuation: continuation)
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func streamAcrossRoutes(systemInstruction: String, turns: [Turn],
                                    grounding: GroundingTool,
                                    continuation: AsyncThrowingStream<StreamEvent, Error>.Continuation) async throws {
        var lastError: Error = APIError(message: "No Gemini key routes")
        for route in Self.keyRoutes {
            var emitted = false
            do {
                try await streamGenerate(systemInstruction: systemInstruction, turns: turns,
                                         grounding: grounding, route: route,
                                         emitted: &emitted, continuation: continuation)
                return
            } catch {
                // No network: skip the remaining key entirely rather than paying its timeout too.
                if Self.isOffline(error) { throw error }
                // Text already reached the UI — a retry on the next key would replay the answer.
                if emitted { throw error }
                // Blocked routes (403 API_KEY_SERVICE_BLOCKED, 429) answer fast; move straight to the next key.
                lastError = error
            }
        }
        throw lastError
    }

    private func streamGenerate(systemInstruction: String,
                                turns: [Turn],
                                grounding: GroundingTool,
                                route: KeyRoute,
                                emitted: inout Bool,
                                continuation: AsyncThrowingStream<StreamEvent, Error>.Continuation) async throws {
        guard let url = URL(string:
            "https://generativelanguage.googleapis.com/v1beta/models/\(Self.model):streamGenerateContent?alt=sse")
        else { throw APIError(message: "Bad endpoint") }

        let contents: [[String: Any]] = turns
            .filter { !$0.text.isEmpty }
            .map { ["role": $0.fromUser ? "user" : "model",
                    "parts": [["text": $0.text]]] }

        var body: [String: Any] = [
            "systemInstruction": ["parts": [["text": systemInstruction]]],
            "contents": contents,
            // No thinkingConfig: 3.5-flash-lite rejects the 2.5-era thinkingBudget field with a 400 and spends no thought tokens by default (verified 2026-08-16).
            "generationConfig": ["temperature": 0.7, "maxOutputTokens": 1024],
        ]
        switch grounding {
        case .googleMaps(let coordinate):
            body["tools"] = [["google_maps": [String: Any]()]]
            if let coordinate, CLLocationCoordinate2DIsValid(coordinate) {
                body["toolConfig"] = ["retrievalConfig": ["latLng": [
                    "latitude": coordinate.latitude, "longitude": coordinate.longitude]]]
            }
        case .googleSearch:
            body["tools"] = [["google_search": [String: Any]()]]
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(route.key, forHTTPHeaderField: "x-goog-api-key")
        if route.sendsBundleID {
            request.setValue(Bundle.main.bundleIdentifier ?? "com.ahmedbegovic.Sightline",
                             forHTTPHeaderField: "X-Ios-Bundle-Identifier")
        }

        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw APIError(message: "No response from Gemini")
        }
        guard http.statusCode == 200 else {
            // Error responses come as one JSON body, not SSE.
            var bodyText = ""
            for try await line in bytes.lines {
                bodyText += line
                if bodyText.count > 4096 { break }
            }
            let envelope = bodyText.data(using: .utf8)
                .flatMap { try? JSONDecoder().decode(ErrorEnvelope.self, from: $0) }
            throw APIError(message: envelope?.error.message ?? "Gemini error \(http.statusCode)",
                           status: http.statusCode)
        }

        var sawGrounding = false
        for try await line in bytes.lines {
            guard line.hasPrefix("data:") else { continue }
            let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
            guard payload != "[DONE]",
                  let data = payload.data(using: .utf8),
                  let chunk = try? JSONDecoder().decode(ChunkEnvelope.self, from: data),
                  let candidate = chunk.candidates?.first
            else { continue }
            // Only "text" parts are output — grounded chunks also carry thoughtSignature parts that must not be rendered.
            for part in candidate.content?.parts ?? [] {
                if let text = part.text, !text.isEmpty {
                    emitted = true
                    continuation.yield(.text(text))
                }
            }
            if !sawGrounding, candidate.groundingMetadata?.groundingChunks?.isEmpty == false {
                sawGrounding = true
                continuation.yield(.grounded)
            }
        }
        // Safety blocks and empty candidates land here — an empty reply is a failure, not an answer.
        guard emitted else { throw APIError(message: "Empty Gemini reply") }
    }

    // MARK: - DTOs

    private struct ChunkEnvelope: Decodable {
        struct Candidate: Decodable {
            let content: Content?
            let groundingMetadata: GroundingMetadata?
        }
        struct Content: Decodable { let parts: [Part]? }
        struct Part: Decodable { let text: String? }
        struct GroundingMetadata: Decodable { let groundingChunks: [GroundingChunk]? }
        /// Presence is the whole signal; the payload shape differs between the Search and Maps tools.
        struct GroundingChunk: Decodable {}
        let candidates: [Candidate]?
    }

    private struct ErrorEnvelope: Decodable {
        struct Payload: Decodable { let message: String }
        let error: Payload
    }
}
