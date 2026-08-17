import XCTest
import CoreLocation
@testable import Sightline

/// Audits the contract between the ambient allowlist and the type→category table: an allowlisted type without a real category renders as a junk "Place" bubble.
final class CategoryMappingTests: XCTestCase {

    // Mirror of VenueCategoryPolicy.allowedTypes minus the four deliberate .other types; a stale mirror fails the isAmbientVenue leg of the audit below.
    private static let expectedMappings: [(type: String, category: PlaceCategory)] = [
        // Food & drink.
        ("restaurant", .restaurant), ("meal_takeaway", .restaurant), ("meal_delivery", .restaurant),
        ("food_court", .restaurant), ("sandwich_shop", .restaurant), ("diner", .restaurant),
        ("cafe", .cafe), ("coffee_shop", .cafe), ("tea_house", .cafe), ("cafeteria", .cafe),
        ("juice_shop", .cafe),
        ("bakery", .bakery), ("donut_shop", .bakery), ("bagel_shop", .bakery),
        ("dessert_shop", .bakery), ("confectionery", .bakery),
        ("ice_cream_shop", .iceCream),
        ("bar", .bar), ("pub", .bar), ("wine_bar", .bar), ("night_club", .bar), ("brewery", .bar),
        // Retail.
        ("store", .shop), ("shopping_mall", .shop), ("market", .shop), ("gift_shop", .shop),
        ("supermarket", .grocery), ("grocery_store", .grocery), ("food_market", .grocery),
        ("convenience_store", .grocery), ("butcher_shop", .grocery),
        // Attractions & culture.
        ("tourist_attraction", .landmark), ("historical_landmark", .landmark),
        ("monument", .landmark), ("historical_place", .landmark), ("observation_deck", .landmark),
        ("cultural_landmark", .landmark), ("plaza", .landmark),
        ("zoo", .landmark), ("amusement_park", .landmark), ("stadium", .landmark),
        ("museum", .museum), ("art_gallery", .museum), ("planetarium", .museum), ("aquarium", .museum),
        ("movie_theater", .theater), ("performing_arts_theater", .theater),
        ("concert_hall", .theater), ("opera_house", .theater), ("amphitheatre", .theater),
        ("theater", .theater),
        // Outdoors.
        ("park", .park), ("national_park", .park), ("state_park", .park), ("garden", .park),
        ("botanical_garden", .park), ("dog_park", .park), ("hiking_area", .park),
        ("beach", .park), ("marina", .park),
        // Worship buildings read as landmarks, matching the name-keyword pass.
        ("church", .landmark), ("place_of_worship", .landmark), ("synagogue", .landmark),
        ("mosque", .landmark), ("hindu_temple", .landmark),
        // Transit.
        ("subway_station", .transit), ("train_station", .transit), ("transit_station", .transit),
        ("bus_station", .transit), ("bus_stop", .transit), ("light_rail_station", .transit),
        ("transit_depot", .transit), ("airport", .transit), ("ferry_terminal", .transit),
        ("taxi_stand", .transit),
        // Walk-in lodging.
        ("hotel", .hotel), ("motel", .hotel), ("resort_hotel", .hotel),
        ("extended_stay_hotel", .hotel), ("hostel", .hotel), ("inn", .hotel),
        // Essentials & visitor services.
        ("pharmacy", .pharmacy), ("drugstore", .pharmacy), ("hospital", .pharmacy),
        ("tourist_information_center", .landmark), ("visitor_center", .landmark),
    ]

    // Allowlisted on purpose with no category: the ambient rating gate is these types' junk filter.
    private static let deliberateOtherTypes = ["casino", "bowling_alley", "amusement_center", "public_bathroom"]

    func testEveryAllowlistedTypeMapsToARealCategory() {
        for row in Self.expectedMappings {
            XCTAssertTrue(VenueCategoryPolicy.isAmbientVenue(primaryType: row.type, types: nil),
                          "\(row.type) fell out of the ambient allowlist — mirror table is stale")
            XCTAssertNotEqual(row.category, .other, "\(row.type) — audit rows must name a real category")
            XCTAssertEqual(GooglePlacesService.mapType(row.type), row.category, row.type)
        }
    }

    func testDeliberateExemptionsPassTheGateButStayUnmapped() {
        for type in Self.deliberateOtherTypes {
            XCTAssertTrue(VenueCategoryPolicy.isAmbientVenue(primaryType: type, types: nil), type)
            // nil falls through to the name-keyword pass and lands on .other by design.
            XCTAssertNil(GooglePlacesService.mapType(type), type)
        }
    }

    // The 2026-08 allowlist/mapper reconciliation, pinned so a refactor cannot silently unmap these again.
    func testReconciledMappingsFromTheReview() {
        XCTAssertEqual(GooglePlacesService.mapType("bus_stop"), .transit)
        XCTAssertEqual(GooglePlacesService.mapType("taxi_stand"), .transit)
        // .pharmacy is the closest health category until a .hospital case exists; .other would let the rating gate hide ERs.
        XCTAssertEqual(GooglePlacesService.mapType("hospital"), .pharmacy)
        XCTAssertEqual(GooglePlacesService.mapType("zoo"), .landmark)
        XCTAssertEqual(GooglePlacesService.mapType("amusement_park"), .landmark)
        XCTAssertEqual(GooglePlacesService.mapType("stadium"), .landmark)
        XCTAssertEqual(GooglePlacesService.mapType("place_of_worship"), .landmark)
        XCTAssertEqual(GooglePlacesService.mapType("tourist_information_center"), .landmark)
        XCTAssertEqual(GooglePlacesService.mapType("visitor_center"), .landmark)
    }

    func testSuffixFamiliesMapAndPassTheGateTogether() {
        for type in ["italian_restaurant", "sushi_restaurant", "vegan_restaurant"] {
            XCTAssertEqual(GooglePlacesService.mapType(type), .restaurant, type)
            XCTAssertTrue(VenueCategoryPolicy.isAmbientVenue(primaryType: type, types: nil), type)
        }
        for type in ["shoe_store", "hardware_store", "book_store"] {
            XCTAssertEqual(GooglePlacesService.mapType(type), .shop, type)
            XCTAssertTrue(VenueCategoryPolicy.isAmbientVenue(primaryType: type, types: nil), type)
        }
        // "_shop" is deliberately not a family — it would re-admit barber_shop et al.
        XCTAssertNil(GooglePlacesService.mapType("barber_shop"))
        XCTAssertFalse(VenueCategoryPolicy.isAmbientVenue(primaryType: "barber_shop", types: nil))
    }

    // Search-only types still deserve honest categories when a typed query returns them.
    func testSearchOnlyTypesStillCategorize() {
        XCTAssertEqual(GooglePlacesService.mapType("atm"), .atm)
        XCTAssertEqual(GooglePlacesService.mapType("bank"), .bank)
        XCTAssertEqual(GooglePlacesService.mapType("credit_union"), .bank)
        XCTAssertEqual(GooglePlacesService.mapType("lodging"), .hotel)
        XCTAssertEqual(GooglePlacesService.mapType("bed_and_breakfast"), .hotel)
        for type in ["atm", "bank", "credit_union", "lodging", "bed_and_breakfast"] {
            XCTAssertFalse(VenueCategoryPolicy.isAmbientVenue(primaryType: type, types: nil), type)
        }
    }

    func testUnknownTypesFallToTheKeywordPass() {
        for type in ["laundromat", "real_estate_agency", "gas_station", "post_office",
                     "point_of_interest", "establishment", ""] {
            XCTAssertNil(GooglePlacesService.mapType(type), type)
        }
    }
}
