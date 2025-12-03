# ==========================================
# 阶段 1: 构建阶段 (Builder)
# ==========================================
# 使用 Python 3.9 作为基础镜像 [cite: 1]
FROM python:3.9-slim-bullseye AS builder

WORKDIR /app

# 安装构建依赖 [cite: 1]
RUN apt-get update && apt-get install -y --no-install-recommends \
    gcc \
    libc6-dev \
    binutils \
    libpq-dev \
    && rm -rf /var/lib/apt/lists/*

# 安装 Python 依赖 [cite: 2]
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
RUN pip install --no-cache-dir pyinstaller

# 复制源码并构建
COPY . .
# 运行构建脚本，这会在 /app/release 生成最终文件 
RUN python build.py

# ==========================================
# 阶段 2: 运行时阶段 (Runtime)
# ==========================================
# 使用相同的精简版基础镜像，确保 glibc 版本一致
FROM python:3.9-slim-bullseye

WORKDIR /app

# 安装运行时必需的系统库 (例如 libpq5 用于数据库)
# 去除了 gcc 等编译工具，减小体积
RUN apt-get update && apt-get install -y --no-install-recommends \
    libpq5 \
    && rm -rf /var/lib/apt/lists/*

# [核心] 从 builder 阶段只复制构建好的 release 文件夹
COPY --from=builder /app/release .

# 赋予二进制文件执行权限
RUN chmod +x NodeTool

# 暴露端口 (根据您的代码，默认是 5000)
EXPOSE 5000

# 设置容器启动命令：直接运行二进制文件
CMD ["./NodeTool"]