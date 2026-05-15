import Foundation

/// Best-effort redaction of patterns that look like sensitive identifiers
/// (credit card numbers, US SSNs, email addresses, IBANs). Opt-in via
/// SettingsRepository.loadSanitizeBeforeSend(); off by default because the
/// patterns can over-match and degrade brief quality. Intended only for cloud
/// LLM egress — local Ollama calls never need sanitisation.
///
/// NOTE: This is harm-reduction, not protection. Determined exfiltration could
/// still happen via paraphrased content. Treat this as a guardrail, not a guarantee.
enum MessageSanitizer {
    private static let patterns: [(name: String, regex: NSRegularExpression)] = {
        let raw: [(String, String)] = [
            ("CARD", #"\b(?:\d[ -]*?){13,19}\b"#),                      // credit card numbers
            ("SSN",  #"\b\d{3}-\d{2}-\d{4}\b"#),                        // US SSN
            ("IBAN", #"\b[A-Z]{2}\d{2}[A-Z0-9]{11,30}\b"#),             // IBAN
            ("EMAIL", #"\b[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}\b"#)
        ]
        return raw.compactMap { name, pattern in
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
            return (name, regex)
        }
    }()

    /// Replace each matched pattern with a `[REDACTED:CARD]` style token.
    static func redact(_ text: String) -> String {
        var result = text
        for (name, regex) in patterns {
            let range = NSRange(result.startIndex..<result.endIndex, in: result)
            result = regex.stringByReplacingMatches(in: result, options: [], range: range,
                                                    withTemplate: "[REDACTED:\(name)]")
        }
        return result
    }

    /// Apply redact to every message's content, leaving role untouched.
    static func sanitize(_ messages: [LLMMessage]) -> [LLMMessage] {
        messages.map { LLMMessage(role: $0.role, content: redact($0.content)) }
    }
}
