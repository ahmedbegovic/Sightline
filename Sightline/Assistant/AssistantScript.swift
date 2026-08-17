import Foundation
import CoreLocation

/// Canned UI copy for the assistant: the opening greeting and the per-kind quick-question chips.
enum AssistantScript {

    /// The greeting becomes a raw Gemini turn, so it must never interpolate the Places-derived name — that text is fenced-only (see AssistantPrompt); the sheet header already shows the name.
    static func greeting(for place: Place) -> String {
        switch place.category.guideKind {
        case .eatery:
            return "Hey! I'm your local guide for the place named above. Ask me what to order, what it costs, or whether it's worth the walk."
        case .landmark:
            return "Hi! That's the landmark named above in front of you. Ask me what you're looking at, why it matters, or how to get the shot."
        case .museum:
            return "Hi there! I can help you plan a visit to this museum — what's inside, how long people spend, and what to check before you go."
        case .theater:
            return "Hey! This spot is a venue, so I can tell you what kind of room it is and how people usually get tickets."
        case .park:
            return "Hey! Ask me about this park — what people do there, what visitors say, or how far the walk is."
        case .hotel:
            return "Hey! I'm your local guide for this hotel. Ask me about the stay, the value, or how to book."
        case .retail:
            return "Hi! Ask me about this shop — what kind of shop it is, what people make of it, or when it's open."
        case .transit:
            return "Hi! The stop named above is yours. Ask me which lines run from here, how to pay, or how to use it."
        case .essential:
            return "Hi! I can help with the place named above — what you can do there, when it's likely open, and how far it is."
        case .generic:
            return "Hey! I'm your local guide. Ask me anything about the place named above — what it is, the reviews, or how to get there."
        }
    }

    static func quickQuestions(for place: Place, userLocation: CLLocation?) -> [String] {
        let located = place.distance(from: userLocation) != nil
        let closed = place.isOpenNow == false
        let rated = place.reviewCount > 0
        let priced = place.priceLevel > 0

        switch place.category.guideKind {
        case .eatery:
            return chips([
                (true, eateryLead(for: place)),
                (closed, "When does it open again?"),
                (place.servesVegetarian == true, "Any vegetarian options?"),
                (priced, "Is it affordable?"),
                (rated, "Summarize the reviews"),
                (place.category == .cafe, "Can I work from here?"),
                (place.reviewCount >= 200, "Is it usually busy?"),
                (!closed, "When is it usually open?"),
                (located, "How far is it?"),
                (true, "Tell me about this place"),
            ])

        case .landmark:
            return chips([
                (true, "What am I looking at?"),
                (true, "Why is it famous?"),
                (closed, "When does it open again?"),
                (true, "Best spot for a photo?"),
                (place.isFarLandmark || (place.distance(from: userLocation) ?? 0) > 900, "Is it worth the trip?"),
                (rated, "What do visitors say?"),
                (located, "How far is it?"),
                (true, "Tell me about this place"),
            ])

        case .museum:
            return chips([
                (true, "What's inside?"),
                (closed, "When does it open again?"),
                (true, "Do I need tickets?"),
                (true, "How much time do I need?"),
                (rated, "What do visitors say?"),
                (true, "Why is it worth visiting?"),
                (located, "How far is it?"),
                (true, "Tell me about this place"),
            ])

        case .theater:
            return chips([
                (true, "What plays here?"),
                (closed, "When do doors open?"),
                (true, "How do I get tickets?"),
                (rated, "What do people say?"),
                (true, "Is it worth seeing?"),
                (located, "How far is it?"),
                (true, "Tell me about this place"),
            ])

        case .park:
            return chips([
                (true, "What's there to do?"),
                (true, "Is it open after dark?"),
                (rated, "What do visitors say?"),
                (located, "How far is it?"),
                (true, "Is it worth a stop?"),
                (true, "Good spot for a photo?"),
                (true, "Tell me about this place"),
            ])

        case .hotel:
            return chips([
                (rated, "What do guests say?"),
                (priced, "Is it affordable?"),
                (true, "How do I book a room?"),
                (true, "Is there Wi-Fi in the lobby?"),
                (true, "Is it a nice stay?"),
                (located, "How far is it?"),
                (true, "Tell me about this place"),
            ])

        case .retail:
            return chips([
                (true, place.category == .grocery ? "What can I pick up here?" : "What do they sell?"),
                (closed, "When does it open again?"),
                (rated, place.category == .grocery ? "What do people say?" : "What do shoppers say?"),
                (priced, "Is it pricey?"),
                (true, "Is it worth a look?"),
                (!closed, "When is it usually open?"),
                (located, "How far is it?"),
                (true, "Tell me about this place"),
            ])

        case .transit:
            return chips([
                (true, "Where can I go from here?"),
                (true, "How do I pay the fare?"),
                (true, "How often does it run?"),
                (located, "How far is the entrance?"),
                (true, "When does service run?"),
                (true, "Tell me about this place"),
            ])

        case .essential:
            return chips([
                (true, essentialLead(for: place)),
                (true, place.category == .atm ? "Is it open 24 hours?" : "Is it open right now?"),
                (located, "How far is it?"),
                (true, "What should I expect?"),
                (true, "Tell me about this place"),
            ])

        case .generic:
            return chips([
                (true, "What is this place?"),
                (rated, "What do people say?"),
                (true, "When is it usually open?"),
                (located, "How far is it?"),
                (true, "Is it worth a stop?"),
                (true, "Tell me about this place"),
            ])
        }
    }

    private static func eateryLead(for place: Place) -> String {
        switch place.category {
        case .cafe: return "What's the coffee like?"
        case .bar:  return "What should I drink?"
        default:    return "What's good here?"
        }
    }

    private static func essentialLead(for place: Place) -> String {
        switch place.category {
        case .atm:  return "Is there a withdrawal fee?"
        case .bank: return "Do I need an appointment?"
        default:    return "Can they fill a prescription?"
        }
    }

    /// First four passing questions only — the chip ForEach ids on the string itself, so duplicates must never ship.
    private static func chips(_ candidates: [(Bool, String)]) -> [String] {
        var out: [String] = []
        for (include, question) in candidates where include {
            guard !out.contains(question) else { continue }
            out.append(question)
            if out.count == 4 { break }
        }
        return out
    }
}
