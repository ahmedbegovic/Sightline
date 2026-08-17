import Foundation
import Combine

@MainActor
final class ScanUIModel: ObservableObject {
    @Published var state: ScanState = .idle
    @Published var resultsLabel: String?
    let search = SearchTextModel()
}

@MainActor
final class SearchTextModel: ObservableObject {
    @Published var text: String = ""
}
