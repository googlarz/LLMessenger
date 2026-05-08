// LLMessenger/UI/Settings/OllamaModelPicker.swift
import SwiftUI

/// Replaces the Ollama model name text field with a picker populated from the local Ollama API.
/// Falls back to a plain text field if Ollama is not running or returns no models.
struct OllamaModelPicker: View {
    @Binding var selectedModel: String

    fileprivate enum LoadState {
        case idle
        case loading
        case loaded([OllamaModel])
        case failed
    }

    @State private var loadState: LoadState = .idle

    var body: some View {
        HStack(spacing: 8) {
            switch loadState {
            case .idle, .loading:
                TextField("Model name (e.g. llama3.1)", text: $selectedModel)
                    .textFieldStyle(.roundedBorder)
                if case .loading = loadState {
                    ProgressView().controlSize(.small)
                }

            case .loaded(let models) where !models.isEmpty:
                Picker("", selection: $selectedModel) {
                    ForEach(models) { model in
                        Text(model.displayLabel).tag(model.name)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()

                Button {
                    Task { await load() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 12))
                        .foregroundStyle(Color.secondary)
                }
                .buttonStyle(.plain)
                .help("Refresh model list")

            case .loaded, .failed:
                TextField("Model name (e.g. llama3.1)", text: $selectedModel)
                    .textFieldStyle(.roundedBorder)
                Button {
                    Task { await load() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 12))
                        .foregroundStyle(loadState == .failed ? Color.red : Color.secondary)
                }
                .buttonStyle(.plain)
                .help(loadState == .failed ? "Ollama not running — click to retry" : "Refresh")
            }
        }
        .task { await load() }
    }

    @MainActor
    private func load() async {
        guard loadState != .loading else { return }
        loadState = .loading
        do {
            let models = try await OllamaClient.fetchModels()
            loadState = .loaded(models)
            if !models.isEmpty {
                let names = models.map(\.name)
                if selectedModel.isEmpty || !names.contains(selectedModel) {
                    selectedModel = models[0].name
                }
            }
        } catch {
            loadState = .failed
        }
    }
}

extension OllamaModelPicker.LoadState: Equatable {
    static func == (lhs: OllamaModelPicker.LoadState, rhs: OllamaModelPicker.LoadState) -> Bool {
        switch (lhs, rhs) {
        case (.idle, .idle), (.loading, .loading), (.failed, .failed): return true
        case (.loaded(let a), .loaded(let b)): return a.map(\.name) == b.map(\.name)
        default: return false
        }
    }
}
