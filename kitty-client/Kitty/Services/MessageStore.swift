import Foundation

struct Attachment: Codable {
    let fileName: String
    let fileSize: Int64
}

struct Message: Identifiable, Codable {
    let id: UUID
    let role: String      // "user" or "assistant"
    let content: String
    let timestamp: Date
    var attachment: Attachment?

    init(role: String, content: String, attachment: Attachment? = nil) {
        self.id = UUID()
        self.role = role
        self.content = content
        self.timestamp = Date()
        self.attachment = attachment
    }
}

class MessageStore: ObservableObject {
    static let shared = MessageStore()

    @Published var messages: [Message] = []
    let sessionId: String

    private let messagesKey = "kitty_messages"
    private let sessionIdKey = "kitty_session_id"

    private init() {
        // 加载或创建 sessionId
        if let savedId = UserDefaults.standard.string(forKey: sessionIdKey) {
            sessionId = savedId
        } else {
            sessionId = UUID().uuidString
            UserDefaults.standard.set(sessionId, forKey: sessionIdKey)
        }
        loadMessages()
    }

    func addMessage(role: String, content: String, attachment: Attachment? = nil) {
        let message = Message(role: role, content: content, attachment: attachment)
        messages.append(message)
        saveMessages()
    }

    func clearMessages() {
        messages = []
        saveMessages()
        // 清空服务端会话
        Task {
            try? await KittyService.shared.clearSession(sessionId: sessionId)
        }
    }

    private func saveMessages() {
        guard let data = try? JSONEncoder().encode(messages) else { return }
        UserDefaults.standard.set(data, forKey: messagesKey)
    }

    private func loadMessages() {
        guard let data = UserDefaults.standard.data(forKey: messagesKey),
              let savedMessages = try? JSONDecoder().decode([Message].self, from: data) else {
            return
        }
        messages = savedMessages
    }
}