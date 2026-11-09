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
            ("serviceSlack", Theme.serviceSlack),
            ("serviceWhatsApp", Theme.serviceWhatsApp),
            ("textDisabled", Theme.textDisabled)
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

    // MARK: - Increase Contrast variants

    func testSemanticColorsMeetAAUnderIncreaseContrast() throws {
        ThemeEnvironment.forceIncreaseContrast = true
        defer { ThemeEnvironment.forceIncreaseContrast = nil }
        let foregrounds: [(String, Color)] = [
            ("textPrimary", Theme.textPrimary), ("textSecondary", Theme.textSecondary),
            ("textTertiary", Theme.textTertiary), ("textDisabled", Theme.textDisabled),
            ("signal", Theme.signal), ("standby", Theme.standby), ("ok", Theme.ok),
            ("serviceWhatsApp", Theme.serviceWhatsApp)
        ]
        for appearanceName in [NSAppearance.Name.aqua, .darkAqua] {
            let appearance = try XCTUnwrap(NSAppearance(named: appearanceName))
            for (fgName, fg) in foregrounds {
                for (bgName, bg) in standardBackgrounds {
                    let ratio = contrastRatio(resolved(fg, appearance: appearance), resolved(bg, appearance: appearance))
                    XCTAssertGreaterThanOrEqual(ratio, 4.5,
                        "[Increase Contrast] \(fgName) on \(bgName) is \(ratio):1 in \(appearanceName.rawValue)")
                }
            }
            // Hairlines are UI components: 3:1 against the ground (WCAG 1.4.11).
            for (bgName, bg) in standardBackgrounds.prefix(3) {
                let ratio = contrastRatio(resolved(Theme.border, appearance: appearance), resolved(bg, appearance: appearance))
                XCTAssertGreaterThanOrEqual(ratio, 3.0,
                    "[Increase Contrast] border on \(bgName) is \(ratio):1 in \(appearanceName.rawValue)")
            }
        }
    }

    // MARK: - Composite surfaces

    /// Text on the translucent surfaces the app really draws it on: the error
    /// banner (signalWash), Act section headers (surfaceHigh at 50%).
    func testTextOnTranslucentSurfacesMeetsAA() throws {
        let foregrounds: [(String, Color)] = [
            ("textPrimary", Theme.textPrimary), ("textSecondary", Theme.textSecondary),
            ("textTertiary", Theme.textTertiary), ("signal", Theme.signal),
            ("standby", Theme.standby), ("ok", Theme.ok)
        ]
        for contrastOn in [false, true] {
            ThemeEnvironment.forceIncreaseContrast = contrastOn
            defer { ThemeEnvironment.forceIncreaseContrast = nil }
            for appearanceName in [NSAppearance.Name.aqua, .darkAqua] {
                let appearance = try XCTUnwrap(NSAppearance(named: appearanceName))
                for groundName in ["bg", "sidebar"] {
                    let ground = resolved(groundName == "bg" ? Theme.bg : Theme.sidebar, appearance: appearance)
                    let surfaces: [(String, NSColor)] = [
                        ("signalWash", over(resolved(Theme.signal, appearance: appearance), alpha: 0.10, ground)),
                        ("surfaceHigh@50%", over(resolved(Theme.surfaceHigh, appearance: appearance), alpha: 0.5, ground))
                    ]
                    for (fgName, fg) in foregrounds {
                        for (surfaceName, surface) in surfaces {
                            let ratio = contrastRatio(resolved(fg, appearance: appearance), surface)
                            XCTAssertGreaterThanOrEqual(ratio, 4.5,
                                "\(fgName) on \(surfaceName) over \(groundName) is \(ratio):1 in \(appearanceName.rawValue) (increaseContrast=\(contrastOn))")
                        }
                    }
                }
            }
        }
    }

    // MARK: - Filled controls

    /// The label on a filled `PrimaryActionStyle` button (resting and hovered)
    /// and on the Act rail's count badge. White on the bright dark-mode amber
    /// was ~1.7:1, which is why the label is `Theme.onTint`.
    func testLabelOnFilledControlsMeetsAA() throws {
        for contrastOn in [false, true] {
            ThemeEnvironment.forceIncreaseContrast = contrastOn
            defer { ThemeEnvironment.forceIncreaseContrast = nil }
            for appearanceName in [NSAppearance.Name.aqua, .darkAqua] {
                let appearance = try XCTUnwrap(NSAppearance(named: appearanceName))
                let bg = resolved(Theme.bg, appearance: appearance)
                let label = resolved(Theme.onTint, appearance: appearance)
                let amber = resolved(Theme.standby, appearance: appearance)
                let signal = resolved(Theme.signal, appearance: appearance)
                let fills: [(String, NSColor)] = [
                    ("PrimaryActionStyle fill", amber),
                    ("PrimaryActionStyle fill, hovered", over(amber, alpha: 0.85, bg)),
                    ("Act badge fill", signal)
                ]
                for (name, fill) in fills {
                    let ratio = contrastRatio(label, fill)
                    XCTAssertGreaterThanOrEqual(ratio, 4.5,
                        "onTint on \(name) is \(ratio):1 in \(appearanceName.rawValue) (increaseContrast=\(contrastOn))")
                }
                // The prominent PaperButtonStyle is ink-on-paper by construction; pin it.
                let paper = contrastRatio(resolved(Theme.bg, appearance: appearance),
                                          resolved(Theme.textPrimary, appearance: appearance))
                XCTAssertGreaterThanOrEqual(paper, 7.0, "PaperButtonStyle(prominent) is \(paper):1")
            }
        }
    }

    private var standardBackgrounds: [(String, Color)] {
        [("bg", Theme.bg), ("sidebar", Theme.sidebar), ("surface", Theme.surface), ("surfaceHigh", Theme.surfaceHigh)]
    }

    /// `fg` at `alpha` composited over opaque `background`.
    private func over(_ fg: NSColor, alpha: CGFloat, _ background: NSColor) -> NSColor {
        let f = fg.usingColorSpace(.sRGB) ?? fg
        let b = background.usingColorSpace(.sRGB) ?? background
        return NSColor(srgbRed: f.redComponent * alpha + b.redComponent * (1 - alpha),
                       green: f.greenComponent * alpha + b.greenComponent * (1 - alpha),
                       blue: f.blueComponent * alpha + b.blueComponent * (1 - alpha),
                       alpha: 1)
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
