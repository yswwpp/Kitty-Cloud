"""
Kitty Server API 回归测试脚本

测试顺序：
1. 服务健康检查
2. 模型列表查询
3. 默认模型对话
4. 指定模型对话（验证模型切换）
5. 查看会话历史
6. 清空会话
7. TTS 语音合成
8. ASR 语音识别（可选，需要测试音频）

用法：
    pytest test_api.py -v                    # 运行所有测试
    pytest test_api.py -v -k "chat"          # 只运行 chat 相关测试
    pytest test_api.py -v --tb=short         # 简短错误输出

环境变量：
    SERVER_URL: 服务端地址，默认 http://localhost:8081
"""

import os
import pytest
import httpx
import json
import base64
import struct


# 配置
SERVER_URL = os.getenv("SERVER_URL", "http://localhost:8081")
TIMEOUT = 30


class TestServerHealth:
    """服务健康检查"""

    def test_root_endpoint(self):
        """GET / - 服务是否正常运行"""
        with httpx.Client(timeout=TIMEOUT) as client:
            resp = client.get(f"{SERVER_URL}/")

        assert resp.status_code == 200
        data = resp.json()
        assert data["name"] == "Kitty Server"
        assert data["status"] == "running"
        print(f"✅ 服务运行正常: {data['version']}")


class TestModels:
    """模型管理"""

    def test_list_models(self):
        """GET /models - 查询可用模型列表"""
        with httpx.Client(timeout=TIMEOUT) as client:
            resp = client.get(f"{SERVER_URL}/models")

        assert resp.status_code == 200
        data = resp.json()
        assert data["object"] == "list"
        assert "data" in data
        assert len(data["data"]) > 0

        models = [m["id"] for m in data["data"]]
        print(f"✅ 可用模型: {models}")


class TestChat:
    """对话接口"""

    session_id = "test_session"

    def test_chat_default_model(self):
        """POST /chat - 使用默认模型对话"""
        with httpx.Client(timeout=60) as client:
            resp = client.post(
                f"{SERVER_URL}/chat",
                json={
                    "message": "你是什么模型？一句话回答",
                    "history": [],
                    "session_id": self.session_id,
                },
            )

        assert resp.status_code == 200
        # 流式响应，读取完整内容
        content = resp.text
        assert len(content) > 0
        print(f"✅ 默认模型回复: {content[:100]}")

    def test_chat_specific_model(self):
        """POST /chat - 使用指定模型对话（验证模型切换）"""
        # 先获取模型列表
        with httpx.Client(timeout=TIMEOUT) as client:
            models_resp = client.get(f"{SERVER_URL}/models")
            models = models_resp.json()["data"]

        # 选择一个非默认模型
        default_model = "openclaw/main"
        other_model = None
        for m in models:
            if m["id"] != default_model:
                other_model = m["id"]
                break

        if not other_model:
            pytest.skip("只有一个模型，无法测试切换")

        # 用另一个模型对话
        with httpx.Client(timeout=60) as client:
            resp = client.post(
                f"{SERVER_URL}/chat",
                json={
                    "message": "你是什么模型？一句话回答",
                    "history": [],
                    "session_id": f"{self.session_id}_switch",
                    "model": other_model,
                },
            )

        assert resp.status_code == 200
        content = resp.text
        print(f"✅ 切换模型 {other_model} 回复: {content[:100]}")


class TestSession:
    """会话管理"""

    session_id = "test_session_mgmt"

    def setup_method(self):
        """每个测试前先创建一个会话"""
        with httpx.Client(timeout=60) as client:
            client.post(
                f"{SERVER_URL}/chat",
                json={
                    "message": "测试消息",
                    "history": [],
                    "session_id": self.session_id,
                },
            )

    def test_get_session(self):
        """GET /session/{id} - 查看会话历史"""
        with httpx.Client(timeout=TIMEOUT) as client:
            resp = client.get(f"{SERVER_URL}/session/{self.session_id}")

        assert resp.status_code == 200
        data = resp.json()
        assert data["exists"] == True
        assert "messages" in data
        print(f"✅ 会话 {self.session_id} 有 {len(data['messages'])} 条消息")

    def test_clear_session(self):
        """DELETE /session/{id} - 清空会话"""
        # 清空
        with httpx.Client(timeout=TIMEOUT) as client:
            resp = client.delete(f"{SERVER_URL}/session/{self.session_id}")

        assert resp.status_code == 200
        data = resp.json()
        assert data["status"] == "cleared"
        print(f"✅ 会话 {self.session_id} 已清空")

        # 验证已清空
        with httpx.Client(timeout=TIMEOUT) as client:
            resp = client.get(f"{SERVER_URL}/session/{self.session_id}")

        data = resp.json()
        assert data["exists"] == False
        assert len(data["messages"]) == 0
        print(f"✅ 验证会话已不存在")


class TestTTS:
    """语音合成"""

    def test_tts(self):
        """POST /tts - 文本转语音"""
        with httpx.Client(timeout=TIMEOUT) as client:
            resp = client.post(
                f"{SERVER_URL}/tts",
                json={
                    "text": "测试语音合成",
                    "voice": "BV001_streaming",
                },
            )

        if resp.status_code == 500:
            # 可能缺少火山引擎凭证
            error_detail = resp.json().get("detail", "Unknown error")
            pytest.skip(f"TTS 服务不可用: {error_detail}")

        assert resp.status_code == 200
        audio_data = resp.content
        assert len(audio_data) > 0
        print(f"✅ TTS 返回音频 {len(audio_data)} bytes")


class TestASR:
    """语音识别（可选）"""

    @pytest.mark.skipif(
        not os.path.exists("test_audio.wav"),
        reason="缺少测试音频文件 test_audio.wav",
    )
    def test_asr(self):
        """POST /asr - 语音转文本"""
        # 读取测试音频
        with open("test_audio.wav", "rb") as f:
            audio_data = f.read()

        base64_audio = base64.b64encode(audio_data).decode()

        with httpx.Client(timeout=TIMEOUT) as client:
            resp = client.post(
                f"{SERVER_URL}/asr",
                json={
                    "audio": base64_audio,
                    "format": "wav",
                },
            )

        assert resp.status_code == 200
        data = resp.json()
        assert "text" in data
        print(f"✅ ASR 识别结果: {data['text']}")


def create_test_audio():
    """创建简单的测试音频文件（16kHz 单声道 WAV）"""
    sample_rate = 16000
    duration = 1  # 1秒
    samples = sample_rate * duration

    # 生成简单的正弦波
    import math

    audio_samples = []
    for i in range(samples):
        value = int(32767 * math.sin(2 * math.pi * 440 * i / sample_rate))
        audio_samples.append(value)

    # 构建 WAV 文件
    wav_header = struct.pack(
        "<4sI4sIHHIIHH4sI",
        b"RIFF",
        36 + samples * 2,
        b"WAVE",
        b"fmt ",
        16,
        1,
        1,
        sample_rate,
        sample_rate * 2,
        2,
        16,
        b"data",
        samples * 2,
    )

    audio_bytes = b"".join(struct.pack("<h", s) for s in audio_samples)

    with open("test_audio.wav", "wb") as f:
        f.write(wav_header + audio_bytes)

    print("✅ 创建测试音频: test_audio.wav")


if __name__ == "__main__":
    # 直接运行脚本
    import sys

    print("=== Kitty Server API 回归测试 ===")
    print(f"服务地址: {SERVER_URL}")
    print()

    # 创建测试音频（可选）
    if not os.path.exists("test_audio.wav"):
        print("⚠️  缺少测试音频，ASR 测试将被跳过")
        print("   可运行: python test_api.py --create-audio")
        print()

    if "--create-audio" in sys.argv:
        create_test_audio()
        sys.exit(0)

    # 运行 pytest
    exit_code = pytest.main([__file__, "-v", "--tb=short"])
    sys.exit(exit_code)