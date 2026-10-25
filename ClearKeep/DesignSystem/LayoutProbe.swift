import SwiftUI

#if DEBUG
struct LayoutFramesKey: PreferenceKey {
    static let defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) { value.merge(nextValue(), uniquingKeysWith: { _, next in next }) }
}
#endif

extension View {
    @ViewBuilder func layoutProbe(_ identifier: String) -> some View {
        #if DEBUG
        background(GeometryReader { proxy in Color.clear.preference(key: LayoutFramesKey.self, value: [identifier: proxy.frame(in: .global)]) })
        #else
        self
        #endif
    }
}
