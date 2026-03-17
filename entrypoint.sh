#!/bin/bash
set -e

# Allow overriding the ffmpeg user password via environment variable
if [ -n "$SSH_PASSWORD" ]; then
    echo "ffmpeg:${SSH_PASSWORD}" | chpasswd
fi

# If an authorized_keys file is bind-mounted or provided via env, install it
if [ -n "$SSH_AUTHORIZED_KEYS" ]; then
    mkdir -p /home/ffmpeg/.ssh
    echo "$SSH_AUTHORIZED_KEYS" > /home/ffmpeg/.ssh/authorized_keys
    chmod 700 /home/ffmpeg/.ssh
    chmod 600 /home/ffmpeg/.ssh/authorized_keys
    chown -R ffmpeg:ffmpeg /home/ffmpeg/.ssh
fi

# Ensure host keys exist (they should from build, but just in case volume wipes them)
ssh-keygen -A

echo "==> ffmpeg-ssh container started"
echo "==> SSH listening on port 22"
echo "==> Mount point: /mnt/media"

# Run sshd in foreground — this IS the main process, keeping the container alive
exec /usr/sbin/sshd -D -e
