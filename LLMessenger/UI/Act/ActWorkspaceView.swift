// LLMessenger/UI/Act/ActWorkspaceView.swift
//
// The Act section's full-width content: to-do strip + ranked action queue.
// Occupies the entire main content area when Act is selected in the sidebar,
// instead of being squeezed into a narrow column beside an unrelated digest.

import SwiftUI

struct ActWorkspaceView: View {
    var body: some View {
        VStack(spacing: 0) {
            ToDoStripView(layout: .regular)
            ActFeedView(layout: .regular)
        }
    }
}
