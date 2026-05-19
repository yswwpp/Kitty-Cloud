# Kitty Server 测试说明

## 回归测试脚本

测试所有服务端 API 接口，按逻辑顺序执行。

## 运行方式

### 方式1: pytest（推荐）

```bash
cd kitty-server/tests
pytest test_api.py -v
```

### 方式2: 直接运行

```bash
cd kitty-server/tests
python test_api.py
```

### 方式3: 测试远程服务器

```bash
SERVER_URL=http://10.8.0.122:8081 pytest test_api.py -v
```

## 测试顺序

| 测试 | 接口 | 说明 |
|------|------|------|
| test_root_endpoint | GET / | 服务健康检查 |
| test_list_models | GET /models | 查询可用模型 |
| test_chat_default_model | POST /chat | 默认模型对话 |
| test_chat_specific_model | POST /chat | 指定模型对话（验证切换） |
| test_get_session | GET /session/{id} | 查看会话历史 |
| test_clear_session | DELETE /session/{id} | 清空会话 |
| test_tts | POST /tts | 语音合成 |
| test_asr | POST /asr | 语音识别（可选） |

## 测试音频

ASR 测试需要音频文件。可以生成测试音频：

```bash
python test_api.py --create-audio
```

## 只运行部分测试

```bash
# 只测试 chat
pytest test_api.py -v -k "chat"

# 只测试 session
pytest test_api.py -v -k "session"

# 跳过 ASR
pytest test_api.py -v -k "not asr"
```