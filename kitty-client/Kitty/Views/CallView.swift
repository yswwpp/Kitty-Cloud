import SwiftUI
import AVFoundation

struct CallView: View {
    @StateObject private var manager = ConversationManager()
    @State private var showingSettings = false
    @State private var showingHistory = false
    @State private var isSpeakerOn = true
    @State private var isMuted = false

    var body: some View {
        NavigationView {
            VStack(spacing: 20) {
                statusView
                callDurationView
                buttonArea

                // 通话控制条（仅在通话中显示）
                if manager.state != .idle {
                    callControlBar
                }

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

    private var callDurationView: some View {
        Group {
            if manager.state != .idle {
                Text(formatDuration(manager.callDuration))
                    .font(.system(.title2, design: .monospaced))
                    .foregroundColor(.secondary)
            }
        }
    }

    @ViewBuilder
    private var buttonArea: some View {
        if manager.state == .idle {
            // 待机状态：显示开始通话按钮
            VStack(spacing: 16) {
                callButton
                testServerButton
            }
        } else {
            // 通话中：显示挂断按钮
            hangupButton
        }
    }

    /// 通话控制条：扬声器切换和静音按钮
    private var callControlBar: some View {
        HStack(spacing: 40) {
            // 扬声器切换按钮
            Button(action: {
                isSpeakerOn.toggle()
                setSpeakerMode(isSpeakerOn)
            }) {
                VStack(spacing: 4) {
                    Image(systemName: isSpeakerOn ? "speaker.wave.3.fill" : "speaker.fill")
                        .font(.title2)
                    Text(isSpeakerOn ? "扬声器" : "听筒")
                        .font(.caption2)
                }
                .foregroundColor(isSpeakerOn ? .blue : .gray)
                .frame(width: 60, height: 60)
                .background(Color.gray.opacity(0.15))
                .cornerRadius(30)
            }

            // 静音按钮
            Button(action: {
                isMuted.toggle()
                manager.setMuted(isMuted)
            }) {
                VStack(spacing: 4) {
                    Image(systemName: isMuted ? "mic.slash.fill" : "mic.fill")
                        .font(.title2)
                    Text(isMuted ? "已静音" : "麦克风")
                        .font(.caption2)
                }
                .foregroundColor(isMuted ? .red : .gray)
                .frame(width: 60, height: 60)
                .background(Color.gray.opacity(0.15))
                .cornerRadius(30)
            }
        }
        .padding(.top, 8)
    }

    private func setSpeakerMode(_ speaker: Bool) {
        do {
            let session = AVAudioSession.sharedInstance()
            if speaker {
                // 扬声器模式：使用 default 模式 + 强制扬声器
                try session.setCategory(
                    .playAndRecord,
                    mode: .default,
                    options: [.defaultToSpeaker, .mixWithOthers]
                )
                try session.overrideOutputAudioPort(.speaker)
                NSLog("🔊 切换到扬声器模式（高音量）")
            } else {
                // 听筒/蓝牙模式
                try session.setCategory(
                    .playAndRecord,
                    mode: .voiceChat,
                    options: [.allowBluetooth, .mixWithOthers]
                )
                NSLog("🔊 切换到听筒/蓝牙模式")
            }
            try session.setActive(true)
        } catch {
            NSLog("❌ 切换扬声器失败: \(error)")
        }
    }

    private var testServerButton: some View {
        Button("测试服务器") {
            testServerConnection()
        }
        .buttonStyle(.bordered)
        .font(.caption)
    }

    private func testServerConnection() {
        Task {
            do {
                NSLog("🔍 开始测试服务器连接...")
                let serverURL = KittyService.shared.serverURL
                let (_, _) = try await URLSession.shared.data(from: URL(string: serverURL + "/")!)
                NSLog("✅ 服务器连接成功")

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

                let ttsUrl = URL(string: serverURL + "/tts")!
                var ttsRequest = URLRequest(url: ttsUrl)
                ttsRequest.httpMethod = "POST"
                ttsRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
                ttsRequest.httpBody = try? JSONSerialization.data(withJSONObject: [
                    "text": "测试成功",
                    "voice": "zh_female_vv_uranus_bigtts"
                ])

                let (audioData, _) = try await URLSession.shared.data(for: ttsRequest)
                NSLog("✅ TTS 返回: \(audioData.count) bytes")

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
        Button(action: {
            manager.startCall()
        }) {
            ZStack {
                Circle()
                    .fill(Color.green)
                    .frame(width: 120, height: 120)

                Image(systemName: "phone.fill")
                    .font(.system(size: 50))
                    .foregroundColor(.white)
            }
        }
    }

    private var hangupButton: some View {
        Button(action: {
            manager.endCall()
        }) {
            ZStack {
                Circle()
                    .fill(Color.red)
                    .frame(width: 120, height: 120)

                Image(systemName: "phone.down.fill")
                    .font(.system(size: 50))
                    .foregroundColor(.white)
            }
        }
    }

    private var audioIndicator: some View {
        WaveformView(
            audioLevel: manager.audioLevel,
            isListening: manager.state == .listening || manager.state == .speaking || manager.state == .thinking,
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
        case .connected: return .green
        case .listening: return .green
        case .thinking: return .blue
        case .speaking: return .purple
        case .error: return .red
        }
    }

    private func formatDuration(_ seconds: Int) -> String {
        let minutes = seconds / 60
        let secs = seconds % 60
        return String(format: "%02d:%02d", minutes, secs)
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
