# Build argument for base image selection
ARG BASE_IMAGE=runpod/worker-comfyui:5.4.1-base
# Stage 1: Base image with common dependencies
FROM ${BASE_IMAGE}
# Install Python, git and other necessary tools
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

RUN pip install --no-cache-dir --upgrade pip
RUN pip install --no-cache-dir opencv-python-headless numba requirements-parser

RUN comfy node install comfyui-kjnodes comfyui-impact-pack comfyui-logic comfyui_essentials comfy-mtb comfyui_instantid comfyui_ipadapter_plus comfyui-impact-subpack was-ns

#Change working directory to ComfyUI

WORKDIR /comfyui/custom_nodes

RUN git clone https://github.com/BadCafeCode/masquerade-nodes-comfyui.git && \
    git clone https://github.com/Suzie1/ComfyUI_Comfyroll_CustomNodes.git

# Change working directory to ComfyUI
WORKDIR /comfyui
# Support for the network volume
ADD src/extra_model_paths.yaml ./

