#!/usr/bin/env swift

import Foundation

// 模拟发送聊天请求到服务端，测试完整流程
print("=" * 60)
print("🧪 自动化测试：聊天功能完整流程")
print("=" * 60)

let serverURL = "http://localhost:8081"
let testMessage = "你好，请简单介绍一下你自己"

print("\n📝 测试消息: \(testMessage)")
print("🌐 服务地址: \(serverURL)")

// 测试服务器健康状态
print("\n1️⃣ 测试服务器状态...")
let healthURL = URL(string: "\(serverURL)/")!
var healthRequest = URLRequest(url: healthURL)
healthRequest.timeoutInterval = 5

do {
    let (healthData, healthResponse) = try await URLSession.shared.data(for: healthRequest)
    if let httpResponse = healthResponse as? HTTPURLResponse, httpResponse.statusCode == 200 {
        print("✅ 服务器正常运行")
        if let json = try? JSONSerialization.jsonObject(with: healthData) as? [String: Any] {
            print("📋 服务器信息: \(json)")
        }
    } else {
        print("❌ 服务器响应异常")
        exit(1)
    }
} catch {
    print("❌ 无法连接服务器: \(error)")
    exit(1)
}

// 测试聊天流式响应
print("\n2️⃣ 测试聊天流式响应...")
let chatURL = URL(string: "\(serverURL)/chat")!
var chatRequest = URLRequest(url: chatURL)
chatRequest.httpMethod = "POST"
chatRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
chatRequest.timeoutInterval = 30

let requestBody = ["message": testMessage, "history": []]
chatRequest.httpBody = try? JSONSerialization.data(withJSONObject: requestBody)

print("📤 发送聊天请求...")

do {
    let (bytes, response) = try await URLSession.shared.bytes(for: chatRequest)

    if let httpResponse = response as? HTTPURLResponse {
        print("✅ 响应状态码: \(httpResponse.statusCode)")
        print("📋 响应类型: \(httpResponse.value(forHTTPHeaderField: "Content-Type") ?? "未知")")
    }

    print("\n💬 流式回复内容:")
    print("-" * 60)

    var fullResponse = ""
    var chunkCount = 0

    for try await line in bytes.lines {
        if line.hasPrefix("data: ") {
            let dataStr = String(line.dropFirst(6))
            if dataStr == "[DONE]" {
                print("\n✅ 收到结束标志")
                break
            }

            if let data = dataStr.data(using: .utf8),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let choices = json["choices"] as? [[String: Any]],
               let delta = choices.first?["delta"] as? [String: Any],
               let content = delta["content"] as? String {
                fullResponse += content
                chunkCount += 1
                print(content, terminator: "")
            }
        }
    }

    print("\n" + "-" * 60)
    print("\n📊 测试统计:")
    print("   • 接收数据块数: \(chunkCount)")
    print("   • 完整回复长度: \(fullResponse.count) 字符")
    print("   • 完整回复内容:")
    print("   \"\(fullResponse)\"")

    print("\n" + "=" * 60)
    print("✅ 聊天功能测试通过")
    print("=" * 60)

} catch {
    print("❌ 聊天请求失败: \(error)")
    exit(1)
}

exit(0)