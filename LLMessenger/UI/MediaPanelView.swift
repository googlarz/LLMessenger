// LLMessenger/UI/MediaPanelView.swift
import SwiftUI

struct MediaPanelView: View {
    let onClose: () -> Void
    @State private var selectedTab = "photos"

    private let tabs = [
        ("photos", "photo", "Photos"),
        ("voice",  "waveform", "Voice"),
        ("videos", "video", "Videos"),
        ("gifs",   "rectangle.dashed", "GIFs"),
    ]

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                WireLabel("Media", color: Theme.textSecondary)
                Spacer()
                Button { onClose() } label: {
                    Image(systemName: "xmark")
                        .font(Theme.sans(11, weight: .medium))
                        .foregroundStyle(Theme.textTertiary)
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)

            Rule()

            // Tab bar
            HStack(spacing: 0) {
                ForEach(tabs, id: \.0) { tab in
                    let sel = selectedTab == tab.0
                    Button { selectedTab = tab.0 } label: {
                        VStack(spacing: 3) {
                            Image(systemName: tab.1)
                                .font(Theme.sans(11))
                            Text(tab.2)
                                .font(Theme.sans(10.5, weight: sel ? .semibold : .medium))
                        }
                        .foregroundStyle(sel ? Theme.textPrimary : Theme.textTertiary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .overlay(alignment: .bottom) {
                            if sel {
                                Theme.textPrimary.frame(height: 1)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 4)

            Rule()

            // Content
            EmptyMediaState(tab: selectedTab)
        }
    }
}

private struct EmptyMediaState: View {
    let tab: String

    private var icon: String {
        switch tab {
        case "photos": return "photo.stack"
        case "voice":  return "waveform"
        case "videos": return "video.slash"
        default:       return "rectangle.dashed"
        }
    }

    private var label: String {
        switch tab {
        case "photos": return "No photos in this brief"
        case "voice":  return "No voice messages"
        case "videos": return "No videos"
        default:       return "No GIFs"
        }
    }

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: icon)
                .font(Theme.sans(32, weight: .thin))
                .foregroundStyle(Theme.textTertiary)
            Text(label)
                .font(Theme.sans(12))
                .foregroundStyle(Theme.textTertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
