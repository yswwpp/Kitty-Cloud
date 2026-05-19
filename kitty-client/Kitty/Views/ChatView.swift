import SwiftUI

struct ChatView: View {
    @StateObject private var chatManager = ChatManager()
    @ObservedObject private var messageStore = MessageStore.shared
    @State private var inputText = ""
    @AppStorage("selectedModel") private var selectedModel: String = "bailian/qwen3.6-plus"
    @State private var showingModelPicker = false
    @State private var availableModels: [ModelInfo] = []
    @State private var showingSettings = false
    @State private var showingClearAlert = false

    private var currentModelDisplayName: String {
        if let model = availableModels.first(where: { $0.id == selectedModel }) {
            return model.displayName
        }
        return "Qwen3.6 Plus"
    }

    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                // 消息列表
                messageList

                Divider()

                // 错误提示（更明显）
                if let error = chatManager.errorMessage {
                    HStack {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundColor(.red)
                            .font(.title2)
                        Text("错误: \(error)")
                            .font(.body)
                            .foregroundColor(.red)
                        Spacer()
                        Button("关闭") {
                            chatManager.errorMessage = nil
                        }
                        .font(.caption)
                        .foregroundColor(.blue)
                    }
                    .padding(16)
                    .background(Color.red.opacity(0.2))
                    .cornerRadius(12)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                }

                // 流式状态指示器（调试用）
                if chatManager.isStreaming {
                    HStack {
                        ProgressView()
                        Text("正在连接...")
                            .font(.caption)
                            .foregroundColor(.blue)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 4)
                    .background(Color.blue.opacity(0.1))
                }

                // 输入区域
                inputBar
            }
            .navigationTitle("🐱 Kitty")
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button(action: { showingClearAlert = true }) {
                        Image(systemName: "trash")
                    }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    HStack(spacing: 12) {
                        Button(action: {
                            Task {
                                if let models = try? await KittyService.shared.fetchModels() {
                                    availableModels = models
                                }
                                showingModelPicker = true
                            }
                        }) {
                            HStack(spacing: 4) {
                                Image(systemName: "cpu")
                                    .font(.caption)
                                Text(currentModelDisplayName)
                                    .font(.caption)
                            }
                        }
                        .confirmationDialog("选择模型", isPresented: $showingModelPicker, titleVisibility: .visible) {
                            ForEach(availableModels) { model in
                                Button(model.displayName) {
                                    selectedModel = model.id
                                }
                            }
                            Button("取消", role: .cancel) {}
                        }

                        Button(action: { showingSettings = true }) {
                            Image(systemName: "gearshape")
                        }
                    }
                }
            }
            .sheet(isPresented: $showingSettings) {
                SettingsView()
            }
            .alert("清空对话", isPresented: $showingClearAlert) {
                Button("取消", role: .cancel) { }
                Button("清空", role: .destructive) {
                    chatManager.clearHistory()
                }
            } message: {
                Text("确定要清空所有对话记录吗？")
            }
        }
    }

    // MARK: - Message List

    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 12) {
                    if messageStore.messages.isEmpty && !chatManager.isStreaming {
                        emptyStateView
                    }

                    ForEach(messageStore.messages) { message in
                        MessageBubbleView(message: message)
                            .id(message.id)
                    }

                    // 流式回复气泡
                    if chatManager.isStreaming && !chatManager.streamingText.isEmpty {
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("🐱 Kitty")
                                    .font(.caption2)
                                    .foregroundColor(.green)
                                Text(chatManager.streamingText)
                                    .font(.body)
                                    + Text("▊")
                                    .font(.body)
                                    .foregroundColor(.green)
                            }
                            .padding(12)
                            .background(Color.green.opacity(0.1))
                            .cornerRadius(16)
                            .frame(maxWidth: 280, alignment: .leading)
                            Spacer()
                        }
                        .id("streaming")
                    }

                    // 打字指示器（动态省略号效果）
                    if chatManager.isStreaming && chatManager.streamingText.isEmpty {
                        HStack {
                            TypingIndicatorView()
                                .padding(12)
                                .background(Color.green.opacity(0.1))
                                .cornerRadius(16)
                            Spacer()
                        }
                        .id("typing")
                    }
                }
                .padding()
            }
            .onChange(of: messageStore.messages.count) { _ in
                scrollToBottom(proxy: proxy)
            }
            .onChange(of: chatManager.streamingText) { _ in
                scrollToBottom(proxy: proxy)
            }
        }
    }

    private var emptyStateView: some View {
        VStack(spacing: 16) {
            Spacer()
            Text("🐱")
                .font(.system(size: 60))
            Text("和 Kitty 聊聊天吧")
                .font(.title3)
                .foregroundColor(.secondary)
            Text("在下方输入消息开始对话")
                .font(.caption)
                .foregroundColor(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 80)
    }

    private func scrollToBottom(proxy: ScrollViewProxy) {
        withAnimation(.easeOut(duration: 0.2)) {
            if chatManager.isStreaming {
                proxy.scrollTo("streaming", anchor: .bottom)
            } else if let lastMessage = messageStore.messages.last {
                proxy.scrollTo(lastMessage.id, anchor: .bottom)
            }
        }
    }

    // MARK: - Input Bar

    private var inputBar: some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField("输入消息...", text: $inputText)
                .textFieldStyle(.roundedBorder)

            if chatManager.isStreaming {
                Button(action: { chatManager.cancelStreaming() }) {
                    Image(systemName: "stop.circle.fill")
                        .font(.title2)
                        .foregroundColor(.red)
                }
            } else {
                Button(action: sendMessage) {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.title2)
                        .foregroundColor(canSend ? .blue : .gray)
                }
                .disabled(!canSend)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color(UIColor.systemBackground))
    }

    private var canSend: Bool {
        !inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !chatManager.isStreaming
    }

    private func sendMessage() {
        guard canSend else { return }
        let text = inputText
        inputText = ""

        // 强制在主线程更新UI
        DispatchQueue.main.async {
            print("🔴 [UI] 发送按钮被点击，消息: \(text)")
            self.chatManager.sendMessage(text)
        }
    }
}

// MARK: - Message Bubble

struct MessageBubbleView: View {
    let message: Message

    var body: some View {
        if message.role == "user" {
            HStack {
                Spacer(minLength: 60)
                VStack(alignment: .trailing, spacing: 4) {
                    Text("👤 你")
                        .font(.caption2)
                        .foregroundColor(.blue)
                    if message.content.isEmpty {
                        Text("（空消息）")
                            .font(.body)
                            .foregroundColor(.red)
                            .padding(12)
                            .background(Color.red.opacity(0.1))
                            .cornerRadius(16)
                    } else {
                        Text(message.content)
                            .font(.body)
                            .padding(12)
                            .background(Color.blue.opacity(0.1))
                            .cornerRadius(16)
                            .frame(maxWidth: 280, alignment: .trailing)
                    }
                }
            }
        } else {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("🐱 Kitty")
                        .font(.caption2)
                        .foregroundColor(.green)
                    if message.content.isEmpty {
                        Text("（空回复）")
                            .font(.body)
                            .foregroundColor(.red)
                            .padding(12)
                            .background(Color.red.opacity(0.1))
                            .cornerRadius(16)
                    } else {
                        Text(message.content)
                            .font(.body)
                            .padding(12)
                            .background(Color.green.opacity(0.1))
                            .cornerRadius(16)
                            .frame(maxWidth: 280, alignment: .leading)
                    }
                }
                Spacer(minLength: 60)
            }
        }
    }
}

// MARK: - Typing Indicator

struct TypingIndicatorView: View {
    @State private var animationPhase = 0

    var body: some View {
        HStack(spacing: 4) {
            ForEach(0..<3, id: \.self) { index in
                Circle()
                    .fill(Color.green.opacity(0.6))
                    .frame(width: 8, height: 8)
                    .scaleEffect(animationPhase == index ? 1.2 : 0.8)
                    .opacity(animationPhase == index ? 1.0 : 0.5)
                    .animation(
                        .easeInOut(duration: 0.3)
                        .repeatForever(autoreverses: true),
                        value: animationPhase
                    )
            }
        }
        .onAppear {
            // 启动动画循环
            Timer.scheduledTimer(withTimeInterval: 0.4, repeats: true) { timer in
                withAnimation {
                    animationPhase = (animationPhase + 1) % 3
                }
            }
        }
    }
}

#Preview {
    ChatView()
}