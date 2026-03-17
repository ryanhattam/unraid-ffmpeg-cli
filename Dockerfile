FROM debian:bookworm-slim

# Install runtime tools and utilities (ffmpeg installed separately below)
RUN apt-get update && apt-get install -y --no-install-recommends \
    openssh-server \
    bash \
    bash-completion \
    ca-certificates \
    curl \
    gnupg2 \
    vim \
    mkvtoolnix \
    mediainfo \
    && rm -rf /var/lib/apt/lists/*

# Install Jellyfin's ffmpeg build — Debian-native package that includes VMAF (with
# model files), x264, x265, SVT-AV1, dav1d, VP8/VP9, libfdk-aac, libopus, libass, etc.
RUN curl -fsSL https://repo.jellyfin.org/jellyfin_team.gpg.key \
        | gpg --dearmor -o /etc/apt/keyrings/jellyfin.gpg && \
    echo "deb [signed-by=/etc/apt/keyrings/jellyfin.gpg arch=amd64] https://repo.jellyfin.org/debian bookworm main" \
        > /etc/apt/sources.list.d/jellyfin.list && \
    apt-get update && apt-get install -y --no-install-recommends jellyfin-ffmpeg7 && \
    ln -s /usr/lib/jellyfin-ffmpeg/ffmpeg /usr/local/bin/ffmpeg && \
    ln -s /usr/lib/jellyfin-ffmpeg/ffprobe /usr/local/bin/ffprobe && \
    rm -rf /var/lib/apt/lists/* /etc/apt/sources.list.d/jellyfin.list /etc/apt/keyrings/jellyfin.gpg

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