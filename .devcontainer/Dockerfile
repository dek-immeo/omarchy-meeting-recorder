FROM python:3.13-slim-trixie AS onnx
# Same CPU runtime as the upstream ort-sys lock, for Linux x64 and ARM64.
COPY onnxruntime.txt /tmp/onnxruntime.txt
RUN --mount=type=secret,id=proxy_ca,target=/etc/ssl/certs/ca-certificates.crt \
    PIP_CERT=/etc/ssl/certs/ca-certificates.crt python -m pip install --no-cache-dir --only-binary=:all: --no-deps --require-hashes \
        -r /tmp/onnxruntime.txt --target /tmp/ort \
    && mkdir /runtime && cp /tmp/ort/onnxruntime/capi/libonnxruntime*.so* /runtime/

FROM rust:slim-trixie

# Build the upstream Linux reference and exercise the shared audio fixtures.
RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential ca-certificates clang cmake ffmpeg git glslc libadwaita-1-dev \
    libclang-dev libgtk-4-dev libssl-dev libvulkan-dev pkg-config pulseaudio-utils python3 \
    && rm -rf /var/lib/apt/lists/* \
    && useradd --create-home --shell /bin/bash vscode

ENV CARGO_HOME=/home/vscode/.cargo

COPY --from=onnx /runtime/ /usr/local/lib/
ENV ORT_DYLIB_PATH=/usr/local/lib/libonnxruntime.so.1.28.0
