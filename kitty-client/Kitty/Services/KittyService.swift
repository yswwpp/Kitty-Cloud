import Foundation
import AVFoundation

class KittyService: ObservableObject {
    static let shared = KittyService()

    @Published var isLoading = false
    @Published var errorMessage: String?

    var serverURL: String {
        // 获取存储的地址
        if let savedURL = UserDefaults.standard.string(forKey: "serverURL"), !savedURL.isEmpty {
            // 真机上：如果地址包含 localhost/127.0.0.1 或错误的端口(18789)，强制替换为正确的地址
            #if !targetEnvironment(simulator)
            if savedURL.contains("localhost") || savedURL.contains("127.0.0.1") || savedURL.contains(":18789") {
                return "http://192.168.31.70:8080"
            }
            #endif
            return savedURL
        }
        // 默认地址
        #if targetEnvironment(simulator)
        return "http://localhost:8080"
        #else
        return "http://192.168.31.70:8080"
        #endif
    }

    private let session: URLSession
    private var audioPlayer: AVAudioPlayer?

    private init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 120
        config.timeoutIntervalForResource = 180
        config.waitsForConnectivity = true
        self.session = URLSession(configuration: config)
    }

    // MARK: - ASR

    func recognizeSpeech(audioData: Data) async throws -> String {
        print("🌐 服务器地址: \(serverURL)")
        let base64Audio = audioData.base64EncodedString()
        let request = ["audio": base64Audio, "format": "wav"]

        let urlString = "\(serverURL)/asr"
        print("📤 请求 URL: \(urlString)")

        guard let url = URL(string: urlString) else {
            print("❌ URL 无效")
            throw KittyError.invalidURL(urlString)
        }

        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.timeoutInterval = 60  // ASR 可能需要更长时间
        urlRequest.httpBody = try JSONSerialization.data(withJSONObject: request)

        do {
            let (data, response) = try await session.data(for: urlRequest)

            guard let httpResponse = response as? HTTPURLResponse else {
                throw KittyError.invalidResponse
            }

            switch httpResponse.statusCode {
            case 200:
                guard let result = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let text = result["text"] as? String else {
                    throw KittyError.invalidResponse
                }
                return text
            case 401, 403:
                throw KittyError.unauthorized
            case 500...599:
                throw KittyError.serverError(httpResponse.statusCode)
            default:
                throw KittyError.httpError(httpResponse.statusCode)
            }
        } catch let error as KittyError {
            throw error
        } catch {
            if (error as NSError).code == NSURLErrorTimedOut {
                throw KittyError.timeout
            } else if (error as NSError).code == NSURLErrorNotConnectedToInternet ||
                      (error as NSError).code == NSURLErrorNetworkConnectionLost {
                throw KittyError.networkError
            }
            throw KittyError.serverError(0)
        }
    }

    // MARK: - Chat

    func chatStream(_ message: String, history: [[String: String]], onChunk: @escaping (String) -> Void) async throws {
        let request: [String: Any] = ["message": message, "history": history]

        guard let url = URL(string: "\(serverURL)/chat") else {
            throw KittyError.invalidURL("\(serverURL)/chat")
        }

        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.timeoutInterval = 120  // 流式对话可能较长
        urlRequest.httpBody = try JSONSerialization.data(withJSONObject: request)

        do {
            let (bytes, response) = try await session.bytes(for: urlRequest)

            guard let httpResponse = response as? HTTPURLResponse else {
                throw KittyError.invalidResponse
            }

            switch httpResponse.statusCode {
            case 200:
                break
            case 401, 403:
                throw KittyError.unauthorized
            case 500...599:
                throw KittyError.serverError(httpResponse.statusCode)
            default:
                throw KittyError.httpError(httpResponse.statusCode)
            }

            for try await line in bytes.lines {
                if line.hasPrefix("data: ") {
                    let dataStr = String(line.dropFirst(6))
                    if dataStr == "[DONE]" {
                        break
                    }
                    if let data = dataStr.data(using: .utf8),
                       let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                       let choices = json["choices"] as? [[String: Any]],
                       let delta = choices.first?["delta"] as? [String: Any],
                       let content = delta["content"] as? String {
                        onChunk(content)
                    }
                } else if !line.isEmpty {
                    // 兼容非 SSE 格式的响应
                    onChunk(line)
                }
            }
        } catch let error as KittyError {
            throw error
        } catch {
            if (error as NSError).code == NSURLErrorTimedOut {
                throw KittyError.timeout
            } else if (error as NSError).code == NSURLErrorNotConnectedToInternet ||
                      (error as NSError).code == NSURLErrorNetworkConnectionLost {
                throw KittyError.networkError
            }
            throw KittyError.serverError(0)
        }
    }

    // MARK: - TTS

    func synthesizeSpeech(_ text: String, voice: String? = nil) async throws -> Data {
        let selectedVoice = UserDefaults.standard.string(forKey: "selectedVoice") ?? "zh_female_vv_uranus_bigtts"
        let request: [String: Any] = ["text": text, "voice": voice ?? selectedVoice]

        guard let url = URL(string: "\(serverURL)/tts") else {
            throw KittyError.invalidURL("\(serverURL)/tts")
        }

        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.timeoutInterval = 30
        urlRequest.httpBody = try JSONSerialization.data(withJSONObject: request)

        do {
            let (data, response) = try await session.data(for: urlRequest)

            guard let httpResponse = response as? HTTPURLResponse else {
                throw KittyError.invalidResponse
            }

            switch httpResponse.statusCode {
            case 200:
                // 检查返回的数据是否有效
                if data.isEmpty {
                    throw KittyError.ttsFailed("返回音频数据为空")
                }
                return data
            case 401, 403:
                throw KittyError.unauthorized
            case 500...599:
                // 尝试解析错误信息
                if let errorJson = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let errorMsg = errorJson["detail"] as? String {
                    throw KittyError.ttsFailed(errorMsg)
                }
                throw KittyError.serverError(httpResponse.statusCode)
            default:
                throw KittyError.httpError(httpResponse.statusCode)
            }
        } catch let error as KittyError {
            throw error
        } catch {
            if (error as NSError).code == NSURLErrorTimedOut {
                throw KittyError.timeout
            } else if (error as NSError).code == NSURLErrorNotConnectedToInternet ||
                      (error as NSError).code == NSURLErrorNetworkConnectionLost {
                throw KittyError.networkError
            }
            throw KittyError.serverError(0)
        }
    }

    func playAudio(_ data: Data) throws {
        DispatchQueue.main.async {
            do {
                // 配置音频会话
                try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
                try AVAudioSession.sharedInstance().setActive(true)

                self.audioPlayer = try AVAudioPlayer(data: data)
                self.audioPlayer?.prepareToPlay()
                let success = self.audioPlayer?.play() ?? false
                print("🔊 播放音频: \(success ? "成功" : "失败"), 数据量: \(data.count) bytes")
            } catch {
                print("❌ 播放音频失败: \(error)")
            }
        }
    }

    func stopSpeaking() {
        audioPlayer?.stop()
        audioPlayer = nil
    }

    // MARK: - Server Test

    func testConnection() async -> Bool {
        guard let url = URL(string: "\(serverURL)/") else {
            return false
        }

        do {
            let (_, response) = try await session.data(from: url)
            if let httpResponse = response as? HTTPURLResponse {
                return httpResponse.statusCode == 200
            }
            return false
        } catch {
            return false
        }
    }
}

// MARK: - Error Types

enum KittyError: Error, LocalizedError {
    case invalidURL(String)
    case invalidResponse
    case serverError(Int)
    case httpError(Int)
    case timeout
    case networkError
    case unauthorized
    case recordingFailed
    case ttsFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidURL(let url):
            return "无效的服务器地址: \(url)"
        case .invalidResponse:
            return "服务器响应格式错误"
        case .serverError(let code):
            return "服务器错误 (状态码: \(code))"
        case .httpError(let code):
            return "请求失败 (状态码: \(code))"
        case .timeout:
            return "请求超时，请检查网络连接"
        case .networkError:
            return "网络连接失败，请检查网络设置"
        case .unauthorized:
            return "认证失败，请检查 API Token"
        case .recordingFailed:
            return "录音失败，请检查麦克风权限"
        case .ttsFailed(let message):
            return "语音合成失败: \(message)"
        }
    }
}