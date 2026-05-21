import asyncio
import json
import uuid
import gzip
import struct
import base64
import os
import time
import httpx
from fastapi import FastAPI, HTTPException, UploadFile, File, Form
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

# 对话系统提示词（语音和文字聊天共用）
VOICE_SYSTEM_PROMPT = """你是一个温馨的助手 Kitty，正在和用户聊天。

## 对话风格

- 像跟好朋友聊天一样，轻松自然
- 用口语化表达，不要用书面语
- 回复简洁，不要长篇大论
- 适当加入自然的过渡词，如"嗯…"、"让我想想…"、"这个问题嘛…"

## 格式要求（非常重要，必须严格遵守）

- 禁止使用任何 Markdown 格式：不要用 **、*、#、-、`、>、| 等符号
- 禁止使用列表：不要用编号列表或项目符号
- 禁止使用 emoji 表情符号
- 纯文本输出：只输出纯文字，不要加任何格式标记

## 示例

用户："今天天气怎么样？"
你："嗯…让我想想。今天天气挺不错的，阳光明媚，适合出去走走。"

用户："帮我查下航班"
你："好的，我来帮你查一下。请问是哪个城市的航班？"

## 禁止事项

- 不要用复杂的句式和专业术语
- 不要像客服机器人一样说"为您服务"
- 不要用 emoji 表情
- 不要用 Markdown（粗体、斜体、列表、标题等）
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
    model: Optional[str] = None
    stream: Optional[bool] = True


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

    # 构建通用请求头
    openclaw_headers = {
        "Content-Type": "application/json",
        "Authorization": f"Bearer {OPENCLAW_TOKEN}",
    }
    if req.model:
        openclaw_headers["x-openclaw-model"] = req.model

    # 根据stream参数选择响应模式
    if req.stream == False:
        full_response = ""
        async with httpx.AsyncClient(timeout=120) as client:
            response = await client.post(
                f"{OPENCLAW_URL}/v1/chat/completions",
                headers=openclaw_headers,
                json={
                    "model": "openclaw/main",
                    "messages": messages,
                    "stream": False,
                    "session_id": "main",
                },
                timeout=120,
            )
            result = response.json()
            # 如果模型切换失败，去掉 x-openclaw-model 重试
            if "error" in result and req.model:
                print(f"[chat] 模型 {req.model} 失败: {result['error']}, 使用默认模型重试")
                retry_headers = {k: v for k, v in openclaw_headers.items() if k != "x-openclaw-model"}
                response = await client.post(
                    f"{OPENCLAW_URL}/v1/chat/completions",
                    headers=retry_headers,
                    json={
                        "model": "openclaw/main",
                        "messages": messages,
                        "stream": False,
                        "session_id": "main",
                    },
                    timeout=120,
                )
                result = response.json()
            print(f"[chat] OpenClaw 非流式响应: {result}")
            if "choices" in result and len(result["choices"]) > 0:
                full_response = result["choices"][0]["message"].get("content", "")
            elif "error" in result:
                print(f"[chat] OpenClaw 错误: {result['error']}")

        session["messages"].append({"role": "assistant", "content": full_response})
        session["messages"] = session["messages"][-MAX_HISTORY_LENGTH:]
        return {"role": "assistant", "content": full_response}

    # 流式模式：返回SSE流
    async def generate():
        full_response = ""
        async with httpx.AsyncClient(timeout=120) as client:
            async with client.stream(
                "POST",
                f"{OPENCLAW_URL}/v1/chat/completions",
                headers=openclaw_headers,
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
                            yield "data: [DONE]\n\n"
                            break
                        try:
                            chunk = json.loads(data)
                            if "error" in chunk:
                                print(f"[chat] 流式错误: {chunk['error']}")
                                break
                            if content := chunk["choices"][0]["delta"].get("content"):
                                full_response += content
                                yield f"data: {json.dumps({'choices': [{'delta': {'content': content}}]})}\n\n"
                        except:
                            pass

        session["messages"].append({"role": "assistant", "content": full_response})
        session["messages"] = session["messages"][-MAX_HISTORY_LENGTH:]

    return StreamingResponse(generate(), media_type="text/event-stream")


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


# 模型列表缓存
_models_cache: dict = {"data": [], "cached_at": 0}
_MODELS_CACHE_TTL = 300  # 缓存 5 分钟


def load_models_from_config() -> list:
    """从本地 models.json 读取模型列表"""
    config_path = os.path.join(os.path.dirname(__file__), "models.json")
    try:
        with open(config_path, "r") as f:
            config = json.load(f)
        result = []
        for provider_name, provider_info in config.get("providers", {}).items():
            for m in provider_info.get("models", []):
                result.append({
                    "id": f"{provider_name}/{m['id']}",
                    "object": "model",
                    "created": 0,
                    "owned_by": provider_name,
                    "display_name": m.get("name", m["id"]),
                    "description": f"支持 {', '.join(m.get('input', ['text']))}",
                    "context_window": m.get("contextWindow"),
                    "max_tokens": m.get("maxTokens"),
                })
        return result
    except Exception as e:
        print(f"[models] 读取 models.json 失败: {e}")
        return []


# 硬编码模型列表（models.json 不存在时回退）
_FALLBACK_MODELS = [
    {"id": "bailian/qwen3.6-plus", "object": "model", "created": 0, "owned_by": "bailian", "display_name": "Qwen3.6 Plus", "context_window": 131072},
    {"id": "bailian/glm-5", "object": "model", "created": 0, "owned_by": "bailian", "display_name": "GLM-5", "context_window": 131072},
]


@app.get("/models")
async def list_models():
    """返回可用模型列表，从本地 models.json 读取，带缓存"""
    if _models_cache["data"] and (time.time() - _models_cache["cached_at"]) < _MODELS_CACHE_TTL:
        return {"object": "list", "data": _models_cache["data"]}
    models = load_models_from_config()
    if not models:
        return {"object": "list", "data": _FALLBACK_MODELS}
    _models_cache["data"] = models
    _models_cache["cached_at"] = time.time()
    return {"object": "list", "data": models}


MAX_PDF_CHARS = 8000  # PDF 文本截断长度，避免超上下文


def extract_pdf_text(file_bytes: bytes, filename: str = "unknown.pdf") -> str:
    """提取 PDF 文本，截断到 MAX_PDF_CHARS"""
    import pdfplumber
    import io

    text_parts = []
    with pdfplumber.open(io.BytesIO(file_bytes)) as pdf:
        for i, page in enumerate(pdf.pages):
            page_text = page.extract_text() or ""
            if page_text:
                text_parts.append(f"[第{i+1}页]\n{page_text}")

    full_text = "\n\n".join(text_parts)
    if len(full_text) > MAX_PDF_CHARS:
        full_text = full_text[:MAX_PDF_CHARS] + f"\n\n...(已截断，原文共{len(full_text)}字符)"
    return full_text


@app.post("/chat-with-file")
async def chat_with_file(
    message: str = Form(""),
    file: UploadFile = File(...),
    session_id: Optional[str] = Form("default"),
    model: Optional[str] = Form(None),
):
    """接收 PDF 文件 + 消息，提取文本后发给 OpenClaw"""
    # 1. 读取并验证文件
    file_bytes = await file.read()
    filename = file.filename or "unknown.pdf"
    print(f"[chat-with-file] 收到文件: {filename}, 大小: {len(file_bytes)} bytes")

    if not filename.lower().endswith(".pdf"):
        raise HTTPException(status_code=400, detail="仅支持 PDF 文件")

    # 2. 提取 PDF 文本
    try:
        pdf_text = extract_pdf_text(file_bytes, filename)
    except Exception as e:
        print(f"[chat-with-file] PDF 提取失败: {e}")
        raise HTTPException(status_code=400, detail=f"PDF 解析失败: {str(e)}")

    if not pdf_text.strip():
        raise HTTPException(status_code=400, detail="无法从 PDF 中提取文本，可能是扫描版 PDF")

    # 3. 拼接带文件上下文的消息
    user_message = message.strip() or "请解读这个文件"
    contextual_message = (
        f"[用户上传了PDF文件: {filename}]\n\n"
        f"以下是PDF内容：\n---\n{pdf_text}\n---\n\n"
        f"用户消息: {user_message}"
    )

    # 4. 复用 /chat 逻辑
    req = ChatRequest(
        message=contextual_message,
        session_id=session_id,
        history=[],
        model=model,
        stream=False,
    )
    return await chat(req)


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
