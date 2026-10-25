import SwiftUI

enum CKColor {
    private static func adaptive(light: UIColor, dark: UIColor) -> Color {
        Color(UIColor { $0.userInterfaceStyle == .dark ? dark : light })
    }
    static let canvas = adaptive(light: UIColor(red: 0.969, green: 0.973, blue: 0.961, alpha: 1), dark: UIColor(red: 0.063, green: 0.071, blue: 0.063, alpha: 1))
    static let surface = adaptive(light: .white, dark: UIColor(red: 0.106, green: 0.118, blue: 0.106, alpha: 1))
    static let muted = adaptive(light: UIColor(red: 0.933, green: 0.945, blue: 0.929, alpha: 1), dark: UIColor(red: 0.145, green: 0.161, blue: 0.145, alpha: 1))
    static let ink = adaptive(light: UIColor(red: 0.094, green: 0.125, blue: 0.098, alpha: 1), dark: UIColor(red: 0.953, green: 0.965, blue: 0.945, alpha: 1))
    static let secondary = adaptive(light: UIColor(red: 0.325, green: 0.376, blue: 0.341, alpha: 1), dark: UIColor(red: 0.702, green: 0.741, blue: 0.710, alpha: 1))
    static let keep = adaptive(light: UIColor(red: 0.090, green: 0.420, blue: 0.318, alpha: 1), dark: UIColor(red: 0.380, green: 0.788, blue: 0.655, alpha: 1))
    static let keepSurface = adaptive(light: UIColor(red: 0.867, green: 0.953, blue: 0.914, alpha: 1), dark: UIColor(red: 0.090, green: 0.227, blue: 0.188, alpha: 1))
    static let focus = adaptive(light: UIColor(red: 0.192, green: 0.361, blue: 0.745, alpha: 1), dark: UIColor(red: 0.557, green: 0.694, blue: 1, alpha: 1))
    static let onFocus = adaptive(light: .white, dark: UIColor(red: 0.063, green: 0.071, blue: 0.063, alpha: 1))
}

struct PrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline).frame(maxWidth: .infinity, minHeight: 44)
            .padding(.horizontal, 16).foregroundStyle(isEnabled ? CKColor.onFocus : CKColor.secondary)
            .background(CKColor.focus.opacity(isEnabled ? (configuration.isPressed ? 0.75 : 1) : 0.18), in: RoundedRectangle(cornerRadius: 14))
            .layoutProbe("primaryAction")
    }
}

struct PrivacyPill: View {
    var body: some View {
        Label("Analyzed on your iPhone", systemImage: "checkmark.shield")
            .font(.subheadline.weight(.semibold)).foregroundStyle(CKColor.keep)
            .padding(.horizontal, 12).frame(minHeight: 44)
            .background(CKColor.keepSurface, in: Capsule())
            .accessibilityElement(children: .combine)
    }
}
