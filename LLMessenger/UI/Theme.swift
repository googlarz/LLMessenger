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
    init(light: Color, dark: Color) {
        self.init(NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                ? NSColor(dark) : NSColor(light)
        })
    }
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
    /// Hairline rule colour.
    static let border = Color(
        light: Color(red: 0.780, green: 0.769, blue: 0.745).opacity(0.7),
        dark:  Color(red: 0.227, green: 0.247, blue: 0.271).opacity(0.55)
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
        dark:  Color(red: 0.745, green: 0.729, blue: 0.690)
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

    static func serviceName(_ service: String) -> String {
        switch service {
        case "imessage": return "iMessage"
        case "telegram": return "Telegram"
        case "signal":   return "Signal"
        case "slack":    return "Slack"
        default:         return service.capitalized
        }
    }

    static func serviceColor(_ service: String) -> Color {
        switch service {
        case "imessage": return serviceIMessage
        case "telegram": return serviceTelegram
        case "signal":   return serviceSignal
        case "slack":    return serviceSlack
        default:         return textTertiary
        }
    }

    // MARK: - Typography — three voices

    /// Editorial voice: brief and card headlines. New York, the system serif.
    static func display(_ size: CGFloat, weight: Font.Weight = .semibold) -> Font {
        .system(size: size, weight: weight, design: .serif)
    }
    /// Wire voice: timestamps, counts, section labels, evidence metadata.
    static func mono(_ size: CGFloat, weight: Font.Weight = .medium) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }
    /// Interface voice: body copy and controls.
    static func sans(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight)
    }

    // Named styles
    static let headlineFont  = display(22)                 // brief headline
    static let cardTitleFont = display(16.5)               // card headline
    static let bodyFont      = sans(13.5)                  // prose
    static let labelFont     = mono(10.5, weight: .semibold) // tracked microlabels
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

    static let spring = Animation.spring(response: 0.32, dampingFraction: 0.86)
    static let quick  = Animation.easeOut(duration: 0.14)

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
            .font(Theme.mono(size <= 18 ? 8 : 9, weight: .bold))
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
        default:         return String(service.prefix(2)).uppercased()
        }
    }
}

/// Primary action: paper on ink — the inverted button. Secondary: quiet text.
struct PaperButtonStyle: ButtonStyle {
    var prominent = false
    @State private var isHovered = false

    func makeBody(configuration: Configuration) -> some View {
        let pressed = configuration.isPressed
        return configuration.label
            .font(Theme.sans(12.5, weight: .semibold))
            .foregroundStyle(prominent ? Theme.bg : Theme.textSecondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: Theme.controlRadius)
                    .fill(prominent
                          ? (isHovered ? Theme.textPrimary.opacity(0.88) : Theme.textPrimary)
                          : (isHovered ? Theme.surfaceHigh : Theme.surface))
            )
            .overlay(
                RoundedRectangle(cornerRadius: Theme.controlRadius)
                    .strokeBorder(prominent ? Color.clear : Theme.border, lineWidth: Theme.hairline)
            )
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

    func makeBody(configuration: Configuration) -> some View {
        let pressed = configuration.isPressed
        return configuration.label
            .font(Theme.mono(11, weight: .bold))
            .tracking(0.4)
            .foregroundStyle(.white)
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: Theme.controlRadius)
                    .fill(isHovered ? tint.opacity(0.85) : tint)
            )
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
    @State private var isHovered = false

    func makeBody(configuration: Configuration) -> some View {
        let pressed = configuration.isPressed
        return configuration.label
            .font(Theme.mono(11, weight: .semibold))
            .tracking(0.4)
            .foregroundStyle(isHovered ? (tint == Theme.textSecondary ? Theme.textPrimary : tint) : tint)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: Theme.controlRadius)
                    .fill(pressed ? Theme.surfaceHigh : (isHovered ? Theme.surface : Color.clear))
            )
            .contentShape(Rectangle())
            .animation(Theme.quick, value: pressed)
            .animation(Theme.quick, value: isHovered)
            .onHover { isHovered = $0 }
    }
}

// MARK: - NSAppearance helpers

@MainActor
extension NSAppearance {
    static let dark  = NSAppearance(named: .darkAqua)!
    static let light = NSAppearance(named: .aqua)!
}
