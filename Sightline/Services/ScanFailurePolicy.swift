import Foundation
import MapKit

/// Error -> the one thing worth telling the user. Copy lives at the render site; nothing here is user-visible.
enum ScanFailurePolicy {

    /// URLError is a struct, so classification is by code. NSError values in NSURLErrorDomain bridge to these.
    private static let connectivityCodes: Set<URLError.Code> = [
        .notConnectedToInternet, .networkConnectionLost, .timedOut,
        .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed,
        .dataNotAllowed, .internationalRoamingOff, .callIsActive,
        .cannotLoadFromNetwork, .secureConnectionFailed,
    ]

    static func classify(_ error: Error) -> ScanFailure {
        if error is CancellationError { return .other }
        if let mapKit = error as? MKError {
            if mapKit.code == .loadingThrottled { return .serviceBusy }
            // MapKit wraps the network failure; the underlying URLError is what says "offline".
            if let underlying = (error as NSError).userInfo[NSUnderlyingErrorKey] as? Error {
                return classify(underlying)
            }
            return .other
        }
        guard let urlError = error as? URLError else { return .other }
        return connectivityCodes.contains(urlError.code) ? .offline : .other
    }
}
