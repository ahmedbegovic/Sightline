import CoreLocation
import Foundation

/// Error -> the one thing worth telling the user. Copy lives at the render site; nothing here is user-visible.
enum ScanFailurePolicy {

    /// A fix older than this no longer says where the user is standing now.
    static let maxLocationAge: TimeInterval = 30
    /// Roughly a city block; a cone aimed from a vaguer fix returns the wrong street's places.
    static let maxHorizontalAccuracy: CLLocationDistance = 65

    /// URLError is a struct, so classification is by code. NSError values in NSURLErrorDomain bridge to these.
    private static let connectivityCodes: Set<URLError.Code> = [
        .notConnectedToInternet, .networkConnectionLost, .timedOut,
        .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed,
        .dataNotAllowed, .internationalRoamingOff, .callIsActive,
        .cannotLoadFromNetwork, .secureConnectionFailed,
    ]

    /// Pre-scan gate; nil means good enough to aim a cone with. Call only where real sensor metadata exists — simulator poses are synthetic and exempt at the call site.
    static func sensorFailure(location: CLLocation,
                              compassUnreliable: Bool,
                              now: Date = Date()) -> ScanFailure? {
        // horizontalAccuracy < 0 is CoreLocation's "invalid fix" sentinel, not a great fix.
        if location.horizontalAccuracy < 0 || location.horizontalAccuracy > maxHorizontalAccuracy {
            return .poorSensors
        }
        if now.timeIntervalSince(location.timestamp) > maxLocationAge { return .poorSensors }
        if compassUnreliable { return .poorSensors }
        return nil
    }

    static func classify(_ error: Error) -> ScanFailure {
        // Cancellation never reaches the user (both call sites check Task.isCancelled first) — classify it defensively anyway.
        if error is CancellationError { return .other }
        // HTTP-status classes get their own copy; a 429 telling the user to "check your connection" is a lie.
        if let request = error as? GooglePlacesService.RequestError {
            switch request {
            case .accessDenied: return .accessDenied
            case .rateLimited, .serverError: return .serviceBusy
            case .badRequest: return .other
            }
        }
        guard let urlError = error as? URLError else { return .other }
        if urlError.code == .cancelled { return .other }
        return connectivityCodes.contains(urlError.code) ? .offline : .other
    }
}

#if DEBUG
extension ScanFailurePolicy {
    /// One-shot assertions run from AppState.start() in DEBUG; the XCTest suite in SightlineTests now covers these, and this remains a belt-and-suspenders debug check.
    static func selfTest() {
        assert(classify(URLError(.notConnectedToInternet)) == .offline)
        assert(classify(URLError(.timedOut)) == .offline)
        assert(classify(URLError(.networkConnectionLost)) == .offline)
        // An HTTP 403 or a decode failure is not a connectivity problem and must not claim to be one.
        assert(classify(GooglePlacesService.APIError(message: "Places API error 403")) == .other)
        assert(classify(URLError(.badServerResponse)) == .other)
        assert(classify(CancellationError()) == .other)
        assert(classify(GooglePlacesService.RequestError.accessDenied(status: 403, message: nil)) == .accessDenied)
        assert(classify(GooglePlacesService.RequestError.rateLimited(status: 429, message: nil)) == .serviceBusy)
        assert(classify(GooglePlacesService.RequestError.serverError(status: 503, message: nil)) == .serviceBusy)
        assert(classify(GooglePlacesService.RequestError.badRequest(status: 400, message: nil)) == .other)
        // NSError in the URL domain must classify the same as the bridged struct.
        assert(classify(NSError(domain: NSURLErrorDomain, code: -1009)) == .offline)

        func fix(accuracy: CLLocationDistance, age: TimeInterval) -> CLLocation {
            CLLocation(coordinate: CLLocationCoordinate2D(latitude: 37.7880, longitude: -122.4074),
                       altitude: 0, horizontalAccuracy: accuracy, verticalAccuracy: 5,
                       timestamp: Date(timeIntervalSinceNow: -age))
        }
        assert(sensorFailure(location: fix(accuracy: 12, age: 1), compassUnreliable: false) == nil)
        assert(sensorFailure(location: fix(accuracy: -1, age: 1), compassUnreliable: false) == .poorSensors)
        assert(sensorFailure(location: fix(accuracy: 200, age: 1), compassUnreliable: false) == .poorSensors)
        assert(sensorFailure(location: fix(accuracy: 12, age: 120), compassUnreliable: false) == .poorSensors)
        assert(sensorFailure(location: fix(accuracy: 12, age: 1), compassUnreliable: true) == .poorSensors)
        // The thresholds themselves are usable — the gate rejects only strictly worse metadata.
        assert(sensorFailure(location: fix(accuracy: maxHorizontalAccuracy, age: 0), compassUnreliable: false) == nil)
    }
}
#endif
