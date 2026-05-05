// LLMessenger/UI/Theme.swift
import SwiftUI

enum Theme {
    // Anthropic brand palette — dark mode only
    static let bg          = Color(red: 0.102, green: 0.098, blue: 0.094)   // #1A1918
    static let sidebar     = Color(red: 0.122, green: 0.118, blue: 0.114)   // #1F1E1D
    static let surface     = Color(red: 0.149, green: 0.145, blue: 0.141)   // #262524
    static let surfaceHigh = Color(red: 0.180, green: 0.176, blue: 0.172)   // #2E2D2C
    static let border      = Color(red: 0.216, green: 0.212, blue: 0.208)   // #373634
    static let selection   = Color(red: 0.188, green: 0.184, blue: 0.180)   // #302F2E

    static let accent      = Color(red: 0.847, green: 0.467, blue: 0.337)   // #D87856 coral
    static let accentMuted = Color(red: 0.847, green: 0.467, blue: 0.337).opacity(0.18)

    static let textPrimary   = Color(red: 0.910, green: 0.894, blue: 0.875) // #E8E4DF warm white
    static let textSecondary = Color(red: 0.545, green: 0.529, blue: 0.510) // #8B8782 muted
    static let textTertiary  = Color(red: 0.373, green: 0.361, blue: 0.349) // #5F5C59 dimmed

    static let unread      = accent
    static let separator   = border
}

// MARK: - NSAppearance helper

extension NSAppearance {
    static let dark = NSAppearance(named: .darkAqua)!
}
