# Build argument for base image selection
ARG BASE_IMAGE=nvidia/cuda:12.6.3-cudnn-runtime-ubuntu24.04

# Stage 1: Base image with common dependencies
FROM ${BASE_IMAGE}

# Build arguments for this stage with sensible defaults for standalone builds
ARG COMFYUI_VERSION=latest
ARG CUDA_VERSION_FOR_COMFY=12.6
ARG ENABLE_PYTORCH_UPGRADE=true
ARG PYTORCH_INDEX_URL=https://download.pytorch.org/whl/cu126

# Prevents prompts from packages asking for user input during installation
ENV DEBIAN_FRONTEND=noninteractive
# Prefer binary wheels over source distributions for faster pip installations
ENV PIP_PREFER_BINARY=1
# Ensures output from python is printed immediately to the terminal without buffering
ENV PYTHONUNBUFFERED=1
# Speed up some cmake builds
ENV CMAKE_BUILD_PARALLEL_LEVEL=8

RUN apt-get update && apt-get install -y \
    python3.12 \
    python3.12-venv \
    python3.12-dev \
    git \
    wget \
    libgl1 \
    libglib2.0-0 \
    build-essential \
    gcc \
    g++ \
    ffmpeg \
    unzip \
    libavcodec-dev \
    libavformat-dev \
    libavutil-dev \
    libswscale-dev \
    && ln -sf /usr/bin/python3.12 /usr/bin/python \
    && ln -sf /usr/bin/pip3 /usr/bin/pip 
# Clean up to reduce image size
RUN apt-get autoremove -y && apt-get clean -y && rm -rf /var/lib/apt/lists/*

# Install uv (latest) using official installer and create isolated venv
RUN wget -qO- https://astral.sh/uv/install.sh | sh \
    && ln -s /root/.local/bin/uv /usr/local/bin/uv \
    && uv venv /opt/venv

# Use the virtual environment for all subsequent commands
ENV PATH="/opt/venv/bin:${PATH}"

# Install comfy-cli + dependencies needed by it to install ComfyUI
ENV PIP_NO_INPUT=1
RUN uv pip install comfy-cli pip setuptools wheel
RUN pip install --no-cache-dir --upgrade pip
RUN pip install --no-cache-dir opencv-python-headless numba requirements-parser insightface==0.7.3 onnxruntime-gpu

# Install ComfyUI
RUN if [ -n "${CUDA_VERSION_FOR_COMFY}" ]; then \
      /usr/bin/yes | comfy --workspace /comfyui install --version "${COMFYUI_VERSION}" --cuda-version "${CUDA_VERSION_FOR_COMFY}" --nvidia; \
    else \
      /usr/bin/yes | comfy --workspace /comfyui install --version "${COMFYUI_VERSION}" --nvidia; \
    fi

# Upgrade PyTorch if needed (for newer CUDA versions)
RUN if [ "$ENABLE_PYTORCH_UPGRADE" = "true" ]; then \
      uv pip install --force-reinstall torch torchvision torchaudio --index-url ${PYTORCH_INDEX_URL}; \
    fi

# Change working directory to ComfyUI
WORKDIR /comfyui

RUN mkdir -p models/insightface/models/antelopev2 && \
    cd models/insightface/models/antelopev2 && \
    wget -q -O antelopev2.zip https://github.com/deepinsight/insightface/releases/download/v0.7/antelopev2.zip && \
    unzip -q antelopev2.zip && \
    rm antelopev2.zip && \
    mkdir -p models/insightface/models/buffalo_l && \
    cd models/insightface/models/buffalo_l && \
    wget -q https://github.com/deepinsight/insightface/releases/download/v0.7/buffalo_l.zip && \
    unzip -q buffalo_l.zip && \
    rm buffalo_l.zip && \
    chmod -R 755 /comfyui/models/insightface

# Support for the network volume
ADD src/extra_model_paths.yaml ./

WORKDIR /comfyui/custom_nodes

RUN git clone https://github.com/BadCafeCode/masquerade-nodes-comfyui.git && \
    git clone https://github.com/Suzie1/ComfyUI_Comfyroll_CustomNodes.git && \
    git clone https://github.com/anedsa/ComfyUI-Logic.git

# Go back to the root
WORKDIR /
# Install Python runtime dependencies for the handler and ultralytics
RUN uv pip install runpod requests websocket-client ultralytics

# Add application code and scripts
ADD src/start.sh handler.py ./
RUN chmod +x /start.sh

# Prevent pip from asking for confirmation during uninstall steps in custom nodes
# Add script to install custom nodes
#COPY scripts/comfy-node-install.sh /usr/local/bin/comfy-node-install
#RUN chmod +x /usr/local/bin/comfy-node-install

# Prevent pip from asking for confirmation during uninstall steps in custom nodes


# Copy helper script to switch Manager network mode at container start
COPY scripts/comfy-manager-set-mode.sh /usr/local/bin/comfy-manager-set-mode
RUN chmod +x /usr/local/bin/comfy-manager-set-mode

RUN comfy node install comfyui-kjnodes comfyui-impact-pack comfyui_essentials comfy-mtb comfyui_instantid comfyui_ipadapter_plus comfyui-impact-subpack was-ns comfyui-tooling-nodes

WORKDIR /

# Set the default command to run when starting the container
CMD ["/start.sh"]
