FROM ruby:3.4-slim

# Static ffmpeg/ffprobe — fully self-contained, no runtime lib dependencies.
# Includes VMAF, x264, x265, SVT-AV1, dav1d, libaom, VP9, opus, mp3, AAC, and more.
COPY --from=mwader/static-ffmpeg:latest /ffmpeg /usr/local/bin/ffmpeg
COPY --from=mwader/static-ffmpeg:latest /ffprobe /usr/local/bin/ffprobe

# Install SSH, tools, and utilities
RUN apt-get update && apt-get install -y --no-install-recommends \
    openssh-server \
    bash \
    bash-completion \
    ca-certificates \
    curl \
    vim \
    mkvtoolnix \
    mediainfo \
    locales \
    && sed -i 's/# en_US.UTF-8 UTF-8/en_US.UTF-8 UTF-8/' /etc/locale.gen \
    && locale-gen \
    && rm -rf /var/lib/apt/lists/*

ENV LANG=en_US.UTF-8 \
    LANGUAGE=en_US:en \
    LC_ALL=en_US.UTF-8 \
    PATH="/scripts:$PATH"

# Make /scripts available in PATH for SSH login shells (profile.d is sourced by bash login)
RUN echo 'export PATH="/scripts:$PATH"' > /etc/profile.d/scripts-path.sh

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
RUN useradd -m -s /bin/bash media && \
    echo "media:changeme" | chpasswd

# SSH hardening - disable root login, allow only our user
RUN sed -i \
    -e 's/#PermitRootLogin prohibit-password/PermitRootLogin no/' \
    -e 's/#PasswordAuthentication yes/PasswordAuthentication yes/' \
    -e 's/#PubkeyAuthentication yes/PubkeyAuthentication yes/' \
    /etc/ssh/sshd_config && \
    echo "AllowUsers media" >> /etc/ssh/sshd_config && \
    echo "X11Forwarding no" >> /etc/ssh/sshd_config && \
    echo "PrintMotd no" >> /etc/ssh/sshd_config

# Install Ruby gems for scripts
COPY scripts/Gemfile scripts/Gemfile.lock /scripts/
RUN cd /scripts && bundle install

# Copy scripts and make ruby files executable
COPY scripts/ /scripts/
RUN chmod +x /scripts/*.rb

# Create mount point directories (owned by media user for direct access)
RUN mkdir -p /mnt/media && \
    chown media:media /mnt/media

# Generate host keys at build time (stable across restarts)
RUN ssh-keygen -A

# Copy entrypoint
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

# SSH port
EXPOSE 22

ENTRYPOINT ["/entrypoint.sh"]
