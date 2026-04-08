import Foundation
import AVFoundation
import SwiftUI

struct Message: Identifiable, Codable {
    let id: UUID
    let role: String
    let content: String
    let timestamp: Date

    init(role: String, content: String) {
        self.id = UUID()
        self.role = role
        self.content = content
        self.timestamp = Date()
    }
}

class ConversationManager: ObservableObject {
    @Published var state: ConversationState = .idle
    @Published var userText: String = ""
    @Published var assistantText: String = ""
    @Published var errorMessage: String?
    @Published var audioLevel: Float = 0
    @Published var messages: [Message] = []

    enum ConversationState: String {
        case idle = "待机"
        case listening = "监听中"
        case thinking = "思考中"
        case speaking = "回复中"
        case error = "错误"
    }

    private let kittyService = KittyService.shared
    private var audioEngine: AVAudioEngine?
    private var audioBuffer: Data = Data()
    private var isRecording = false

    private let maxHistoryCount = 20
    private let messagesKey = "kitty_messages"

    // 用于等待音频播放完成
    private var audioPlayer: AVAudioPlayer?
    private var audioPlayerDelegate: AudioPlayerDelegate?
    private var playbackContinuation: CheckedContinuation<Void, Never>?

    // 静音检测配置
    private let silenceThreshold: Float = 0.08  // 静音阈值（降低以适应模拟器）
    private let silenceDuration: Double = 2.5   // 静音持续时间（增加到2.5秒）
    private var silenceStartTime: Date?
    private var hasSpoken: Bool = false         // 是否已经说话过
    private var audioDataCount: Int = 0         // 收集的音频数据计数

    // 语音打断配置
    private let interruptionThreshold: Float = 0.25  // 打断阈值（比静音阈值高）
    private let interruptionDuration: Double = 0.5   // 打断持续时间（秒）
    private var interruptionStartTime: Date?

    // 当前任务取消标志
    private var currentTask: Task<Void, Never>?
    private var isCancelled = false

    init() {
        loadMessages()
    }

    // MARK: - Public Methods

    func startConversation() {
        NSLog("🚀 startConversation 被调用")
        userText = ""
        assistantText = ""
        errorMessage = nil
        isCancelled = false
        state = .listening
        hasSpoken = false
        silenceStartTime = nil
        startRecording()
    }

    func stopConversation() {
        NSLog("🛑 stopConversation 被调用")
        stopRecording()

        if !audioBuffer.isEmpty {
            currentTask = Task { [weak self] in
                await self?.processAudio()
            }
        } else {
            state = .idle
        }
    }

    func cancelCurrentOperation() {
        NSLog("⏹️ cancelCurrentOperation 被调用")

        // 设置取消标志
        isCancelled = true

        // 取消当前任务
        currentTask?.cancel()
        currentTask = nil

        // 停止音频播放
        stopAudioPlayback()

        // 停止录音
        stopRecording()

        // 重置状态
        state = .idle
        userText = ""
        assistantText = ""
        errorMessage = nil
    }

    func clearHistory() {
        messages = []
        saveMessages()
    }

    // MARK: - Audio Recording

    private func startRecording() {
        audioBuffer = Data()
        audioDataCount = 0

        let audioSession = AVAudioSession.sharedInstance()
        do {
            try audioSession.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .mixWithOthers])
            try audioSession.setActive(true)
        } catch {
            print("❌ 音频会话配置失败: \(error)")
            errorMessage = "音频配置失败"
            state = .error
            return
        }

        audioEngine = AVAudioEngine()
        let inputNode = audioEngine!.inputNode

        let format = inputNode.outputFormat(forBus: 0)
        let targetFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16000, channels: 1, interleaved: true)!

        guard let converter = AVAudioConverter(from: format, to: targetFormat) else {
            print("❌ 无法创建音频转换器")
            return
        }

        inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            guard let self = self else { return }

            let level = self.calculateAudioLevel(buffer: buffer)
            DispatchQueue.main.async {
                self.audioLevel = level

                // 每50帧打印一次音频级别（用于调试）
                if self.audioDataCount % 50 == 0 && self.isRecording {
                    NSLog("🎤 音频级别: \(String(format: "%.2f", level)), 是否说话: \(self.hasSpoken)")
                }

                // 根据状态选择检测模式
                if self.state == .listening && self.isRecording {
                    self.checkSilence(level: level)
                } else if self.state == .speaking {
                    self.checkInterruption(level: level)
                }
            }

            // 只在 listening 状态下收集音频数据
            if self.isRecording {
                let frameCount = UInt32(Double(buffer.frameLength) * 16000.0 / format.sampleRate)
                guard let convertedBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: frameCount) else { return }

                var error: NSError?
                let inputBlock: AVAudioConverterInputBlock = { _, outStatus in
                    outStatus.pointee = .haveData
                    return buffer
                }

                converter.convert(to: convertedBuffer, error: &error, withInputFrom: inputBlock)

                if let channelData = convertedBuffer.int16ChannelData {
                    let data = Data(bytes: channelData[0], count: Int(convertedBuffer.frameLength) * 2)
                    self.audioBuffer.append(data)
                    self.audioDataCount += 1
                    // 每100帧打印一次
                    if self.audioDataCount % 100 == 0 {
                        NSLog("🎤 录音中... 已收集 \(self.audioBuffer.count) bytes, level: \(level)")
                    }
                }
            }
        }

        do {
            try audioEngine?.start()
            isRecording = true
            NSLog("🎤 开始录音, 音频引擎已启动")
        } catch {
            NSLog("❌ 音频引擎启动失败: \(error)")
        }
    }

    private func stopRecording() {
        isRecording = false
        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine?.stop()
        audioEngine = nil
        silenceStartTime = nil
        interruptionStartTime = nil
        NSLog("🎤 停止录音，数据量: \(audioBuffer.count) bytes")
    }

    private func calculateAudioLevel(buffer: AVAudioPCMBuffer) -> Float {
        guard let channelData = buffer.floatChannelData else { return 0 }
        let channelDataValue = channelData[0]

        var sum: Float = 0
        for i in 0..<Int(buffer.frameLength) {
            sum += abs(channelDataValue[i])
        }

        let average = sum / Float(buffer.frameLength)
        let level = 20 * log10(average + 0.0001)
        return min(max(level + 50, 0), 100) / 100
    }

    // MARK: - Silence Detection

    private func checkSilence(level: Float) {
        guard state == .listening, isRecording else { return }

        if level > silenceThreshold {
            // 有声音，标记已说话并重置静音计时
            hasSpoken = true
            silenceStartTime = nil
        } else if hasSpoken {
            // 静音状态，且之前已经说话过
            if silenceStartTime == nil {
                silenceStartTime = Date()
            } else if let startTime = silenceStartTime {
                let duration = Date().timeIntervalSince(startTime)
                if duration >= silenceDuration {
                    print("🔇 静音检测：自动停止录音")
                    stopConversation()
                }
            }
        }
    }

    // MARK: - Interruption Detection (Voice Interruption)

    private func checkInterruption(level: Float) {
        guard state == .speaking else { return }

        if level > interruptionThreshold {
            // 检测到用户说话
            if interruptionStartTime == nil {
                interruptionStartTime = Date()
            } else if let startTime = interruptionStartTime {
                let duration = Date().timeIntervalSince(startTime)
                if duration >= interruptionDuration {
                    print("🔊 语音打断：用户说话，停止播放")
                    handleInterruption()
                }
            }
        } else {
            // 静音，重置打断计时
            interruptionStartTime = nil
        }
    }

    private func handleInterruption() {
        // 停止音频播放
        stopAudioPlayback()

        // 重置打断检测
        interruptionStartTime = nil

        // 开始新的对话
        state = .listening
        hasSpoken = false
        silenceStartTime = nil
        audioBuffer = Data()

        // 如果录音引擎还在运行，继续监听
        // 否则重新启动录音
        if !isRecording {
            startRecording()
        }

        print("✅ 打断处理完成，进入监听状态")
    }

    private func stopAudioPlayback() {
        audioPlayer?.stop()
        audioPlayer = nil
        audioPlayerDelegate = nil

        // 如果有等待中的 continuation，需要 resume
        if let continuation = playbackContinuation {
            continuation.resume()
            playbackContinuation = nil
        }
    }

    // MARK: - Processing

    private func processAudio() async {
        state = .thinking
        NSLog("📤 开始处理音频, 数据量: \(audioBuffer.count) bytes")

        do {
            NSLog("📤 发送 ASR 请求")
            let text = try await kittyService.recognizeSpeech(audioData: audioBuffer)
            NSLog("📥 ASR 结果: \(text)")

            // 检查是否被取消
            if isCancelled || Task.isCancelled {
                print("⏹️ 任务已取消")
                return
            }

            await MainActor.run {
                self.userText = text
            }

            if text.isEmpty {
                await MainActor.run {
                    self.state = .idle
                }
                return
            }

            // 添加用户消息
            await MainActor.run {
                self.messages.append(Message(role: "user", content: text))
            }

            // 构建历史上下文
            let history = buildChatHistory()

            var fullReply = ""

            try await kittyService.chatStream(text, history: history) { [weak self] chunk in
                guard let self = self, !self.isCancelled, !Task.isCancelled else { return }

                fullReply += chunk
                Task { @MainActor [weak self] in
                    self?.assistantText = fullReply
                }
            }

            // 检查是否被取消
            if isCancelled || Task.isCancelled {
                print("⏹️ 任务已取消")
                return
            }

            print("🐱 助手: \(fullReply)")

            if !fullReply.isEmpty {
                // 添加助手消息
                await MainActor.run {
                    self.messages.append(Message(role: "assistant", content: fullReply))
                    self.saveMessages()
                    self.state = .speaking
                }

                let audioData = try await kittyService.synthesizeSpeech(fullReply)

                // 检查是否被取消
                if isCancelled || Task.isCancelled {
                    print("⏹️ 播放前任务已取消")
                    return
                }

                // 等待音频播放完成（支持打断）
                await playAudioAndWait(audioData)
            }

            if !isCancelled && !Task.isCancelled {
                await MainActor.run {
                    self.state = .idle
                }
            }

        } catch {
            if isCancelled || Task.isCancelled {
                print("⏹️ 任务已取消")
                return
            }

            print("❌ 处理失败: \(error)")
            await MainActor.run {
                self.state = .error
                self.errorMessage = error.localizedDescription
            }

            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
                self?.state = .idle
                self?.errorMessage = nil
            }
        }
    }

    // MARK: - Audio Playback with Wait (Supports Interruption)

    private func playAudioAndWait(_ data: Data) async {
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default, options: [.mixWithOthers])
            try AVAudioSession.sharedInstance().setActive(true)

            await withCheckedContinuation { continuation in
                DispatchQueue.main.async {
                    do {
                        // 创建 delegate 并强引用
                        self.audioPlayerDelegate = AudioPlayerDelegate(onFinish: {
                            continuation.resume()
                        })

                        self.audioPlayer = try AVAudioPlayer(data: data)
                        self.audioPlayer?.delegate = self.audioPlayerDelegate
                        self.audioPlayer?.prepareToPlay()

                        let success = self.audioPlayer?.play() ?? false
                        print("🔊 播放音频: \(success ? "成功" : "失败"), 数据量: \(data.count) bytes")
                        self.playbackContinuation = continuation

                        // 如果播放失败，直接 resume
                        if !success {
                            self.playbackContinuation = nil
                            self.audioPlayerDelegate = nil
                            continuation.resume()
                        }
                    } catch {
                        print("❌ 播放音频失败: \(error)")
                        continuation.resume()
                    }
                }
            }
        } catch {
            print("❌ 音频会话配置失败: \(error)")
        }
    }

    // MARK: - History Management

    private func buildChatHistory() -> [[String: String]] {
        let recentMessages = messages.suffix(maxHistoryCount)
        return recentMessages.map { ["role": $0.role, "content": $0.content] }
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

// MARK: - Audio Player Delegate

private class AudioPlayerDelegate: NSObject, AVAudioPlayerDelegate {
    let onFinish: () -> Void

    init(onFinish: @escaping () -> Void) {
        self.onFinish = onFinish
        super.init()
    }

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        onFinish()
    }
}