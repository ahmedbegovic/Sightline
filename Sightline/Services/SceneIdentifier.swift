import Foundation
import CoreGraphics
import CoreLocation
import FoundationModels
import OSLog
import Vision

/// Field-test trail: which scan path ran, why the model failed, how many candidates each lookup returned. Filter Console by category "scan".
let scanLog = Logger(subsystem: "com.ahmedbegovic.Sightline", category: "scan")

// MARK: - Model output

@Generable
struct SceneReading {
    @Guide(description: "Things you recognise in the photo, the one nearest the centre first. Empty when nothing is recognisable.",
           .maximumCount(3))
    var subjects: [SceneSubject]
}

@Generable
struct SceneSubject {
    @Guide(description: "Number of the matching place in the list, or 0 when it is not in the list")
    var candidate: Int
    @Guide(description: "Proper name, for example CN Tower")
    var name: String
    var kind: SceneKind
    @Guide(description: "Horizontal position in the photo: 0 is the left edge, 0.5 the centre, 1 the right edge", .range(0...1))
    var position: Double
    @Guide(description: "One short sentence telling a tourist what this is")
    var summary: String
    var confidence: SceneConfidence
}

@Generable
enum SceneKind {
    case landmark, building, museum, park, venue, business, transit, artwork, nature, other

    var category: PlaceCategory {
        switch self {
        case .landmark, .building, .artwork: return .landmark
        case .museum: return .museum
        case .park, .nature: return .park
        case .venue: return .theater
        case .business: return .shop
        case .transit: return .transit
        case .other: return .other
        }
    }
}

@Generable
enum SceneConfidence { case high, medium, low }

// MARK: - Pipeline

/// Scan = "what is in my camera right now". The photo is the evidence; location only supplies names to choose from.
/// Works at any distance (5 m or 5 km) and any height, because nothing is filtered by radius or ground-level geometry.
enum SceneIdentifier {

    static let instructions = """
        You help a tourist identify what their phone camera is pointing at. Name only things you can actually \
        see in the photo: landmarks, towers, notable buildings, monuments, bridges, venues, parks, artworks, or \
        businesses whose sign is readable. A numbered list of known places in the camera's direction is given, \
        with distance and angle from the centre of the photo. Use it to put the right name on what you see, and \
        give its number. If you clearly recognise a famous landmark that is not in the list, give its name with \
        number 0. Never pick a place only because it is in the list: it must be visible. Do not name generic \
        things such as a road, a car, a tree, the sky or an ordinary building. Put the thing nearest the centre \
        first. If you recognise nothing, return an empty list.
        """

    /// Located and unlocated places for everything the scan recognised, best first. Throws only for a real lookup failure with nothing to show.
    static func identify(_ frame: ScanFrame) async throws -> [Place] {
        let signs = await readSigns(frame.image)

        var candidates: [Place] = []
        var lookupError: Error?
        if let origin = frame.location?.coordinate {
            do {
                candidates = try await MapKitPlaces.candidates(around: origin, headingDegrees: frame.headingDegrees,
                                                               signs: signs)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                lookupError = error
            }
        }
        try Task.checkCancellation()
        let listed = SceneMatcher.inView(candidates, frame: frame, signs: signs)

        var results: [Place]
        switch try await read(frame, signs: signs, listed: listed) {
        case .subjects(let subjects):
            scanLog.info("model path: \(subjects.count) subjects, \(listed.count) listed, \(signs.count) signs")
            results = []
            for resolved in SceneMatcher.resolve(subjects, listed: listed, frame: frame) {
                switch resolved {
                case .located(let place):
                    results.append(place)
                case .unlocated(var place):
                    if let origin = frame.location?.coordinate, let sighting = place.sighting,
                       let found = await MapKitPlaces.locate(place.name, near: origin, bearing: sighting.bearing) {
                        place.coordinate = found.coordinate
                        place.isLocated = true
                        place.category = found.category
                        place.phone = found.phone
                        place.url = found.url
                        place.address = found.address
                    }
                    results.append(place)
                }
            }
            // The model saw nothing, but a readable sign still names what is in front of the user.
            if results.isEmpty { results = SceneMatcher.fallback(listed, frame: frame, allowCentered: false) }
        case .failed:
            // A model that tried and failed must not turn into a heading-only guess: signs only.
            results = SceneMatcher.fallback(listed, frame: frame, allowCentered: false)
        case .unavailable:
            // No vision model on this device: sign matches, else a notable place dead ahead.
            scanLog.info("fallback path: no vision model, \(listed.count) listed, \(signs.count) signs")
            results = SceneMatcher.fallback(listed, frame: frame, allowCentered: true)
        }

        var seen = Set<String>()
        results = results.filter { seen.insert($0.id).inserted }
        for index in results.indices { results[index].snapshot = frame.image }
        if results.isEmpty, let lookupError { throw lookupError }
        return results
    }

    private enum Reading {
        case subjects([SceneMatcher.Sighted])
        /// No image or no vision-capable model on this device.
        case unavailable
        /// The model ran and errored (guardrail, context, decoding): never a failed scan, but never a guess either.
        case failed
    }

    private static func read(_ frame: ScanFrame, signs: [String],
                             listed: [SceneMatcher.Listed]) async throws -> Reading {
        let model = SystemLanguageModel.default
        guard let image = frame.image, model.availability == .available, model.capabilities.contains(.vision)
        else { return .unavailable }
        let session = LanguageModelSession(model: model, instructions: instructions)
        let text = SceneMatcher.prompt(frame: frame, signs: signs, listed: listed)
        do {
            let reading = try await session.respond(generating: SceneReading.self) {
                Attachment(image)
                text
            }.content
            return .subjects(reading.subjects.map {
                SceneMatcher.Sighted(candidate: $0.candidate, name: $0.name, category: $0.kind.category,
                                     position: $0.position, summary: $0.summary,
                                     confidence: $0.confidence == .high ? 2 : $0.confidence == .medium ? 1 : 0)
            })
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            scanLog.error("model failed: \(String(describing: error), privacy: .public)")
            return .failed
        }
    }

    /// On-device OCR. Signs are the strongest evidence for a storefront, and free.
    static func readSigns(_ image: CGImage?) async -> [String] {
        guard let image else { return [] }
        var request = RecognizeTextRequest()
        request.recognitionLevel = .accurate
        guard let observations = try? await request.perform(on: image) else { return [] }
        let lines = observations.compactMap { $0.topCandidates(1).first }
            .filter { $0.confidence >= 0.5 }
            .map(\.string)
        return SceneMatcher.cleanSigns(lines)
    }
}

// MARK: - Matching (pure, unit-tested)

enum SceneMatcher {

    /// Compass error allowance beyond the frame edge.
    static let viewMarginDegrees = 15.0
    /// A sign match is strong evidence, so it may sit further off the heading (close range magnifies compass error).
    static let signMarginDegrees = 35.0
    /// How far a by-name lookup may sit from where the camera saw the thing.
    static let lookupToleranceDegrees = 30.0
    /// The no-model fallback only trusts a notable place this close to dead ahead.
    static let centeredDegrees = 6.0
    /// Keeps the prompt well inside the on-device context window.
    static let maxListed = 12

    struct Listed {
        let place: Place
        /// Signed degrees from the photo centre; negative = left.
        let offset: Double
        let distance: CLLocationDistance
        let signMatch: Bool
    }

    /// Model output with FoundationModels types stripped, so matching is testable on its own.
    struct Sighted {
        var candidate: Int
        var name: String
        var category: PlaceCategory
        var position: Double
        var summary: String
        /// 2 high, 1 medium, 0 low.
        var confidence: Int
    }

    enum Resolved {
        case located(Place)
        /// Recognised but not on the list; the caller may still find it by name.
        case unlocated(Place)
    }

    static func inView(_ candidates: [Place], frame: ScanFrame, signs: [String]) -> [Listed] {
        guard let origin = frame.location?.coordinate else { return [] }
        let half = frame.horizontalFOV / 2
        return candidates
            .map { place in
                Listed(place: place,
                       offset: Angles.shortestDelta(from: frame.headingDegrees,
                                                    to: ARProjector.bearing(from: origin, to: place.coordinate)),
                       distance: ARProjector.distanceMeters(from: origin, to: place.coordinate),
                       signMatch: matchesSign(place.name, signs: signs))
            }
            .filter { abs($0.offset) <= half + ($0.signMatch ? signMarginDegrees : viewMarginDegrees) }
            .sorted { $0.signMatch != $1.signMatch ? $0.signMatch : abs($0.offset) < abs($1.offset) }
            .prefix(maxListed)
            .map { $0 }
    }

    static func prompt(frame: ScanFrame, signs: [String], listed: [Listed]) -> String {
        var lines: [String] = []
        lines.append(String(format: "Camera heading: %.0f°, tilted %.0f° %@.",
                            frame.headingDegrees, abs(frame.pitchDegrees), frame.pitchDegrees >= 0 ? "up" : "down"))
        lines.append(signs.isEmpty ? "Sign text in the photo: none."
                     : "Sign text in the photo: " + signs.map { "\"\($0)\"" }.joined(separator: ", ") + ".")
        if listed.isEmpty {
            lines.append("Known places in this direction: none.")
        } else {
            lines.append("Known places in this direction:")
            for (index, entry) in listed.enumerated() {
                lines.append("\(index + 1). \(entry.place.name) (\(entry.place.category.displayName)), "
                             + "\(distanceText(entry.distance)) away, \(angleText(entry.offset))"
                             + (entry.signMatch ? ", name matches a sign" : ""))
            }
        }
        lines.append("What do you recognise in the photo?")
        return lines.joined(separator: "\n")
    }

    static func resolve(_ subjects: [Sighted], listed: [Listed], frame: ScanFrame) -> [Resolved] {
        subjects.compactMap { subject in
            let name = subject.name.trimmingCharacters(in: .whitespacesAndNewlines)
            let sighting = Sighting(
                bearing: Angles.normalized(frame.headingDegrees + (min(1, max(0, subject.position)) - 0.5) * frame.horizontalFOV),
                elevation: frame.pitchDegrees,
                origin: frame.location)
            let summary = subject.summary.trimmingCharacters(in: .whitespacesAndNewlines)

            // A name that matches the list beats the number: small models slip on indices more than on names.
            let byName = name.isEmpty ? nil : listed.first { namesMatch($0.place.name, name) }
            let byIndex = listed.indices.contains(subject.candidate - 1) && subject.confidence > 0
                ? listed[subject.candidate - 1] : nil
            if let entry = byName ?? byIndex {
                var place = entry.place
                place.sighting = sighting
                place.summary = summary.isEmpty ? nil : summary
                return .located(place)
            }
            // Off-list names must be confident: this is where a small model would otherwise invent a tower.
            guard subject.confidence == 2, !name.isEmpty else { return nil }
            let origin = frame.location?.coordinate ?? CLLocationCoordinate2D(latitude: 0, longitude: 0)
            var place = Place(id: "seen|" + Place.stableID(name: name, coordinate: origin),
                              name: name, category: subject.category, coordinate: origin)
            place.isLocated = false
            place.sighting = sighting
            place.summary = summary.isEmpty ? nil : summary
            return .unlocated(place)
        }
    }

    /// Deterministic pick when the model is unavailable or saw nothing: readable signs first, then (optionally) a notable place dead ahead.
    static func fallback(_ listed: [Listed], frame: ScanFrame, allowCentered: Bool) -> [Place] {
        var picks = listed.filter(\.signMatch).prefix(3).map { $0 }
        if picks.isEmpty, allowCentered,
           let ahead = listed.filter({ abs($0.offset) <= centeredDegrees }).min(by: { abs($0.offset) < abs($1.offset) }) {
            picks = [ahead]
        }
        return picks.map { entry in
            var place = entry.place
            place.sighting = Sighting(bearing: Angles.normalized(frame.headingDegrees + entry.offset),
                                      elevation: frame.pitchDegrees,
                                      origin: frame.location)
            return place
        }
    }

    // MARK: - Text

    static func cleanSigns(_ lines: [String]) -> [String] {
        var seen = Set<String>()
        return lines
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { (3...40).contains($0.count) && $0.contains(where: \.isLetter) }
            .filter { seen.insert(normalize($0)).inserted }
            .prefix(8)
            .map { $0 }
    }

    static func matchesSign(_ name: String, signs: [String]) -> Bool {
        signs.contains { namesMatch(name, $0) }
    }

    /// Case- and accent-insensitive containment either way; very short strings never match ("BAR" would match everything).
    static func namesMatch(_ a: String, _ b: String) -> Bool {
        let (x, y) = (normalize(a), normalize(b))
        guard x.count >= 4, y.count >= 4 else { return x == y && !x.isEmpty }
        return x.contains(y) || y.contains(x)
    }

    private static func normalize(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .map { $0.isLetter || $0.isNumber ? $0 : " " }
            .reduce(into: "") { $0.append($1) }
            .split(separator: " ")
            .joined(separator: " ")
    }

    private static func distanceText(_ meters: CLLocationDistance) -> String {
        meters < 1_000 ? "\(Int(meters.rounded())) m" : String(format: "%.1f km", meters / 1_000)
    }

    private static func angleText(_ offset: Double) -> String {
        let degrees = Int(abs(offset).rounded())
        if degrees == 0 { return "at the centre" }
        return "\(degrees)° \(offset < 0 ? "left" : "right") of centre"
    }
}
