FROM rust:slim-trixie

# Build the upstream Linux reference and exercise the shared audio fixtures.
RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential ca-certificates clang cmake ffmpeg git glslc libadwaita-1-dev \
    libclang-dev libgtk-4-dev libssl-dev libvulkan-dev pkg-config pulseaudio-utils python3 \
    && rm -rf /var/lib/apt/lists/* \
    && useradd --create-home --shell /bin/bash vscode

ENV CARGO_HOME=/home/vscode/.cargo
