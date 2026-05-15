#!/usr/bin/env bash
# milou-backend installer.
#
# Run via curl|bash:
#
#   bash <(curl -fsSL https://raw.githubusercontent.com/FelixN1l/milou/main/install.sh)
#
# Or with a pinned version:
#
#   MILOU_VERSION=v0.1.0 bash <(curl -fsSL https://raw.githubusercontent.com/FelixN1l/milou/main/install.sh)
#
# Sister script `milou.sh` is in the same repo; the installer drops it
# into /usr/bin/milou as the management wrapper (same pattern as soga's
# /usr/bin/soga). After install, the daemon is set up but NOT started —
# run `milou init` to fill in panel keys interactively, then `milou start`.

set -euo pipefail

# --- knobs ----------------------------------------------------------------
: "${MILOU_REPO:=FelixN1l/milou}"       # public repo holding releases + scripts
: "${MILOU_VERSION:=}"                  # empty → resolve latest tag
: "${MILOU_PREFIX:=/usr/local/milou}"   # binary install dir
: "${MILOU_CONFDIR:=/etc/milou}"        # config dir
: "${MILOU_VARDIR:=/var/lib/milou}"     # state/work dir

# --- ANSI -----------------------------------------------------------------
if [[ -t 1 ]]; then
    R='\033[0;31m'; G='\033[0;32m'; Y='\033[0;33m'; N='\033[0m'
else
    R=''; G=''; Y=''; N=''
fi
red()    { printf "${R}%s${N}\n" "$*"; }
green()  { printf "${G}%s${N}\n" "$*"; }
yellow() { printf "${Y}%s${N}\n" "$*"; }

[[ $EUID -eq 0 ]] || { red "must run as root"; exit 1; }

# --- arch detect ----------------------------------------------------------
case "$(uname -m)" in
    x86_64|amd64) ARCH=amd64 ;;
    aarch64|arm64) ARCH=arm64 ;;
    *) red "unsupported arch $(uname -m)"; exit 1 ;;
esac
green ">> arch: $ARCH"

# --- 1. runtime prerequisites --------------------------------------------
# acme.sh's cron job lives in cron; openssl is used by milou cert status.
green ">> installing apt prerequisites"
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq ca-certificates openssl curl cron tar

# --- 2. acme.sh ----------------------------------------------------------
# Same pattern as soga/install.sh: installs acme.sh on first run so cert
# issuance / renewal works out of the box. Subsequent runs leave it alone.
if [[ ! -f "$HOME/.acme.sh/acme.sh" ]]; then
    green ">> installing acme.sh"
    curl -fsSL https://get.acme.sh | sh >/tmp/acme-install.log 2>&1 || {
        red "acme.sh install failed — see /tmp/acme-install.log"; tail -20 /tmp/acme-install.log; exit 1
    }
    "$HOME/.acme.sh/acme.sh" --set-default-ca --server letsencrypt >/dev/null 2>&1 || true
fi

# --- 3. resolve version + download tarball -------------------------------
if [[ -z "$MILOU_VERSION" ]]; then
    green ">> resolving latest release of $MILOU_REPO"
    # Capture the response in one shot, THEN parse. Doing
    #   curl ... | grep -m1 ...
    # under `set -o pipefail` is fragile: grep -m1 closes the pipe after
    # the first match, curl gets SIGPIPE, exits 23, and the whole script
    # fails. Read the body fully, then parse from a string.
    RESP=$(curl -fsSL "https://api.github.com/repos/${MILOU_REPO}/releases/latest") || {
        red "could not reach GitHub API for $MILOU_REPO"; exit 1
    }
    MILOU_VERSION=$(printf '%s\n' "$RESP" | grep -m1 '"tag_name"' | sed -E 's/.*"tag_name":[[:space:]]*"([^"]+)".*/\1/')
    [[ -n "$MILOU_VERSION" ]] || { red "could not resolve latest tag — pass MILOU_VERSION=vX.Y.Z"; exit 1; }
fi
green ">> version: $MILOU_VERSION"

BASE="https://github.com/${MILOU_REPO}/releases/download/${MILOU_VERSION}"
TAR="milou-${MILOU_VERSION}-linux-${ARCH}.tar.gz"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
cd "$TMP"

green ">> downloading $TAR"
curl -fsSL -o "$TAR"     "${BASE}/${TAR}"
curl -fsSL -o SHA256SUMS "${BASE}/SHA256SUMS"

green ">> verifying checksum"
# sha256sum has two output styles depending on text/binary mode and host:
#   linux (default):   <hash>  <filename>
#   binary mode (-b)   <hash> *<filename>     # leading asterisk on the name
# Strip the optional leading `*` so either form matches.
EXPECTED=$(awk -v f="$TAR" '{ sub(/^\*/,"",$2); if ($2==f) { print $1; exit } }' SHA256SUMS)
[[ -n "$EXPECTED" ]] || { red "no entry for $TAR in SHA256SUMS"; exit 1; }
ACTUAL=$(sha256sum "$TAR" | awk '{print $1}')
[[ "$ACTUAL" == "$EXPECTED" ]] || { red "checksum mismatch: expected $EXPECTED got $ACTUAL"; exit 1; }

green ">> extracting"
tar xzf "$TAR"
EXTRACTED="milou-${MILOU_VERSION}-linux-${ARCH}"
[[ -d "$EXTRACTED" ]] || { red "tarball layout unexpected — no $EXTRACTED/ inside"; exit 1; }
cd "$EXTRACTED"

# --- 4. layout -----------------------------------------------------------
green ">> laying out $MILOU_PREFIX $MILOU_CONFDIR $MILOU_VARDIR"
install -d -m 0755 "$MILOU_PREFIX" "$MILOU_CONFDIR" "$MILOU_VARDIR/caddy"
install -m 0755 milou "$MILOU_PREFIX/milou"
install -m 0755 caddy "$MILOU_PREFIX/caddy"
install -m 0644 scripts/milou.conf.default "$MILOU_PREFIX/milou.conf.default"

if [[ ! -f "$MILOU_CONFDIR/milou.conf" ]]; then
    install -m 0640 scripts/milou.conf.default "$MILOU_CONFDIR/milou.conf"
    yellow ">> wrote default $MILOU_CONFDIR/milou.conf — run 'milou init' to fill it in"
else
    yellow ">> kept existing $MILOU_CONFDIR/milou.conf"
fi

# --- 4a. geosite.dat / geoip.dat ----------------------------------------
# Same Loyalsoldier release used by sing-box's geosite/geoip rule families.
# Re-download when missing OR >30 days old. Failures are soft — only
# blocklist rules that reference those data files stop firing.
GEOSITE_URL=https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geosite.dat
GEOIP_URL=https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geoip.dat
fetch_dat() {
    local url=$1 dest=$2 name=$3
    if [[ -f "$dest" ]] && [[ $(( $(date +%s) - $(stat -c %Y "$dest") )) -lt 2592000 ]]; then
        yellow ">> kept existing $dest (refreshed within 30 days)"
        return 0
    fi
    green ">> downloading $name → $dest"
    if curl -fsSL --connect-timeout 10 --max-time 120 -o "$dest.new" "$url"; then
        mv "$dest.new" "$dest"; chmod 0644 "$dest"
    else
        rm -f "$dest.new"
        yellow ">> $name download failed — geosite:/geoip: rules will be skipped at runtime"
    fi
}
fetch_dat "$GEOSITE_URL" "$MILOU_CONFDIR/geosite.dat" geosite.dat
fetch_dat "$GEOIP_URL"   "$MILOU_CONFDIR/geoip.dat"   geoip.dat

# --- 5. management wrapper + systemd ------------------------------------
install -m 0755 scripts/milou.sh        /usr/bin/milou
install -m 0644 scripts/milou.service   /etc/systemd/system/milou.service
install -m 0644 scripts/milou@.service  /etc/systemd/system/milou@.service
systemctl daemon-reload
systemctl enable milou.service >/dev/null 2>&1 || true

# --- 6. summary ---------------------------------------------------------
green ""
green "==== milou-backend $MILOU_VERSION installed ===="
green "  binary       : $MILOU_PREFIX/milou"
green "  caddy        : $MILOU_PREFIX/caddy"
green "  config       : $MILOU_CONFDIR/milou.conf"
green "  data dir     : $MILOU_VARDIR/caddy"
green "  systemd unit : /etc/systemd/system/milou.service (enabled, not started)"
green "  template     : /etc/systemd/system/milou@.service  (for extra instances)"
green "  manage cmd   : milou [start|stop|restart|status|log|init|config|cert|version]"
yellow ""
yellow "Next: run 'milou init' to fill in node_id / webapi_url / webapi_key / cert_domain,"
yellow "      then 'milou cert issue' (if cert_mode=http or dns), then 'milou start'."
yellow ""
yellow "Multi-instance: drop $MILOU_CONFDIR/<name>.conf and"
yellow "  systemctl enable --now milou@<name>.service"
