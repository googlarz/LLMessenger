// LLMessenger/UI/Settings/LaunchAtLoginModel.swift
//
// The Launch at login switch. The switch always shows what macOS reports after the change,
// never what was asked for: registration can fail, or succeed but wait for the user to
// approve it in Login Items.

import Foundation
import ServiceManagement

enum LaunchAtLoginStatus: Equatable {
    case enabled
    case disabled
    /// Registered, but macOS wants the user to allow it in System Settings → Login Items.
    case requiresApproval

    static func current() -> LaunchAtLoginStatus {
        switch SMAppService.mainApp.status {
        case .enabled:           return .enabled
        case .requiresApproval:  return .requiresApproval
        default:                 return .disabled
        }
    }
}

@MainActor
final class LaunchAtLoginModel: ObservableObject {
    @Published private(set) var status: LaunchAtLoginStatus
    @Published private(set) var errorMessage: String?

    private let readStatus: () -> LaunchAtLoginStatus
    private let write: (Bool) throws -> Void

    init(readStatus: @escaping () -> LaunchAtLoginStatus = LaunchAtLoginStatus.current,
         write: @escaping (Bool) throws -> Void = AutoLaunchManager.setEnabled) {
        self.readStatus = readStatus
        self.write = write
        status = readStatus()
    }

    /// What the switch shows: on while registered, including while waiting for approval.
    var isOn: Bool { status != .disabled }

    var needsApproval: Bool { status == .requiresApproval }

    func refresh() {
        status = readStatus()
    }

    func set(_ enabled: Bool) {
        do {
            try write(enabled)
            errorMessage = nil
        } catch {
            errorMessage = enabled
                ? "Couldn't turn on Launch at login: \(error.localizedDescription)"
                : "Couldn't turn off Launch at login: \(error.localizedDescription)"
        }
        status = readStatus()
    }
}
