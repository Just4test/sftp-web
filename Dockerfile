FROM alpine:3.20

RUN apk add --no-cache \
    rclone \
    caddy \
    openssh-client \
    fuse3 \
    bash \
    coreutils \
    && echo "user_allow_other" >> /etc/fuse.conf

# Directory structure:
#   /user-key/          - Mount point: user SSH private key (read-only recommended)
#   /data/caddyfile/    - Mount point: user Caddyfile override (replaces built-in)
#   /keys/              - Volume: auto-generated SSH key pair (persist across restarts)
#   /mnt/sftp/          - Internal: rclone SFTP mount point
#   /srv/web/           - Internal: Caddy web root (symlinked from SFTP)
#   /root/.ssh/         - Internal: SSH working directory (symlinked, never mount here)
RUN mkdir -p \
    /user-key \
    /data/caddyfile \
    /keys \
    /srv/web \
    /mnt/sftp \
    /root/.ssh \
    /root/.config/rclone

# Copy default SPA-ready Caddyfile
COPY Caddyfile /data/caddyfile/Caddyfile

# Copy entrypoint
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

EXPOSE 80 443

# /keys volume persists auto-generated SSH keys across container restarts
VOLUME ["/keys"]

ENTRYPOINT ["/entrypoint.sh"]
