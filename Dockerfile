# Build argument for base image selection
ARG BASE_IMAGE=nvidia/cuda:12.6.3-cudnn-runtime-ubuntu24.04

# Stage 1: Base image with common dependencies
FROM ${BASE_IMAGE} AS base

# Build arguments for this stage with sensible defaults for standalone builds
ARG COMFYUI_VERSION=latest
ARG CUDA_VERSION_FOR_COMFY
ARG ENABLE_PYTORCH_UPGRADE=false
ARG PYTORCH_INDEX_URL

# Prevents prompts from packages asking for user input during installation
ENV DEBIAN_FRONTEND=noninteractive
# Prefer binary wheels over source distributions for faster pip installations
ENV PIP_PREFER_BINARY=1
# Ensures output from python is printed immediately to the terminal without buffering
ENV PYTHONUNBUFFERED=1
# Speed up some cmake builds
ENV CMAKE_BUILD_PARALLEL_LEVEL=8

# Install Python, git, build tools, and other necessary tools
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
    && ln -sf /usr/bin/python3.12 /usr/bin/python \
    && ln -sf /usr/bin/pip3 /usr/bin/pip \
    && apt-get autoremove -y && apt-get clean -y && rm -rf /var/lib/apt/lists/*

# Verify git is available
RUN which git

# Install uv (latest) using official installer and create isolated venv
RUN wget -qO- https://astral.sh/uv/install.sh | sh \
    && ln -s /root/.local/bin/uv /usr/local/bin/uv \
    && uv venv /opt/venv

# Use the virtual environment for all subsequent commands
ENV PATH="/opt/venv/bin:${PATH}"

# Install comfy-cli + dependencies needed by it to install ComfyUI
RUN uv pip install comfy-cli pip setuptools wheel

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

# Support for the network volume
ADD src/extra_model_paths.yaml ./

# Go back to the root
WORKDIR /

# Install Python runtime dependencies for the handler
RUN uv pip install runpod requests websocket-client

# Add application code and scripts
ADD src/start.sh handler.py workflow_api.json ./
RUN chmod +x /start.sh

# Prevent pip from asking for confirmation during uninstall steps in custom nodes
# Add script to install custom nodes
COPY scripts/comfy-node-install.sh /usr/local/bin/comfy-node-install
RUN chmod +x /usr/local/bin/comfy-node-install

# Prevent pip from asking for confirmation during uninstall steps in custom nodes
ENV PIP_NO_INPUT=1

# Copy helper script to switch Manager network mode at container start
COPY scripts/comfy-manager-set-mode.sh /usr/local/bin/comfy-manager-set-mode
RUN chmod +x /usr/local/bin/comfy-manager-set-mode

# Step 1: Clone all repositories. This is not memory-intensive and caches well.
RUN git clone https://github.com/ltdrdata/ComfyUI-Impact-Pack.git && \
    git clone https://github.com/cubiq/ComfyUI_IPAdapter_plus.git && \
    git clone https://github.com/ZHO-ZHO-ZHO/ComfyUI-InstantID.git && \
    git clone https://github.com/cubiq/ComfyUI_essentials.git && \
    git clone https://github.com/anedsa/ComfyUI-Logic.git && \
    git clone https://github.com/BadCafeCode/masquerade-nodes-comfyui.git && \
    git clone https://github.com/kijai/ComfyUI-KJNodes.git && \
    git clone https://github.com/Suzie1/ComfyUI_Comfyroll_CustomNodes.git && \
    git clone https://github.com/melMass/comfy_mtb.git && \
    git clone https://github.com/ltdrdata/ComfyUI-Impact-Subpack.git && \
    git clone https://github.com/ltdrdata/was-node-suite-comfyui.git

# Step 2: Pin setuptools and numpy, then install dependencies
RUN uv pip install setuptools==60.10.0
    uv pip install ffmpeg-python
    uv pip install numpy==2.3.3
    uv pip install -r ComfyUI-Impact-Pack/requirements.txt && \
    uv pip install -r ComfyUI-InstantID/requirements.txt && \
    uv pip install -r was-node-suite-comfyui/requirements.txt && \
    uv pip install -r comfy_mtb/requirements.txt


WORKDIR /

# Set the default command to run when starting the container
CMD ["/start.sh"]

# Stage 2: Download models
FROM base AS downloader

# Change working directory to ComfyUI
WORKDIR /comfyui

# Create necessary directories upfront
RUN mkdir -p models/checkpoints models/vae models/upscale_models models/controlnet \
             models/ipadapter models/instantid models/clip_vision models/insightface models/loras \
             models/ultralytics/bbox

# --- Download Models ---
# Main Checkpoint
RUN wget --user-agent="Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/58.0.3029.110 Safari/537.36" -q -O "models/checkpoints/Realistic Freedom - Omega .safetensors" https://civitai.com/api/download/models/1461059

# VAE
RUN wget -q -O models/vae/sdxl_vae.safetensors https://huggingface.co/stabilityai/sdxl-vae/resolve/main/sdxl_vae.safetensors

# Upscale Models
RUN wget -q -O models/upscale_models/DAT_light_x3.pth https://huggingface.co/jaideepsingh/upscale_models/resolve/main/DAT/DAT_light_x3.pth?download=true
RUN wget -q -O models/upscale_models/x1_ITF_SkinDiffDetail_Lite__v1.pth https://huggingface.co/datasets/mpiquero/Upscalers/resolve/main/x1_ITF_SkinDiffDetail_Lite_v1.pth

# InstantID Models
RUN wget -q -O "models/controlnet/control instant iD.safetensors" https://huggingface.co/InstantX/InstantID/resolve/main/ControlNetModel/diffusion_pytorch_model.safetensors
RUN wget -q -O models/instantid/ip-adapter.bin https://huggingface.co/InstantX/InstantID/resolve/main/ip-adapter.bin

# IPAdapter Plus FaceID Models
RUN wget -q -O models/ipadapter/ip-adapter-faceid-plusv2_sdxl.bin https://huggingface.co/h94/IP-Adapter-FaceID/resolve/main/ip-adapter-faceid-plusv2_sdxl.bin
RUN wget -q -O models/loras/ip-adapter-faceid-plusv2_sdxl_lora.safetensors https://huggingface.co/h94/IP-Adapter-FaceID/resolve/main/ip-adapter-faceid-plusv2_sdxl_lora.safetensors

# CLIP Vision Model
RUN wget -q -O models/clip_vision/CLIP-ViT-H-14-laion2B-s32B-b79K.safetensors https://huggingface.co/laion/CLIP-ViT-H-14-laion2B-s32B-b79K/resolve/main/model.safetensors

# InsightFace Model (for face analysis)
#RUN mkdir -p models/insightface/models/antelopev2 && \
#    wget -q -O models/insightface/models/antelopev2/1k3d68.onnx https://huggingface.co/datasets/insightface/models/resolve/main/antelopev2/1k3d68.onnx && \
#    wget -q -O models/insightface/models/antelopev2/2d106det.onnx https://huggingface.co/datasets/insightface/models/resolve/main/antelopev2/2d106det.onnx && \
#    wget -q -O models/insightface/models/antelopev2/genderage.onnx https://huggingface.co/datasets/insightface/models/resolve/main/antelopev2/genderage.onnx && \
#    wget -q -O models/insightface/models/antelopev2/glint360k_cosface_r18_fp16_0.1.onnx https://huggingface.co/datasets/insightface/models/resolve/main/antelopev2/glint360k_cosface_r18_fp16_0.1.onnx && \
#    wget -q -O models/insightface/models/antelopev2/scrfd_10g_bnkps.onnx https://huggingface.co/datasets/insightface/models/resolve/main/antelopev2/scrfd_10g_bnkps.onnx

# Impact Pack Detector Model
RUN wget -q -O models/ultralytics/bbox/face_yolov8m.pt https://huggingface.co/Ultralytics/YOLOv8/resolve/main/yolov8m.pt

# Stage 3: Final image
FROM base AS final

# Copy models from stage 2 to the final image
COPY --from=downloader /comfyui/models /comfyui/models
