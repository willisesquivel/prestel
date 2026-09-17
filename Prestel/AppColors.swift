import AppKit
import SwiftUI

private final class AppColorsBundleFinder: NSObject {}

/// Central access to `Assets.xcassets` colors.
///
/// Edit values in Xcode: `Prestel/Assets.xcassets`.
/// Each `Review*` set has Any + Dark variants.
///
/// - SwiftUI (`reviewAddition` / `reviewDeletion`) returns a dynamic
///   `Color` — the system resolves light/dark automatically.
/// - AppKit metrics take `dark:` and return a concrete sRGB color
///   resolved for that appearance, so unit tests
///   (`.usingColorSpace(.sRGB)`) see the right variant even though the
///   catalog stores one dynamic color. At runtime `dark` comes from
///   `effectiveAppearance`, matching what drawing would resolve anyway.
///
/// Fallbacks mirror the catalog values so tests/previews keep working
/// if the catalog is missing from the bundle.
enum AppColors {
    static var bundle: Bundle {
        Bundle(for: AppColorsBundleFinder.self)
    }

    // MARK: - SwiftUI (headers: panel totals + per-file +/− counts)

    static var reviewAddition: Color {
        Color("ReviewAddition", bundle: bundle)
    }

    static var reviewDeletion: Color {
        Color("ReviewDeletion", bundle: bundle)
    }

    // MARK: - AppKit dynamic (markers + bars resolve at draw time)

    static var additionNS: NSColor {
        named("ReviewAddition", fallback: .systemGreen)
    }

    static var deletionNS: NSColor {
        named("ReviewDeletion", fallback: .systemRed)
    }

    static var additionBarNS: NSColor {
        named("ReviewAdditionBar", fallback: NSColor.systemGreen.withAlphaComponent(0.85))
    }

    static var deletionBarNS: NSColor {
        named("ReviewDeletionBar", fallback: NSColor.systemRed.withAlphaComponent(0.85))
    }

    // MARK: - AppKit resolved (metrics + tests need a concrete variant)

    static func addition(dark: Bool) -> NSColor {
        resolved(
            named: "ReviewAddition",
            dark: dark,
            lightFallback: NSColor(srgbRed: 0.204, green: 0.780, blue: 0.349, alpha: 1),
            darkFallback: NSColor(srgbRed: 0.188, green: 0.820, blue: 0.345, alpha: 1)
        )
    }

    static func deletion(dark: Bool) -> NSColor {
        resolved(
            named: "ReviewDeletion",
            dark: dark,
            lightFallback: NSColor(srgbRed: 1.000, green: 0.220, blue: 0.235, alpha: 1),
            darkFallback: NSColor(srgbRed: 1.000, green: 0.259, blue: 0.271, alpha: 1)
        )
    }

    static func additionFill(dark: Bool) -> NSColor {
        resolved(
            named: "ReviewAdditionFill",
            dark: dark,
            lightFallback: NSColor(srgbRed: 0.204, green: 0.780, blue: 0.349, alpha: 0.10),
            darkFallback: NSColor(srgbRed: 0.188, green: 0.820, blue: 0.345, alpha: 0.16)
        )
    }

    static func deletionFill(dark: Bool) -> NSColor {
        resolved(
            named: "ReviewDeletionFill",
            dark: dark,
            lightFallback: NSColor(srgbRed: 1.000, green: 0.220, blue: 0.235, alpha: 0.08),
            darkFallback: NSColor(srgbRed: 1.000, green: 0.259, blue: 0.271, alpha: 0.14)
        )
    }

    static func additionBar(dark: Bool) -> NSColor {
        resolved(
            named: "ReviewAdditionBar",
            dark: dark,
            lightFallback: NSColor(srgbRed: 0.204, green: 0.780, blue: 0.349, alpha: 0.85),
            darkFallback: NSColor(srgbRed: 0.188, green: 0.820, blue: 0.345, alpha: 0.85)
        )
    }

    static func deletionBar(dark: Bool) -> NSColor {
        resolved(
            named: "ReviewDeletionBar",
            dark: dark,
            lightFallback: NSColor(srgbRed: 1.000, green: 0.220, blue: 0.235, alpha: 0.85),
            darkFallback: NSColor(srgbRed: 1.000, green: 0.259, blue: 0.271, alpha: 0.85)
        )
    }

    static func gutterNumber(dark: Bool) -> NSColor {
        resolved(
            named: "ReviewGutterNumber",
            dark: dark,
            lightFallback: NSColor(srgbRed: 0.30, green: 0.31, blue: 0.34, alpha: 1),
            darkFallback: NSColor(srgbRed: 0.80, green: 0.81, blue: 0.83, alpha: 1)
        )
    }

    // MARK: - Private

    private static func named(_ name: String, fallback: NSColor) -> NSColor {
        if let color = NSColor(named: NSColor.Name(name), bundle: bundle) {
            return color
        }
        if let color = NSColor(named: NSColor.Name(name), bundle: .main) {
            return color
        }
        return fallback
    }

    private static func resolved(named name: String, dark: Bool, lightFallback: NSColor, darkFallback: NSColor) -> NSColor {
        let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)!
        var result: NSColor?
        appearance.performAsCurrentDrawingAppearance {
            if let color = NSColor(named: NSColor.Name(name), bundle: bundle)?.usingColorSpace(.sRGB) {
                result = color
            } else if let color = NSColor(named: NSColor.Name(name), bundle: .main)?.usingColorSpace(.sRGB) {
                result = color
            }
        }
        return result ?? (dark ? darkFallback : lightFallback)
    }
}
