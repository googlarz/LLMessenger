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

enum Theme {

    // MARK: - Ink (ground) — cool, deep, layered

    /// Window ground. Cool ink, not gray.
    static let bg          = Color(red: 0.055, green: 0.067, blue: 0.082)   // #0E1115
    /// Sidebar / chrome ground, one step below the page.
    static let sidebar     = Color(red: 0.043, green: 0.053, blue: 0.065)   // #0B0D11
    /// Raised ink: cards' hover wash, fields, popovers.
    static let surface     = Color(red: 0.082, green: 0.098, blue: 0.118)   // #15191E
    /// Highest ink step: active chips, pressed states.
    static let surfaceHigh = Color(red: 0.114, green: 0.133, blue: 0.157)   // #1D2228
    /// Hairline rule colour (use with `hairline` width).
    static let border      = Color(red: 0.227, green: 0.247, blue: 0.271).opacity(0.55)
    /// Row selection wash.
    static let selection   = Color(red: 0.114, green: 0.133, blue: 0.157)

    // MARK: - Paper (text) — warm against the cool ink

    static let textPrimary   = Color(red: 0.929, green: 0.910, blue: 0.871) // #EDE8DE warm paper
    static let textSecondary = Color(red: 0.608, green: 0.596, blue: 0.561) // #9B988F faded ink
    static let textTertiary  = Color(red: 0.412, green: 0.404, blue: 0.376) // #696760 margin notes

    // MARK: - Signal — the only colour that means anything

    /// Vermilion. Urgency, unread, "needs you now". Use in small doses.
    static let signal      = Color(red: 0.886, green: 0.310, blue: 0.196)   // #E24F32
    static let signalWash  = signal.opacity(0.10)
    /// Standby amber — partial states, warnings, "heads-up".
    static let standby     = Color(red: 0.851, green: 0.647, blue: 0.302)   // #D9A54D
    /// Quiet sage — health OK, handled, success. Desaturated on purpose.
    static let ok          = Color(red: 0.498, green: 0.651, blue: 0.467)   // #7FA677

    // Legacy aliases — `accent` now maps to the signal vermilion.
    static let accent      = signal
    static let accentMuted = signalWash
    static let unread      = signal
    static let separator   = border

    // MARK: - Service inks — uniform saturation, like rubber stamps

    static let serviceIMessage = Color(red: 0.467, green: 0.624, blue: 0.443) // sage
    static let serviceTelegram = Color(red: 0.420, green: 0.604, blue: 0.733) // sky steel
    static let serviceSignal   = Color(red: 0.478, green: 0.541, blue: 0.776) // wire blue
    static let serviceSlack    = Color(red: 0.671, green: 0.518, blue: 0.690) // clay violet

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

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Theme.sans(12.5, weight: .semibold))
            .foregroundStyle(prominent ? Theme.bg : Theme.textSecondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: Theme.controlRadius)
                    .fill(prominent ? Theme.textPrimary : Theme.surface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Theme.controlRadius)
                    .strokeBorder(prominent ? Color.clear : Theme.border, lineWidth: Theme.hairline)
            )
            .opacity(configuration.isPressed ? 0.75 : 1)
            .scaleEffect(configuration.isPressed ? 0.985 : 1)
            .animation(Theme.quick, value: configuration.isPressed)
    }
}

/// Quiet inline action — mono label, no chrome until hover.
struct WireActionStyle: ButtonStyle {
    var tint: Color = Theme.textSecondary

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Theme.mono(11, weight: .semibold))
            .tracking(0.4)
            .foregroundStyle(tint)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: Theme.controlRadius)
                    .fill(configuration.isPressed ? Theme.surfaceHigh : Color.clear)
            )
            .contentShape(Rectangle())
            .animation(Theme.quick, value: configuration.isPressed)
    }
}

// MARK: - NSAppearance helper

extension NSAppearance {
    static let dark = NSAppearance(named: .darkAqua)!
}
