# sftp-web

Mount a remote SFTP directory and serve it as a static website — powered by **rclone** (FUSE mount) and **Caddy** (web server), all in a single Docker container.

## Features

- SFTP as storage backend via rclone mount (FUSE)
- Caddy web server with built-in SPA support
- Automatic SSH key pair generation (Ed25519)
- Flexible authentication: SSH key (priority) or password
- Customizable Caddyfile from SFTP remote, local mount, or built-in default
- Configurable remote web folder

## Quick Start

### 1. Build the image

```bash
docker build -t sftp-web .
```

### 2. Run with password authentication

```bash
docker run -d \
  --name sftp-web \
  --privileged \
  -p 8080:80 \
  -e SFTP_HOST=your-sftp-server.com \
  -e SFTP_PORT=22 \
  -e SFTP_USER=your-username \
  -e SFTP_PASS=your-password \
  -e SFTP_REMOTE_WEB_FOLDER=/www \
  -v ssh-keys:/keys \
  sftp-web
```

### 3. Run with SSH key authentication

```bash
docker run -d \
  --name sftp-web \
  --privileged \
  -p 8080:80 \
  -e SFTP_HOST=your-sftp-server.com \
  -e SFTP_USER=your-username \
  -e SFTP_REMOTE_WEB_FOLDER=/www \
  -v /path/to/your/id_rsa:/user-key/id_rsa:ro \
  sftp-web
```

### 4. Run with docker-compose

```bash
# Edit docker-compose.yml with your settings, then:
docker compose up -d
```

Visit **http://localhost:8080** to see your SFTP files served as a website.

## Environment Variables

| Variable | Required | Default | Description |
|---|---|---|---|
| `SFTP_HOST` | **Yes** | — | SFTP server hostname or IP |
| `SFTP_PORT` | No | `22` | SFTP server port |
| `SFTP_USER` | **Yes** | — | SFTP username |
| `SFTP_PASS` | No | — | SFTP password (used when no SSH key is provided) |
| `SFTP_REMOTE_WEB_FOLDER` | No | `/` | Remote directory to serve as web root |
| `SFTP_REMOTE_CADDYFILE` | No | — | Remote path to a Caddyfile or folder containing one |

## Volume Mounts

| Container Path | Purpose | Example |
|---|---|---|
| `/user-key/` | Mount your SSH private key here (read-only recommended) | `-v ./id_rsa:/user-key/id_rsa:ro` |
| `/data/caddyfile/` | Override the built-in Caddyfile | `-v ./my-caddyfile-dir:/data/caddyfile:ro` |
| `/keys/` | Persist auto-generated SSH key pair across restarts | `-v ssh-keys:/keys` |

> **Important:** Never mount directly to `/root/.ssh/`. The entrypoint manages that directory internally via symlinks.

## SSH Key Management

The container follows this priority for SSH authentication:

```
User-mounted key (/user-key/)  >  Password (SFTP_PASS)  >  Auto-generated key (/keys/)
```

### Behavior on startup

| Scenario | Action |
|---|---|
| Key file found in `/user-key/` | Symlink to SSH working dir, print public key, use for auth |
| No user key, `SFTP_PASS` is set | Use password auth; auto-generate key pair and print pubkey for future use |
| No user key, no password, key in `/keys/` | Print existing pubkey, use generated key for auth |
| No user key, no password, no key in `/keys/` | Generate new Ed25519 key pair, print pubkey, use for auth |

When using auto-generated keys, **add the printed public key to your SFTP server's `authorized_keys`** before the container can connect successfully.

To view the public key of a running container:

```bash
docker logs sftp-web 2>&1 | grep -A1 "Public key"
```

## Caddyfile Configuration

The Caddyfile is resolved in this order:

### 1. Remote Caddyfile (`SFTP_REMOTE_CADDYFILE`)

If set, the entrypoint looks for it on the mounted SFTP filesystem:

- **Folder** containing a `Caddyfile` → the entire folder is symlinked as `/etc/caddy/`
- **Single file** → an empty `/etc/caddy/` is created and the file is symlinked as `/etc/caddy/Caddyfile`

```bash
# Use a Caddyfile folder from SFTP
-e SFTP_REMOTE_CADDYFILE=/config/caddy

# Use a single Caddyfile from SFTP
-e SFTP_REMOTE_CADDYFILE=/config/Caddyfile
```

### 2. Local mount override

Mount your own Caddyfile directory to `/data/caddyfile/`:

```bash
-v ./my-caddyfile-dir:/data/caddyfile:ro
```

### 3. Built-in default

If nothing is specified, the built-in SPA-ready Caddyfile is used:

```caddyfile
:80 {
    root * /srv/web
    encode gzip zstd
    try_files {path} /index.html
    file_server
}
```

## Docker Compose Example

```yaml
services:
  sftp-web:
    build: .
    container_name: sftp-web
    privileged: true
    ports:
      - "8080:80"
    environment:
      - SFTP_HOST=your-sftp-server.com
      - SFTP_PORT=22
      - SFTP_USER=your-username
      - SFTP_PASS=your-password
      - SFTP_REMOTE_WEB_FOLDER=/www
    volumes:
      - ssh-keys:/keys
      # - ./my-ssh-key:/user-key/id_rsa:ro
      # - ./my-caddyfile:/data/caddyfile:ro
    restart: unless-stopped

volumes:
  ssh-keys:
```

## Why `--privileged`?

rclone mount uses FUSE to mount the SFTP filesystem. Inside Docker, FUSE requires elevated privileges. You have two options:

```bash
# Option 1: Privileged mode (simple)
docker run --privileged ...

# Option 2: Minimal capabilities (more secure)
docker run --device /dev/fuse --cap-add SYS_ADMIN --security-opt apparmor:unconfined ...
```

## Architecture

```
┌─────────────────────────────────────────────────┐
│                  Docker Container                │
│                                                  │
│  ┌──────────┐    FUSE     ┌──────────────────┐  │
│  │  rclone   │──────────▶│  /mnt/sftp/       │  │
│  │  (daemon) │            │  (SFTP mounted)   │  │
│  └──────────┘            └────────┬──────────┘  │
│                                    │ ln -s       │
│                                    ▼             │
│  ┌──────────┐            ┌──────────────────┐   │
│  │  Caddy    │◀──────────│  /srv/web/        │  │
│  │  (:80)    │  serves   │  (web root)       │  │
│  └──────────┘            └──────────────────┘   │
│       │                                          │
└───────┼──────────────────────────────────────────┘
        │ :80 / :443
        ▼
    Browser
```

## License

MIT
