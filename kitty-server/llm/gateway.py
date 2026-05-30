"""统一的 LLM 调用网关。

设计原则：
- 用 httpx 直连 Provider，少一跳网络
- 解析 models.json，根据 model_id (`<provider>/<model>`) 路由
- 同时支持流式 SSE 和非流式
- 暴露 usage / cache 命中字段，便于上层统计
- 不引入 LiteLLM、ChatOpenAI 等额外抽象层

目前实现的 API 类型：
- openai-completions（DeepSeek 官方、百炼 OpenAI 模式、LiteLLM）

anthropic-messages 暂未实现（V1 不需要，遗留 TODO）。
"""

from __future__ import annotations

import json
import os
from dataclasses import dataclass, field
from typing import Any, AsyncIterator, Dict, List, Optional, Tuple

import httpx

from .cache import CacheMetrics, parse_usage, record_metrics


# ──────────────────────────────────────────────────────────────────────────
# Provider 配置加载
# ──────────────────────────────────────────────────────────────────────────


@dataclass
class ProviderConfig:
    name: str
    base_url: str
    api: str               # "openai-completions" / "anthropic-messages"
    api_key: str
    models: List[str] = field(default_factory=list)


def _load_providers(models_json_path: str) -> Dict[str, ProviderConfig]:
    """读取 models.json，构造 ProviderConfig。"""
    with open(models_json_path, "r", encoding="utf-8") as f:
        cfg = json.load(f)

    providers: Dict[str, ProviderConfig] = {}
    for name, info in cfg.get("providers", {}).items():
        api_key_env = info.get("apiKeyEnv")
        api_key = os.getenv(api_key_env, "") if api_key_env else info.get("apiKey", "")
        providers[name] = ProviderConfig(
            name=name,
            base_url=info.get("baseUrl", "").rstrip("/"),
            api=info.get("api", "openai-completions"),
            api_key=api_key,
            models=[m["id"] for m in info.get("models", [])],
        )
    return providers


# ──────────────────────────────────────────────────────────────────────────
# Gateway
# ──────────────────────────────────────────────────────────────────────────


class LLMGateway:
    """多 Provider LLM 调用网关。"""

    def __init__(self, models_json_path: str, default_model: Optional[str] = None):
        self.models_json_path = models_json_path
        self.providers = _load_providers(models_json_path)
        # 不再硬编码默认模型；未配置就保持 None，调用时若也没传 model 就报错
        self.default_model = default_model or os.getenv("DEFAULT_MODEL") or None

    # ── 解析 model_id ───────────────────────────────────────────────
    def _resolve(self, model: Optional[str]) -> Tuple[ProviderConfig, str]:
        """返回 (provider_config, real_model_id)。"""
        model_id = model or self.default_model
        if not model_id:
            raise ValueError(
                "未指定 model，且未配置 DEFAULT_MODEL 环境变量；"
                "请在请求中传 model 或在 .env 中设置 DEFAULT_MODEL"
            )
        if "/" not in model_id:
            raise ValueError(f"model 必须形如 'provider/model'，收到: {model_id!r}")
        provider_name, real_model = model_id.split("/", 1)
        if provider_name not in self.providers:
            raise ValueError(
                f"未知 provider: {provider_name}，可用: {list(self.providers)}"
            )
        return self.providers[provider_name], real_model

    # ── 非流式 ──────────────────────────────────────────────────────
    async def chat_sync(
        self,
        messages: List[Dict[str, Any]],
        model: Optional[str] = None,
        tools: Optional[List[Dict[str, Any]]] = None,
        temperature: Optional[float] = None,
        max_tokens: Optional[int] = None,
        timeout: float = 120.0,
    ) -> Dict[str, Any]:
        provider, real_model = self._resolve(model)
        if provider.api != "openai-completions":
            raise NotImplementedError(
                f"暂只支持 openai-completions，当前 provider={provider.name} api={provider.api}"
            )

        url = f"{provider.base_url}/chat/completions"
        if provider.base_url.endswith("/v1"):
            url = f"{provider.base_url}/chat/completions"
        elif "/v1/" not in provider.base_url and not provider.base_url.endswith("/v1"):
            url = f"{provider.base_url}/v1/chat/completions"

        payload: Dict[str, Any] = {
            "model": real_model,
            "messages": messages,
            "stream": False,
        }
        if tools:
            payload["tools"] = tools
        if temperature is not None:
            payload["temperature"] = temperature
        if max_tokens is not None:
            payload["max_tokens"] = max_tokens

        headers = {
            "Content-Type": "application/json",
            "Authorization": f"Bearer {provider.api_key}",
        }

        async with httpx.AsyncClient(timeout=timeout) as client:
            resp = await client.post(url, headers=headers, json=payload)
            if resp.status_code >= 400:
                raise RuntimeError(
                    f"LLM API error {resp.status_code}: {resp.text[:500]}"
                )
            data = resp.json()

        # 记录 cache 命中
        metrics = parse_usage(data.get("usage", {}))
        record_metrics(metrics)
        _log_metrics(provider.name, real_model, metrics)

        # 统一返回结构
        content = ""
        if "choices" in data and data["choices"]:
            content = data["choices"][0].get("message", {}).get("content", "") or ""
        return {
            "role": "assistant",
            "content": content,
            "raw": data,
            "metrics": metrics.to_dict(),
        }

    # ── 流式 ────────────────────────────────────────────────────────
    async def chat_stream(
        self,
        messages: List[Dict[str, Any]],
        model: Optional[str] = None,
        tools: Optional[List[Dict[str, Any]]] = None,
        temperature: Optional[float] = None,
        max_tokens: Optional[int] = None,
        timeout: float = 120.0,
    ) -> AsyncIterator[Dict[str, Any]]:
        """返回 OpenAI 风格的 chunk 迭代器。

        每个 yield 是一个 dict：
            {"type": "delta", "content": "..."}
            {"type": "done", "metrics": {...}}
            {"type": "error", "message": "..."}
        """
        provider, real_model = self._resolve(model)
        if provider.api != "openai-completions":
            yield {"type": "error", "message": f"不支持的 provider api: {provider.api}"}
            return

        if provider.base_url.endswith("/v1"):
            url = f"{provider.base_url}/chat/completions"
        elif "/v1/" not in provider.base_url and not provider.base_url.endswith("/v1"):
            url = f"{provider.base_url}/v1/chat/completions"
        else:
            url = f"{provider.base_url}/chat/completions"

        payload: Dict[str, Any] = {
            "model": real_model,
            "messages": messages,
            "stream": True,
            # DeepSeek 支持在流式响应中返回 usage（最后一帧）
            "stream_options": {"include_usage": True},
        }
        if tools:
            payload["tools"] = tools
        if temperature is not None:
            payload["temperature"] = temperature
        if max_tokens is not None:
            payload["max_tokens"] = max_tokens

        headers = {
            "Content-Type": "application/json",
            "Authorization": f"Bearer {provider.api_key}",
            "Accept": "text/event-stream",
        }

        usage_seen: Optional[Dict[str, Any]] = None

        try:
            async with httpx.AsyncClient(timeout=timeout) as client:
                async with client.stream(
                    "POST", url, headers=headers, json=payload
                ) as resp:
                    if resp.status_code >= 400:
                        body = await resp.aread()
                        yield {
                            "type": "error",
                            "message": f"LLM API error {resp.status_code}: {body.decode('utf-8', 'replace')[:500]}",
                        }
                        return

                    async for line in resp.aiter_lines():
                        if not line:
                            continue
                        if line.startswith("data: "):
                            data_str = line[6:]
                        elif line.startswith("data:"):
                            data_str = line[5:]
                        else:
                            continue
                        data_str = data_str.strip()
                        if data_str == "[DONE]":
                            break
                        try:
                            chunk = json.loads(data_str)
                        except json.JSONDecodeError:
                            continue

                        # 部分 Provider 在流尾单独发一个含 usage 的 chunk（choices 为空）
                        if chunk.get("usage"):
                            usage_seen = chunk["usage"]

                        choices = chunk.get("choices") or []
                        if not choices:
                            continue

                        delta = choices[0].get("delta") or {}
                        content_piece = delta.get("content")
                        if content_piece:
                            yield {"type": "delta", "content": content_piece}

                        # tool_calls 流式 piece（V1 不消费，预留）
                        if delta.get("tool_calls"):
                            yield {
                                "type": "tool_call_delta",
                                "data": delta["tool_calls"],
                            }
        except httpx.HTTPError as e:
            yield {"type": "error", "message": f"网络错误: {e!r}"}
            return

        metrics = parse_usage(usage_seen or {})
        record_metrics(metrics)
        _log_metrics(provider.name, real_model, metrics)
        yield {"type": "done", "metrics": metrics.to_dict()}


# ──────────────────────────────────────────────────────────────────────────
# 日志
# ──────────────────────────────────────────────────────────────────────────


def _log_metrics(provider: str, model: str, m: CacheMetrics) -> None:
    print(
        f"[LLM] {provider}/{model} usage: "
        f"prompt={m.prompt_tokens} completion={m.completion_tokens} "
        f"cache_hit={m.prompt_cache_hit_tokens} cache_miss={m.prompt_cache_miss_tokens} "
        f"hit_rate={m.hit_rate:.2%}"
    )


# ──────────────────────────────────────────────────────────────────────────
# 单例
# ──────────────────────────────────────────────────────────────────────────


_GATEWAY: Optional[LLMGateway] = None


def get_gateway(models_json_path: Optional[str] = None) -> LLMGateway:
    global _GATEWAY
    if _GATEWAY is None:
        if models_json_path is None:
            models_json_path = os.path.join(
                os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
                "models.json",
            )
        _GATEWAY = LLMGateway(models_json_path)
    return _GATEWAY
