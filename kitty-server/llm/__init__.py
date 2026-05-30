"""LLM 模块：多 Provider 网关 + Cache 友好的消息拼接"""
from .gateway import LLMGateway, get_gateway
from .cache import build_cache_stable_messages, trim_history, CacheMetrics

__all__ = [
    "LLMGateway",
    "get_gateway",
    "build_cache_stable_messages",
    "trim_history",
    "CacheMetrics",
]
