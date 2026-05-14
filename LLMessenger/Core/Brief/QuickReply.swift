// LLMessenger/Core/Brief/QuickReply.swift
import Foundation

/// A pre-generated reply option with a short label and a full style-matched draft.
/// The label (≤3 words) is shown as a chip in the UI; the draft is the message
/// that gets sent after the user reviews and confirms.
struct QuickReply: Identifiable, Decodable {
    let id: UUID
    let label: String
    let draft: String

    init(id: UUID = UUID(), label: String, draft: String) {
        self.id = id
        self.label = label
        self.draft = draft
    }

    enum CodingKeys: String, CodingKey {
        case label, draft
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = UUID()
        self.label = try c.decode(String.self, forKey: .label)
        self.draft = try c.decode(String.self, forKey: .draft)
    }
}
