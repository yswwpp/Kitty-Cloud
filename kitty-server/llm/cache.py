"""Cache-First 消息拼接策略。

核心目标：让 DeepSeek 官方 API 的自动 Prefix Cache 达到最大命中率。
参考：技术方案 6.4 节、DeepSeek-Reasonix 项目。

三区划分：
- IMMUTABLE PREFIX：system prompt + 工具描述 + 长期记忆（会话内不变）
- APPEND-ONLY LOG：对话历史（只追加，不修改）
- VOLATILE SCRATCH：临时草稿（绝不发送给 LLM API）
"""

from __future__ import annotations

import json
from dataclasses import dataclass, field
from typing import Any, Dict, List, Optional


# 粗略估算 token，1 个汉字 ≈ 1 token，1 个英文单词 ≈ 1.3 token
# 这里只做粗估，避免引入 tiktoken 等重依赖
def estimate_tokens(text_or_messages) -> int:
    if isinstance(text_or_messages, str):
        return max(1, len(text_or_messages))
    if isinstance(text_or_messages, list):
        total = 0
        for msg in text_or_messages:
            if isinstance(msg, dict):
                content = msg.get("content") or ""
                if isinstance(content, list):
                    # multimodal: 简化为字符数
                    content = json.dumps(content, ensure_ascii=False)
                total += len(str(content))
                total += 4  # role / 标记开销
        return total
    return 0


def build_cache_stable_messages(
    system_prompt: str,
    memories: Optional[List[str]] = None,
    history: Optional[List[Dict[str, Any]]] = None,
    current_user_msg: Optional[str] = None,
) -> List[Dict[str, Any]]:
    """构建字节级稳定的消息列表。

    拼接顺序（会话期间不可改变）：
        [system] → [memories...] → [history...] → [current_user_msg]

    - system_prompt：严格固定，不要注入当前时间等可变字段
    - memories：排序后注入，保证顺序稳定
    - history：append-only，调用方负责保证不重排
    - current_user_msg：当轮新增；为 None 时表示 history 末尾已是 user 消息
    """
    messages: List[Dict[str, Any]] = []

    # ── Zone 1: IMMUTABLE PREFIX ──
    if system_prompt:
        messages.append({"role": "system", "content": system_prompt})

    if memories:
        # sorted 保证顺序稳定
        for mem in sorted(memories):
            messages.append({"role": "system", "content": f"[记忆] {mem}"})

    # ── Zone 2: APPEND-ONLY LOG ──
    if history:
        # 不做任何 in-place 修改
        messages.extend(history)

    if current_user_msg is not None:
        messages.append({"role": "user", "content": current_user_msg})

    return messages


def trim_history(history: List[Dict[str, Any]], max_tokens: int) -> List[Dict[str, Any]]:
    """Cache 友好的历史裁剪：从头部丢弃旧消息。

    - 不从尾部截断：尾部是 cache 命中的后缀，丢弃会破坏字节前缀
    - 不做摘要替换：会改变中间字节，导致从替换点往后全部 miss
    - 成对删除最早的 user+assistant 轮次
    """
    trimmed = list(history)
    while estimate_tokens(trimmed) > max_tokens and len(trimmed) > 2:
        trimmed = trimmed[2:]
    return trimmed


@dataclass
class CacheMetrics:
    """单次 LLM 调用的 cache 命中统计。"""
    prompt_cache_hit_tokens: int = 0
    prompt_cache_miss_tokens: int = 0
    prompt_tokens: int = 0
    completion_tokens: int = 0
    total_tokens: int = 0

    @property
    def hit_rate(self) -> float:
        total = self.prompt_cache_hit_tokens + self.prompt_cache_miss_tokens
        if total <= 0:
            # 部分 Provider 不返回 cache 字段，fallback 到 prompt_tokens
            return 0.0
        return self.prompt_cache_hit_tokens / total

    def to_dict(self) -> Dict[str, Any]:
        return {
            "prompt_cache_hit_tokens": self.prompt_cache_hit_tokens,
            "prompt_cache_miss_tokens": self.prompt_cache_miss_tokens,
            "prompt_tokens": self.prompt_tokens,
            "completion_tokens": self.completion_tokens,
            "total_tokens": self.total_tokens,
            "hit_rate": round(self.hit_rate, 4),
        }


@dataclass
class CacheStats:
    """会话级累计统计。"""
    calls: int = 0
    total_hit: int = 0
    total_miss: int = 0

    def add(self, m: CacheMetrics) -> None:
        self.calls += 1
        self.total_hit += m.prompt_cache_hit_tokens
        self.total_miss += m.prompt_cache_miss_tokens

    @property
    def hit_rate(self) -> float:
        total = self.total_hit + self.total_miss
        return self.total_hit / total if total > 0 else 0.0


# 进程级简易统计（多会话共享）
_GLOBAL_STATS = CacheStats()


def record_metrics(m: CacheMetrics) -> None:
    _GLOBAL_STATS.add(m)


def global_stats() -> CacheStats:
    return _GLOBAL_STATS


def parse_usage(usage: Dict[str, Any]) -> CacheMetrics:
    """从 LLM 响应的 usage 字段解析 cache 命中。

    DeepSeek 字段：
        prompt_cache_hit_tokens, prompt_cache_miss_tokens
    OpenAI 通用字段：
        prompt_tokens, completion_tokens, total_tokens
    """
    if not isinstance(usage, dict):
        return CacheMetrics()
    return CacheMetrics(
        prompt_cache_hit_tokens=int(usage.get("prompt_cache_hit_tokens", 0) or 0),
        prompt_cache_miss_tokens=int(usage.get("prompt_cache_miss_tokens", 0) or 0),
        prompt_tokens=int(usage.get("prompt_tokens", 0) or 0),
        completion_tokens=int(usage.get("completion_tokens", 0) or 0),
        total_tokens=int(usage.get("total_tokens", 0) or 0),
    )
