import Foundation
import CoreLocation

/// Collapses the near-duplicate transit stops map providers return for both sides of one intersection.
enum TransitStopIdentity {

    /// Two transit places closer than this that share a stop identity are the same stop.
    static let mergeRadiusMeters: CLLocationDistance = 120

    /// Direction words carry no stop identity; matched as whole tokens only, so "Springside" survives.
    private static let directionTokens: Set<String> = [
        "north", "south", "east", "west",
        "northbound", "southbound", "eastbound", "westbound",
        "nb", "sb", "eb", "wb", "side",
    ]

    /// Street-type suffixes: two names for the same corner usually differ only by these.
    private static let streetTypeTokens: Set<String> = [
        "st", "street", "rd", "road", "ave", "avenue", "blvd", "boulevard",
        "dr", "drive", "cres", "crescent", "way", "ct", "court", "pl", "place",
        "ln", "lane", "ter", "terrace", "pkwy", "parkway", "hwy", "highway",
    ]

    /// Stable key for a transit stop name, or nil when the name carries no cross-street identity.
    /// "Jane St / Springside Rd", "Jane Street at Springside Rd (North Side)" and
    /// "Springside Rd / Jane St - Platform 2" all collapse to "jane|springside".
    static func identity(forName name: String) -> String? {
        var text = name
            .folding(options: [.diacriticInsensitive, .widthInsensitive], locale: .current)
            .lowercased()

        // Parentheticals and brackets hold side/direction notes, never the cross street.
        text = text.replacingOccurrences(of: "\\([^)]*\\)", with: " ", options: .regularExpression)
        text = text.replacingOccurrences(of: "\\[[^\\]]*\\]", with: " ", options: .regularExpression)
        // Trailing "- platform 2" / "stop #1234", then any bare trailing number.
        text = text.replacingOccurrences(of: "[\\s\\-–—]*(platform|plat|bay|stop)\\s*#?\\s*\\d+\\s*$",
                                         with: " ", options: .regularExpression)
        text = text.replacingOccurrences(of: "[\\s\\-–—]+#?\\d+\\s*$",
                                         with: " ", options: .regularExpression)

        // Fold every cross-street separator onto one delimiter before splitting.
        text = text.replacingOccurrences(of: "/", with: "\u{1}")
        text = text.replacingOccurrences(of: "&", with: "\u{1}")
        text = text.replacingOccurrences(of: "\\bat\\b", with: "\u{1}", options: .regularExpression)
        text = text.replacingOccurrences(of: "\\band\\b", with: "\u{1}", options: .regularExpression)

        let rawParts = text.components(separatedBy: "\u{1}")
        // One part means no cross street — leave the place alone rather than guess.
        guard rawParts.count >= 2 else { return nil }

        var keys: [String] = []
        for part in rawParts {
            // Direction words and street-type suffixes are noise on both sides of the split.
            let tokens = part
                .components(separatedBy: CharacterSet.alphanumerics.inverted)
                .filter { !$0.isEmpty && !directionTokens.contains($0) && !streetTypeTokens.contains($0) }
            guard !tokens.isEmpty else { continue }
            keys.append(tokens.joined(separator: "-"))
        }
        guard keys.count >= 2 else { return nil }
        // Sorted so "A / B" and "B / A" produce the same key.
        return keys.sorted().joined(separator: "|")
    }

    /// Keeps the nearest member of each identity cluster; non-transit places pass through untouched.
    static func deduped(_ places: [Place], origin: CLLocationCoordinate2D) -> [Place] {
        guard places.count > 1 else { return places }

        // Precompute distances once — the sort closure would otherwise rebuild CLLocations per comparison.
        let originLocation = CLLocation(latitude: origin.latitude, longitude: origin.longitude)
        let ranked = places
            .map { (place: $0, distance: distanceMeters(from: originLocation, to: $0.arCoordinate)) }
            .sorted { $0.distance != $1.distance ? $0.distance < $1.distance : $0.place.id < $1.place.id }

        var kept: [(identity: String, coordinate: CLLocationCoordinate2D)] = []
        var dropped: Set<String> = []
        for entry in ranked {
            let place = entry.place
            guard place.category == .transit,
                  let identity = identity(forName: place.name) else { continue }
            let isDuplicate = kept.contains { candidate in
                candidate.identity == identity
                    && distanceMeters(from: candidate.coordinate, to: place.arCoordinate) <= mergeRadiusMeters
            }
            if isDuplicate {
                dropped.insert(place.id)
            } else {
                kept.append((identity, place.arCoordinate))
            }
        }

        guard !dropped.isEmpty else { return places }
        return places.filter { !dropped.contains($0.id) }
    }

    // MARK: - Geodesy

    private static func distanceMeters(from location: CLLocation,
                                       to coordinate: CLLocationCoordinate2D) -> CLLocationDistance {
        location.distance(from: CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude))
    }

    private static func distanceMeters(from a: CLLocationCoordinate2D,
                                       to b: CLLocationCoordinate2D) -> CLLocationDistance {
        CLLocation(latitude: a.latitude, longitude: a.longitude)
            .distance(from: CLLocation(latitude: b.latitude, longitude: b.longitude))
    }
}

#if DEBUG
extension TransitStopIdentity {
    /// One-shot assertions run from AppState.start() in DEBUG; this project has no test target.
    static func selfTest() {
        assert(identity(forName: "Jane St / Springside Rd") == "jane|springside")
        assert(identity(forName: "Jane Street at Springside Rd (North Side)") == "jane|springside")
        assert(identity(forName: "Springside Rd / Jane St - Platform 2") == "jane|springside")
        assert(identity(forName: "Springside Rd & Jane St Northbound") == "jane|springside")
        // No cross street means no identity — never merge two places called "Union Station".
        assert(identity(forName: "Union Station") == nil)

        let origin = CLLocationCoordinate2D(latitude: 43.7700, longitude: -79.5100)
        func stop(_ name: String, _ lat: Double, _ lon: Double,
                  _ category: PlaceCategory = .transit) -> Place {
            let coordinate = CLLocationCoordinate2D(latitude: lat, longitude: lon)
            return Place(id: "\(name)|\(lat)|\(lon)", name: name,
                         category: category, coordinate: coordinate)
        }

        // 74 m and 82 m from origin, ~10 m apart: the near one survives.
        let nearPair = [stop("Jane St / Springside Rd", 43.77066, -79.51000),
                        stop("Springside Rd at Jane St (South Side)", 43.77073, -79.51000)]
        let collapsed = deduped(nearPair, origin: origin)
        assert(collapsed.count == 1)
        assert(collapsed.first?.name == "Jane St / Springside Rd")

        // Same names 400 m apart are two genuinely different corners.
        let farPair = [stop("Jane St / Springside Rd", 43.77066, -79.51000),
                       stop("Springside Rd / Jane St", 43.77426, -79.51000)]
        assert(deduped(farPair, origin: origin).count == 2)

        // Identity-less transit names are never merged.
        let stations = [stop("Union Station", 43.77066, -79.51000),
                        stop("Union Station", 43.77070, -79.51002)]
        assert(deduped(stations, origin: origin).count == 2)

        // A restaurant that happens to be named "A / B" is untouched.
        let restaurants = [stop("Fish / Chips", 43.77066, -79.51000, .restaurant),
                           stop("Chips / Fish", 43.77070, -79.51002, .restaurant)]
        assert(deduped(restaurants, origin: origin).count == 2)
    }
}
#endif
