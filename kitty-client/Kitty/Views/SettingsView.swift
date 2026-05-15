import SwiftUI

struct SettingsView: View {
    @Environment(\.dismiss) var dismiss

    @AppStorage("serverURL") private var serverURL = "http://localhost:8081"
    @AppStorage("selectedVoice") private var selectedVoice: String = VoiceType.uranus.rawValue
    @AppStorage("selectedModel") private var selectedModel: String = "openclaw/main"
    @State private var availableModels: [ModelInfo] = []

    var body: some View {
        NavigationView {
            Form {
                Section("服务器设置") {
                    HStack {
                        Text("服务器地址")
                        Spacer()
                        TextField("http://", text: $serverURL)
                            .multilineTextAlignment(.trailing)
                            .foregroundColor(.secondary)
                            .autocapitalization(.none)
                            .autocorrectionDisabled()
                    }
                }

                Section("模型设置") {
                    Picker("模型", selection: $selectedModel) {
                        ForEach(availableModels) { model in
                            Text(model.displayName).tag(model.id)
                        }
                    }
                    .onAppear {
                        Task {
                            if let models = try? await KittyService.shared.fetchModels() {
                                availableModels = models
                            }
                        }
                    }
                }

                Section("语音设置") {
                    Picker("音色", selection: $selectedVoice) {
                        ForEach(VoiceType.allCases, id: \.rawValue) { voice in
                            Text(voice.displayName).tag(voice.rawValue)
                        }
                    }
                }

                Section("关于") {
                    HStack {
                        Text("版本")
                        Spacer()
                        Text("3.0")
                            .foregroundColor(.secondary)
                    }
                }
            }
            .navigationTitle("设置")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") {
                        dismiss()
                    }
                }
            }
        }
    }
}

#Preview {
    SettingsView()
}