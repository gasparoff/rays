import LightCore
import SwiftUI

/// 30 Hz live state from the engine (separate object so static UI does not re-render).
final class LiveState: ObservableObject {
    @Published var snapshot = EngineSnapshot()
}
