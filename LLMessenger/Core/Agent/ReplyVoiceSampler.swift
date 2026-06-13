// LLMessenger/Core/Agent/ReplyVoiceSampler.swift
//
// Shared voice/tone sampling for reply drafting. Both ChatViewModel (interactive
// drafts) and AgentEngine (proposed actions) must calibrate to the user's voice
// the same way: a sample of recent sent messages in the conversation plus the
// conversation's preferred tone. Extracted here so the two paths can't diverge.

import Foundation

enum ReplyVoiceSampler {
    /// 14-day window for the sent-message style sample. Mirrors ChatViewModel.draftReply.
    static let styleWindowDays: Double = 14
    /// Last N sent messages used as the style reference. Mirrors ChatViewModel.
    static let sampleSize = 15

    /// Filters `messages` to the user's most recent sent texts in `conversationId`,
    /// oldest-first, capped at `sampleSize`. `messages` should already be scoped to
    /// the conversation's service and the style window.
    static func sampleSentTexts(messages: [Message], conversationId: String) -> [String] {
        messages
            .filter { $0.conversationId == conversationId && $0.isSent }
            .sorted { $0.timestamp < $1.timestamp }
            .suffix(sampleSize)
            .map { $0.text }
    }

    /// Builds the style-reference block. Reuses ChatViewModel's canonical formatting
    /// so interactive and agent drafts share one voice contract.
    static func styleBlock(sentTexts: [String], tone: String?) -> String {
        ChatViewModel.styleReferenceBlock(sentTexts: sentTexts, tone: tone)
    }
}
