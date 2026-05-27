#!/usr/bin/env python3
"""
测试聊天功能的完整流程
"""
import asyncio
import json
import httpx

async def test_chat_stream():
    """测试流式聊天响应"""
    print("=" * 50)
    print("测试聊天流式响应")
    print("=" * 50)

    url = "http://localhost:8081/chat"
    payload = {
        "message": "你好，请简单介绍一下你自己",
        "history": [],
        "model": "bailian/qwen3.6-plus"
    }

    print(f"\n📤 发送请求: {payload['message']}")

    async with httpx.AsyncClient(timeout=30) as client:
        async with client.stream(
            "POST",
            url,
            headers={"Content-Type": "application/json"},
            json=payload,
        ) as response:
            print(f"\n✅ 响应状态码: {response.status_code}")
            print(f"📋 响应类型: {response.headers.get('content-type')}")
            print(f"\n📝 流式内容:\n")

            full_response = ""
            chunk_count = 0

            async for line in response.aiter_lines():
                if line.startswith("data: "):
                    data = line[6:]
                    if data == "[DONE]":
                        print("\n✅ 收到结束标志")
                        break

                    try:
                        chunk = json.loads(data)
                        if choices := chunk.get("choices"):
                            if delta := choices[0].get("delta"):
                                if content := delta.get("content"):
                                    full_response += content
                                    chunk_count += 1
                                    print(f"[{chunk_count}] {content}", end="", flush=True)
                    except Exception as e:
                        print(f"\n❌ 解析错误: {e}")

            print(f"\n\n📊 统计信息:")
            print(f"   - 总块数: {chunk_count}")
            print(f"   - 完整回复长度: {len(full_response)} 字符")
            print(f"\n💬 完整回复:\n{full_response}")

async def test_server_health():
    """测试服务器健康状态"""
    print("\n" + "=" * 50)
    print("测试服务器健康状态")
    print("=" * 50)

    url = "http://localhost:8081/"

    async with httpx.AsyncClient(timeout=5) as client:
        try:
            response = await client.get(url)
            print(f"\n✅ 服务器状态: {response.status_code}")
            print(f"📋 服务器信息: {response.json()}")
        except Exception as e:
            print(f"\n❌ 服务器连接失败: {e}")

async def main():
    """运行所有测试"""
    await test_server_health()
    await test_chat_stream()
    print("\n" + "=" * 50)
    print("✅ 所有测试完成")
    print("=" * 50)

if __name__ == "__main__":
    asyncio.run(main())