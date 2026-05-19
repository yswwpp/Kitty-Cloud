import Foundation

@MainActor
class ChatManager: ObservableObject {
    let messageStore = MessageStore.shared
    @Published var isStreaming = false
    @Published var streamingText = ""
    @Published var errorMessage: String?

    private var selectedModel: String {
        UserDefaults.standard.string(forKey: "selectedModel") ?? "bailian/qwen3.6-plus"
    }

    private let kittyService = KittyService.shared
    private var currentTask: Task<Void, Never>?
    private var typingTask: Task<Void, Never>?

    func sendMessage(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        // 取消之前的打字任务
        typingTask?.cancel()
        typingTask = nil

        errorMessage = nil
        messageStore.addMessage(role: "user", content: trimmed)
        isStreaming = true
        streamingText = ""

        let model = selectedModel
        let history = buildHistory()

        currentTask = Task { [weak self] in
            guard let self = self else { return }

            do {
                // 使用非流式模式获取完整响应（绕过代理缓冲问题）
                let fullResponse = try await self.kittyService.chatComplete(trimmed, history: history, model: model)

                // 模拟打字效果
                await self.simulateTyping(fullResponse)

                // 完成后添加完整消息
                self.messageStore.addMessage(role: "assistant", content: fullResponse)
                self.isStreaming = false
                self.streamingText = ""
            } catch {
                self.errorMessage = error.localizedDescription
                self.isStreaming = false
                self.streamingText = ""
            }
        }
    }

    private func simulateTyping(_ text: String) async {
        typingTask = Task { [weak self] in
            guard let self = self else { return }

            var displayed = ""
            let characters = Array(text)

            for char in characters {
                if Task.isCancelled { break }
                displayed.append(char)
                self.streamingText = displayed
                // 每个字符延迟30-80毫秒，模拟真实打字
                try? await Task.sleep(nanoseconds: UInt64.random(in: 30_000_000...80_000_000))
            }
        }
        await typingTask?.value
    }

    func cancelStreaming() {
        currentTask?.cancel()
        currentTask = nil
        typingTask?.cancel()
        typingTask = nil
        isStreaming = false
        streamingText = ""
    }

    func clearHistory() {
        messageStore.clearMessages()
    }

    private func buildHistory() -> [[String: String]] {
        let recent = messageStore.messages.suffix(20)
        return recent.map { ["role": $0.role, "content": $0.content] }
    }
}