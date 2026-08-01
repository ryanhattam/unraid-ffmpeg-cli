#!/bin/bash
set -e

# Allow overriding the media user password via environment variable
if [ -n "$SSH_PASSWORD" ]; then
    echo "media:${SSH_PASSWORD}" | chpasswd
fi

# If an authorized_keys file is bind-mounted or provided via env, install it
if [ -n "$SSH_AUTHORIZED_KEYS" ]; then
    mkdir -p /home/media/.ssh
    echo "$SSH_AUTHORIZED_KEYS" > /home/media/.ssh/authorized_keys
    chmod 700 /home/media/.ssh
    chmod 600 /home/media/.ssh/authorized_keys
    chown -R media:media /home/media/.ssh
fi

# Ensure host keys exist (they should from build, but just in case volume wipes them)
ssh-keygen -A

echo "==> ffmpeg-ssh container started"
echo "==> SSH listening on port 22"
echo "==> Mount point: /mnt/media"

# Run sshd in foreground — this IS the main process, keeping the container alive
exec /usr/sbin/sshd -D -e
