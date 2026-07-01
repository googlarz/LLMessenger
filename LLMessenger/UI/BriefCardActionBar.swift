import SwiftUI

struct BriefCardActionBar: View {
    let sourceCount: Int
    let quoteCount: Int
    let messageCount: Int
    let evidenceExpanded: Bool
    let isHandled: Bool
    let onToggleEvidence: () -> Void
    let onAskDetail: () -> Void
    let onReply: () -> Void
    let onToggleHandled: () -> Void

    var body: some View {
        ViewThatFits(in: .horizontal) {
            full
            compact
        }
    }

    private var full: some View {
        HStack(spacing: 2) {
            evidenceButton
            divider
            detailButton
            divider
            replyButton
            Spacer(minLength: 0)
            doneButton
        }
    }

    private var compact: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 2) {
                replyButton
                divider
                detailButton
                Spacer(minLength: 0)
                doneButton
            }
            evidenceButton
        }
    }

    private var evidenceButton: some View {
        Button(action: onToggleEvidence) {
            HStack(spacing: 5) {
                Text("\(sourceCount) \(sourceCount == 1 ? "SOURCE" : "SOURCES")")
                if quoteCount > 0 {
                    Text("· \(quoteCount) QUOTED")
                }
                Image(systemName: "chevron.down")
                    .font(.system(size: 7, weight: .bold))
                    .rotationEffect(.degrees(evidenceExpanded ? 180 : 0))
            }
        }
        .buttonStyle(WireActionStyle(tint: evidenceExpanded ? Theme.textPrimary : Theme.textTertiary))
        .help(evidenceExpanded ? "Hide the source messages" : "Show the source messages behind this card")
    }

    private var detailButton: some View {
        Button(messageCount > 20 ? "CATCH ME UP" : "DETAIL", action: onAskDetail)
            .buttonStyle(WireActionStyle())
            .help(messageCount > 20 ? "Deeper summary of this long thread" : "Ask for more detail")
    }

    private var replyButton: some View {
        Button("REPLY", action: onReply)
            .buttonStyle(WireActionStyle(tint: Theme.signal))
            .help("Draft a reply")
    }

    private var doneButton: some View {
        Button(action: onToggleHandled) {
            HStack(spacing: 4) {
                Image(systemName: isHandled ? "arrow.uturn.left" : "checkmark")
                    .font(.system(size: 9, weight: .bold))
                Text(isHandled ? "REOPEN" : "DONE")
            }
        }
        .buttonStyle(WireActionStyle(tint: isHandled ? Theme.textTertiary : Theme.ok))
        .help(isHandled ? "Put this card back in the active digest" : "Mark this card as handled")
    }

    private var divider: some View {
        Text("·")
            .font(Theme.mono(11))
            .foregroundStyle(Theme.textTertiary.opacity(0.5))
    }
}
