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
    @Published var callDuration: Int = 0  // 通话时长（秒）
    @Published var isSpeakerOn: Bool = true  // 扬声器状态（供 UI 绑定）

    enum ConversationState: String {
        case idle = "待机"
        case connected = "通话中"
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
    private var currentAudioData: Data?  // 当前播放的音频数据（用于切换扬声器后恢复）

    // 静音检测配置
    private let silenceThreshold: Float = 0.08
    private let silenceDuration: Double = 2.0
    private var silenceStartTime: Date?
    private var hasSpoken: Bool = false
    private var audioDataCount: Int = 0

    // 用户长时间不说话检测
    private let askStillThereTimeout: Double = 5.0    // 用户说完后5秒没反应才询问"还在听吗？"
    private let initialSilenceTimeout: Double = 15.0  // 用户一开始不说话，15秒后才询问
    private let hangupTimeout: Double = 60.0          // 60秒后挂断
    private var listeningStartTime: Date?  // 开始监听的时间
    private var lastSpeechTime: Date?      // 上次用户说话的时间
    private var hasAskedStillThere: Bool = false
    private var inactivityCheckTimer: Timer?

    // 语音打断配置（启用回声消除后可以使用更敏感的参数）
    private let interruptionThreshold: Float = 0.10  // 从 0.15 降低到 0.10
    private let interruptionDuration: Double = 0.2   // 从 0.3 降低到 0.2 秒
    private var interruptionStartTime: Date?

    // 通话控制
    private var isInCall = false
    private var isMuted = false  // 用户静音状态
    private var currentTask: Task<Void, Never>?
    private var isCancelled = false
    private var callTimer: Timer?

    // 思考音效
    private var thinkingAudioPlayer: AVAudioPlayer?

    // 来电中断处理
    private var wasPausedByInterruption = false
    private var stateBeforeInterruption: ConversationState = .idle

    init() {
        loadMessages()
        setupThinkingSound()
        setupAudioSessionInterruptionObserver()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: - Audio Session Interruption

    private func setupAudioSessionInterruptionObserver() {
        // 监听音频中断（来电等）
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleAudioSessionInterruption),
            name: AVAudioSession.interruptionNotification,
            object: nil
        )

        // 监听音频路由变化（扬声器切换等）
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleRouteChange),
            name: AVAudioSession.routeChangeNotification,
            object: nil
        )
    }

    @objc private func handleRouteChange(_ notification: Notification) {
        guard let userInfo = notification.userInfo,
              let reasonValue = userInfo[AVAudioSessionRouteChangeReasonKey] as? UInt,
              let reason = AVAudioSession.RouteChangeReason(rawValue: reasonValue) else {
            return
        }

        // 只处理我们主动触发的路由变化
        switch reason {
        case .override:
            // 用户通过 overrideOutputAudioPort 触发的变化
            NSLog("📡 路由变化: override")
            // 路由变化后恢复播放
            resumePlaybackIfNeeded()
        case .newDeviceAvailable, .oldDeviceUnavailable:
            NSLog("📡 路由变化: 设备连接/断开")
        default:
            NSLog("📡 路由变化: \(reason.rawValue)")
        }
    }

    /// 路由变化后恢复播放
    private func resumePlaybackIfNeeded() {
        guard let data = currentAudioData else { return }

        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }

            // 如果当前没有播放，尝试恢复
            if self.audioPlayer?.isPlaying != true {
                do {
                    self.audioPlayer = try AVAudioPlayer(data: data)
                    self.audioPlayer?.delegate = self.audioPlayerDelegate
                    self.audioPlayer?.volume = 1.0
                    self.audioPlayer?.prepareToPlay()

                    let success = self.audioPlayer?.play() ?? false
                    NSLog("🔊 路由变化后恢复播放: \(success ? "成功" : "失败")")
                } catch {
                    NSLog("❌ 路由变化后恢复播放失败: \(error)")
                }
            }
        }
    }

    @objc private func handleAudioSessionInterruption(_ notification: Notification) {
        guard let userInfo = notification.userInfo,
              let typeValue = userInfo[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: typeValue) else {
            return
        }

        switch type {
        case .began:
            // 中断开始（来电、闹钟等）
            handleInterruptionBegan()
        case .ended:
            // 中断结束（电话挂断）
            if let optionsValue = userInfo[AVAudioSessionInterruptionOptionKey] as? UInt {
                let options = AVAudioSession.InterruptionOptions(rawValue: optionsValue)
                handleInterruptionEnded(shouldResume: options.contains(.shouldResume))
            }
        @unknown default:
            break
        }
    }

    private func handleInterruptionBegan() {
        guard isInCall else { return }

        NSLog("📞 来电中断：暂停对话")
        wasPausedByInterruption = true
        stateBeforeInterruption = state

        // 停止思考音效
        stopThinkingSound()

        // 停止音频播放
        stopAudioPlayback()

        // 暂停音频引擎
        audioEngine?.pause()

        // 取消当前任务
        currentTask?.cancel()
        currentTask = nil

        // 停止计时器
        stopCallTimer()
        stopInactivityCheck()
    }

    private func handleInterruptionEnded(shouldResume: Bool) {
        guard wasPausedByInterruption else { return }

        NSLog("📞 中断结束：shouldResume=\(shouldResume)")

        wasPausedByInterruption = false

        if shouldResume && isInCall {
            // 恢复对话
            resumeAfterInterruption()
        } else {
            // 无法恢复，结束通话
            NSLog("📞 无法恢复通话，结束")
            Task { @MainActor in
                self.endCall()
            }
        }
    }

    private func resumeAfterInterruption() {
        NSLog("📞 恢复通话")

        // 重新激活音频会话
        do {
            try AVAudioSession.sharedInstance().setActive(true, options: .notifyOthersOnDeactivation)
        } catch {
            NSLog("❌ 激活音频会话失败: \(error)")
        }

        // 恢复音频引擎
        do {
            try audioEngine?.start()
        } catch {
            NSLog("❌ 启动音频引擎失败: \(error)")
        }

        // 重启计时器
        startCallTimer()

        // 提示用户
        Task { [weak self] in
            guard let self = self else { return }

            await MainActor.run {
                self.state = .speaking
            }

            if let audioData = try? await self.kittyService.synthesizeSpeech("刚才说到哪里了？") {
                await self.playAudioAndWait(audioData)
            }

            // 恢复监听状态
            if self.isInCall {
                await MainActor.run {
                    self.startListening()
                }
            }
        }
    }

    private func setupThinkingSound() {
        // 生成内置的思考音效（轻柔的和弦）
        thinkingAudioPlayer = generateThinkingSound()
    }

    /// 生成思考音效（轻柔温暖的 ambient 背景音乐）
    private func generateThinkingSound() -> AVAudioPlayer? {
        let sampleRate: Double = 44100
        let duration: Double = 8.0  // 8秒循环，更紧凑
        let samples = Int(sampleRate * duration)

        var audioData = Data(capacity: samples * 2)

        // 温暖的和弦进行（大七和弦 + 小七和弦，更有 ambient 感）
        // Am7 - Fmaj7 - Cmaj7 - G7
        let chordProgression: [[Double]] = [
            [110.0, 220.0, 261.63, 329.63, 392.0],   // Am7 (A-C-E-G)
            [87.31, 174.61, 220.0, 261.63, 329.63],  // Fmaj7 (F-A-C-E)
            [65.41, 130.81, 164.81, 196.0, 246.94],  // Cmaj7 (C-E-G-B) 低八度更温暖
            [98.0, 196.0, 246.94, 293.66, 349.23]    // G7 (G-B-D-F)
        ]
        let chordDuration = duration / Double(chordProgression.count)

        for i in 0..<samples {
            let t = Double(i) / sampleRate

            // 当前和弦索引
            let chordIndex = Int(t / chordDuration) % chordProgression.count
            let localT = t.truncatingRemainder(dividingBy: chordDuration)
            let chord = chordProgression[chordIndex]

            // 平滑过渡（交叉淡入淡出）
            let transitionTime = 1.0  // 更长的过渡时间，更柔和
            let crossfade = min(1.0, max(0.0, (localT - (chordDuration - transitionTime)) / transitionTime))

            var sample: Double = 0

            // 柔和的 pad 音色（持续性的背景音）
            for (index, freq) in chord.enumerated() {
                // 每个音符有不同的音量，低音更响，高音更轻
                let noteVolume = 0.08 * exp(-Double(index) * 0.3)

                // 柔和的包络 - 缓慢的 attack 和 decay
                let attack = min(1.0, localT / 1.5)
                let decay = exp(-localT / 6.0)
                let envelope = attack * decay

                // 使用三角波（更柔和）+ 正弦波组合
                let triangle = 2.0 * abs(2.0 * (freq * t / 1.0).truncatingRemainder(dividingBy: 1.0) - 0.5) - 1.0
                let sine = sin(2.0 * .pi * freq * t)
                let wave = 0.6 * triangle + 0.4 * sine  // 混合波形

                // 添加轻微的颤音
                let vibrato = 1.0 + 0.002 * sin(2.0 * .pi * 4.0 * t)
                let note = wave * vibrato * envelope * noteVolume * (1.0 - crossfade)

                sample += note
            }

            // 下一个和弦（淡入）
            if crossfade > 0 {
                let nextChordIndex = (chordIndex + 1) % chordProgression.count
                let nextChord = chordProgression[nextChordIndex]

                for (index, freq) in nextChord.enumerated() {
                    let noteVolume = 0.08 * exp(-Double(index) * 0.3)

                    let noteT = localT - (chordDuration - transitionTime)
                    let attack = min(1.0, noteT / 1.5)
                    let decay = exp(-noteT / 6.0)
                    let envelope = attack * decay

                    let triangle = 2.0 * abs(2.0 * (freq * t / 1.0).truncatingRemainder(dividingBy: 1.0) - 0.5) - 1.0
                    let sine = sin(2.0 * .pi * freq * t)
                    let wave = 0.6 * triangle + 0.4 * sine

                    let vibrato = 1.0 + 0.002 * sin(2.0 * .pi * 4.0 * t)
                    let note = wave * vibrato * envelope * noteVolume * crossfade

                    sample += note
                }
            }

            // 添加高频"闪烁"效果（像星星一样）
            let sparkleFreq = 880.0 + 440.0 * sin(2.0 * .pi * 0.5 * t)  // 轻微变化
            let sparkle = 0.02 * sin(2.0 * .pi * sparkleFreq * t) * (0.5 + 0.5 * sin(2.0 * .pi * 2.0 * t))
            sample += sparkle

            // 添加轻微的"呼吸"效果（音量缓慢变化）
            let breath = 0.8 + 0.2 * sin(2.0 * .pi * 0.25 * t)
            sample *= breath

            // 归一化并转换为16位整数
            let normalizedSample = max(-1.0, min(1.0, sample * 0.5))
            let intSample = Int16(normalizedSample * 32767)

            var bytes = withUnsafeBytes(of: intSample.littleEndian) { Array($0) }
            audioData.append(contentsOf: bytes)
        }

        // 创建 WAV 文件头
        let wavHeader = createWavHeader(dataSize: audioData.count, sampleRate: Int(sampleRate))
        var wavData = wavHeader
        wavData.append(audioData)

        do {
            let player = try AVAudioPlayer(data: wavData)
            player.numberOfLoops = -1
            player.volume = 0.35  // 降低音量，更柔和
            return player
        } catch {
            NSLog("❌ 创建思考音效失败: \(error)")
            return nil
        }
    }

    /// 创建 WAV 文件头
    private func createWavHeader(dataSize: Int, sampleRate: Int) -> Data {
        var header = Data()
        let bytesPerSample: Int = 2
        let channels: Int = 1
        let byteRate = sampleRate * channels * bytesPerSample
        let blockAlign = channels * bytesPerSample

        // RIFF header
        header.append(contentsOf: "RIFF".utf8)
        header.append(contentsOf: withUnsafeBytes(of: UInt32(36 + dataSize).littleEndian) { Array($0) })
        header.append(contentsOf: "WAVE".utf8)

        // fmt chunk
        header.append(contentsOf: "fmt ".utf8)
        header.append(contentsOf: withUnsafeBytes(of: UInt32(16).littleEndian) { Array($0) })  // chunk size
        header.append(contentsOf: withUnsafeBytes(of: UInt16(1).littleEndian) { Array($0) })   // PCM format
        header.append(contentsOf: withUnsafeBytes(of: UInt16(channels).littleEndian) { Array($0) })
        header.append(contentsOf: withUnsafeBytes(of: UInt32(sampleRate).littleEndian) { Array($0) })
        header.append(contentsOf: withUnsafeBytes(of: UInt32(byteRate).littleEndian) { Array($0) })
        header.append(contentsOf: withUnsafeBytes(of: UInt16(blockAlign).littleEndian) { Array($0) })
        header.append(contentsOf: withUnsafeBytes(of: UInt16(bytesPerSample * 8).littleEndian) { Array($0) })

        // data chunk
        header.append(contentsOf: "data".utf8)
        header.append(contentsOf: withUnsafeBytes(of: UInt32(dataSize).littleEndian) { Array($0) })

        return header
    }

    private func startThinkingSound() {
        DispatchQueue.main.async {
            self.thinkingAudioPlayer?.currentTime = 0
            self.thinkingAudioPlayer?.play()
        }
    }

    private func stopThinkingSound() {
        DispatchQueue.main.async {
            self.thinkingAudioPlayer?.stop()
        }
    }

    // MARK: - Public Methods - Call Control

    /// 开始通话（持续对话模式）
    func startCall() {
        NSLog("📞 开始通话")
        isInCall = true
        isCancelled = false
        userText = ""
        assistantText = ""
        errorMessage = nil
        callDuration = 0

        state = .connected
        startCallTimer()

        // 启动音频引擎（持续运行，用于打断检测和录音）
        startAudioEngine()

        // 开始第一轮监听
        startListening()
    }

    /// 结束通话（挂断）
    func endCall() {
        NSLog("📞 结束通话")
        isInCall = false
        isCancelled = true

        // 停止计时器
        stopCallTimer()

        // 停止不活动检测
        stopInactivityCheck()

        // 停止思考音效
        stopThinkingSound()

        // 取消当前任务
        currentTask?.cancel()
        currentTask = nil

        // 停止音频播放
        stopAudioPlayback()

        // 停止音频引擎
        stopAudioEngine()

        // 重置状态
        state = .idle
        userText = ""
        assistantText = ""
        errorMessage = nil
    }

    /// 切换通话状态
    func toggleCall() {
        if isInCall {
            endCall()
        } else {
            startCall()
        }
    }

    /// 清空历史消息
    func clearHistory() {
        messages = []
        saveMessages()

        // 同时清空服务端会话
        Task {
            try? await kittyService.clearSession()
        }
    }

    /// 设置静音状态
    func setMuted(_ muted: Bool) {
        isMuted = muted
        NSLog("🔇 静音状态: \(muted ? "开启" : "关闭")")

        if muted {
            // 静音时清空当前收集的音频
            audioBuffer = Data()
            audioDataCount = 0
        }
    }

    /// 切换扬声器模式
    func setSpeakerMode(_ speaker: Bool) {
        NSLog("🔊 切换扬声器: \(speaker ? "扬声器" : "听筒")")

        // 更新状态
        isSpeakerOn = speaker

        let audioSession = AVAudioSession.sharedInstance()

        do {
            // 只使用 overrideOutputAudioPort，路由变化通知会触发恢复播放
            if speaker {
                try audioSession.overrideOutputAudioPort(.speaker)
            } else {
                try audioSession.overrideOutputAudioPort(.none)
            }

            let route = audioSession.currentRoute
            NSLog("   ✓ 输出: \(route.outputs.first?.portName ?? "未知")")
        } catch {
            NSLog("   ❌ 切换失败: \(error)")
        }
    }

    // MARK: - Private Methods - Conversation Flow

    /// 开始监听（一轮对话）
    private func startListening() {
        guard isInCall else { return }

        NSLog("🎤 开始监听")
        audioBuffer = Data()
        audioDataCount = 0
        hasSpoken = false
        silenceStartTime = nil
        lastSpeechTime = nil  // 重置说话时间
        state = .listening

        // 开始用户不活动检测
        startInactivityCheck()
    }

    /// 结束监听，处理音频
    private func stopListeningAndProcess() {
        guard isInCall else { return }

        // 停止不活动检测
        stopInactivityCheck()

        NSLog("🎤 结束监听，开始处理")

        guard !audioBuffer.isEmpty else {
            // 没有音频数据，继续监听
            NSLog("⚠️ 无音频数据，继续监听")
            startListening()
            return
        }

        // 处理音频
        currentTask = Task { [weak self] in
            await self?.processAudio()
        }
    }

    // MARK: - Inactivity Check

    /// 开始检测用户不活动
    private func startInactivityCheck() {
        listeningStartTime = Date()
        lastSpeechTime = nil
        hasAskedStillThere = false

        inactivityCheckTimer?.invalidate()
        inactivityCheckTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.checkInactivity()
        }
    }

    /// 停止不活动检测
    private func stopInactivityCheck() {
        inactivityCheckTimer?.invalidate()
        inactivityCheckTimer = nil
        listeningStartTime = nil
        lastSpeechTime = nil
        hasAskedStillThere = false
    }

    /// 检测用户不活动
    private func checkInactivity() {
        guard isInCall, state == .listening else { return }

        // 用户正在说话，记录说话时间
        if hasSpoken && silenceStartTime == nil {
            lastSpeechTime = Date()
            hasAskedStillThere = false
            return
        }

        // 情况1：用户说过了话，但已经沉默（silenceStartTime 已设置）
        if let speechTime = lastSpeechTime {
            let silenceElapsed = Date().timeIntervalSince(speechTime)

            // 用户说完后5秒没反应，询问"还在听吗？"
            if silenceElapsed >= askStillThereTimeout && !hasAskedStillThere {
                NSLog("⏰ 用户说完后\(Int(silenceElapsed))秒没反应，询问是否在线")
                hasAskedStillThere = true
                askStillThere()
            }

            // 60秒后挂断（从最后说话算起）
            if silenceElapsed >= hangupTimeout {
                NSLog("⏰ 用户长时间未说话，自动挂断")
                sayGoodbyeAndHangup()
            }
        }
        // 情况2：用户一开始就没说话
        else if let startTime = listeningStartTime {
            let elapsed = Date().timeIntervalSince(startTime)

            if elapsed >= initialSilenceTimeout && !hasAskedStillThere {
                NSLog("⏰ 用户\(Int(initialSilenceTimeout))秒未说话，询问是否在线")
                hasAskedStillThere = true
                askStillThere()
            }
        }
    }

    /// 询问"还在听吗？"
    private func askStillThere() {
        Task { [weak self] in
            guard let self = self else { return }

            // 播放询问语音
            if let audioData = try? await self.kittyService.synthesizeSpeech("还在听吗？") {
                await MainActor.run {
                    self.state = .speaking
                }
                await self.playAudioAndWait(audioData)

                // 恢复监听状态
                if self.isInCall {
                    await MainActor.run {
                        self.lastSpeechTime = nil  // 重置，等待用户新的输入
                        self.hasSpoken = false
                        self.silenceStartTime = nil
                        self.hasAskedStillThere = false
                        self.state = .listening
                    }
                }
            }
        }
    }

    /// 说再见并挂断
    private func sayGoodbyeAndHangup() {
        Task { [weak self] in
            guard let self = self else { return }

            // 播放告别语音
            if let audioData = try? await self.kittyService.synthesizeSpeech("我要先挂断了，需要时随时呼叫我哦。再见！") {
                await MainActor.run {
                    self.state = .speaking
                }
                await self.playAudioAndWait(audioData)
            }

            // 挂断
            await MainActor.run {
                self.endCall()
            }
        }
    }

    // MARK: - Audio Recording

    /// 配置音频会话（在通话开始时调用一次）
    private func configureAudioSession() {
        let audioSession = AVAudioSession.sharedInstance()
        do {
            // 检测是否有蓝牙设备
            let hasBluetooth = audioSession.availableInputs?.contains { input in
                input.portType == .bluetoothHFP || input.portType == .bluetoothLE
            } ?? false

            if hasBluetooth {
                // 蓝牙模式：使用 voiceChat 保证双向通信
                try audioSession.setCategory(
                    .playAndRecord,
                    mode: .voiceChat,
                    options: [.allowBluetooth, .mixWithOthers]
                )
                NSLog("📍 蓝牙模式")
            } else {
                // 扬声器模式：使用 default 模式获得更大音量
                // .voiceChat 模式会限制扬声器音量
                try audioSession.setCategory(
                    .playAndRecord,
                    mode: .default,
                    options: [.defaultToSpeaker, .mixWithOthers]
                )
                // 强制扬声器输出
                try audioSession.overrideOutputAudioPort(.speaker)
                NSLog("📍 扬声器模式（高音量）")
            }

            try audioSession.setActive(true, options: .notifyOthersOnDeactivation)

            // 打印当前音频路由信息
            let currentRoute = audioSession.currentRoute
            NSLog("   输入: \(currentRoute.inputs.first?.portName ?? "未知") (\(currentRoute.inputs.first?.portType.rawValue ?? "未知"))")
            NSLog("   输出: \(currentRoute.outputs.first?.portName ?? "未知") (\(currentRoute.outputs.first?.portType.rawValue ?? "未知"))")

            // 打印所有可用输入
            NSLog("📍 可用输入设备:")
            for input in audioSession.availableInputs ?? [] {
                NSLog("   - \(input.portName) (\(input.portType.rawValue))")
            }
        } catch {
            NSLog("❌ 音频会话配置失败: \(error)")
        }
    }

    /// 启动音频引擎（持续运行，用于打断检测和录音）
    private func startAudioEngine() {
        // 配置音频会话（只需一次）
        configureAudioSession()

        audioEngine = AVAudioEngine()
        let inputNode = audioEngine!.inputNode

        // 启用语音处理（回声消除、降噪）
        do {
            try inputNode.setVoiceProcessingEnabled(true)
            NSLog("✅ 语音处理已启用（回声消除）")
        } catch {
            NSLog("⚠️ 启用语音处理失败: \(error)")
        }

        let format = inputNode.outputFormat(forBus: 0)
        let targetFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16000, channels: 1, interleaved: true)!

        guard let converter = AVAudioConverter(from: format, to: targetFormat) else {
            NSLog("❌ 无法创建音频转换器")
            return
        }

        inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            guard let self = self else { return }

            let level = self.calculateAudioLevel(buffer: buffer)
            DispatchQueue.main.async {
                self.audioLevel = level

                // 根据状态选择检测模式
                if self.state == .listening {
                    self.checkSilence(level: level)
                } else if self.state == .speaking {
                    self.checkInterruption(level: level)
                }
            }

            // 只在 listening 状态下且未静音时收集音频数据
            if self.state == .listening && !self.isMuted {
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
                }
            }
        }

        do {
            try audioEngine?.start()
            isRecording = true
            NSLog("🎤 音频引擎已启动")
        } catch {
            NSLog("❌ 音频引擎启动失败: \(error)")
        }
    }

    private func stopAudioEngine() {
        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine?.stop()
        audioEngine = nil
        isRecording = false
        silenceStartTime = nil
        interruptionStartTime = nil
        NSLog("🎤 音频引擎已停止")
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
        guard state == .listening, isRecording, isInCall else { return }

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
                    NSLog("🔇 静音检测：用户说完")
                    stopListeningAndProcess()
                }
            }
        }
    }

    // MARK: - Interruption Detection

    private func checkInterruption(level: Float) {
        guard state == .speaking, isInCall else { return }

        // 添加调试日志（当音量超过最小阈值时）
        if level > 0.05 {
            NSLog("🔊 打断检测: 音量=\(String(format: "%.2f", level)), 阈值=\(interruptionThreshold)")
        }

        if level > interruptionThreshold {
            if interruptionStartTime == nil {
                interruptionStartTime = Date()
                NSLog("🔊 检测到用户语音，开始计时")
            } else if let startTime = interruptionStartTime {
                let duration = Date().timeIntervalSince(startTime)
                if duration >= interruptionDuration {
                    NSLog("🔊 用户打断（持续 \(String(format: "%.2f", duration))秒）")
                    handleInterruption()
                }
            }
        } else {
            if interruptionStartTime != nil {
                NSLog("🔊 用户语音中断，重置计时")
            }
            interruptionStartTime = nil
        }
    }

    private func handleInterruption() {
        NSLog("🔊 用户打断，立即停止语音")

        // 停止思考音效
        stopThinkingSound()

        // 停止音频播放
        stopAudioPlayback()

        // 取消当前任务
        currentTask?.cancel()
        currentTask = nil

        // 重置打断检测
        interruptionStartTime = nil

        // 清空音频缓冲区，开始收集新的语音
        audioBuffer = Data()
        audioDataCount = 0

        // 清空显示的文本
        Task { @MainActor in
            self.userText = ""
            self.assistantText = ""
        }

        // 进入监听状态，重置所有计时状态
        state = .listening
        hasSpoken = false
        silenceStartTime = nil
        lastSpeechTime = nil
        hasAskedStillThere = false

        // 启动用户不活动检测
        startInactivityCheck()

        NSLog("✅ 打断处理完成，开始监听用户说话")
    }

    private func stopAudioPlayback() {
        // 先获取并清空 continuation，防止重复 resume
        let continuation = playbackContinuation
        playbackContinuation = nil

        audioPlayer?.stop()
        audioPlayer = nil
        audioPlayerDelegate = nil

        // 最后 resume
        continuation?.resume()
    }

    // MARK: - Processing

    private func processAudio() async {
        guard isInCall else { return }

        state = .thinking
        startThinkingSound()  // 播放思考音效
        NSLog("📤 开始处理音频, 数据量: \(audioBuffer.count) bytes")

        do {
            NSLog("📤 发送 ASR 请求")
            let text = try await kittyService.recognizeSpeech(audioData: audioBuffer)
            NSLog("📥 ASR 结果: \(text)")

            // 检查是否被取消或通话结束
            if isCancelled || Task.isCancelled || !isInCall {
                NSLog("⏹️ 任务已取消")
                stopThinkingSound()
                return
            }

            await MainActor.run {
                self.userText = text
            }

            // 如果识别结果为空，继续监听
            if text.isEmpty {
                NSLog("⚠️ ASR 结果为空，继续监听")
                stopThinkingSound()
                await MainActor.run {
                    self.startListening()
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

            let selectedModel = UserDefaults.standard.string(forKey: "selectedModel")
            try await kittyService.chatStream(text, history: history, model: selectedModel) { [weak self] chunk in
                guard let self = self, !self.isCancelled, !Task.isCancelled, self.isInCall else { return }

                fullReply += chunk
                Task { @MainActor [weak self] in
                    self?.assistantText = fullReply
                }
            }

            // 检查是否被取消
            if isCancelled || Task.isCancelled || !isInCall {
                NSLog("⏹️ 任务已取消")
                stopThinkingSound()
                return
            }

            NSLog("🐱 助手: \(fullReply)")

            if !fullReply.isEmpty {
                // 停止思考音效
                stopThinkingSound()

                // 添加助手消息
                await MainActor.run {
                    self.messages.append(Message(role: "assistant", content: fullReply))
                    self.saveMessages()
                    self.state = .speaking
                }

                let audioData = try await kittyService.synthesizeSpeech(fullReply)

                // 检查是否被取消
                if isCancelled || Task.isCancelled || !isInCall {
                    NSLog("⏹️ 播放前任务已取消")
                    return
                }

                // 等待音频播放完成（支持打断）
                await playAudioAndWait(audioData)
            } else {
                stopThinkingSound()
            }

            // 如果还在通话中，继续下一轮监听
            if isInCall && !isCancelled && !Task.isCancelled {
                NSLog("🔄 回复完成，继续监听")
                await MainActor.run {
                    self.startListening()
                }
            }

        } catch {
            stopThinkingSound()
            if isCancelled || Task.isCancelled || !isInCall {
                NSLog("⏹️ 任务已取消")
                return
            }

            NSLog("❌ 处理失败: \(error)")

            // 在通话模式下，出错后继续监听
            if isInCall {
                await MainActor.run {
                    self.errorMessage = error.localizedDescription
                }

                // 2秒后清除错误，继续监听
                try? await Task.sleep(nanoseconds: 2_000_000_000)

                if isInCall {
                    await MainActor.run {
                        self.errorMessage = nil
                        self.startListening()
                    }
                }
            }
        }
    }

    // MARK: - Audio Playback

    private func playAudioAndWait(_ data: Data) async {
        // 保存音频数据（用于切换扬声器后恢复）
        currentAudioData = data

        // 不切换音频模式，保持 voiceChat 配置
        // 这确保蓝牙路由不会丢失
        let audioSession = AVAudioSession.sharedInstance()
        try? audioSession.setActive(true)

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.main.async { [weak self] in
                guard let self = self else {
                    continuation.resume()
                    return
                }

                do {
                    var isResumed = false

                    self.audioPlayerDelegate = AudioPlayerDelegate(onFinish: { [weak self] in
                        guard let self = self, !isResumed else { return }
                        isResumed = true
                        self.currentAudioData = nil  // 播放完成，清除数据
                        self.playbackContinuation = nil
                        continuation.resume()
                    })

                    self.audioPlayer = try AVAudioPlayer(data: data)
                    self.audioPlayer?.delegate = self.audioPlayerDelegate
                    self.audioPlayer?.volume = 1.0
                    self.audioPlayer?.prepareToPlay()

                    let success = self.audioPlayer?.play() ?? false
                    NSLog("🔊 播放音频: \(success ? "成功" : "失败"), 数据量: \(data.count) bytes")

                    if success {
                        self.playbackContinuation = continuation
                    } else {
                        isResumed = true
                        self.currentAudioData = nil
                        self.audioPlayerDelegate = nil
                        continuation.resume()
                    }
                } catch {
                    NSLog("❌ 播放音频失败: \(error)")
                    self.currentAudioData = nil
                    continuation.resume()
                }
            }
        }
    }

    // MARK: - Call Timer

    private func startCallTimer() {
        callTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self = self, self.isInCall else { return }
            self.callDuration += 1
        }
    }

    private func stopCallTimer() {
        callTimer?.invalidate()
        callTimer = nil
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
