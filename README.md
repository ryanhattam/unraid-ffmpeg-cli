# ffmpeg-ssh Docker Container for Unraid

A minimal, always-on Docker container that exposes SSH access to run ffmpeg
against your Unraid shares — with zero filesystem overhead on the share data.

## How it works

- **sshd runs in the foreground** as PID 1, so the container never exits
- **Unraid shares are bind-mounted** directly into the container — reads/writes
  go straight to the underlying share with no copy-on-write layer in between
- ffmpeg sees your files as a normal Linux path; no performance penalty

## Adding to Unraid

### Option A — Community Applications template (recommended)

1. In Unraid → Apps, click **Add Container** → paste the following template URL:

   ```text
   https://raw.githubusercontent.com/ryanhattam/unraid-ffmpeg-cli/main/unraid-template.xml
   ```

2. Fill in your share paths and set a strong `SSH_PASSWORD` (or paste your SSH public key)
3. Click **Apply**

### Option B — Docker Compose

1. Copy `docker-compose.yml` from this repo to a share, e.g. `/mnt/user/appdata/ffmpeg-ssh/`
2. Update the volume paths to your actual share names
3. In Unraid → Settings → Docker → Compose Manager, point it at the file

### Option C — Manual "Add Container"

1. In Unraid → Docker → **Add Container**
2. Set **Repository** to `ryanhattam/unraid-ffmpeg-cli` (or build your own image)
3. Add **Port** mapping: Host `2244` → Container `22` (TCP)
4. Add **Path** mappings for each share (see table below)
5. Add **Variable** `SSH_PASSWORD` with a strong password

### Recommended share mount paths

| Unraid Share Path       | Container Path | Mode |
|-------------------------|----------------|------|
| `/mnt/user/Media`       | `/mnt/media`   | RW   |
| `/mnt/user/Output`      | `/mnt/output`  | RW   |
| `/mnt/user/Data`        | `/mnt/data`    | RW   |

> **Tip:** Use `/mnt/disk1/ShareName` instead of `/mnt/user/ShareName` to pin
> to a specific disk and avoid the user-share mover overhead during encodes.

## Connecting via SSH

```bash
ssh ffmpeg@your-unraid-ip -p 2244
# password: whatever you set in SSH_PASSWORD
```

### Key-based auth (recommended)

Pass your public key via the `SSH_AUTHORIZED_KEYS` variable in the Unraid template,
or in `docker-compose.yml`:

```yaml
environment:
  - SSH_AUTHORIZED_KEYS=ssh-ed25519 AAAA...your-key-here
```

Then connect without a password:

```bash
ssh -i ~/.ssh/id_ed25519 ffmpeg@your-unraid-ip -p 2244
```

## Example ffmpeg Commands (once SSH'd in)

```bash
# Transcode to H.265
ffmpeg -i /mnt/media/movie.mkv -c:v libx265 -crf 22 -c:a copy /mnt/output/movie_x265.mkv

# Batch transcode a folder
for f in /mnt/media/*.mkv; do
  out="/mnt/output/$(basename "${f%.mkv}")_x265.mkv"
  ffmpeg -i "$f" -c:v libx265 -crf 22 -c:a copy "$out"
done

# Extract audio
ffmpeg -i /mnt/media/movie.mkv -vn -c:a aac /mnt/output/audio.aac

# Check hardware acceleration availability
ffmpeg -hwaccels
```

## Hardware Acceleration (optional)

To pass through Intel QSV or NVIDIA NVENC, add to your docker run / compose:

**Intel iGPU (QSV/VAAPI):**

```yaml
devices:
  - /dev/dri:/dev/dri
```

**NVIDIA:**

```yaml
deploy:
  resources:
    reservations:
      devices:
        - capabilities: [gpu]
```

And use `--runtime=nvidia` or install the NVIDIA Container Toolkit on Unraid.

## Security Notes

- Change `SSH_PASSWORD` immediately — the default `changeme` is not safe
- Prefer key-based auth; you can disable password auth by setting
  `PasswordAuthentication no` in a custom sshd_config bind-mount
- The container runs sshd as root internally (required to fork sessions)
  but the `ffmpeg` login user is unprivileged
- `PermitRootLogin no` is enforced in the image
