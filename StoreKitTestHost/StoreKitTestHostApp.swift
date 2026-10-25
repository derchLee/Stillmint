import SwiftUI

/// Separate test host compiles the same production sources without initializing the normal AppModel.
/// Only this target contains the local StoreKit configuration; it is not a shipping product.
@main struct StoreKitTestHostApp: App {
    var body: some Scene { WindowGroup { Color.clear } }
}
