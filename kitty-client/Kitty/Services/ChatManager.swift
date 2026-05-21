import Foundation

// 扩展 Character 判断是否为 emoji
extension Character {
    var isEmoji: Bool {
        guard let scalar = unicodeScalars.first else { return false }
        return (scalar.value >= 0x1F600 && scalar.value <= 0x1F64F)  // emoticons
            || (scalar.value >= 0x1F300 && scalar.value <= 0x1F5FF)  // symbols & pictographs
            || (scalar.value >= 0x1F680 && scalar.value <= 0x1F6FF)  // transport & map
            || (scalar.value >= 0x1F900 && scalar.value <= 0x1F9FF)  // supplemental
            || (scalar.value >= 0x2600 && scalar.value <= 0x26FF)    // misc symbols
            || (scalar.value >= 0x2700 && scalar.value <= 0x27BF)    // dingbats
            || scalar.value == 0xFE0F  // variation selector
            || scalar.value == 0x200D  // ZWJ
    }
}

struct PendingAttachment {
    let fileName: String
    let fileSize: Int64
    let fileData: Data
}

@MainActor
class ChatManager: ObservableObject {
    let messageStore = MessageStore.shared
    @Published var isStreaming = false
    @Published var streamingText = ""
    @Published var errorMessage: String?
    @Published var pendingAttachment: PendingAttachment?

    private var selectedModel: String {
        UserDefaults.standard.string(forKey: "selectedModel") ?? "bailian/qwen3.6-plus"
    }

    private let kittyService = KittyService.shared
    private var currentTask: Task<Void, Never>?
    private var typingTask: Task<Void, Never>?

    func sendMessage(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasAttachment = pendingAttachment != nil
        guard !trimmed.isEmpty || hasAttachment else { return }

        // 取消之前的打字任务
        typingTask?.cancel()
        typingTask = nil

        errorMessage = nil

        let displayText = trimmed.isEmpty ? "[上传了PDF: \(pendingAttachment?.fileName ?? "")]" : trimmed
        let attachment = pendingAttachment.map { Attachment(fileName: $0.fileName, fileSize: $0.fileSize) }
        messageStore.addMessage(role: "user", content: displayText, attachment: attachment)

        isStreaming = true
        streamingText = ""

        let model = selectedModel
        let history = buildHistory()
        let attachmentData = pendingAttachment

        // 清除待发送附件
        pendingAttachment = nil

        currentTask = Task { [weak self] in
            guard let self = self else { return }

            do {
                let fullResponse: String
                if let att = attachmentData {
                    // 带文件的消息
                    fullResponse = try await self.kittyService.chatWithFile(
                        trimmed.isEmpty ? "请解读这个文件" : trimmed,
                        fileData: att.fileData,
                        fileName: att.fileName,
                        model: model
                    )
                } else {
                    // 纯文本消息
                    fullResponse = try await self.kittyService.chatComplete(trimmed, history: history, model: model)
                }

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
            // Swift 的 Character 是 grapheme cluster，emoji 不会被拆开
            for char in text {
                if Task.isCancelled { break }
                displayed.append(char)
                self.streamingText = displayed
                // emoji 显示稍慢，普通字符快速
                let delay: UInt64 = char.isEmoji ? 150_000_000 : UInt64.random(in: 20_000_000...50_000_000)
                try? await Task.sleep(nanoseconds: delay)
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
