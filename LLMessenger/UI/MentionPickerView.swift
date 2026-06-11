import SwiftUI

struct MentionPickerView: View {
    @EnvironmentObject var directory: ContactDirectory
    @EnvironmentObject var chatViewModel: ChatViewModel

    let searchQuery: String
    let onSelect: (ChatViewModel.MentionTarget) -> Void
    let onDismiss: () -> Void

    private var filtered: [Contact] {
        let q = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if q.isEmpty {
            return Array(directory.contacts.prefix(60))
        }
        return directory.contacts.filter { $0.sortKey.contains(q) }.prefix(60).map { $0 }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if filtered.isEmpty {
                Text(directory.contacts.isEmpty ? "Loading contacts…" : "No matches")
                    .font(Theme.sans(12))
                    .foregroundStyle(Theme.textTertiary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(filtered) { contact in
                            ContactRow(contact: contact,
                                       directory: directory,
                                       onPickService: { handle in
                                           directory.recordPick(displayName: contact.displayName,
                                                                service: handle.service)
                                           onSelect(ChatViewModel.MentionTarget(
                                               service: handle.service,
                                               conversationId: handle.conversationId,
                                               displayName: contact.displayName,
                                               isGroup: handle.isGroup
                                           ))
                                       })
                            Rule(color: Theme.border.opacity(0.4))
                        }
                    }
                }
                .frame(maxHeight: 300)
            }
        }
        .frame(width: 320)
        .background(Theme.surface)
        .overlay(
            RoundedRectangle(cornerRadius: Theme.radius)
                .strokeBorder(Theme.border, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: Theme.radius))
        .shadow(radius: 12, y: 4)
        .onTapGesture {} // swallow taps so they don't dismiss
    }
}

private struct ContactRow: View {
    let contact: Contact
    let directory: ContactDirectory
    let onPickService: (ServiceHandle) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(contact.displayName)
                    .font(Theme.sans(13, weight: .medium))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                Spacer()
            }
            HStack(spacing: 6) {
                ForEach(directory.orderedHandles(for: contact), id: \.self) { handle in
                    Button {
                        onPickService(handle)
                    } label: {
                        HStack(spacing: 4) {
                            Circle()
                                .fill(Theme.serviceColor(handle.service))
                                .frame(width: 6, height: 6)
                            Text(Theme.serviceName(handle.service))
                                .font(Theme.mono(10, weight: .semibold))
                                .foregroundStyle(Theme.textSecondary)
                            if handle.isGroup {
                                Text("GROUP")
                                    .font(Theme.mono(8.5, weight: .semibold))
                                    .tracking(0.5)
                                    .foregroundStyle(Theme.textTertiary)
                            }
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(
                            RoundedRectangle(cornerRadius: Theme.controlRadius)
                                .fill(Theme.surfaceHigh)
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}
