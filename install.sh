#!/usr/bin/env bash
# Production install script — runs from inside an extracted release
# tarball. Assumes `milou` and `caddy` binaries are sitting in the same
# directory as this script. For dev / source builds, see
# install-from-source.sh (kept alongside this file).
#
# Layout produced:
#   /usr/local/milou/milou               — daemon binary
#   /usr/local/milou/caddy               — data-plane binary
#   /usr/bin/milou                       — management wrapper
#   /etc/milou/milou.conf                — config (template if missing)
#   /etc/systemd/system/milou.service    — systemd unit
#   /var/lib/milou/caddy/                — caddy work dir
#
# Side effects:
#   - apt install: ca-certificates, openssl, cron (acme.sh's cron host)
#   - acme.sh installed under ~/.acme.sh if absent
#   - systemd unit enabled (but NOT started — operator must fill in
#     node_id / webapi_url / webapi_key / cert_domain first)

set -euo pipefail

red()    { printf "\033[0;31m%s\033[0m\n" "$*"; }
green()  { printf "\033[0;32m%s\033[0m\n" "$*"; }
yellow() { printf "\033[0;33m%s\033[0m\n" "$*"; }

[[ $EUID -eq 0 ]] || { red "must run as root"; exit 1; }

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
[[ -x "$SCRIPT_DIR/milou" && -x "$SCRIPT_DIR/caddy" ]] || {
    red "expected milou + caddy binaries next to install.sh — for a"
    red "from-source build use scripts/dist/install-from-source.sh"
    exit 1
}

# --- 1. apt deps --------------------------------------------------------
green ">> installing runtime prerequisites (apt)"
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq ca-certificates openssl curl cron

# --- 2. acme.sh ---------------------------------------------------------
# Identical to vaxilu/soga's install.sh: leaves the cron job in place so
# automatic renewals fire. milou's daemon issues the initial cert via
# acme.sh on first start when cert_mode != manual.
if [[ ! -f "$HOME/.acme.sh/acme.sh" ]]; then
    green ">> installing acme.sh"
    curl -fsSL https://get.acme.sh | sh >/tmp/acme-install.log 2>&1 || {
        red "acme.sh install failed — see /tmp/acme-install.log"
        tail -20 /tmp/acme-install.log
        exit 1
    }
    "$HOME/.acme.sh/acme.sh" --set-default-ca --server letsencrypt >/dev/null 2>&1 || true
fi

# --- 3. layout ----------------------------------------------------------
green ">> laying out /usr/local/milou /etc/milou /var/lib/milou"
install -d -m 0755 /usr/local/milou /etc/milou /var/lib/milou/caddy
install -m 0755 "$SCRIPT_DIR/milou" /usr/local/milou/milou
install -m 0755 "$SCRIPT_DIR/caddy" /usr/local/milou/caddy

# Static fake-website content (a looking-glass facsimile) for caddy's
# file_server to serve when probes hit the naive node without the secret
# URL. The path is referenced by milou.conf.default's naive_fake_server=
# setting. We overwrite on every install so style updates ship cleanly;
# operators who've customised should mount their own dir and point
# naive_fake_server= elsewhere.
if [[ -d "$SCRIPT_DIR/fakeweb" ]]; then
    install -d -m 0755 /usr/local/milou/fakeweb
    cp -r "$SCRIPT_DIR/fakeweb/." /usr/local/milou/fakeweb/
    find /usr/local/milou/fakeweb -type f -exec chmod 0644 {} +
    find /usr/local/milou/fakeweb -type d -exec chmod 0755 {} +
    green ">> installed fakeweb cover pages to /usr/local/milou/fakeweb"
fi

if [[ ! -f /etc/milou/milou.conf ]]; then
    install -m 0640 "$SCRIPT_DIR/scripts/milou.conf.default" /etc/milou/milou.conf
    yellow ">> wrote default /etc/milou/milou.conf — edit before starting"
else
    yellow ">> kept existing /etc/milou/milou.conf"
fi

# Seed an empty blockList so milou.conf's default `block_list_file=
# /etc/milou/blockList` setting resolves to a real (empty + commented)
# file out of the box. Operators editing the file later get mtime
# hot-reload within 10s. Keep existing content untouched on upgrade.
if [[ ! -f /etc/milou/blockList ]]; then
    install -m 0644 "$SCRIPT_DIR/scripts/blockList.default" /etc/milou/blockList
    yellow ">> wrote default /etc/milou/blockList (empty rule set — edit to add rules)"
else
    yellow ">> kept existing /etc/milou/blockList"
fi

# --- 3a. geosite.dat / geoip.dat ----------------------------------------
# Used by the blocklist's `geosite:<cat>` and `geoip:<cc>` rule types
# (e.g. `geosite:category-ads-all`, `geoip:cn`). The Loyalsoldier release
# is the canonical fork — broader category coverage than v2fly's own
# dat and faster updates.
#
# Re-downloads when the file is missing OR older than 30 days, so a
# routine `bash install.sh` upgrade also refreshes stale routing data.
# Failures are non-fatal — the dat files are optional, only blocklist
# rules that reference them stop firing.
GEOSITE_URL=https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geosite.dat
GEOIP_URL=https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geoip.dat
fetch_dat() {
    local url=$1 dest=$2 name=$3
    if [[ -f "$dest" ]] && [[ $(( $(date +%s) - $(stat -c %Y "$dest") )) -lt 2592000 ]]; then
        yellow ">> kept existing $dest (refreshed within 30 days)"
        return 0
    fi
    green ">> downloading $name -> $dest"
    if curl -fsSL --connect-timeout 10 --max-time 120 -o "$dest.new" "$url"; then
        mv "$dest.new" "$dest"
        chmod 0644 "$dest"
    else
        rm -f "$dest.new"
        yellow ">> $name download failed — geosite:/geoip: rules will be skipped at runtime"
    fi
}
fetch_dat "$GEOSITE_URL" /etc/milou/geosite.dat "geosite.dat"
fetch_dat "$GEOIP_URL"   /etc/milou/geoip.dat   "geoip.dat"

# --- 4. management wrapper + systemd ------------------------------------
install -m 0755 "$SCRIPT_DIR/scripts/milou.sh" /usr/bin/milou
install -m 0644 "$SCRIPT_DIR/scripts/milou.service"  /etc/systemd/system/milou.service
# Template unit for additional instances; resolves milou@<name> to
# /etc/milou/<name>.conf. The default `milou.service` keeps owning
# /etc/milou/milou.conf so single-node operators see no change.
install -m 0644 "$SCRIPT_DIR/scripts/milou@.service" /etc/systemd/system/milou@.service
systemctl daemon-reload
systemctl enable milou.service >/dev/null 2>&1 || true

# --- 5. summary ---------------------------------------------------------
green ""
green "==== milou-backend installed ===="
green "  binary       : /usr/local/milou/milou"
green "  caddy        : /usr/local/milou/caddy"
green "  config       : /etc/milou/milou.conf"
green "  data dir     : /var/lib/milou/caddy"
green "  systemd unit : /etc/systemd/system/milou.service (enabled, not started)"
green "  template     : /etc/systemd/system/milou@.service  (for extra instances)"
green "  manage cmd   : milou [start|stop|restart|status|log|config|cert|version]"
yellow ""
yellow "Edit /etc/milou/milou.conf to fill node_id, webapi_url, webapi_key,"
yellow "cert_domain (and DNS_* keys for cert_mode=dns) — then 'milou start'."
yellow ""
yellow "Multi-instance: drop /etc/milou/<name>.conf and run"
yellow "  systemctl enable --now milou@<name>.service"
yellow "Each instance binds to its own listen= IP from its own conf."
