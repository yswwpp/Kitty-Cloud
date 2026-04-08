import SwiftUI
import AVFoundation

struct CallView: View {
    @StateObject private var manager = ConversationManager()
    @State private var showingSettings = false
    @State private var showingHistory = false
    @State private var showingTextInput = false
    @State private var inputText = ""

    var body: some View {
        NavigationView {
            VStack(spacing: 20) {
                statusView
                buttonArea
                audioIndicator
                conversationView
                errorView
                Spacer()
            }
            .padding()
            .navigationTitle("🐱 Kitty")
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button(action: { showingHistory = true }) {
                        Image(systemName: "clock.arrow.circlepath")
                    }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(action: { showingSettings = true }) {
                        Image(systemName: "gearshape")
                    }
                }
            }
            .sheet(isPresented: $showingSettings) {
                SettingsView()
            }
            .sheet(isPresented: $showingHistory) {
                HistoryView(messages: manager.messages, onClear: {
                    manager.clearHistory()
                })
            }
            .sheet(isPresented: $showingTextInput) {
                TextInputSheet(text: $inputText, onSend: { text in
                    sendTextMessage(text)
                })
            }
        }
    }

    private var statusView: some View {
        VStack(spacing: 8) {
            Circle()
                .fill(statusColor)
                .frame(width: 12, height: 12)

            Text(manager.state.rawValue)
                .font(.headline)
                .foregroundColor(.secondary)
        }
    }

    @ViewBuilder
    private var buttonArea: some View {
        switch manager.state {
        case .idle:
            // 待机状态：显示开始通话按钮和测试按钮
            VStack(spacing: 16) {
                callButton
                HStack(spacing: 12) {
                    testServerButton
                    textInputButton
                }
            }
        case .listening:
            // 监听状态：显示停止按钮
            callButton
        case .thinking, .speaking:
            // 思考/回复状态：显示取消按钮
            cancelButton
        case .error:
            // 错误状态：显示重试按钮
            callButton
        }
    }

    private var testServerButton: some View {
        Button("测试服务器") {
            testServerConnection()
        }
        .buttonStyle(.bordered)
        .font(.caption)
    }

    private var textInputButton: some View {
        Button("文字输入") {
            showingTextInput = true
        }
        .buttonStyle(.bordered)
        .font(.caption)
    }

    private func testServerConnection() {
        Task {
            do {
                NSLog("🔍 开始测试服务器连接...")
                // 使用 KittyService 的服务器地址
                let serverURL = KittyService.shared.serverURL
                let (_, _) = try await URLSession.shared.data(from: URL(string: serverURL + "/")!)
                NSLog("✅ 服务器连接成功")

                // 测试 chat API
                let url = URL(string: serverURL + "/chat")!
                var request = URLRequest(url: url)
                request.httpMethod = "POST"
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                request.httpBody = try? JSONSerialization.data(withJSONObject: [
                    "message": "测试",
                    "history": []
                ])

                let (data, _) = try await URLSession.shared.data(for: request)
                let response = String(data: data, encoding: .utf8) ?? ""
                NSLog("✅ Chat 响应: \(response.prefix(50))")

                // 测试 TTS
                let ttsUrl = URL(string: serverURL + "/tts")!
                var ttsRequest = URLRequest(url: ttsUrl)
                ttsRequest.httpMethod = "POST"
                ttsRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
                ttsRequest.httpBody = try? JSONSerialization.data(withJSONObject: [
                    "text": "测试成功",
                    "voice": "BV001_streaming"
                ])

                let (audioData, _) = try await URLSession.shared.data(for: ttsRequest)
                NSLog("✅ TTS 返回: \(audioData.count) bytes")

                // 播放音频
                try await MainActor.run {
                    let player = try AVAudioPlayer(data: audioData)
                    player.play()
                }
                NSLog("✅ 测试完成，音频正在播放")
            } catch {
                NSLog("❌ 测试失败: \(error)")
            }
        }
    }

    private var callButton: some View {
        ZStack {
            Circle()
                .fill(callButtonColor)
                .frame(width: 120, height: 120)

            Image(systemName: callButtonIcon)
                .font(.system(size: 50))
                .foregroundColor(.white)
        }
        .contentShape(Circle())
        .onTapGesture {
            toggleCall()
        }
    }

    private var cancelButton: some View {
        Button(action: {
            manager.cancelCurrentOperation()
        }) {
            HStack(spacing: 8) {
                Image(systemName: "xmark.circle.fill")
                    .font(.title2)
                Text("取消")
                    .font(.headline)
            }
            .foregroundColor(.white)
            .padding(.horizontal, 32)
            .padding(.vertical, 16)
            .background(Color.red)
            .cornerRadius(30)
        }
    }

    private var audioIndicator: some View {
        WaveformView(
            audioLevel: manager.audioLevel,
            isListening: manager.state == .listening || manager.state == .speaking,
            barCount: 7,
            maxHeight: 50
        )
    }

    @ViewBuilder
    private var conversationView: some View {
        if !manager.userText.isEmpty || !manager.assistantText.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                if !manager.userText.isEmpty {
                    HStack {
                        Text("👤")
                        Text(manager.userText)
                            .font(.body)
                        Spacer()
                    }
                    .padding()
                    .background(Color.blue.opacity(0.1))
                    .cornerRadius(12)
                }

                if !manager.assistantText.isEmpty {
                    HStack {
                        Text("🐱")
                        Text(manager.assistantText)
                            .font(.body)
                        Spacer()
                    }
                    .padding()
                    .background(Color.green.opacity(0.1))
                    .cornerRadius(12)
                }
            }
        }
    }

    @ViewBuilder
    private var errorView: some View {
        if let error = manager.errorMessage {
            HStack {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundColor(.red)
                Text(error)
                    .foregroundColor(.red)
                    .font(.caption)
            }
            .padding()
            .background(Color.red.opacity(0.1))
            .cornerRadius(8)
        }
    }

    private var statusColor: Color {
        switch manager.state {
        case .idle: return .gray
        case .listening: return .green
        case .thinking: return .blue
        case .speaking: return .purple
        case .error: return .red
        }
    }

    private var callButtonColor: Color {
        switch manager.state {
        case .idle: return .green
        case .listening: return .red
        case .error: return .orange
        default: return .gray
        }
    }

    private var callButtonIcon: String {
        switch manager.state {
        case .idle: return "phone.fill"
        case .listening: return "phone.down.fill"
        case .error: return "arrow.clockwise"
        default: return "phone.fill"
        }
    }

    private func toggleCall() {
        NSLog("📱 toggleCall 被调用, 当前状态: \(manager.state.rawValue)")

        switch manager.state {
        case .idle:
            manager.startConversation()
        case .listening:
            manager.stopConversation()
        case .error:
            // 错误状态点击重新开始
            manager.startConversation()
        default:
            break
        }
    }

    private func sendTextMessage(_ text: String) {
        guard !text.isEmpty else { return }
        inputText = ""

        Task {
            do {
                // 显示用户文本
                await MainActor.run {
                    manager.userText = text
                    manager.state = .thinking
                }

                // 发送 chat 请求
                var fullReply = ""
                let url = URL(string: "http://localhost:8080/chat")!
                var request = URLRequest(url: url)
                request.httpMethod = "POST"
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                request.httpBody = try? JSONSerialization.data(withJSONObject: [
                    "message": text,
                    "session_id": "text_input"
                ])

                let (bytes, _) = try await URLSession.shared.bytes(for: request)

                for try await line in bytes.lines {
                    if line.hasPrefix("data: ") {
                        let dataStr = String(line.dropFirst(6))
                        if dataStr == "[DONE]" { break }
                        if let data = dataStr.data(using: .utf8),
                           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                           let choices = json["choices"] as? [[String: Any]],
                           let delta = choices.first?["delta"] as? [String: Any],
                           let content = delta["content"] as? String {
                            fullReply += content
                            await MainActor.run {
                                manager.assistantText = fullReply
                            }
                        }
                    } else if !line.isEmpty {
                        fullReply += line
                        await MainActor.run {
                            manager.assistantText = fullReply
                        }
                    }
                }

                // 播放 TTS
                if !fullReply.isEmpty {
                    await MainActor.run {
                        manager.state = .speaking
                    }

                    let ttsUrl = URL(string: "http://localhost:8080/tts")!
                    var ttsRequest = URLRequest(url: ttsUrl)
                    ttsRequest.httpMethod = "POST"
                    ttsRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    ttsRequest.httpBody = try? JSONSerialization.data(withJSONObject: [
                        "text": fullReply,
                        "voice": "BV001_streaming"
                    ])

                    let (audioData, _) = try await URLSession.shared.data(for: ttsRequest)

                    // 播放音频
                    try await MainActor.run {
                        let player = try AVAudioPlayer(data: audioData)
                        player.play()
                        // 等待播放完成
                        RunLoop.current.run(until: Date(timeIntervalSinceNow: player.duration))
                    }
                }

                await MainActor.run {
                    manager.state = .idle
                }

            } catch {
                NSLog("❌ 发送消息失败: \(error)")
                await MainActor.run {
                    manager.state = .error
                    manager.errorMessage = error.localizedDescription
                }
            }
        }
    }
}

struct HistoryView: View {
    let messages: [Message]
    let onClear: () -> Void

    @Environment(\.dismiss) var dismiss
    @State private var showingClearAlert = false

    var body: some View {
        NavigationView {
            List {
                if messages.isEmpty {
                    Text("暂无历史消息")
                        .foregroundColor(.secondary)
                } else {
                    ForEach(messages.reversed()) { message in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(message.role == "user" ? "👤 用户" : "🐱 Kitty")
                                    .font(.caption)
                                    .fontWeight(.semibold)
                                    .foregroundColor(message.role == "user" ? .blue : .green)
                                Spacer()
                                Text(formatTime(message.timestamp))
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                            }
                            Text(message.content)
                                .font(.body)
                        }
                        .padding(.vertical, 4)
                    }
                }
            }
            .navigationTitle("历史消息")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                }
                ToolbarItem(placement: .destructiveAction) {
                    if !messages.isEmpty {
                        Button("清空", role: .destructive) {
                            showingClearAlert = true
                        }
                    }
                }
            }
            .alert("确认清空", isPresented: $showingClearAlert) {
                Button("取消", role: .cancel) { }
                Button("清空", role: .destructive) {
                    onClear()
                }
            } message: {
                Text("确定要清空所有历史消息吗？")
            }
        }
    }

    private func formatTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "MM-dd HH:mm"
        return formatter.string(from: date)
    }
}

#Preview {
    CallView()
}

// MARK: - Text Input Sheet

struct TextInputSheet: View {
    @Binding var text: String
    let onSend: (String) -> Void
    @Environment(\.dismiss) var dismiss

    var body: some View {
        NavigationView {
            VStack(spacing: 20) {
                Text("输入消息进行对话")
                    .font(.headline)
                    .foregroundColor(.secondary)

                TextField("输入消息...", text: $text)
                    .textFieldStyle(RoundedBorderTextFieldStyle())
                    .padding()

                Button("发送") {
                    onSend(text)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .disabled(text.isEmpty)

                Spacer()
            }
            .padding()
            .navigationTitle("文字输入")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
            }
        }
    }
}