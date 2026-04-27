#!/bin/bash
set -e

# ============================================================================
#  sftp-web entrypoint
#  Mounts a remote SFTP directory via rclone and serves it with Caddy
# ============================================================================

SSH_DIR="/root/.ssh"
GENERATED_KEY_DIR="/keys"
USER_KEY_DIR="/user-key"
MOUNT_POINT="/mnt/sftp"
WEB_ROOT="/srv/web"
CADDY_CONFIG_DIR="/etc/caddy"
DEFAULT_CADDYFILE_DIR="/data/caddyfile"
RCLONE_CONFIG="/root/.config/rclone/rclone.conf"

# Ensure base directories exist
mkdir -p "$SSH_DIR" "$MOUNT_POINT" "$(dirname "$RCLONE_CONFIG")"
chmod 700 "$SSH_DIR"

# ============================================================================
#  Step 1: SSH Key Management
# ============================================================================

USER_KEY_PROVIDED=false

# Check if user mounted a private key
if [ -n "$(ls -A "$USER_KEY_DIR" 2>/dev/null)" ]; then
    # Find the first key file in the user-key directory
    USER_KEY=$(find "$USER_KEY_DIR" -maxdepth 1 -type f | head -1)

    if [ -n "$USER_KEY" ]; then
        USER_KEY_PROVIDED=true

        # Symlink user key into the SSH working directory (never mount directly to .ssh)
        ln -sfn "$USER_KEY" "$SSH_DIR/id_rsa"
        chmod 600 "$SSH_DIR/id_rsa"

        echo "══════════════════════════════════════════════════════════════"
        echo "  SSH Key: User-provided key detected"
        echo "  Source:  $USER_KEY"
        echo "  Using user-provided private key for SFTP connection."
        echo "══════════════════════════════════════════════════════════════"

        # Try to derive and display the public key
        if PUB_KEY=$(ssh-keygen -y -f "$SSH_DIR/id_rsa" 2>/dev/null); then
            echo "  Public key:"
            echo "  $PUB_KEY"
            echo "══════════════════════════════════════════════════════════════"
        fi
    fi
fi

# If user didn't provide a key, manage the built-in key pair
if [ "$USER_KEY_PROVIDED" = false ]; then
    if [ -f "$GENERATED_KEY_DIR/id_rsa" ]; then
        echo "══════════════════════════════════════════════════════════════"
        echo "  SSH Key: Using previously generated key pair"
        echo "══════════════════════════════════════════════════════════════"
    else
        echo "══════════════════════════════════════════════════════════════"
        echo "  SSH Key: No key found. Generating new Ed25519 key pair..."
        echo "══════════════════════════════════════════════════════════════"
        ssh-keygen -t ed25519 -f "$GENERATED_KEY_DIR/id_rsa" -N "" -q
    fi

    # Symlink generated key into SSH working directory
    ln -sfn "$GENERATED_KEY_DIR/id_rsa" "$SSH_DIR/id_rsa"
    chmod 600 "$SSH_DIR/id_rsa"

    echo "  Public key (add this to your SFTP server's authorized_keys):"
    echo ""
    cat "$GENERATED_KEY_DIR/id_rsa.pub"
    echo ""
    echo "══════════════════════════════════════════════════════════════"
fi

# ============================================================================
#  Step 2: rclone SFTP Configuration
# ============================================================================

# Validate required environment variables
if [ -z "$SFTP_HOST" ]; then
    echo "ERROR: SFTP_HOST environment variable is required."
    exit 1
fi
if [ -z "$SFTP_USER" ]; then
    echo "ERROR: SFTP_USER environment variable is required."
    exit 1
fi

SFTP_PORT="${SFTP_PORT:-22}"
SFTP_PASS="${SFTP_PASS:-}"
SFTP_REMOTE_WEB_FOLDER="${SFTP_REMOTE_WEB_FOLDER:-/}"
SFTP_REMOTE_CADDYFILE="${SFTP_REMOTE_CADDYFILE:-}"

# Write rclone base config
cat > "$RCLONE_CONFIG" <<EOF
[sftp]
type = sftp
host = ${SFTP_HOST}
port = ${SFTP_PORT}
user = ${SFTP_USER}
known_hosts_file = /dev/null
EOF

# Authentication priority:
#   1. User-mounted private key (highest)
#   2. Password (when no user key provided)
#   3. Auto-generated key (when no user key and no password)
if [ "$USER_KEY_PROVIDED" = true ]; then
    echo "key_file = ${SSH_DIR}/id_rsa" >> "$RCLONE_CONFIG"
    echo "==> Auth: Using user-provided SSH key."
elif [ -n "$SFTP_PASS" ]; then
    OBSCURED_PASS=$(rclone obscure "$SFTP_PASS")
    echo "pass = ${OBSCURED_PASS}" >> "$RCLONE_CONFIG"
    echo "==> Auth: Using password."
    echo "    Tip: You can switch to key-based auth by adding the public key above to your SFTP server."
else
    echo "key_file = ${SSH_DIR}/id_rsa" >> "$RCLONE_CONFIG"
    echo "==> Auth: Using auto-generated SSH key."
    echo "    Make sure the public key above has been added to your SFTP server's authorized_keys."
fi

# ============================================================================
#  Step 3: Mount SFTP via rclone
# ============================================================================

echo "==> Mounting SFTP ${SFTP_USER}@${SFTP_HOST}:${SFTP_PORT} to ${MOUNT_POINT} ..."

rclone mount sftp: "$MOUNT_POINT" \
    --daemon \
    --allow-other \
    --allow-non-empty \
    --vfs-cache-mode full \
    --vfs-read-ahead 128M \
    --dir-cache-time 5m \
    --poll-interval 10s \
    --attr-timeout 1s \
    --no-modtime

# Wait for the mount to become available
echo "==> Waiting for SFTP mount to be ready..."
MOUNT_READY=false
for i in $(seq 1 30); do
    if mountpoint -q "$MOUNT_POINT" 2>/dev/null; then
        MOUNT_READY=true
        break
    fi
    sleep 1
done

if [ "$MOUNT_READY" = false ]; then
    echo "ERROR: SFTP mount failed or timed out after 30 seconds."
    echo "       Please check your SFTP credentials and connectivity."
    # Try to capture rclone log for debugging
    if [ -f /tmp/rclone.log ]; then
        echo "--- rclone log ---"
        tail -20 /tmp/rclone.log
    fi
    exit 1
fi

echo "==> SFTP mounted successfully."

# ============================================================================
#  Step 4: Setup Web Root (symlink SFTP folder to Caddy web root)
# ============================================================================

# Remove existing web root (may be a dir or old symlink)
rm -rf "$WEB_ROOT"

SFTP_WEB_PATH="${MOUNT_POINT}${SFTP_REMOTE_WEB_FOLDER}"

if [ -d "$SFTP_WEB_PATH" ]; then
    ln -sfn "$SFTP_WEB_PATH" "$WEB_ROOT"
    echo "==> Web root: ${SFTP_REMOTE_WEB_FOLDER} -> ${WEB_ROOT}"
else
    echo "WARNING: SFTP_REMOTE_WEB_FOLDER '${SFTP_REMOTE_WEB_FOLDER}' not found on remote."
    echo "         Falling back to SFTP mount root '/'."
    ln -sfn "$MOUNT_POINT" "$WEB_ROOT"
fi

# ============================================================================
#  Step 5: Setup Caddyfile Configuration
# ============================================================================

# Remove any previous caddy config link/dir
rm -rf "$CADDY_CONFIG_DIR"

if [ -n "$SFTP_REMOTE_CADDYFILE" ]; then
    # User specified a remote Caddyfile path on the SFTP server
    REMOTE_CADDY_PATH="${MOUNT_POINT}${SFTP_REMOTE_CADDYFILE}"

    if [ -d "$REMOTE_CADDY_PATH" ] && [ -f "${REMOTE_CADDY_PATH}/Caddyfile" ]; then
        # It's a folder containing a Caddyfile -> symlink the folder
        ln -sfn "$REMOTE_CADDY_PATH" "$CADDY_CONFIG_DIR"
        echo "==> Caddyfile: Using remote directory ${SFTP_REMOTE_CADDYFILE}"
    elif [ -f "$REMOTE_CADDY_PATH" ]; then
        # It's a single file -> create config dir and symlink the file
        mkdir -p "$CADDY_CONFIG_DIR"
        ln -sfn "$REMOTE_CADDY_PATH" "$CADDY_CONFIG_DIR/Caddyfile"
        echo "==> Caddyfile: Using remote file ${SFTP_REMOTE_CADDYFILE}"
    else
        echo "WARNING: SFTP_REMOTE_CADDYFILE '${SFTP_REMOTE_CADDYFILE}' not found on remote."
        echo "         Falling back to default Caddyfile."
        ln -sfn "$DEFAULT_CADDYFILE_DIR" "$CADDY_CONFIG_DIR"
    fi
else
    # No remote Caddyfile specified -> use built-in default
    # (user can override the built-in by mounting to /data/caddyfile/)
    ln -sfn "$DEFAULT_CADDYFILE_DIR" "$CADDY_CONFIG_DIR"
    echo "==> Caddyfile: Using default (SPA mode). Mount to /data/caddyfile/ to override."
fi

# ============================================================================
#  Step 6: Start Caddy
# ============================================================================

echo ""
echo "══════════════════════════════════════════════════════════════"
echo "  sftp-web is ready!"
echo "  SFTP:    ${SFTP_USER}@${SFTP_HOST}:${SFTP_PORT}"
echo "  Serving: ${SFTP_REMOTE_WEB_FOLDER}"
echo "  Caddy:   http://0.0.0.0:80"
echo "══════════════════════════════════════════════════════════════"
echo ""

exec caddy run --config /etc/caddy/Caddyfile --adapter caddyfile
