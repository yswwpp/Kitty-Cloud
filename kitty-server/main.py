import asyncio
import json
import uuid
import gzip
import struct
import base64
import os
import httpx
from fastapi import FastAPI, HTTPException
from fastapi.responses import StreamingResponse, Response
from fastapi.middleware.cors import CORSMiddleware
from pydantic import BaseModel
from typing import Optional
import websockets

app = FastAPI(title="Kitty Server", version="1.0.0")

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

# 从环境变量读取配置，提供默认值用于开发
OPENCLAW_URL = os.getenv("OPENCLAW_URL", "http://localhost:18789")
OPENCLAW_TOKEN = os.getenv("OPENCLAW_TOKEN", "f894296566d6b5365d2dd6ec9b19ecb70555add6cd73b0c7")

VOLC_ASR_APP_ID = os.getenv("VOLC_ASR_APP_ID", "3214571057")
VOLC_ASR_TOKEN = os.getenv("VOLC_ASR_TOKEN", "RSi0XcS9HHmyVMcvhie9-yDo_tIxRWE0")
VOLC_ASR_RESOURCE_ID = os.getenv("VOLC_ASR_RESOURCE_ID", "volc.seedasr.sauc.duration")
VOLC_TTS_APP_ID = os.getenv("VOLC_TTS_APP_ID", "3214571057")
VOLC_TTS_TOKEN = os.getenv("VOLC_TTS_TOKEN", "RSi0XcS9HHmyVMcvhie9-yDo_tIxRWE0")
VOLC_TTS_CLUSTER = os.getenv("VOLC_TTS_CLUSTER", "volcano_tts")

# 会话管理
MAX_HISTORY_LENGTH = 20
sessions = {}

# 语音对话系统提示词
VOICE_SYSTEM_PROMPT = """你是一个温馨的语音助手 Kitty，正在和用户进行实时语音对话。

## 核心原则

1. **短句优先**：每次回复控制在 2-4 秒内说完，不要长篇大论
2. **可被打断**：用户随时可能插话，你要准备好随时停下来倾听
3. **呼吸感**：在回复中加入自然的停顿和过渡词，如"嗯…"、"让我想想…"、"这个问题嘛…"

## 对话风格

- 像跟好朋友聊天一样，轻松自然
- 不要用书面语，用口语化表达
- 回复简洁，一两个短句即可
- 如果需要详细说明，分段说，每段 2-4 秒

## 格式要求（重要）

- **禁止使用任何 Markdown 格式**：不要用 **、*、#、-、`、>、| 等符号
- **禁止使用列表**：不要用编号列表或项目符号
- **纯文本输出**：只输出纯文字，不要加任何格式标记
- TTS 会把你的文字读出来，所以必须是可以直接朗读的文字

## 示例

用户："今天天气怎么样？"
你："嗯…让我想想。今天天气挺不错的，阳光明媚，适合出去走走。"

用户："帮我查下航班"
你："好的，我来帮你查一下。请问是哪个城市的航班？"

## 禁止事项

- 不要一次性说超过 10 秒的内容
- 不要用复杂的句式和专业术语
- 不要像客服机器人一样说"为您服务"
- 不要用 Markdown（粗体、斜体、列表、标题等）
- 不要用 emoji 表情

记住：你是在跟人聊天，不是在写文章。保持自然、亲切、简洁。"""


class ASRRequest(BaseModel):
    audio: str
    format: str = "wav"


class ChatRequest(BaseModel):
    message: str
    session_id: Optional[str] = "default"
    history: list = []


class TTSRequest(BaseModel):
    text: str
    voice: str = "BV001_streaming"


class ClearSessionRequest(BaseModel):
    session_id: str = "default"


@app.on_event("startup")
async def startup_event():
    print(f"[SERVER] 🚀 Kitty Server 启动中...")
    print(f"[SERVER] 📦 版本: 1.0.1")
    print(f"[SERVER] OpenClaw URL: {OPENCLAW_URL}")


@app.get("/")
async def root():
    print(f"[SERVER] 📨 收到请求: /")
    return {"name": "Kitty Server", "version": "1.0.0", "status": "running"}


@app.post("/asr")
async def speech_to_text(req: ASRRequest):
    audio_data = base64.b64decode(req.audio)
    result = await recognize_speech(audio_data)
    return {"text": result}


@app.post("/chat")
async def chat(req: ChatRequest):
    session_id = req.session_id or "default"

    if session_id not in sessions:
        sessions[session_id] = {
            "messages": [],
            "created_at": asyncio.get_event_loop().time(),
        }

    session = sessions[session_id]

    if req.history:
        session["messages"] = req.history[-MAX_HISTORY_LENGTH:]

    session["messages"].append({"role": "user", "content": req.message})

    # 构建消息列表，包含系统提示词
    messages = [{"role": "system", "content": VOICE_SYSTEM_PROMPT}]
    messages.extend(session["messages"][-MAX_HISTORY_LENGTH:])

    async def generate():
        full_response = ""
        async with httpx.AsyncClient(timeout=120) as client:
            async with client.stream(
                "POST",
                f"{OPENCLAW_URL}/v1/chat/completions",
                headers={
                    "Content-Type": "application/json",
                    "Authorization": f"Bearer {OPENCLAW_TOKEN}",
                    "x-openclaw-scopes": "operator.write,operator.read",
                },
                json={
                    "model": "openclaw/main",
                    "messages": messages,
                    "stream": True,
                    "session_id": "main",
                },
            ) as response:
                async for line in response.aiter_lines():
                    if line.startswith("data: "):
                        data = line[6:]
                        if data == "[DONE]":
                            break
                        try:
                            chunk = json.loads(data)
                            if content := chunk["choices"][0]["delta"].get("content"):
                                full_response += content
                                yield content
                        except:
                            pass

        session["messages"].append({"role": "assistant", "content": full_response})
        session["messages"] = session["messages"][-MAX_HISTORY_LENGTH:]

    return StreamingResponse(generate(), media_type="text/plain")


@app.get("/session/{session_id}")
async def get_session(session_id: str):
    if session_id not in sessions:
        return {"session_id": session_id, "messages": [], "exists": False}

    return {
        "session_id": session_id,
        "messages": sessions[session_id]["messages"],
        "exists": True,
    }


@app.delete("/session/{session_id}")
async def clear_session(session_id: str):
    if session_id in sessions:
        del sessions[session_id]
        return {"status": "cleared", "session_id": session_id}
    return {"status": "not_found", "session_id": session_id}


@app.post("/tts")
async def text_to_speech(req: TTSRequest):
    audio_data = await synthesize_speech(req.text, req.voice)
    return Response(content=audio_data, media_type="audio/mp3")


async def recognize_speech(audio_data: bytes) -> str:
    ws_url = "wss://openspeech.bytedance.com/api/v3/sauc/bigmodel_nostream"
    request_id = str(uuid.uuid4())

    print(f"[ASR] 收到音频数据: {len(audio_data)} bytes")

    headers = {
        "X-Api-App-Key": VOLC_ASR_APP_ID,
        "X-Api-Access-Key": VOLC_ASR_TOKEN,
        "X-Api-Resource-Id": VOLC_ASR_RESOURCE_ID,
        "X-Api-Request-Id": request_id,
    }

    result_text = ""
    # 序列号从1开始（火山引擎要求）
    seq_counter = [1]

    try:
        print(f"[ASR] 正在连接 WebSocket...")
        async with websockets.connect(
            ws_url,
            additional_headers=headers,
            ping_interval=None,
            close_timeout=10,
            open_timeout=10,
        ) as ws:
            print(f"[ASR] WebSocket 连接成功")

            request_json = {
                "user": {"uid": "kitty_user"},
                "audio": {
                    "format": "wav",
                    "codec": "raw",
                    "rate": 16000,
                    "bits": 16,
                    "channel": 1,
                },
                "request": {
                    "model_name": "bigmodel",
                    "show_utterances": True,
                    "enable_itn": True,
                    "enable_punc": True,
                    "enable_ddc": True,
                },
            }

            await ws.send(build_binary_message(request_json, seq_counter))
            print(f"[ASR] 发送配置请求 (seq={seq_counter[0]-1})")

            # 处理音频数据
            if audio_data[:4] != b"RIFF":
                audio_data = create_wav_header(len(audio_data)) + audio_data
                print(f"[ASR] 添加 WAV 头，总大小: {len(audio_data)} bytes")

            # 发送完整音频数据
            await ws.send(build_binary_message(audio_data, seq_counter, is_audio=True))
            print(f"[ASR] 发送音频数据 (seq={seq_counter[0]-1})")

            # 发送结束标志（使用特殊序列号 0xFFFFFFFD = -3）
            finish_msg = bytes([0x11, 0x23, 0x01, 0x01]) + struct.pack(">I", 0xFFFFFFFD) + struct.pack(">I", len(gzip.compress(b""))) + gzip.compress(b"")
            await ws.send(finish_msg)
            print(f"[ASR] 发送结束标志")

            # 接收结果
            message_count = 0
            while True:
                try:
                    message = await asyncio.wait_for(ws.recv(), timeout=20)
                    message_count += 1
                    if isinstance(message, bytes):
                        text, is_final = parse_asr_response(message)
                        if text:
                            result_text = text
                        if is_final:
                            print(f"[ASR] 识别完成")
                            break
                except asyncio.TimeoutError:
                    print(f"[ASR] 接收超时，已收到 {message_count} 条消息")
                    break
                except websockets.exceptions.ConnectionClosed:
                    print(f"[ASR] WebSocket 连接正常关闭")
                    break
                except Exception as e:
                    print(f"[ASR] 接收错误: {type(e).__name__}: {e}")
                    break

    except websockets.exceptions.InvalidStatusCode as e:
        print(f"[ASR] HTTP 错误: {e}")
    except Exception as e:
        print(f"[ASR] 连接错误: {type(e).__name__}: {e}")

    print(f"[ASR] 最终结果: '{result_text}'")
    return result_text


async def synthesize_speech(text: str, voice: str) -> bytes:
    url = "https://openspeech.bytedance.com/api/v1/tts"

    payload = {
        "app": {
            "appid": VOLC_TTS_APP_ID,
            "token": VOLC_TTS_TOKEN,
            "cluster": VOLC_TTS_CLUSTER,
        },
        "user": {"uid": "kitty_user"},
        "audio": {
            "voice_type": voice,
            "encoding": "mp3",
            "rate": 24000,
            "bits": 16,
            "channel": 1,
        },
        "request": {
            "reqid": str(uuid.uuid4()),
            "text": text,
            "operation": "query",
        },
    }

    async with httpx.AsyncClient(timeout=30) as client:
        response = await client.post(
            url,
            json=payload,
            headers={
                "Content-Type": "application/json",
                "Authorization": f"Bearer; {VOLC_TTS_TOKEN}",
            },
        )
        data = response.json()
        print(f"[TTS] Response: {data}")
        if data.get("code") == 3000 and "data" in data:
            return base64.b64decode(data["data"])
        raise HTTPException(status_code=500, detail=data.get("message", "TTS failed"))


def build_binary_message(
    data: bytes | dict,
    seq_counter: list,
    is_audio: bool = False,
    is_finish: bool = False,
) -> bytes:
    if isinstance(data, dict):
        json_data = json.dumps(data).encode()
        compressed = gzip.compress(json_data)
        # 配置消息: protocol_type=0x11, msg_type=0x11, msg_type_specific=0x11, compress=0x00
        header = bytes([0x11, 0x11, 0x11, 0x00])
    else:
        if is_audio and data:
            compressed = gzip.compress(data)
        else:
            compressed = gzip.compress(b"")
        # 音频消息: protocol_type=0x11, msg_type=0x21(音频) 或 0x23(结束), msg_type_specific=0x01, compress=0x01
        msg_type = 0x23 if is_finish else 0x21
        header = bytes([0x11, msg_type, 0x01, 0x01])

    seq = seq_counter[0]
    seq_counter[0] += 1

    return (
        header
        + struct.pack(">I", seq)
        + struct.pack(">I", len(compressed))
        + compressed
    )


def create_wav_header(data_size: int) -> bytes:
    return bytes(
        [
            *b"RIFF",
            *struct.pack("<I", 36 + data_size),
            *b"WAVE",
            *b"fmt ",
            *struct.pack("<I", 16),
            *struct.pack("<H", 1),
            *struct.pack("<H", 1),
            *struct.pack("<I", 16000),
            *struct.pack("<I", 32000),
            *struct.pack("<H", 2),
            *struct.pack("<H", 16),
            *b"data",
            *struct.pack("<I", data_size),
        ]
    )


def parse_asr_response(data: bytes) -> tuple[str, bool]:
    if len(data) < 12:
        print(f"[ASR] 响应数据太短: {len(data)} bytes")
        return "", False
    try:
        # 解析协议头
        protocol_type = data[0]
        msg_type = data[1]
        msg_type_specific = data[2]
        msg_compress = data[3]
        seq = struct.unpack(">I", data[4:8])[0]
        payload_len = struct.unpack(">I", data[8:12])[0]

        print(f"[ASR] 协议头: type={protocol_type:#x}, msg_type={msg_type:#x}, compress={msg_compress:#x}, seq={seq}, payload_len={payload_len}")

        payload = data[12 : 12 + payload_len]

        # 根据压缩标志决定是否解压
        # msg_compress: 0x00 = 未压缩, 0x01 = gzip 压缩
        if msg_compress == 0x00 or payload[:2] == b'{"':
            # 未压缩，直接解析 JSON
            json_str = payload.decode('utf-8')
        else:
            # gzip 压缩
            try:
                decompressed = gzip.decompress(payload)
                json_str = decompressed.decode('utf-8')
            except Exception as e:
                # 如果 gzip 解压失败，尝试直接解析
                print(f"[ASR] gzip 解压失败，尝试直接解析: {e}")
                json_str = payload.decode('utf-8')

        json_data = json.loads(json_str)
        print(f"[ASR] 响应 JSON: {json.dumps(json_data, ensure_ascii=False)[:500]}")

        is_final = json_data.get("is_final", False)

        # 检查是否有错误
        if "code" in json_data and json_data["code"] != 0:
            print(f"[ASR] API 错误: code={json_data.get('code')}, message={json_data.get('message')}")

        if result := json_data.get("result", {}):
            return result.get("text", ""), is_final
    except Exception as e:
        print(f"[ASR] 解析错误: {e}")
        print(f"[ASR] 原始数据前50字节: {data[:min(50, len(data))].hex()}")
    return "", False


if __name__ == "__main__":
    import uvicorn

    uvicorn.run(app, host="0.0.0.0", port=8081)
