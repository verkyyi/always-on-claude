#!/bin/bash
# install-macmini-nginx.sh — Serve the shared public directory on the tailnet.
#
# Runs nginx as a root LaunchDaemon and binds directly to the host's Tailscale
# IPs on 443. This keeps the custom domain and the default tailnet hostname on
# the same nginx instance with separate certificates.

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
HTTP_LISTEN_HOST="${AOC_NGINX_HTTP_LISTEN_HOST:-127.0.0.1}"
HTTP_PORT="${AOC_NGINX_HTTP_PORT:-18080}"
TLS_CERT_DIR="${AOC_NGINX_TLS_CERT_DIR:-$STATE_DIR/certs}"
ENABLE_TAILNET_TLS="${AOC_ENABLE_TAILNET_TLS:-1}"
CUSTOM_TLS_CERT="${AOC_CUSTOM_TLS_CERT:-$TLS_CERT_DIR/fullchain.pem}"
CUSTOM_TLS_KEY="${AOC_CUSTOM_TLS_KEY:-$TLS_CERT_DIR/key.pem}"
CUSTOM_TLS_SERVER_NAMES="${AOC_CUSTOM_TLS_SERVER_NAMES:-}"
LABEL="com.always-on-claude.nginx"
PLIST="/Library/LaunchDaemons/$LABEL.plist"
CONFIG="$STATE_DIR/nginx.conf"

[ -x "$BREW" ] || die "Homebrew not found at $BREW"
[ -x "$TAILSCALE" ] || die "tailscale CLI not found"
command -v jq >/dev/null 2>&1 || die "jq is required"
command -v curl >/dev/null 2>&1 || die "curl is required"
command -v openssl >/dev/null 2>&1 || die "openssl is required"
command -v sudo >/dev/null 2>&1 || die "sudo is required"

if ! sudo -n true >/dev/null 2>&1; then
    die "passwordless sudo is required to install the nginx LaunchDaemon"
fi

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

mkdir -p "$PUBLIC_DIR" "$STATE_DIR/logs" "$STATE_DIR/run" "$TLS_CERT_DIR"
if [ ! -f "$PUBLIC_DIR/index.html" ]; then
    printf '%s\n' '<!doctype html><title>always-on-claude</title><h1>always-on-claude</h1>' > "$PUBLIC_DIR/index.html"
fi

TS_FQDN="$("$TAILSCALE" status --json | jq -r '.Self.DNSName // ""' | sed 's/[.]$//')"
TS_IPV4="$("$TAILSCALE" ip -4 | head -1)"
TS_IPV6="$("$TAILSCALE" ip -6 | head -1)"
[ -n "$TS_FQDN" ] && [ "$TS_FQDN" != "null" ] || die "Could not determine Tailscale hostname"
[ -n "$TS_IPV4" ] || die "Could not determine Tailscale IPv4 address"

TAILNET_TLS_CERT="$TLS_CERT_DIR/$TS_FQDN.crt"
TAILNET_TLS_KEY="$TLS_CERT_DIR/$TS_FQDN.key"
PRIMARY_GROUP="$(id -gn)"

write_server_block() {
    local server_names="$1"
    local cert_file="$2"
    local key_file="$3"

    cat >> "$CONFIG" <<NGINX
    server {
        listen $TS_IPV4:443 ssl;
NGINX

    if [ -n "$TS_IPV6" ]; then
        cat >> "$CONFIG" <<NGINX
        listen [$TS_IPV6]:443 ssl;
NGINX
    fi

    cat >> "$CONFIG" <<NGINX
        http2 on;
        server_name $server_names;

        ssl_certificate     $cert_file;
        ssl_certificate_key $key_file;
        ssl_protocols       TLSv1.2 TLSv1.3;

        root $PUBLIC_DIR;
        index index.html;

        location / {
            try_files \$uri \$uri/ =404;
        }
    }
NGINX
}

tailnet_cert_needs_refresh() {
    [ ! -s "$TAILNET_TLS_CERT" ] || [ ! -s "$TAILNET_TLS_KEY" ] || ! openssl x509 -checkend 2592000 -noout -in "$TAILNET_TLS_CERT" >/dev/null 2>&1
}

infer_server_names_from_cert() {
    local cert_file="$1"
    local san subject names

    san="$(openssl x509 -in "$cert_file" -noout -ext subjectAltName 2>/dev/null || true)"
    names="$(printf '%s\n' "$san" | grep -oE 'DNS:[^,]+' | sed 's/^DNS://' | paste -sd' ' -)"
    if [ -n "$names" ]; then
        printf '%s\n' "$names"
        return 0
    fi

    subject="$(openssl x509 -in "$cert_file" -noout -subject 2>/dev/null || true)"
    subject="${subject#subject=}"
    subject="$(printf '%s\n' "$subject" | sed -n 's/.*CN[[:space:]]*=[[:space:]]*//p' | sed 's/[[:space:]]*$//')"
    [ -n "$subject" ] && printf '%s\n' "$subject"
}

if [ "$ENABLE_TAILNET_TLS" = "1" ]; then
    info "tailnet TLS"
    if tailnet_cert_needs_refresh; then
        "$TAILSCALE" cert --cert-file "$TAILNET_TLS_CERT" --key-file "$TAILNET_TLS_KEY" "$TS_FQDN" >/dev/null
        ok "Tailnet certificate ready for $TS_FQDN"
    else
        skip "Tailnet certificate still valid for $TS_FQDN"
    fi
fi

if [ -z "$CUSTOM_TLS_SERVER_NAMES" ] && [ -f "$CUSTOM_TLS_CERT" ] && [ -f "$CUSTOM_TLS_KEY" ]; then
    CUSTOM_TLS_SERVER_NAMES="$(infer_server_names_from_cert "$CUSTOM_TLS_CERT" || true)"
    [ -n "$CUSTOM_TLS_SERVER_NAMES" ] && ok "Detected custom TLS names: $CUSTOM_TLS_SERVER_NAMES"
fi

if [ -n "$CUSTOM_TLS_SERVER_NAMES" ]; then
    [ -f "$CUSTOM_TLS_CERT" ] || die "Custom TLS certificate not found at $CUSTOM_TLS_CERT"
    [ -f "$CUSTOM_TLS_KEY" ] || die "Custom TLS key not found at $CUSTOM_TLS_KEY"
fi

info "nginx config"
cat > "$CONFIG" <<NGINX
user $(id -un) $PRIMARY_GROUP;
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
        listen $HTTP_LISTEN_HOST:$HTTP_PORT;
        server_name localhost;

        root $PUBLIC_DIR;
        index index.html;

        location / {
            try_files \$uri \$uri/ =404;
        }
    }
NGINX

if [ -n "$CUSTOM_TLS_SERVER_NAMES" ]; then
    write_server_block "$CUSTOM_TLS_SERVER_NAMES" "$CUSTOM_TLS_CERT" "$CUSTOM_TLS_KEY"
fi

if [ "$ENABLE_TAILNET_TLS" = "1" ]; then
    write_server_block "$TS_FQDN" "$TAILNET_TLS_CERT" "$TAILNET_TLS_KEY"
fi

printf '}\n' >> "$CONFIG"

sudo "$NGINX_BIN" -t -c "$CONFIG" >/dev/null
ok "nginx config valid"

info "LaunchDaemon"
sudo tee "$PLIST" >/dev/null <<PLIST
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
sudo chmod 644 "$PLIST"
plutil -lint "$PLIST" >/dev/null

if sudo launchctl print "system/$LABEL" >/dev/null 2>&1; then
    sudo "$NGINX_BIN" -s reload -c "$CONFIG" >/dev/null
    sudo launchctl kickstart -k "system/$LABEL" >/dev/null 2>&1 || true
    ok "nginx LaunchDaemon reloaded"
else
    sudo launchctl bootstrap system "$PLIST"
    sudo launchctl enable "system/$LABEL" >/dev/null 2>&1 || true
    sudo launchctl kickstart -k "system/$LABEL" >/dev/null 2>&1 || true
    ok "nginx LaunchDaemon loaded"
fi

for _ in 1 2 3 4 5; do
    if curl -fsS "http://$HTTP_LISTEN_HOST:$HTTP_PORT/" >/dev/null 2>&1; then
        ok "nginx responding on http://$HTTP_LISTEN_HOST:$HTTP_PORT"
        break
    fi
    sleep 1
done

if ! curl -fsS "http://$HTTP_LISTEN_HOST:$HTTP_PORT/" >/dev/null 2>&1; then
    die "nginx did not become ready on http://$HTTP_LISTEN_HOST:$HTTP_PORT"
fi

if [ -n "$CUSTOM_TLS_SERVER_NAMES" ]; then
    first_custom_name="${CUSTOM_TLS_SERVER_NAMES%% *}"
    if curl -kfsS --resolve "$first_custom_name:443:$TS_IPV4" "https://$first_custom_name/" >/dev/null 2>&1; then
        ok "custom TLS responding on https://$first_custom_name/"
    else
        die "custom TLS did not become ready on https://$first_custom_name/"
    fi
fi

if [ "$ENABLE_TAILNET_TLS" = "1" ]; then
    if curl -kfsS --resolve "$TS_FQDN:443:$TS_IPV4" "https://$TS_FQDN/" >/dev/null 2>&1; then
        ok "tailnet TLS responding on https://$TS_FQDN/"
    else
        die "tailnet TLS did not become ready on https://$TS_FQDN/"
    fi
fi

if "$TAILSCALE" serve status --json 2>/dev/null | jq -e 'length > 0' >/dev/null 2>&1; then
    info "Tailscale Serve"
    skip "Serve config left unchanged; nginx is bound directly on Tailscale 443"
fi
