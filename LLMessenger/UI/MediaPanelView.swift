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
                Text("MEDIA")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(Theme.textPrimary)
                    .tracking(0.6)
                Spacer()
                Button { onClose() } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Theme.textTertiary)
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)

            Divider().background(Theme.border)

            // Tab bar
            HStack(spacing: 0) {
                ForEach(tabs, id: \.0) { tab in
                    let sel = selectedTab == tab.0
                    Button { selectedTab = tab.0 } label: {
                        VStack(spacing: 3) {
                            Image(systemName: tab.1)
                                .font(.system(size: 11))
                            Text(tab.2)
                                .font(.system(size: 10.5, weight: sel ? .semibold : .medium))
                        }
                        .foregroundStyle(sel ? Theme.textPrimary : Theme.textTertiary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .overlay(alignment: .bottom) {
                            if sel {
                                Theme.accent.frame(height: 2)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 4)

            Divider().background(Theme.border)

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
                .font(.system(size: 32, weight: .thin))
                .foregroundStyle(Theme.textTertiary)
            Text(label)
                .font(.system(size: 12))
                .foregroundStyle(Theme.textTertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
