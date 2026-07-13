import AppKit
import SwiftUI
import XCTest
@testable import LLMessenger

@MainActor
final class ThemeContrastTests: XCTestCase {
    func testSemanticColorsMeetAAInLightAndDarkAppearances() throws {
        let foregrounds: [(String, Color)] = [
            ("textPrimary", Theme.textPrimary),
            ("textSecondary", Theme.textSecondary),
            ("textTertiary", Theme.textTertiary),
            ("signal", Theme.signal),
            ("standby", Theme.standby),
            ("ok", Theme.ok),
            ("serviceIMessage", Theme.serviceIMessage),
            ("serviceTelegram", Theme.serviceTelegram),
            ("serviceSignal", Theme.serviceSignal),
            ("serviceSlack", Theme.serviceSlack)
        ]
        let backgrounds: [(String, Color)] = [
            ("bg", Theme.bg),
            ("sidebar", Theme.sidebar),
            ("surface", Theme.surface),
            ("surfaceHigh", Theme.surfaceHigh)
        ]

        for appearanceName in [NSAppearance.Name.aqua, .darkAqua] {
            let appearance = try XCTUnwrap(NSAppearance(named: appearanceName))
            for (foregroundName, foreground) in foregrounds {
                for (backgroundName, background) in backgrounds {
                    let ratio = contrastRatio(
                        resolved(foreground, appearance: appearance),
                        resolved(background, appearance: appearance)
                    )
                    XCTAssertGreaterThanOrEqual(
                        ratio,
                        4.5,
                        "\(foregroundName) on \(backgroundName) is \(ratio):1 in \(appearanceName.rawValue)"
                    )
                }
            }
        }
    }

    private func resolved(_ color: Color, appearance: NSAppearance) -> NSColor {
        var resolved = NSColor.clear
        appearance.performAsCurrentDrawingAppearance {
            resolved = NSColor(color).usingColorSpace(.sRGB) ?? NSColor(color)
        }
        return resolved
    }

    private func contrastRatio(_ lhs: NSColor, _ rhs: NSColor) -> CGFloat {
        let lighter = max(luminance(lhs), luminance(rhs))
        let darker = min(luminance(lhs), luminance(rhs))
        return (lighter + 0.05) / (darker + 0.05)
    }

    private func luminance(_ color: NSColor) -> CGFloat {
        let rgb = color.usingColorSpace(.sRGB) ?? color
        return 0.2126 * linear(rgb.redComponent)
            + 0.7152 * linear(rgb.greenComponent)
            + 0.0722 * linear(rgb.blueComponent)
    }

    private func linear(_ component: CGFloat) -> CGFloat {
        component <= 0.04045
            ? component / 12.92
            : pow((component + 0.055) / 1.055, 2.4)
    }
}
