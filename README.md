# ffmpeg-ssh Docker Container for Unraid

A minimal, always-on Docker container with SSH access for running ffmpeg,
ffprobe, mkvmerge, mediainfo, dovi_tool, and vim against your Unraid shares —
with zero filesystem overhead on the share data.

## Tools included

| Tool | Source |
|------|--------|
| ffmpeg | apt |
| ffprobe | apt (bundled with ffmpeg) |
| vim | apt |
| mkvmerge (+ mkvinfo, mkvextract, mkvpropedit) | apt (mkvtoolnix) |
| mediainfo | apt |
| dovi_tool | GitHub releases (latest musl binary) |

## How it works

- **sshd runs in the foreground** as PID 1, so the container never exits
- **Unraid shares are bind-mounted** directly into the container — reads/writes
  go straight to the underlying share with no copy-on-write layer in between
- All tools see your files as normal Linux paths — no performance penalty

## Credentials

- **Username:** `ffmpeg`
- **Default password:** `changeme`

Change the password before deploying — see the SSH_PASSWORD environment variable below.

---

## Unraid Setup (version 7+)

### Option A — Clone from GitHub and run (recommended)

No plugins needed. From the Unraid terminal (or any SSH session into Unraid):

1. Clone the repo and build the image:
   ```bash
   cd /mnt/user/appdata
   git clone https://github.com/ryanhattam/unraid-ffmpeg-cli
   cd unraid-ffmpeg-cli
   docker build -t ffmpeg-ssh .
   ```

2. Start the container:
   ```bash
   docker run -d \
     --name ffmpeg-ssh \
     --restart unless-stopped \
     -p 2244:22 \
     -e SSH_PASSWORD=yourpassword \
     -v /mnt/user/Media:/mnt/media \
     -v /mnt/user/Output:/mnt/output \
     -v /mnt/user/Data:/mnt/data:ro \
     ffmpeg-ssh
   ```
   Adjust the `-v` paths to match your actual share names.

3. To update later, pull and rebuild:

   ```bash
   cd /mnt/user/appdata/unraid-ffmpeg-cli
   git pull
   docker build -t ffmpeg-ssh .
   docker restart ffmpeg-ssh
   ```

The `--restart unless-stopped` flag ensures the container comes back up after an Unraid reboot.

### Option B — Local user template (Unraid Docker UI)

The included `unraid-template.xml` can be used as a local template in Unraid's
native Docker UI:

1. Download the template directly on your Unraid server (from the Unraid terminal):

   ```bash
   curl -fsSL https://raw.githubusercontent.com/ryanhattam/unraid-ffmpeg-cli/main/unraid-template.xml \
     -o /boot/config/plugins/dockerMan/templates-user/ffmpeg-ssh.xml
   ```

2. In Unraid → **Docker** tab → click **Add Container**
3. At the top of the form, click the **Template** dropdown — `ffmpeg-ssh` will
   appear under **User Templates**
4. Select it, fill in your share paths and set `SSH_PASSWORD`
5. Click **Create**

### Option C — Manual Add Container (no template file)

If you prefer to configure everything by hand:

1. In Unraid → **Docker** tab → click **Add Container**
2. Enable **Advanced View** (toggle top-right)
3. Set **Repository** to your built image name
4. Add a **Port** mapping: Host port `2244` → Container port `22` (TCP)
5. Add **Path** mappings for your shares:

   | Unraid Share Path   | Container Path | Mode |
   |---------------------|----------------|------|
   | `/mnt/user/Media`   | `/mnt/media`   | RW   |
   | `/mnt/user/Output`  | `/mnt/output`  | RW   |
   | `/mnt/user/Data`    | `/mnt/data`    | RW   |

6. Add a **Variable**: Name `SSH_PASSWORD`, Value: your chosen password
7. Click **Create**

> **Tip:** Use `/mnt/disk1/ShareName` instead of `/mnt/user/ShareName` to pin
> reads/writes to a specific disk, bypassing the user-share mover entirely
> during encodes.

---

## Connecting via SSH

```bash
ssh ffmpeg@your-unraid-ip -p 2244
# enter the password you set in SSH_PASSWORD
```

### Key-based auth (recommended)

Pass your public key via the `SSH_AUTHORIZED_KEYS` environment variable:

```bash
docker run -d \
  --name ffmpeg-ssh \
  --restart unless-stopped \
  -p 2244:22 \
  -e SSH_AUTHORIZED_KEYS="$(cat ~/.ssh/id_ed25519.pub)" \
  -v /mnt/user/Media:/mnt/media \
  -v /mnt/user/Output:/mnt/output \
  ffmpeg-ssh
```

Then connect without a password:

```bash
ssh -i ~/.ssh/id_ed25519 ffmpeg@your-unraid-ip -p 2244
```

---

## Example commands (once SSH'd in)

```bash
# Check what's in a file
ffprobe /mnt/media/movie.mkv

# Get detailed track info
mediainfo /mnt/media/movie.mkv

# Transcode to H.265
ffmpeg -i /mnt/media/movie.mkv -c:v libx265 -crf 22 -c:a copy /mnt/output/movie_x265.mkv

# Batch transcode a folder
for f in /mnt/media/*.mkv; do
  out="/mnt/output/$(basename "${f%.mkv}")_x265.mkv"
  ffmpeg -i "$f" -c:v libx265 -crf 22 -c:a copy "$out"
done

# Extract Dolby Vision RPU
ffmpeg -i /mnt/media/movie.mkv -c:v copy -bsf:v hevc_mp4toannexb -f hevc - | \
  dovi_tool extract-rpu - -o /mnt/output/RPU.bin

# Remux streams with mkvmerge
mkvmerge -o /mnt/output/remuxed.mkv /mnt/media/movie.mkv

# Check available hardware acceleration
ffmpeg -hwaccels
```

---

## Hardware acceleration (optional)

**Intel iGPU (VAAPI/QSV)** — add `--device /dev/dri:/dev/dri` to your `docker run`:

```bash
docker run -d \
  --name ffmpeg-ssh \
  --restart unless-stopped \
  -p 2244:22 \
  -e SSH_PASSWORD=yourpassword \
  --device /dev/dri:/dev/dri \
  -v /mnt/user/Media:/mnt/media \
  -v /mnt/user/Output:/mnt/output \
  ffmpeg-ssh
```

**NVIDIA** — install the Nvidia Driver plugin in Unraid first, then add the runtime and variables:

```bash
docker run -d \
  --name ffmpeg-ssh \
  --restart unless-stopped \
  -p 2244:22 \
  -e SSH_PASSWORD=yourpassword \
  -e NVIDIA_VISIBLE_DEVICES=all \
  -e NVIDIA_DRIVER_CAPABILITIES=compute,video,utility \
  --runtime nvidia \
  -v /mnt/user/Media:/mnt/media \
  -v /mnt/user/Output:/mnt/output \
  ffmpeg-ssh
```

---

## Security notes

- Change `SSH_PASSWORD` before deploying — the default `changeme` is not safe
- Key-based auth is preferred; once set up you can disable password auth by
  bind-mounting a custom `sshd_config` with `PasswordAuthentication no`
- `PermitRootLogin no` is enforced in the image
- The `ffmpeg` user is unprivileged — sshd forks sessions as root internally
  (required by SSH), but your interactive shell runs as the `ffmpeg` user