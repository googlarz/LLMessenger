import SwiftUI

struct BriefLearningRow: View {
    let learnedHint: String?
    let onMoreLikeThis: () -> Void
    let onLessLikeThis: () -> Void
    let onNotReply: () -> Void
    let onQuietThread: () -> Void

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) {
                label
                controls
                Spacer(minLength: 0)
            }

            VStack(alignment: .leading, spacing: 7) {
                label
                controls
            }
        }
        .padding(.top, 1)
        .accessibilityElement(children: .contain)
    }

    private var label: some View {
        Text(learnedHint ?? "Teach future digests")
            .font(Theme.mono(10, weight: .medium))
            .foregroundStyle(learnedHint == nil ? Theme.textTertiary : Theme.ok)
            .lineLimit(1)
    }

    private var controls: some View {
        HStack(spacing: 6) {
            Button("MORE LIKE THIS", action: onMoreLikeThis)
                .buttonStyle(WireActionStyle(tint: Theme.textSecondary))
                .accessibilityHint("Marks this conversation as higher signal in future digests.")
            Button("LESS", action: onLessLikeThis)
                .buttonStyle(WireActionStyle())
                .accessibilityHint("Marks this kind of item as lower priority in future digests.")
            Button("NOT A REPLY", action: onNotReply)
                .buttonStyle(WireActionStyle())
                .accessibilityHint("Teaches future digests that this kind of card does not need a reply.")
            Button("QUIET + DONE", action: onQuietThread)
                .buttonStyle(WireActionStyle())
                .accessibilityHint("Marks this card done and keeps the conversation lower priority in future digests.")
        }
    }
}
