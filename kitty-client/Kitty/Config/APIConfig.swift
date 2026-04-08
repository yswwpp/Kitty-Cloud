import Foundation

struct ServerConfig {
    // 模拟器使用 localhost，真机使用 Mac 的局域网 IP
    #if targetEnvironment(simulator)
    static let defaultURL = "http://localhost:8080"
    #else
    static let defaultURL = "http://192.168.31.70:8080"
    #endif
}

enum VoiceType: String, CaseIterable {
    case uranus = "zh_female_vv_uranus_bigtts"
    case gentle = "BV001_streaming"
    case cheerful = "BV002_streaming"
    case calm = "BV700_streaming"
    case fresh = "BV021_streaming"
    case young = "BV003_streaming"

    var displayName: String {
        switch self {
        case .uranus: return "天籁女声"
        case .gentle: return "温柔女声"
        case .cheerful: return "通用男声"
        case .calm: return "知性女声"
        case .fresh: return "清新女声"
        case .young: return "青年男声"
        }
    }
}