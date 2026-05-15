// LLMessenger/UI/Settings/TelegramSignInView.swift
import SwiftUI

struct TelegramSignInView: View {
    let adapter: SubprocessAdapter
    var onSuccess: () -> Void = {}

    @Environment(\.dismiss) private var dismiss

    private enum Step {
        case phone, code(phoneCodeHash: String), password, success
    }

    @State private var step: Step = .phone
    @State private var phone: String = ""
    @State private var code: String = ""
    @State private var password: String = ""
    @State private var errorMessage: String? = nil
    @State private var isLoading: Bool = true   // true until adapter starts

    var body: some View {
        ZStack(alignment: .topTrailing) {
            VStack(spacing: 24) {
                // Header
                VStack(spacing: 6) {
                    Image(systemName: "paperplane.fill")
                        .font(.system(size: 36))
                        .foregroundStyle(Theme.serviceTelegram)
                    Text("Connect Telegram")
                        .font(.title2.bold())
                        .foregroundStyle(Theme.textPrimary)
                }

                // Step content
                switch step {
                case .phone:
                    phoneStep
                case .code(let hash):
                    codeStep(phoneCodeHash: hash)
                case .password:
                    passwordStep
                case .success:
                    successStep
                }

                // Error
                if let msg = errorMessage {
                    Text(msg)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }

                // Always-visible Cancel/Close at the bottom too.
                Button("Close") { dismiss() }
                    .controlSize(.small)
                    .keyboardShortcut(.cancelAction)
            }
            .padding(28)

            // Top-right close (⌘W / Esc) for users who want the standard sheet close.
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 18))
                    .foregroundStyle(Theme.textTertiary)
            }
            .buttonStyle(.plain)
            .padding(12)
            .keyboardShortcut("w", modifiers: .command)
        }
        .frame(width: 380)
        .background(Theme.surface)
        .onAppear {
            Task {
                do {
                    try await adapter.start()
                } catch {
                    errorMessage = "Couldn't start Telegram adapter: \(error.localizedDescription)"
                }
                isLoading = false
            }
        }
    }

    // MARK: - Phone step

    private var phoneStep: some View {
        VStack(spacing: 16) {
            Text("Enter your phone number in international format.")
                .font(.subheadline)
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)

            TextField("+491234567890", text: $phone)
                .textFieldStyle(.roundedBorder)
                .font(.subheadline)
                .disabled(isLoading)

            Button(action: sendCode) {
                if isLoading {
                    ProgressView().controlSize(.small)
                } else {
                    Text("Send Code")
                        .frame(maxWidth: .infinity)
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(phone.trimmingCharacters(in: .whitespaces).isEmpty || isLoading)
        }
    }

    // MARK: - Code step

    private func codeStep(phoneCodeHash: String) -> some View {
        VStack(spacing: 16) {
            Text("Enter the code sent to your phone.")
                .font(.subheadline)
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)

            TextField("12345", text: $code)
                .textFieldStyle(.roundedBorder)
                .font(.subheadline)
                .disabled(isLoading)

            Button(action: { verify(phoneCodeHash: phoneCodeHash) }) {
                if isLoading {
                    ProgressView().controlSize(.small)
                } else {
                    Text("Verify")
                        .frame(maxWidth: .infinity)
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(code.trimmingCharacters(in: .whitespaces).isEmpty || isLoading)
        }
    }

    // MARK: - Password step

    private var passwordStep: some View {
        VStack(spacing: 16) {
            Text("Two-factor authentication is enabled. Enter your password.")
                .font(.subheadline)
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)

            SecureField("Password", text: $password)
                .textFieldStyle(.roundedBorder)
                .font(.subheadline)
                .disabled(isLoading)

            Button(action: checkPassword) {
                if isLoading {
                    ProgressView().controlSize(.small)
                } else {
                    Text("Confirm")
                        .frame(maxWidth: .infinity)
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(password.isEmpty || isLoading)
        }
    }

    // MARK: - Success step

    private var successStep: some View {
        VStack(spacing: 16) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 40))
                .foregroundStyle(.green)
            Text("Telegram connected successfully!")
                .font(.subheadline)
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)

            Button("Done") {
                onSuccess()
                dismiss()
            }
            .buttonStyle(.borderedProminent)
            .frame(maxWidth: .infinity)
        }
    }

    // MARK: - Actions

    private func sendCode() {
        errorMessage = nil
        isLoading = true
        Task {
            defer { isLoading = false }
            do {
                let resp = try await adapter.authRoundTrip([
                    "action": "auth_send_code",
                    "phone": phone.trimmingCharacters(in: .whitespaces)
                ])
                if resp["success"] as? Bool == true,
                   let hash = resp["phone_code_hash"] as? String {
                    step = .code(phoneCodeHash: hash)
                } else {
                    let raw = resp["error"] as? String ?? "Failed to send code."
                    // Older telegram-adapter binaries don't expose auth handlers.
                    // Help the user know they have a working session and can just retry.
                    if raw.localizedCaseInsensitiveContains("unknown action") {
                        errorMessage = "Your telegram-adapter binary doesn't support re-auth. Rebuild it from the adapters/telegram source, OR close this dialog and click Retry now — your existing session will reconnect."
                    } else {
                        errorMessage = raw
                    }
                }
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func verify(phoneCodeHash: String) {
        errorMessage = nil
        isLoading = true
        Task {
            defer { isLoading = false }
            do {
                let resp = try await adapter.authRoundTrip([
                    "action": "auth_sign_in",
                    "phone": phone.trimmingCharacters(in: .whitespaces),
                    "phone_code_hash": phoneCodeHash,
                    "code": code.trimmingCharacters(in: .whitespaces)
                ])
                if resp["success"] as? Bool == true {
                    step = .success
                } else if resp["needs_2fa"] as? Bool == true {
                    step = .password
                } else {
                    errorMessage = resp["error"] as? String ?? "Verification failed."
                }
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func checkPassword() {
        errorMessage = nil
        isLoading = true
        Task {
            defer { isLoading = false }
            do {
                let resp = try await adapter.authRoundTrip([
                    "action": "auth_check_password",
                    "password": password
                ])
                if resp["success"] as? Bool == true {
                    step = .success
                } else {
                    errorMessage = resp["error"] as? String ?? "Incorrect password."
                }
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}
