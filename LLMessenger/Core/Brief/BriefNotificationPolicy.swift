import Foundation

enum BriefNotificationPolicy {
    static func highPriorityCount(
        cards: [BriefCard],
        effectivePriority: (BriefCard) -> String
    ) -> Int {
        cards.filter { $0.needsReply || effectivePriority($0) == "high" }.count
    }

    static func content(
        cards: [BriefCard],
        defaultTitle: String,
        defaultBody: String,
        effectivePriority: (BriefCard) -> String
    ) -> (title: String, body: String) {
        let replyCards = cards.filter(\.needsReply)
        let reviewCards = cards.filter {
            !$0.needsReply && effectivePriority($0) == "high"
        }
        guard let topCard = (replyCards + reviewCards).first else {
            return (defaultTitle, defaultBody)
        }

        let title: String
        if !replyCards.isEmpty {
            title = replyCards.count == 1
                ? "1 reply needs you"
                : "\(replyCards.count) replies need you"
        } else {
            title = reviewCards.count == 1
                ? "1 item needs review"
                : "\(reviewCards.count) items need review"
        }
        return (title, "\(topCard.headline) · \(reason(for: topCard))")
    }

    static func heldBackDigestContent(count: Int) -> (title: String, body: String)? {
        guard count > 0 else { return nil }
        let noun = count == 1 ? "update is" : "updates are"
        return ("Morning Brief", "\(count) routine \(noun) ready to review")
    }

    private static func reason(for card: BriefCard) -> String {
        if let reason = card.reason?.trimmingCharacters(in: .whitespacesAndNewlines),
           !reason.isEmpty {
            return "Because \(reason.lowercasedFirstLetter())"
        }
        if card.needsReply {
            return "Because this is waiting for your reply"
        }
        if card.grounding == "context" {
            return "Because it matches what you marked important"
        }
        if card.grounding == "inferred" {
            return "Because it looks important"
        }
        return "Because it was marked high priority"
    }
}

private extension String {
    func lowercasedFirstLetter() -> String {
        guard let first else { return self }
        return first.lowercased() + dropFirst()
    }
}
