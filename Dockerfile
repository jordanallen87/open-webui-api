# syntax=docker/dockerfile:1

#############################
#  Build WebUI frontend     #
#############################
ARG BUILD_HASH=dev-build

FROM --platform=$BUILDPLATFORM node:22-alpine3.20 AS build
WORKDIR /app

COPY package.json package-lock.json ./
RUN npm ci

COPY . .
ENV APP_BUILD_HASH=${BUILD_HASH}
RUN npm run build

#############################
#  Package WebUI backend    #
#############################
FROM python:3.11-slim-bookworm AS base

# Build-time args
ARG USE_CUDA=false
ARG USE_OLLAMA=false
ARG USE_CUDA_VER=cu121
ARG USE_EMBEDDING_MODEL=sentence-transformers/all-MiniLM-L6-v2
ARG USE_RERANKING_MODEL=""
ARG USE_TIKTOKEN_ENCODING_NAME="cl100k_base"
ARG UID=0
ARG GID=0

# Runtime env
ENV ENV=prod \
    PORT=8080 \
    USE_OLLAMA_DOCKER=${USE_OLLAMA} \
    USE_CUDA_DOCKER=${USE_CUDA} \
    USE_CUDA_DOCKER_VER=${USE_CUDA_VER} \
    USE_EMBEDDING_MODEL_DOCKER=${USE_EMBEDDING_MODEL} \
    USE_RERANKING_MODEL_DOCKER=${USE_RERANKING_MODEL} \
    OLLAMA_BASE_URL="/ollama" \
    OPENAI_API_BASE_URL="" \
    OPENAI_API_KEY="" \
    WEBUI_SECRET_KEY="" \
    SCARF_NO_ANALYTICS=true \
    DO_NOT_TRACK=true \
    ANONYMIZED_TELEMETRY=false \
    WHISPER_MODEL="base" \
    WHISPER_MODEL_DIR="/app/backend/data/cache/whisper/models" \
    RAG_EMBEDDING_MODEL="$USE_EMBEDDING_MODEL_DOCKER" \
    RAG_RERANKING_MODEL="$USE_RERANKING_MODEL_DOCKER" \
    SENTENCE_TRANSFORMERS_HOME="/app/backend/data/cache/embedding/models" \
    TIKTOKEN_ENCODING_NAME="$USE_TIKTOKEN_ENCODING_NAME" \
    TIKTOKEN_CACHE_DIR="/app/backend/data/cache/tiktoken" \
    HF_HOME="/app/backend/data/cache/embedding/models"

WORKDIR /app/backend
ENV HOME=/root

# Create non-root user if needed
RUN if [ "$UID" -ne 0 ]; then \
      if [ "$GID" -ne 0 ]; then addgroup --gid $GID app; fi && \
      adduser --uid $UID --gid $GID --home $HOME --disabled-password --no-create-home app; \
    fi

# Prepare cache dirs & permissions
RUN mkdir -p $HOME/.cache/chroma && \
    echo -n 00000000-0000-0000-0000-000000000000 > $HOME/.cache/chroma/telemetry_user_id && \
    chown -R $UID:$GID /app $HOME

# Install system tools (with or without Ollama)
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
      git build-essential pandoc netcat-openbsd curl jq gcc python3-dev ffmpeg libsm6 libxext6 && \
    if [ "$USE_OLLAMA" = "true" ]; then \
      curl -fsSL https://ollama.com/install.sh | sh; \
    fi && \
    rm -rf /var/lib/apt/lists/*

# Copy & install Python deps + verify models
COPY --chown=$UID:$GID ./backend/requirements.txt ./requirements.txt

RUN pip3 install --no-cache-dir uv && \
    if [ "$USE_CUDA" = "true" ]; then \
      pip3 install torch torchvision torchaudio --index-url https://download.pytorch.org/whl/$USE_CUDA_VER --no-cache-dir; \
    else \
      pip3 install torch torchvision torchaudio --index-url https://download.pytorch.org/whl/cpu --no-cache-dir; \
    fi && \
    uv pip install --system -r requirements.txt --no-cache-dir && \
    python - <<'PYCODE'
import os
from sentence_transformers import SentenceTransformer
SentenceTransformer(os.environ['RAG_EMBEDDING_MODEL'], device='cpu')
from faster_whisper import WhisperModel
WhisperModel(os.environ['WHISPER_MODEL'], device='cpu',
             compute_type='int8', download_root=os.environ['WHISPER_MODEL_DIR'])
PYCODE

# Guard tiktoken lookup so empty encodings don’t break the build
RUN python - <<'PYCODE' || (echo "⚠️ skipping tiktoken validation" && exit 0)
import os, tiktoken
name = os.getenv('TIKTOKEN_ENCODING_NAME','cl100k_base')
print("using tiktoken encoding:", name)
tiktoken.get_encoding(name)
PYCODE

# Copy and install the local backend package (makes `open-webui` CLI available)
COPY --chown=$UID:$GID ./backend .
RUN pip3 install --no-cache-dir .

RUN chown -R $UID:$GID /app/backend/data/

# Copy built frontend assets
COPY --chown=$UID:$GID --from=build /app/build /app/build
COPY --chown=$UID:$GID --from=build /app/CHANGELOG.md /app/CHANGELOG.md
COPY --chown=$UID:$GID --from=build /app/package.json /app/package.json

EXPOSE 8080
HEALTHCHECK CMD curl --silent --fail http://localhost:${PORT:-8080}/health | jq -ne 'input.status == true' || exit 1

USER $UID:$GID
ARG BUILD_HASH
ENV WEBUI_BUILD_VERSION=${BUILD_HASH} DOCKER=true

# Now that `open-webui` is installed, this will actually launch the server
CMD ["bash","-lc","exec open-webui serve --host 0.0.0.0 --port ${PORT:-8080}"]