#!/bin/bash
# install-macmini-nginx.sh — Serve the shared public directory on the tailnet.
#
# Runs nginx as a user LaunchAgent on localhost, then publishes it to the
# tailnet with Tailscale Serve. This avoids privileged port binding on macOS
# and leaves Tailscale SSH/sshd untouched.

set -euo pipefail

info() { printf '\n=== %s ===\n' "$*"; }
ok() { printf '  OK: %s\n' "$*"; }
skip() { printf '  SKIP: %s\n' "$*"; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

HOME_DIR="${AOC_HOME:-$HOME}"
BREW="${AOC_BREW:-/opt/homebrew/bin/brew}"
TAILSCALE="${AOC_TAILSCALE:-/Applications/Tailscale.app/Contents/MacOS/Tailscale}"
if [ ! -x "$TAILSCALE" ] && command -v tailscale >/dev/null 2>&1; then
    TAILSCALE="$(command -v tailscale)"
fi

PUBLIC_DIR="${AOC_PUBLIC_DIR:-$HOME_DIR/aoc-data/public}"
STATE_DIR="${AOC_NGINX_STATE_DIR:-$HOME_DIR/.always-on-claude/nginx}"
LISTEN_HOST="${AOC_NGINX_LISTEN_HOST:-127.0.0.1}"
LISTEN_PORT="${AOC_NGINX_PORT:-18080}"
LABEL="com.always-on-claude.nginx"
PLIST="$HOME_DIR/Library/LaunchAgents/$LABEL.plist"
CONFIG="$STATE_DIR/nginx.conf"

[ -x "$BREW" ] || die "Homebrew not found at $BREW"
[ -x "$TAILSCALE" ] || die "tailscale CLI not found"
command -v jq >/dev/null 2>&1 || die "jq is required"
command -v curl >/dev/null 2>&1 || die "curl is required"

info "nginx"
if ! "$BREW" list nginx >/dev/null 2>&1; then
    "$BREW" install nginx
    ok "Installed nginx"
else
    skip "nginx already installed"
fi

NGINX_BIN="$("$BREW" --prefix nginx)/bin/nginx"
MIME_TYPES="$("$BREW" --prefix)/etc/nginx/mime.types"
[ -x "$NGINX_BIN" ] || die "nginx binary not found at $NGINX_BIN"
[ -f "$MIME_TYPES" ] || die "mime.types not found at $MIME_TYPES"

mkdir -p "$PUBLIC_DIR" "$STATE_DIR/logs" "$STATE_DIR/run" "$HOME_DIR/Library/LaunchAgents"
if [ ! -f "$PUBLIC_DIR/index.html" ]; then
    printf '%s\n' '<!doctype html><title>always-on-claude</title><h1>always-on-claude</h1>' > "$PUBLIC_DIR/index.html"
fi

TS_FQDN="$("$TAILSCALE" status --json | jq -r '.Self.DNSName // ""' | sed 's/[.]$//')"
TS_IP="$("$TAILSCALE" ip -4 | head -1)"
[ -n "$TS_FQDN" ] && [ "$TS_FQDN" != "null" ] || die "Could not determine Tailscale hostname"
[ -n "$TS_IP" ] || die "Could not determine Tailscale IPv4 address"

info "nginx config"
cat > "$CONFIG" <<NGINX
worker_processes 1;
error_log $STATE_DIR/logs/error.log warn;
pid $STATE_DIR/run/nginx.pid;

events {
    worker_connections 256;
}

http {
    include $MIME_TYPES;
    default_type application/octet-stream;

    access_log $STATE_DIR/logs/access.log;
    sendfile on;
    keepalive_timeout 65;
    server_tokens off;

    server {
        listen $LISTEN_HOST:$LISTEN_PORT;
        server_name $TS_FQDN localhost;

        root $PUBLIC_DIR;
        index index.html;

        location / {
            try_files \$uri \$uri/ =404;
        }
    }
}
NGINX

"$NGINX_BIN" -t -c "$CONFIG" >/dev/null
ok "nginx config valid"

info "LaunchAgent"
cat > "$PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>$LABEL</string>
  <key>ProgramArguments</key>
  <array>
    <string>$NGINX_BIN</string>
    <string>-c</string>
    <string>$CONFIG</string>
    <string>-g</string>
    <string>daemon off;</string>
  </array>
  <key>RunAtLoad</key>
  <true/>
  <key>KeepAlive</key>
  <true/>
  <key>StandardOutPath</key>
  <string>$STATE_DIR/logs/launchd.log</string>
  <key>StandardErrorPath</key>
  <string>$STATE_DIR/logs/launchd.log</string>
</dict>
</plist>
PLIST
chmod 644 "$PLIST"
plutil -lint "$PLIST" >/dev/null

launchctl unload "$PLIST" >/dev/null 2>&1 || true
launchctl load -w "$PLIST"
launchctl kickstart -k "gui/$(id -u)/$LABEL" >/dev/null 2>&1 || launchctl start "$LABEL" >/dev/null 2>&1 || true
ok "nginx LaunchAgent loaded"

for _ in 1 2 3 4 5; do
    if curl -fsS "http://$LISTEN_HOST:$LISTEN_PORT/" >/dev/null 2>&1; then
        ok "nginx responding on http://$LISTEN_HOST:$LISTEN_PORT"
        break
    fi
    sleep 1
done

if ! curl -fsS "http://$LISTEN_HOST:$LISTEN_PORT/" >/dev/null 2>&1; then
    die "nginx did not become ready on http://$LISTEN_HOST:$LISTEN_PORT"
fi

info "Tailscale Serve"
if [ "${AOC_CONFIGURE_TAILSCALE_SERVE:-1}" = "1" ]; then
    "$TAILSCALE" serve --bg --yes "http://$LISTEN_HOST:$LISTEN_PORT" >/dev/null
    ok "Tailnet URL: https://$TS_FQDN/"
else
    skip "Tailscale Serve configuration disabled"
fi
