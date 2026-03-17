# ─── Stage 1: Compile ffmpeg ──────────────────────────────────────────────────
FROM debian:bookworm AS ffmpeg-builder

RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential \
    pkg-config \
    nasm \
    yasm \
    curl \
    xz-utils \
    libvmaf-dev \
    libx264-dev \
    libx265-dev \
    libvpx-dev \
    libdav1d-dev \
    libaom-dev \
    libopus-dev \
    libmp3lame-dev \
    libass-dev \
    libfreetype-dev \
    libfontconfig1-dev \
    libfribidi-dev \
    libwebp-dev \
    libvorbis-dev \
    && rm -rf /var/lib/apt/lists/*

ARG FFMPEG_VERSION=7.1
RUN curl -fsSL "https://ffmpeg.org/releases/ffmpeg-${FFMPEG_VERSION}.tar.xz" \
        -o /tmp/ffmpeg.tar.xz && \
    tar -xf /tmp/ffmpeg.tar.xz -C /tmp && \
    cd /tmp/ffmpeg-${FFMPEG_VERSION} && \
    ./configure \
        --prefix=/usr/local \
        --enable-gpl \
        --enable-version3 \
        --enable-libvmaf \
        --enable-libx264 \
        --enable-libx265 \
        --enable-libvpx \
        --enable-libdav1d \
        --enable-libaom \
        --enable-libopus \
        --enable-libmp3lame \
        --enable-libass \
        --enable-libfreetype \
        --enable-libfontconfig \
        --enable-libfribidi \
        --enable-libwebp \
        --enable-libvorbis \
        --disable-debug \
        --disable-doc \
        --disable-ffplay && \
    make -j$(nproc) && \
    make install && \
    rm -rf /tmp/ffmpeg*

# ─── Stage 2: Runtime image ───────────────────────────────────────────────────
FROM debian:bookworm-slim

# Codec runtime libs + SSH/tools
RUN apt-get update && apt-get install -y --no-install-recommends \
    libvmaf3 \
    libx264-163 \
    libx265-199 \
    libvpx7 \
    libdav1d6 \
    libaom3 \
    libopus0 \
    libmp3lame0 \
    libass9 \
    libfreetype6 \
    libfontconfig1 \
    libfribidi0 \
    libwebp7 \
    libvorbisenc2 \
    openssh-server \
    bash \
    bash-completion \
    ca-certificates \
    curl \
    vim \
    mkvtoolnix \
    mediainfo \
    && rm -rf /var/lib/apt/lists/*

# Copy compiled ffmpeg/ffprobe from builder
COPY --from=ffmpeg-builder /usr/local/bin/ffmpeg /usr/local/bin/ffmpeg
COPY --from=ffmpeg-builder /usr/local/bin/ffprobe /usr/local/bin/ffprobe

# Install dovi_tool — fetch latest musl-linked binary from GitHub releases
# musl build has no libc dependencies so it works on any Linux distro/container
RUN DOVI_VERSION=$(curl -fsSL https://api.github.com/repos/quietvoid/dovi_tool/releases/latest \
        | grep '"tag_name"' | sed 's/.*"tag_name": "\(.*\)".*/\1/') && \
    curl -fsSL "https://github.com/quietvoid/dovi_tool/releases/download/${DOVI_VERSION}/dovi_tool-${DOVI_VERSION}-x86_64-unknown-linux-musl.tar.gz" \
        -o /tmp/dovi_tool.tar.gz && \
    mkdir /tmp/dovi_extract && \
    tar -xzf /tmp/dovi_tool.tar.gz -C /tmp/dovi_extract && \
    find /tmp/dovi_extract -name 'dovi_tool' -type f \
        -exec install -m 755 {} /usr/local/bin/dovi_tool \; && \
    rm -rf /tmp/dovi_tool.tar.gz /tmp/dovi_extract

# Create SSH run directory
RUN mkdir -p /var/run/sshd

# Create a dedicated user for SSH access
RUN useradd -m -s /bin/bash ffmpeg && \
    echo "ffmpeg:changeme" | chpasswd

# SSH hardening - disable root login, allow only our user
RUN sed -i \
    -e 's/#PermitRootLogin prohibit-password/PermitRootLogin no/' \
    -e 's/#PasswordAuthentication yes/PasswordAuthentication yes/' \
    -e 's/#PubkeyAuthentication yes/PubkeyAuthentication yes/' \
    /etc/ssh/sshd_config && \
    echo "AllowUsers ffmpeg" >> /etc/ssh/sshd_config && \
    echo "X11Forwarding no" >> /etc/ssh/sshd_config && \
    echo "PrintMotd no" >> /etc/ssh/sshd_config

# Create mount point directories (owned by ffmpeg user for direct access)
RUN mkdir -p /mnt/media /mnt/output /mnt/data && \
    chown ffmpeg:ffmpeg /mnt/media /mnt/output /mnt/data

# Generate host keys at build time (stable across restarts)
RUN ssh-keygen -A

# Copy entrypoint
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

# SSH port
EXPOSE 22

ENTRYPOINT ["/entrypoint.sh"]
