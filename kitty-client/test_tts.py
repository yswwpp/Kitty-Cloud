#!/usr/bin/env python3
"""火山引擎 TTS 测试"""

import requests
import json
import base64
import os
import wave

APP_ID = os.getenv("VOLC_TTS_APP_ID")
TOKEN = os.getenv("VOLC_TTS_TOKEN")
VOICE = os.getenv("VOLC_TTS_VOICE", "zh_female_vv_uranus_bigtts")

if not APP_ID or not TOKEN:
    raise SystemExit("请先设置 VOLC_TTS_APP_ID 和 VOLC_TTS_TOKEN 环境变量")

os.environ['NO_PROXY'] = '*'

endpoint = "https://openspeech.bytedance.com/api/v1/tts"

headers = {
    "Content-Type": "application/json",
    "X-Api-App-Key": APP_ID,
    "X-Api-Access-Key": TOKEN,
    "X-Api-Resource-Id": "volcano_tts",
}

payload = {
    "app": {"appid": APP_ID, "token": TOKEN, "cluster": "volcano_tts"},
    "user": {"uid": "test"},
    "audio": {"voice_type": VOICE, "encoding": "pcm", "rate": 16000, "bits": 16, "channel": 1},
    "request": {"reqid": "test-001", "text": "你好，我是Kitty，很高兴认识你。", "operation": "query"}
}

print(f"🔊 TTS 测试")
print(f"   音色: {VOICE}")
print(f"   Cluster: volcano_tts")

resp = requests.post(endpoint, headers=headers, json=payload, timeout=30)
print(f"\n状态码: {resp.status_code}")
print(f"Content-Type: {resp.headers.get('Content-Type')}")

# 检查响应
if 'json' in resp.headers.get('Content-Type', ''):
    data = resp.json()
    print(f"\n响应 JSON:")
    print(json.dumps(data, indent=2, ensure_ascii=False))

    if 'data' in data:
        audio = base64.b64decode(data['data'])
        print(f"\n✅ 音频数据: {len(audio)} bytes")

        output = "/tmp/tts_test.wav"
        with wave.open(output, 'wb') as wf:
            wf.setnchannels(1)
            wf.setsampwidth(2)
            wf.setframerate(16000)
            wf.writeframes(audio)
        print(f"保存: {output}")
        os.system(f"afplay {output}")
elif len(resp.content) > 100:
    print(f"\n二进制响应: {len(resp.content)} bytes")
    # 可能是直接返回的音频
    output = "/tmp/tts_test.pcm"
    with open(output, 'wb') as f:
        f.write(resp.content)
    print(f"保存: {output}")
else:
    print(f"\n响应: {resp.text}")
