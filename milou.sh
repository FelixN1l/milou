#!/usr/bin/env bash
# /usr/bin/milou — management wrapper modeled on vaxilu/soga's `soga` cmd.
#
# Subcommands: start | stop | restart | enable | disable | status | log
#              config | version | update | uninstall | install
#
# All actions are systemd-driven; the daemon (which spawns caddy as a child)
# is a single unit `milou.service`.

set -euo pipefail

# --- knobs ------------------------------------------------------------------
SVC=milou.service
BIN=/usr/local/milou/milou
CADDY=/usr/local/milou/caddy
CONF=/etc/milou/milou.conf
UNIT=/etc/systemd/system/$SVC
SRC=/usr/local/src/milou-backend
EDITOR_DEFAULT=${EDITOR:-nano}

# --- ANSI ------------------------------------------------------------------
if [[ -t 1 ]]; then
    R='\033[0;31m'; G='\033[0;32m'; Y='\033[0;33m'; B='\033[0;34m'; N='\033[0m'
else
    R=''; G=''; Y=''; B=''; N=''
fi
red()    { printf "${R}%s${N}\n" "$*"; }
green()  { printf "${G}%s${N}\n" "$*"; }
yellow() { printf "${Y}%s${N}\n" "$*"; }

[[ $EUID -eq 0 ]] || { red "must run as root"; exit 1; }

# --- helpers ---------------------------------------------------------------
svc_running() { systemctl is-active --quiet "$SVC"; }
svc_enabled() { systemctl is-enabled --quiet "$SVC" 2>/dev/null; }

cmd_start() {
    systemctl start "$SVC"
    sleep 1
    if svc_running; then
        green "milou started"
    else
        red "milou failed to start — run 'milou log' to inspect"
        systemctl status --no-pager -l "$SVC" | tail -20
        exit 1
    fi
}

cmd_stop()    { systemctl stop "$SVC";    green "milou stopped"; }
cmd_restart() { systemctl restart "$SVC"; sleep 1; svc_running && green "milou restarted" || { red "restart failed"; exit 1; }; }
cmd_enable()  { systemctl enable "$SVC";  green "milou will start on boot"; }
cmd_disable() { systemctl disable "$SVC"; green "milou auto-start disabled"; }

cmd_status() {
    printf "service     : "
    svc_running && green "active" || yellow "inactive"
    printf "boot-start  : "
    svc_enabled && green "enabled" || yellow "disabled"
    printf "binary      : "
    if [[ -x "$BIN" ]]; then
        green "$BIN"
    else
        red "missing $BIN"
    fi
    printf "caddy       : "
    if [[ -x "$CADDY" ]]; then
        green "$CADDY"
    else
        red "missing $CADDY"
    fi
    printf "config      : "
    if [[ -f "$CONF" ]]; then
        green "$CONF"
    else
        red "missing $CONF"
    fi
    if svc_running; then
        echo "----"
        # surface listening ports for sanity
        ss -tlnp 2>/dev/null | grep -E 'milou|caddy' | head -6 || true
    fi
}

cmd_log() {
    # Default to live-follow (matches what an operator usually wants —
    # `milou log` is most often run right after `milou restart` to watch
    # the boot path). Pass a numeric argument or `tail` to dump instead:
    #   milou log         → journalctl -fu milou (live, Ctrl-C to exit)
    #   milou log 50      → last 50 lines, no follow
    #   milou log tail    → last 200 lines, no follow
    case "${1:-follow}" in
        ""|follow|-f)
            journalctl -u "$SVC" -f --no-pager -n 50
            ;;
        tail)
            journalctl -u "$SVC" --no-pager -n 200
            ;;
        *[!0-9]*|"")
            red "usage: milou log [N|tail|-f]"; exit 2
            ;;
        *)
            journalctl -u "$SVC" --no-pager -n "$1"
            ;;
    esac
}

cmd_config() {
    # `milou config` with no args = show; `milou config edit` = $EDITOR
    case "${1:-show}" in
        show|cat) cat "$CONF" ;;
        edit)     "$EDITOR_DEFAULT" "$CONF" && cmd_restart ;;
        path)     echo "$CONF" ;;
        *) red "milou config [show|edit|path]"; exit 2 ;;
    esac
}

cmd_version() {
    if [[ -x "$BIN" ]]; then
        "$BIN" -v
    else
        red "milou binary missing"; exit 1
    fi
    if [[ -x "$CADDY" ]]; then
        "$CADDY" version
    fi
}

cmd_update() {
    if [[ ! -d "$SRC/.git" ]]; then
        red "no git checkout at $SRC — set up MILOU_GIT_URL and rerun install"
        exit 1
    fi
    green ">> fetching latest source"
    git -C "$SRC" fetch --depth 1 origin
    git -C "$SRC" reset --hard origin/HEAD
    green ">> rebuilding"
    cd "$SRC"
    export PATH="$PATH:/usr/local/go/bin:$HOME/go/bin"
    CGO_ENABLED=0 go build -trimpath -ldflags='-s -w' -o bin/milou ./cmd/milou
    xcaddy build v2.8.4 \
        --with github.com/milou/milou-backend/plugin/caddy/milouforwardproxy=./plugin/caddy/milouforwardproxy \
        --output ./bin/caddy
    install -m 0755 bin/milou /usr/local/milou/milou
    install -m 0755 bin/caddy /usr/local/milou/caddy
    if svc_running; then
        cmd_restart
    else
        yellow "rebuilt — service was not running, leaving it stopped"
    fi
}

#
# --- cert subcommand ------------------------------------------------------
#
# `milou cert issue|renew|install|status`
#
# Reads the cert-related keys from /etc/milou/milou.conf and drives acme.sh
# accordingly. Mirrors vaxilu/soga's cert handling — same config keys, same
# acme.sh under the hood.
#
# Supported cert_mode values:
#   manual  — operator provides cert_file/key_file; this command is a no-op
#   http    — acme.sh --standalone -d <cert_domain>  (needs :80 free)
#   dns     — acme.sh --dns <dns_provider> -d <cert_domain>
#                with DNS_* keys from milou.conf exported to acme.sh's env
#                (DNS_Ali_Key=… → Ali_Key=…, soga-compat prefix strip)

ACME=$HOME/.acme.sh/acme.sh

# get_conf <key>  — extract a single key=value line from milou.conf
get_conf() {
    awk -F= -v k="$1" '
        /^[[:space:]]*#/ || /^[[:space:]]*$/ {next}
        {
            key=$1; sub(/^[[:space:]]+/, "", key); sub(/[[:space:]]+$/, "", key);
            if (key==k) {
                $1=""; sub(/^=/, "");
                val=$0; sub(/^[[:space:]]+/, "", val); sub(/[[:space:]]+$/, "", val);
                print val; exit
            }
        }' "$CONF"
}

# get_conf_prefix <prefix>  — emit "KEY=VAL" lines for every conf key with
# the given prefix, prefix stripped. Used to pull DNS_* env vars.
get_conf_prefix() {
    awk -F= -v p="$1" '
        /^[[:space:]]*#/ || /^[[:space:]]*$/ {next}
        {
            key=$1; sub(/^[[:space:]]+/, "", key); sub(/[[:space:]]+$/, "", key);
            if (index(key, p)==1 && length(key) > length(p)) {
                $1=""; sub(/^=/, "");
                val=$0; sub(/^[[:space:]]+/, "", val); sub(/[[:space:]]+$/, "", val);
                if (val != "") {
                    print substr(key, length(p)+1) "=" val
                }
            }
        }' "$CONF"
}

cmd_cert() {
    local sub=${1:-help}; shift || true
    local mode keylen domain provider
    mode=$(get_conf cert_mode)
    keylen=$(get_conf cert_key_length)
    domain=$(get_conf cert_domain)
    provider=$(get_conf dns_provider)
    [[ -z "$keylen" ]] && keylen=ec-256
    [[ -z "$mode" ]]   && mode=manual

    case "$sub" in
        status)
            printf "cert_mode      : %s\n" "${mode:-manual}"
            printf "cert_domain    : %s\n" "${domain:-<unset>}"
            printf "cert_key_length: %s\n" "$keylen"
            printf "dns_provider   : %s\n" "${provider:-<unset>}"
            printf "cert_file      : %s " "$(get_conf cert_file || echo /etc/milou/cert.pem)"
            local cf; cf=$(get_conf cert_file); [[ -z "$cf" ]] && cf=/etc/milou/cert.pem
            if [[ -f "$cf" ]]; then
                local exp; exp=$(openssl x509 -enddate -noout -in "$cf" 2>/dev/null | sed 's/notAfter=//')
                green "present (expires $exp)"
            else
                yellow "missing"
            fi
            ;;
        issue)
            [[ -x "$ACME" ]] || { red "acme.sh not installed — re-run install.sh"; exit 1; }
            [[ -n "$domain" ]] || { red "cert_domain not set in $CONF"; exit 2; }
            local issue_args=(--issue -d "$domain" --keylength "$keylen")
            case "$mode" in
                http)
                    if svc_running; then
                        yellow ">> stopping milou to free :80 for acme HTTP-01"
                        cmd_stop
                        trap 'cmd_start' EXIT
                    fi
                    issue_args+=(--standalone --httpport 80)
                    ;;
                dns)
                    [[ -n "$provider" ]] || { red "dns_provider not set"; exit 2; }
                    issue_args+=(--dns "$provider")
                    # Export DNS_*=val as <stripped-name>=val into acme.sh's env.
                    while IFS='=' read -r k v; do
                        [[ -z "$k" ]] && continue
                        export "$k"="$v"
                        yellow ">> env $k=…"
                    done < <(get_conf_prefix DNS_)
                    ;;
                manual)
                    green "cert_mode=manual — nothing to do (provide cert_file/key_file yourself)"
                    return 0
                    ;;
                *)
                    red "unknown cert_mode=$mode (expected manual|http|dns)"
                    exit 2
                    ;;
            esac
            green ">> acme.sh ${issue_args[*]}"
            "$ACME" "${issue_args[@]}" || { red "acme.sh issue failed"; exit 1; }

            # Install issued cert into the paths milou.conf expects.
            cmd_cert install
            ;;
        install)
            [[ -x "$ACME" ]] || { red "acme.sh not installed"; exit 1; }
            [[ -n "$domain" ]] || { red "cert_domain not set"; exit 2; }
            local cf kf
            cf=$(get_conf cert_file); [[ -z "$cf" ]] && cf=/etc/milou/cert.pem
            kf=$(get_conf key_file);  [[ -z "$kf" ]] && kf=/etc/milou/key.pem
            # acme.sh `--ecc` selects the ECC cert dir for ec-256/384 keys.
            local ecc_flag=()
            case "$keylen" in ec-*) ecc_flag=(--ecc) ;; esac
            green ">> acme.sh --install-cert -d $domain ${ecc_flag[*]} --cert-file $cf --key-file $kf"
            "$ACME" --install-cert -d "$domain" "${ecc_flag[@]}" \
                --cert-file "$cf" \
                --key-file  "$kf" \
                --reloadcmd "milou restart" || { red "install-cert failed"; exit 1; }
            green ">> cert installed; acme.sh will renew & reload on its schedule"
            # If milou is running, reloadcmd already restarted it; if not, just bump.
            if svc_running; then green "milou restarted"; fi
            ;;
        renew)
            [[ -x "$ACME" ]] || { red "acme.sh not installed"; exit 1; }
            [[ -n "$domain" ]] || { red "cert_domain not set"; exit 2; }
            "$ACME" --renew -d "$domain" --force || exit 1
            ;;
        help|-h|--help|"")
            cat <<EOF
Usage: milou cert <subcommand>

  status   show cert_mode / domain / cert file expiry
  issue    obtain a new cert via acme.sh (uses cert_mode from milou.conf)
  install  re-deploy the most recently issued cert to cert_file/key_file
  renew    force-renew the cert now (acme.sh has its own cron schedule too)
EOF
            ;;
        *) red "unknown cert subcommand: $sub"; exit 2 ;;
    esac
}

cmd_uninstall() {
    yellow ">> stopping + disabling service"
    systemctl disable --now "$SVC" 2>/dev/null || true
    rm -f "$UNIT"
    systemctl daemon-reload
    yellow ">> removing /usr/local/milou /usr/bin/milou"
    rm -rf /usr/local/milou
    rm -f /usr/bin/milou
    yellow ">> KEEPING /etc/milou and /var/lib/milou (run 'rm -rf /etc/milou /var/lib/milou' to purge)"
    green "uninstalled"
}

cmd_install() {
    if [[ -f "$SRC/scripts/dist/install.sh" ]]; then
        bash "$SRC/scripts/dist/install.sh"
    elif [[ -n "${MILOU_GIT_URL:-}" ]]; then
        bash <(curl -fsSL "${MILOU_GIT_URL%.git}/raw/HEAD/scripts/dist/install.sh")
    else
        red "no source available — clone the repo, then ./scripts/dist/install.sh"
        exit 1
    fi
}

# --- init -----------------------------------------------------------------
#
# `milou init` — interactive config bootstrap. Mirrors what soga's first-run
# wizard does: prompts for the panel-link fields + cert plumbing, writes
# /etc/milou/milou.conf, and tells the operator what to do next.
#
# Re-running on an already-configured node prefills each prompt with the
# current value so it doubles as a "tweak one field" editor.

# Tiny prompt helper: $1=label, $2=default (shown in brackets, kept on empty
# input), $3=optional secret-flag ("secret" → hide while typing).
init_ask() {
    local label=$1 default=${2:-} secret=${3:-} ans
    if [[ -n "$default" ]]; then
        if [[ "$secret" == "secret" ]]; then
            read -r -s -p "  $label [keep current]: " ans; echo
        else
            read -r -p "  $label [$default]: " ans
        fi
        ans=${ans:-$default}
    else
        if [[ "$secret" == "secret" ]]; then
            read -r -s -p "  $label: " ans; echo
        else
            read -r -p "  $label: " ans
        fi
    fi
    printf '%s' "$ans"
}

# init_set_kv <key> <value>  — replace an existing key=value line in $CONF
# in place, or append it if missing.
#
# Why ENVIRON instead of awk -v: -v passes the value through awk's escape
# parser, so a literal `\n` / `\t` / `\\` in the value would be interpreted
# (a webapi_key happening to contain `\n` would split across two lines —
# the second line ending up as a bare value, which then trips the daemon's
# config parser with "expected key=value, got <leftover>"). ENVIRON sees
# the raw bytes verbatim.
init_set_kv() {
    local key=$1 val=$2
    if [[ -f "$CONF" ]] && grep -qE "^[[:space:]]*${key}[[:space:]]*=" "$CONF"; then
        local tmp=$CONF.tmp
        K="$key" V="$val" awk '
            BEGIN { k=ENVIRON["K"]; v=ENVIRON["V"]; done=0 }
            {
                line=$0
                if (!done && match(line, /^[[:space:]]*[A-Za-z0-9_]+[[:space:]]*=/)) {
                    sub(/^[[:space:]]*/, "", line)
                    n=index(line, "=")
                    if (substr(line, 1, n-1) == k) {
                        print k "=" v
                        done=1
                        next
                    }
                }
                print
            }
        ' "$CONF" > "$tmp" && mv "$tmp" "$CONF"
    else
        printf '%s=%s\n' "$key" "$val" >> "$CONF"
    fi
}

cmd_init() {
    install -d -m 0755 /etc/milou
    # Seed from the default template if no file exists yet — gives us all
    # the comments + non-prompted keys (timing intervals, caddy paths, etc.)
    # without having to ship a separate "minimal" template.
    if [[ ! -f "$CONF" ]]; then
        if [[ -f /usr/local/milou/milou.conf.default ]]; then
            install -m 0640 /usr/local/milou/milou.conf.default "$CONF"
        else
            touch "$CONF" && chmod 0640 "$CONF"
        fi
        yellow ">> wrote skeleton $CONF"
    else
        yellow ">> $CONF exists — values will pre-fill from it; press Enter to keep"
    fi
    echo

    # Panel link
    green "panel link"
    local node_id server_type webapi_url webapi_key
    node_id=$(init_ask     "node_id"     "$(get_conf node_id)")
    server_type=$(init_ask "server_type (naive|vmess|vless|trojan|shadowsocks|hysteria2|anytls|socks)" "$(get_conf server_type)")
    webapi_url=$(init_ask  "webapi_url   (e.g. https://panel.example.com)" "$(get_conf webapi_url)")
    webapi_key=$(init_ask  "webapi_key"  "$(get_conf webapi_key)" "secret")
    echo

    # Certificates
    green "tls cert"
    local cert_mode cert_domain cert_dns_provider
    cert_mode=$(init_ask      "cert_mode (manual|http|dns)" "$(get_conf cert_mode)")
    cert_domain=$(init_ask    "cert_domain"                 "$(get_conf cert_domain)")
    if [[ "$cert_mode" == "dns" ]]; then
        cert_dns_provider=$(init_ask "cert_dns_provider (e.g. dns_cf, dns_ali)" "$(get_conf cert_dns_provider)")
    fi
    echo

    # Multi-instance hint
    green "data plane"
    local listen
    listen=$(init_ask "listen IP (empty = bind all interfaces)" "$(get_conf listen)")
    echo

    # Write back
    init_set_kv node_id      "$node_id"
    init_set_kv server_type  "$server_type"
    init_set_kv webapi_url   "$webapi_url"
    init_set_kv webapi_key   "$webapi_key"
    init_set_kv cert_mode    "$cert_mode"
    init_set_kv cert_domain  "$cert_domain"
    init_set_kv listen       "$listen"
    if [[ -n "${cert_dns_provider:-}" ]]; then
        init_set_kv cert_dns_provider "$cert_dns_provider"
    fi
    chmod 0640 "$CONF"

    green ""
    green "==== milou.conf written ===="
    green "  config       : $CONF"
    green "  node_id      : $node_id"
    green "  server_type  : $server_type"
    green "  panel        : $webapi_url"
    green "  cert         : $cert_mode / $cert_domain"
    yellow ""
    case "$cert_mode" in
        http|dns)
            yellow "Next: milou cert issue   # then 'milou start'"
            if [[ "$cert_mode" == "dns" && -z "${cert_dns_provider:-}" ]]; then
                red   "    (set cert_dns_provider + DNS_* keys in $CONF first)"
            fi
            ;;
        manual|"")
            yellow "Next: place your cert at $(get_conf cert_file || echo /etc/milou/cert.pem) +"
            yellow "      $(get_conf key_file || echo /etc/milou/key.pem), then 'milou start'"
            ;;
    esac
}

cmd_help() {
    cat <<EOF
Usage: milou <command> [args]

Service control:
  start                start the milou service
  stop                 stop the milou service
  restart              restart the milou service
  enable               enable start-on-boot
  disable              disable start-on-boot
  status               show service + binary state

Inspection:
  log [N|tail|-f]      live-follow journal (default) | last N lines | last 200
  config [show|edit|path]
                       cat / \$EDITOR / print path of /etc/milou/milou.conf
  version              show milou + caddy versions

Certificates:
  cert status          show cert_mode + domain + expiry
  cert issue           obtain a new cert via acme.sh (mode from milou.conf)
  cert install         re-deploy the most recent acme.sh cert
  cert renew           force-renew now

Lifecycle:
  init                 interactive config bootstrap (writes /etc/milou/milou.conf)
  install              run install.sh from the source checkout
  update               git pull, rebuild, restart if running
  uninstall            remove binaries + systemd unit (config kept)
EOF
}

case "${1:-help}" in
    start)     cmd_start ;;
    stop)      cmd_stop ;;
    restart)   cmd_restart ;;
    enable)    cmd_enable ;;
    disable)   cmd_disable ;;
    status|s)  cmd_status ;;
    log|logs)  shift; cmd_log "$@" ;;
    config|c)  shift; cmd_config "$@" ;;
    cert)      shift; cmd_cert "$@" ;;
    version|v) cmd_version ;;
    update|u)  cmd_update ;;
    install)   cmd_install ;;
    uninstall) cmd_uninstall ;;
    init)      cmd_init ;;
    help|-h|--help) cmd_help ;;
    *) red "unknown command: $1"; cmd_help; exit 2 ;;
esac
