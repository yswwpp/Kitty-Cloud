FROM python:3.11-slim

WORKDIR /app

# 安装依赖（包含 LangGraph、httpx[socks] 等）
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt \
 && pip install --no-cache-dir 'httpx[socks]' socksio

# 复制代码
COPY main.py .
COPY models.json .
COPY agent ./agent
COPY llm ./llm

# checkpoint 目录（compose 里挂 volume 持久化）
RUN mkdir -p /app/data

# 暴露端口
EXPOSE 8081

# 启动服务
CMD ["python", "main.py"]
