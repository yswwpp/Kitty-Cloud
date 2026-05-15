# 🐱 Kitty Cloud

个人专属 7×24 小时语音 Agent 系统。

## 架构 v2.1

```
iOS App ─(火山SDK)→ 火山引擎ASR ─(文本)→ 小龙虾API ─→ LLM
    ↑                                           ↓
    └──────────── 火山引擎TTS ←───────────── 回复文本
```

**优势**：
- ✅ 延迟降低 50%+
- ✅ 无需额外后端服务
- ✅ 直接复用小龙虾 HTTP API

## 项目结构

```
Kitty-Cloud/
├── Kitty/
│   ├── App/
│   │   ├── AppDelegate.swift      # SDK 环境初始化
│   │   └── KittyApp.swift         # 应用入口
│   ├── Config/
│   │   └── APIConfig.swift        # 火山引擎/后端配置
│   ├── Services/
│   │   ├── ASRService.swift       # 语音识别服务
│   │   ├── TTSService.swift       # 语音合成服务
│   │   ├── ChatService.swift      # LLM API 调用
│   │   └── ConversationManager.swift
│   ├── Views/
│   │   ├── CallView.swift
│   │   ├── SettingsView.swift
│   │   └── Components/
│   ├── Models/
│   ├── Resources/
│   ├── Podfile
│   └── Kitty.xcodeproj
└── README.md
```

## 快速开始

### 1. 配置火山引擎凭证

编辑 `kitty-client/Kitty/Config/APIConfig.swift`：

```swift
struct VolcConfig {
    static let appId = "YOUR_APP_ID"      // 火山引擎 App ID
    static let token = "YOUR_TOKEN"       // 火山引擎 Token
}

struct ServerConfig {
    static let apiURL = "http://localhost:3000"  // 小龙虾地址
}
```

### 2. 安装依赖

```bash
cd kitty-client
pod install
```

### 3. 打开并运行

```bash
open kitty-client/Kitty.xcworkspace
```

在 Xcode 中：
1. 选择你的开发团队（签名）
2. 连接 iPhone
3. 点击运行

## SDK 版本

| SDK | Pod | 说明 |
|-----|-----|------|
| ASR | `SpeechEngineAsrToB` | 流式语音识别 |
| TTS | `SpeechEngineToB` | 双向流式语音合成 |

## 所需凭证

| 凭证 | 来源 | 配置位置 |
|------|------|---------|
| App ID | 火山引擎控制台 | `VolcConfig.appId` |
| Token | 火山引擎控制台 | `VolcConfig.token` |
| 小龙虾地址 | 本地/云端 | `ServerConfig.apiURL` |

## 参考

- [火山引擎 ASR iOS SDK](https://www.volcengine.com/docs/6561/113643)
- [火山引擎 TTS iOS SDK](https://www.volcengine.com/docs/6561/1739228)
- [SDK Demo 下载](https://www.volcengine.com/docs/6561/120573)
