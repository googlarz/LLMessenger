// LLMessenger/UI/Theme.swift
//
// "The Wire Desk" design system.
//
// LLMessenger compiles your messages into an intelligence brief, so the UI is
// typeset like one: editorial serif headlines (New York), wire-service mono for
// evidence and metadata (SF Mono), and a near-monochrome ink ground where
// COLOR MEANS URGENCY — vermilion is reserved for "needs you now", everything
// else stays ink and paper. Services appear as muted ink stamps, never as
// saturated brand colors.
//
// All colours and type styles live here — do not hardcode either elsewhere.

import SwiftUI

// MARK: - Appearance-adaptive color helper

extension Color {
    /// Creates a color that resolves to `light` in the light appearance and `dark` in dark.
    /// Optional `lightHC`/`darkHC` variants are used when the user enables
    /// Increase Contrast in System Settings > Accessibility.
    init(light: Color, dark: Color, lightHC: Color? = nil, darkHC: Color? = nil) {
        self.init(NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            let highContrast = ThemeEnvironment.forceIncreaseContrast
                ?? NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
            if isDark {
                return NSColor(highContrast ? (darkHC ?? dark) : dark)
            }
            return NSColor(highContrast ? (lightHC ?? light) : light)
        })
    }
}

/// Test seam: lets the contrast tests resolve the Increase Contrast branches
/// of every adaptive colour without flipping a system setting.
enum ThemeEnvironment {
    nonisolated(unsafe) static var forceIncreaseContrast: Bool?
}

enum Theme {

    // MARK: - Ink (ground) — semantic, appearance-adaptive

    /// Window ground.
    static let bg = Color(
        light: Color(red: 0.976, green: 0.973, blue: 0.965),   // #F9F8F6 warm paper
        dark:  Color(red: 0.055, green: 0.067, blue: 0.082)    // #0E1115
    )
    /// Sidebar / chrome ground, one step below the page.
    static let sidebar = Color(
        light: Color(red: 0.941, green: 0.937, blue: 0.925),   // #F0EFEC
        dark:  Color(red: 0.043, green: 0.053, blue: 0.065)    // #0B0D11
    )
    /// Raised surface: cards' hover wash, fields, popovers.
    static let surface = Color(
        light: Color(red: 0.957, green: 0.953, blue: 0.945),   // #F4F3F1
        dark:  Color(red: 0.082, green: 0.098, blue: 0.118)    // #15191E
    )
    /// Highest surface step: active chips, pressed states.
    static let surfaceHigh = Color(
        light: Color(red: 0.914, green: 0.910, blue: 0.898),   // #E9E8E5
        dark:  Color(red: 0.114, green: 0.133, blue: 0.157)    // #1D2228
    )
    /// Hairline rule colour. Full-strength under Increase Contrast.
    static let border = Color(
        light: Color(red: 0.780, green: 0.769, blue: 0.745).opacity(0.7),
        dark:  Color(red: 0.227, green: 0.247, blue: 0.271).opacity(0.55),
        lightHC: Color(red: 0.55, green: 0.54, blue: 0.52),
        darkHC:  Color(red: 0.42, green: 0.45, blue: 0.49)
    )
    /// Row selection wash.
    static let selection = Color(
        light: Color(red: 0.914, green: 0.910, blue: 0.898),
        dark:  Color(red: 0.114, green: 0.133, blue: 0.157)
    )

    // MARK: - Text — warm against the ground

    static let textPrimary = Color(
        light: Color(red: 0.090, green: 0.082, blue: 0.067),
        dark:  Color(red: 0.965, green: 0.949, blue: 0.918)
    )
    static let textSecondary = Color(
        light: Color(red: 0.235, green: 0.224, blue: 0.200),
        dark:  Color(red: 0.820, green: 0.804, blue: 0.765)
    )
    // Carries real content (timestamps, agent reasoning, captions). Keep substantial
    // headroom above AA because small macOS text loses contrast to antialiasing and several
    // call sites intentionally place this token on raised or translucent surfaces.
    static let textTertiary = Color(
        light: Color(red: 0.300, green: 0.290, blue: 0.267),
        dark:  Color(red: 0.745, green: 0.729, blue: 0.690),
        lightHC: Color(red: 0.16, green: 0.15, blue: 0.13),
        darkHC:  Color(red: 0.87, green: 0.86, blue: 0.83)
    )

    // MARK: - Signal — the only colour that means anything

    // Appearance-adaptive: the bright RGBs read on the dark ground but fail WCAG AA as small
    // text/labels on the warm-paper light ground, so light mode gets darker branches that the
    // audit verified ≥4.5:1 on #F9F8F6. Dark mode unchanged.
    /// Vermilion. Urgency, unread, "needs you now". Use in small doses.
    static let signal = Color(
        light: Color(red: 0.700, green: 0.165, blue: 0.082),
        dark:  Color(red: 0.980, green: 0.420, blue: 0.300)
    )
    static let signalWash  = signal.opacity(0.10)
    /// Label colour on a filled `tint` button (PrimaryActionStyle). White on the
    /// bright dark-mode amber is ~1.7:1, so dark mode flips to ink.
    static let onTint = Color(
        light: Color(red: 1, green: 1, blue: 1),
        dark:  Color(red: 0.055, green: 0.067, blue: 0.082)
    )
    /// Text of a control that is switched off. Disabled controls are exempt from
    /// WCAG contrast, but this stays readable (>= 3:1) and is never the only cue:
    /// pair it with a word such as "off".
    static let textDisabled = Color(
        light: Color(red: 0.420, green: 0.405, blue: 0.375),
        dark:  Color(red: 0.600, green: 0.588, blue: 0.557),
        lightHC: Color(red: 0.30, green: 0.29, blue: 0.27),
        darkHC:  Color(red: 0.78, green: 0.77, blue: 0.74)
    )
    /// Standby amber — partial states, warnings, "heads-up".
    static let standby = Color(
        light: Color(red: 0.505, green: 0.337, blue: 0.055),
        dark:  Color(red: 0.930, green: 0.735, blue: 0.380)
    )
    /// Quiet sage — health OK, handled, success. Desaturated on purpose.
    static let ok = Color(
        light: Color(red: 0.180, green: 0.405, blue: 0.188),
        dark:  Color(red: 0.650, green: 0.800, blue: 0.615)
    )

    // Legacy aliases — `accent` now maps to the signal vermilion.
    static let accent      = signal
    static let accentMuted = signalWash
    static let unread      = signal
    static let separator   = border

    // MARK: - Service inks — uniform saturation, like rubber stamps

    static let serviceIMessage = Color(
        light: Color(red: 0.180, green: 0.380, blue: 0.170),
        dark: Color(red: 0.640, green: 0.800, blue: 0.610)
    )
    static let serviceTelegram = Color(
        light: Color(red: 0.150, green: 0.340, blue: 0.480),
        dark: Color(red: 0.550, green: 0.750, blue: 0.880)
    )
    static let serviceSignal = Color(
        light: Color(red: 0.280, green: 0.320, blue: 0.580),
        dark: Color(red: 0.650, green: 0.700, blue: 0.950)
    )
    static let serviceSlack = Color(
        light: Color(red: 0.400, green: 0.250, blue: 0.450),
        dark: Color(red: 0.780, green: 0.620, blue: 0.820)
    )

    static let serviceWhatsApp = Color(
        light: Color(red: 0.130, green: 0.400, blue: 0.300),
        dark: Color(red: 0.560, green: 0.840, blue: 0.700)
    )

    static func serviceName(_ service: String) -> String {
        switch service {
        case "imessage": return "iMessage"
        case "telegram": return "Telegram"
        case "signal":   return "Signal"
        case "slack":    return "Slack"
        case "whatsapp": return "WhatsApp"
        default:         return service.capitalized
        }
    }

    static func serviceColor(_ service: String) -> Color {
        switch service {
        case "imessage": return serviceIMessage
        case "telegram": return serviceTelegram
        case "signal":   return serviceSignal
        case "slack":    return serviceSlack
        case "whatsapp": return serviceWhatsApp
        default:         return textTertiary
        }
    }

    // MARK: - Typography — three voices

    /// No text is set below this size anywhere in the app. The three font
    /// constructors clamp to it, and `UIFontFloorTests` fails if a literal
    /// smaller size appears in the UI sources.
    static let minimumFontSize: CGFloat = 10

    /// Editorial voice: brief and card headlines. New York, the system serif.
    static func display(_ size: CGFloat, weight: Font.Weight = .semibold) -> Font {
        .system(size: max(size, minimumFontSize), weight: weight, design: .serif)
    }
    /// Wire voice: timestamps, counts, section labels, evidence metadata.
    static func mono(_ size: CGFloat, weight: Font.Weight = .medium) -> Font {
        .system(size: max(size, minimumFontSize), weight: weight, design: .monospaced)
    }
    /// Interface voice: body copy and controls.
    static func sans(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: max(size, minimumFontSize), weight: weight)
    }

    // Named styles
    static let headlineFont  = display(22)                 // brief headline
    static let cardTitleFont = display(16.5)               // card headline
    static let bodyFont      = sans(13.5)                  // prose
    static let labelFont     = mono(10.5, weight: .semibold) // tracked microlabels

    // Wire-voice ladder — three steps, derived from the app's actual usage
    // clusters rather than invented. New mono-caps UI should reach for one of
    // these instead of a fourth ad-hoc size/tracking pair.
    /// Section headers, sidebar/rail labels. Same as `labelFont`.
    static let wireSection = mono(10.5, weight: .semibold)
    static let wireSectionTracking: CGFloat = 1.3
    /// Chips, timestamps, sender stamps — small inline metadata.
    static let wireMeta = mono(11, weight: .medium)
    static let wireMetaTracking: CGFloat = 0.8
    /// Wire-voice buttons that intentionally keep the mono idiom (e.g. QUEUE SEND).
    static let wireControl = mono(11, weight: .semibold)
    static let wireControlTracking: CGFloat = 0.4
    static let microFont     = mono(10)

    /// Tracking for uppercase mono microlabels ("PRIORITY", "3 SOURCES").
    static let labelTracking: CGFloat = 1.3

    // MARK: - Metrics

    /// Hairline rule width — newspaper column rules, not 1px borders.
    static let hairline: CGFloat = 0.5
    /// Page gutter for the main reading column.
    static let gutter: CGFloat = 32
    static let radius: CGFloat = 6        // quiet corner radius for the few true containers
    static let controlRadius: CGFloat = 5

    // MARK: - Motion

    /// Honors Reduce Motion: springs collapse to an imperceptible linear step
    /// so state still updates without movement.
    static var reduceMotion: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    static var spring: Animation {
        reduceMotion ? .linear(duration: 0.01) : .spring(response: 0.32, dampingFraction: 0.86)
    }
    static var quick: Animation {
        reduceMotion ? .linear(duration: 0.01) : .easeOut(duration: 0.14)
    }

    // MARK: - Shared date formatters
    // DateFormatter init costs ~0.1–1 ms; per-row view code must use these
    // cached instances instead of allocating one per call.

    static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f
    }()

    static let dayMonthFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "d MMM"
        return f
    }()

    static let dayMonthTimeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "d MMM, HH:mm"
        return f
    }()
}

// MARK: - Shared components

/// Uppercase, letterspaced mono microlabel — the system's section voice.
struct WireLabel: View {
    let text: String
    var color: Color = Theme.textTertiary

    init(_ text: String, color: Color = Theme.textTertiary) {
        self.text = text
        self.color = color
    }

    var body: some View {
        Text(text.uppercased())
            .font(Theme.labelFont)
            .tracking(Theme.labelTracking)
            .foregroundStyle(color)
    }
}

/// Horizontal hairline rule.
struct Rule: View {
    var color: Color = Theme.border
    var body: some View {
        color.frame(height: Theme.hairline)
    }
}

/// Service ink stamp: bordered mono initials, like a rubber stamp. Replaces
/// the old filled badge — quiet, uniform, unmistakably "filed from".
struct ServiceStamp: View {
    let service: String
    var size: CGFloat = 20

    var body: some View {
        Text(initials)
            .font(Theme.mono(10, weight: .bold))
            .tracking(0.5)
            .foregroundStyle(Theme.serviceColor(service))
            .frame(width: size + 6, height: size - 4)
            .overlay(
                RoundedRectangle(cornerRadius: 3)
                    .strokeBorder(Theme.serviceColor(service).opacity(0.55), lineWidth: 1)
            )
    }

    private var initials: String {
        switch service {
        case "imessage": return "IM"
        case "telegram": return "TG"
        case "signal":   return "SG"
        case "slack":    return "SL"
        case "whatsapp": return "WA"
        default:         return String(service.prefix(2)).uppercased()
        }
    }
}

// MARK: - Keyboard focus

/// The one focus indicator: a paper-coloured ring just outside the control.
/// Shown only while the control has keyboard focus (Full Keyboard Access / Tab),
/// thicker under Increase Contrast. Paper-on-ink matches "interactive = paper,
/// never a hue" and contrasts with both grounds.
private struct FocusRingModifier: ViewModifier {
    var radius: CGFloat
    @Environment(\.isFocused) private var isFocused
    @Environment(\.colorSchemeContrast) private var contrast

    func body(content: Content) -> some View {
        content.overlay(
            RoundedRectangle(cornerRadius: radius + 2)
                .strokeBorder(Theme.textPrimary, lineWidth: contrast == .increased ? 3 : 2)
                .padding(-3)
                .opacity(isFocused ? 1 : 0)
                .allowsHitTesting(false)
        )
    }
}

extension View {
    /// Draws the shared keyboard-focus ring. Put it on the label of a custom
    /// button style, or on any focusable control that draws its own chrome.
    func focusRing(radius: CGFloat = Theme.controlRadius) -> some View {
        modifier(FocusRingModifier(radius: radius))
    }

    /// Guarantees a 24x24pt hit area without changing the visual size of an
    /// icon-only control (WCAG 2.5.8 target size).
    func minimumHitTarget(_ side: CGFloat = 24) -> some View {
        frame(minWidth: side, minHeight: side).contentShape(Rectangle())
    }
}

/// Replacement for `.plain`: no chrome, but a visible focus ring and a pressed
/// state, and every icon-only button gets at least a 24pt target.
struct QuietButtonStyle: ButtonStyle {
    var radius: CGFloat = Theme.controlRadius
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .contentShape(Rectangle())
            .focusRing(radius: radius)
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}

extension ButtonStyle where Self == QuietButtonStyle {
    static var quiet: QuietButtonStyle { QuietButtonStyle() }
}

/// Icon-only control (dismiss, retry, chevron): visual size is the caller's,
/// the hit area is never smaller than 24x24pt.
struct IconButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .minimumHitTarget()
            .focusRing()
            .opacity(configuration.isPressed ? 0.6 : 1)
    }
}

extension ButtonStyle where Self == IconButtonStyle {
    static var icon: IconButtonStyle { IconButtonStyle() }
}

/// Primary action: paper on ink — the inverted button. Secondary: quiet text.
struct PaperButtonStyle: ButtonStyle {
    var prominent = false
    /// Override for buttons that carry the mono wire voice (e.g. QUEUE SEND) —
    /// the fill/foreground inversion stays correct in both appearances either way.
    var labelFont: Font = Theme.sans(12.5, weight: .semibold)
    var tracking: CGFloat = 0
    @State private var isHovered = false
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        let pressed = configuration.isPressed
        let filled = prominent && isEnabled
        return configuration.label
            .font(labelFont)
            .tracking(tracking)
            .foregroundStyle(!isEnabled ? Theme.textDisabled : (prominent ? Theme.bg : Theme.textSecondary))
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: Theme.controlRadius)
                    .fill(filled
                          ? (isHovered ? Theme.textPrimary.opacity(0.88) : Theme.textPrimary)
                          : (isHovered && isEnabled ? Theme.surfaceHigh : Theme.surface))
            )
            .overlay(
                RoundedRectangle(cornerRadius: Theme.controlRadius)
                    .strokeBorder(filled ? Color.clear : Theme.border, lineWidth: Theme.hairline)
            )
            .focusRing()
            .opacity(pressed ? 0.75 : 1)
            .scaleEffect(pressed ? 0.985 : 1)
            .animation(Theme.quick, value: pressed)
            .animation(Theme.quick, value: isHovered)
            .onHover { isHovered = $0 }
    }
}

/// Filled primary action — for destructive-consequence buttons like APPROVE.
/// Colored background makes the send consequence immediately legible.
struct PrimaryActionStyle: ButtonStyle {
    var tint: Color = Theme.standby
    @State private var isHovered = false
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        let pressed = configuration.isPressed
        return configuration.label
            .font(Theme.mono(11, weight: .bold))
            .tracking(0.4)
            .foregroundStyle(isEnabled ? Theme.onTint : Theme.textDisabled)
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: Theme.controlRadius)
                    .fill(!isEnabled ? Theme.surfaceHigh : (isHovered ? tint.opacity(0.85) : tint))
            )
            .focusRing()
            .opacity(pressed ? 0.78 : 1)
            .scaleEffect(pressed ? 0.97 : 1)
            .animation(Theme.quick, value: pressed)
            .animation(Theme.quick, value: isHovered)
            .onHover { isHovered = $0 }
    }
}

/// Quiet inline action — mono label, no chrome until hover.
struct WireActionStyle: ButtonStyle {
    var tint: Color = Theme.textSecondary
    /// A command (Detail, Reply, Edit, Skip…) reads as clickable in title-case
    /// sans; mono-caps is reserved for section labels and evidence metadata.
    /// Opt in per call site rather than flipping the default — most existing
    /// mono-caps buttons in the app are legitimately wire-voice metadata.
    var sansLabel = false
    /// Underlined text-button affordance so a sans-label command never reads as
    /// plain text ("Draft with AI", "Decide later", "Skip"). On by default for
    /// every `sansLabel` button; the mono-caps wire voice stays unmarked.
    var underlined: Bool? = nil
    @State private var isHovered = false
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        let pressed = configuration.isPressed
        return configuration.label
            .font(sansLabel ? Theme.sans(12, weight: .medium) : Theme.mono(11, weight: .semibold))
            .tracking(sansLabel ? 0 : 0.4)
            .underline(underlined ?? sansLabel, pattern: .solid)
            .foregroundStyle(!isEnabled ? Theme.textDisabled
                             : (isHovered ? (tint == Theme.textSecondary ? Theme.textPrimary : tint) : tint))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: Theme.controlRadius)
                    .fill(pressed ? Theme.surfaceHigh : (isHovered ? Theme.surface : Color.clear))
            )
            .contentShape(Rectangle())
            .focusRing()
            .animation(Theme.quick, value: pressed)
            .animation(Theme.quick, value: isHovered)
            .onHover { isHovered = $0 }
    }

    /// The shared secondary text-button: sans, underlined, quiet until hover.
    static func textAction(tint: Color = Theme.textSecondary) -> WireActionStyle {
        WireActionStyle(tint: tint, sansLabel: true, underlined: true)
    }
}

// MARK: - NSAppearance helpers

@MainActor
extension NSAppearance {
    static let dark  = NSAppearance(named: .darkAqua)!
    static let light = NSAppearance(named: .aqua)!
}
