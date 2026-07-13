// LLMessenger/UI/Act/ActWorkspaceView.swift
//
// The Act section's full-width content: one ranked work queue (Needs your
// decision / Ready to send / Waiting on others / Later). Occupies the entire
// main content area when Act is selected in the sidebar.

import SwiftUI

struct ActWorkspaceView: View {
    var body: some View {
        ActFeedView(layout: .regular)
    }
}
