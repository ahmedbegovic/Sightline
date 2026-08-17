import Foundation

/// The ambient-scan venue gate: a scan bubble must be something a stranger can see and walk into; explicit search and the landmark pass bypass this entirely.
enum VenueCategoryPolicy {

    /// True when any of the place's Google types reads as a walk-in venue; untyped places fail the gate (ambient scans are curated, search is not).
    static func isAmbientVenue(primaryType: String?, types: [String]?) -> Bool {
        if let primaryType, matches(primaryType) { return true }
        return (types ?? []).contains(where: matches)
    }

    private static func matches(_ type: String) -> Bool {
        // "_restaurant"/"_store" families read as venues without enumerating every cuisine; "_shop" would re-admit barber_shop et al., so shops are listed explicitly.
        if type.hasSuffix("_restaurant") || type.hasSuffix("_store") { return true }
        return allowedTypes.contains(type)
    }

    /// Places API (New) Table A types a tourist can use on sight. Deliberately absent: home services, offices, salons/spas, gyms, schools, and home-lodging (vacation rentals, guest houses, B&Bs) — a real hotel still passes via its "hotel"/"motel" type even when "lodging" is also present. Banks, ATMs, gas stations and post offices left 2026-08-16: they are errands you search for, not discoveries (twin RBC bubbles on a field test), so they remain searchable but never ambient.
    private static let allowedTypes: Set<String> = [
        // Food & drink.
        "restaurant", "meal_takeaway", "meal_delivery", "food_court", "sandwich_shop",
        "diner", "cafe", "coffee_shop", "tea_house", "cafeteria", "bakery", "donut_shop",
        "bagel_shop", "dessert_shop", "confectionery", "ice_cream_shop", "juice_shop",
        "bar", "pub", "wine_bar", "night_club", "brewery",
        // Retail.
        "store", "shopping_mall", "market", "supermarket", "grocery_store", "food_market",
        "convenience_store", "butcher_shop", "gift_shop",
        // Attractions, culture, entertainment.
        "tourist_attraction", "historical_landmark", "monument", "historical_place",
        "observation_deck", "cultural_landmark", "plaza", "museum", "art_gallery",
        "planetarium", "aquarium", "zoo", "amusement_park",
        "movie_theater", "performing_arts_theater", "concert_hall", "opera_house",
        "amphitheatre", "theater", "stadium",
        // Casino, bowling and arcades map to .other on purpose: the ambient rating gate is their junk filter.
        "casino", "bowling_alley", "amusement_center",
        // Outdoors.
        "park", "national_park", "state_park", "garden", "botanical_garden", "dog_park",
        "hiking_area", "beach", "marina",
        // Prominent, tourist-legible worship buildings.
        "church", "place_of_worship", "synagogue", "mosque", "hindu_temple",
        // Transit.
        "subway_station", "train_station", "transit_station", "bus_station", "bus_stop",
        "light_rail_station", "transit_depot", "airport", "ferry_terminal", "taxi_stand",
        // Walk-in lodging only.
        "hotel", "motel", "resort_hotel", "extended_stay_hotel", "hostel", "inn",
        // Essentials a walker actually stops at; money, fuel and mail are search-only.
        "pharmacy", "drugstore", "hospital",
        "tourist_information_center", "visitor_center",
        // No category fits restrooms yet, so they fall to .other and the unrated-venue gate keeps them search-only in practice.
        "public_bathroom",
    ]
}
