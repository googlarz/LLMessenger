// LLMessenger/Core/Rules/RuleEvaluator.swift
import Foundation

struct RuleMatch {
    let rule: PriorityRule
    let action: RuleAction
}

enum RuleAction {
    case alwaysNotify
    case suppress
    case setPriority(String)
}

struct RuleEvaluator {
    static func evaluate(
        contactName: String,
        service: String?,
        messageText: String,
        rules: [PriorityRule],
        at date: Date = Date()
    ) -> RuleMatch? {
        let sorted = rules.sorted { $0.sortOrder < $1.sortOrder }
        for rule in sorted {
            if let ruleService = rule.service, let msgService = service, ruleService != msgService {
                continue
            }
            if let contact = rule.contactPattern, !contact.isEmpty,
               !contactName.localizedCaseInsensitiveContains(contact) {
                continue
            }
            if let keyword = rule.keywordPattern, !keyword.isEmpty,
               !messageText.localizedCaseInsensitiveContains(keyword) {
                continue
            }
            if isInQuietWindow(rule: rule, at: date) {
                // Suppress alwaysNotify during quiet hours, but suppress rules remain active.
                if rule.alwaysNotify { continue }
            }
            let action: RuleAction
            if rule.suppress {
                action = .suppress
            } else if rule.alwaysNotify {
                action = .alwaysNotify
            } else if let p = rule.setPriority, !p.isEmpty {
                action = .setPriority(p)
            } else {
                continue
            }
            return RuleMatch(rule: rule, action: action)
        }
        return nil
    }

    // Returns true if `date` falls within the rule's quiet window.
    private static func isInQuietWindow(rule: PriorityRule, at date: Date) -> Bool {
        guard let startStr = rule.quietStart, let endStr = rule.quietEnd,
              !startStr.isEmpty, !endStr.isEmpty else { return false }
        guard let startMinutes = parseHHmm(startStr),
              let endMinutes = parseHHmm(endStr) else { return false }
        let cal = Calendar.current
        let comps = cal.dateComponents([.hour, .minute], from: date)
        let currentMinutes = (comps.hour ?? 0) * 60 + (comps.minute ?? 0)
        if startMinutes < endMinutes {
            return currentMinutes >= startMinutes && currentMinutes < endMinutes
        } else {
            // Midnight wrap: e.g. 22:00 – 06:00
            return currentMinutes >= startMinutes || currentMinutes < endMinutes
        }
    }

    private static func parseHHmm(_ s: String) -> Int? {
        let parts = s.split(separator: ":").map { Int($0) }
        guard parts.count == 2, let h = parts[0], let m = parts[1] else { return nil }
        guard h >= 0, h < 24, m >= 0, m < 60 else { return nil }
        return h * 60 + m
    }
}
