import Foundation
import CoreLocation

/// A single place to probe; deliberately plain values so nothing non-Sendable crosses the actor boundary.
struct StreetViewProbe: Sendable {
    let id: String
    let latitude: Double
    let longitude: Double

    init(id: String, coordinate: CLLocationCoordinate2D) {
        self.id = id
        self.latitude = coordinate.latitude
        self.longitude = coordinate.longitude
    }
}

/// Street View coverage is a low-confidence ranking signal, not physical visibility: no outdoor pano within 25 m only suggests the place can't be seen from the street; every failure mode stays neutral.
actor StreetViewVisibilityService {

    static let shared = StreetViewVisibilityService()

    /// Verdict per place id for this session — true means "demote", never "hide".
    private var cache: [String: Bool] = [:]
    private let session: URLSession

    /// Modest parallelism: the endpoint is free but its per-client rate limits are undocumented.
    private static let maxConcurrentProbes = 5
    private static let probeRadiusMeters = 25
    private static let bundleID = Bundle.main.bundleIdentifier ?? "com.ahmedbegovic.Sightline"

    // Injectable session is a test seam only; production always uses the configured default.
    init(session: URLSession? = nil) {
        if let session {
            self.session = session
        } else {
            let config = URLSessionConfiguration.default
            config.timeoutIntervalForRequest = 6
            config.timeoutIntervalForResource = 6
            self.session = URLSession(configuration: config)
        }
    }

    /// Verdicts keyed by place id, cached ones included. Missing keys simply mean "no answer yet".
    func verdicts(for probes: [StreetViewProbe]) async -> [String: Bool] {
        var verdicts: [String: Bool] = [:]
        var pending: [StreetViewProbe] = []
        for probe in probes {
            if let cached = cache[probe.id] {
                verdicts[probe.id] = cached
            } else {
                pending.append(probe)
            }
        }
        guard !pending.isEmpty else { return verdicts }

        await withTaskGroup(of: (id: String, unlikely: Bool?).self) { group in
            var next = 0
            var inFlight = 0
            // Sliding window: keep at most `maxConcurrentProbes` requests alive, starting a new one as each lands.
            while next < pending.count || inFlight > 0 {
                if inFlight < Self.maxConcurrentProbes, next < pending.count {
                    let probe = pending[next]
                    next += 1
                    inFlight += 1
                    group.addTask { [weak self] in
                        guard let self else { return (probe.id, nil) }
                        return (probe.id, await self.hasNoOutdoorPano(probe))
                    }
                    continue
                }
                guard let finished = await group.next() else { break }
                inFlight -= 1
                // Only real answers are cached; an error or a cancelled probe leaves the id re-probeable next scan.
                guard let unlikely = finished.unlikely, !Task.isCancelled else { continue }
                cache[finished.id] = unlikely
                verdicts[finished.id] = unlikely
            }
        }
        return verdicts
    }

    /// True only for ZERO_RESULTS, false only for OK; every other status (REQUEST_DENIED, OVER_QUERY_LIMIT, ...) is nil, so an API error can never masquerade as a coverage answer.
    nonisolated private func hasNoOutdoorPano(_ probe: StreetViewProbe) async -> Bool? {
        var components = URLComponents(string: "https://maps.googleapis.com/maps/api/streetview/metadata")
        components?.queryItems = [
            URLQueryItem(name: "location", value: "\(probe.latitude),\(probe.longitude)"),
            URLQueryItem(name: "radius", value: String(Self.probeRadiusMeters)),
            URLQueryItem(name: "source", value: "outdoor"),
            URLQueryItem(name: "key", value: Secrets.googleAPIKey),
        ]
        guard let url = components?.url else { return nil }

        var request = URLRequest(url: url)
        request.setValue(Self.bundleID, forHTTPHeaderField: "X-Ios-Bundle-Identifier")

        guard let (data, response) = try? await session.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let status = (try? JSONDecoder().decode(MetadataResponse.self, from: data))?.status
        else { return nil }
        switch status {
        case "OK": return false
        case "ZERO_RESULTS": return true
        default: return nil
        }
    }

    private struct MetadataResponse: Decodable { let status: String? }
}
