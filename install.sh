#!/bin/sh
# podkop-engine installer: replaces sing-box with podkop-engine and updates podkop
# on OpenWrt 24.10 (opkg) and 25.12 (apk) with podkop already configured.
#
#   wget -O /root/pe.sh https://raw.githubusercontent.com/markiitwo/podkop-engine-installer/main/install.sh
#   sh /root/pe.sh             install / update (latest releases)
#   sh /root/pe.sh check       check requirements only, change nothing
#   sh /root/pe.sh report      diagnostic report (secrets redacted)
#   sh /root/pe.sh rollback    switch back to the regular sing-box
#   sh /root/pe.sh help
#
# Options: -y (no questions), --pinned (tested versions built into the script),
#          --no-rollback (no automatic rollback), --lang en|ru

SCRIPT_VERSION="3.0"

# ---- tested (pinned) versions: used with --pinned or when GitHub API is unavailable
PIN_ENGINE_VER="1.14.2-r14"
PIN_ENGINE_SHA_IPK="04a97287d556562c28304bc5f246d855a240d1a800e3830f693c363c7b71d643"
PIN_ENGINE_SHA_APK="8956c62696ee292902960cbdb198339527d5d7946a677cf26616afc8632a1f63"
PIN_PODKOP_VER="0.7.24"
PIN_PODKOP_IPK="podkop-v0.7.24-r1-all.ipk";         PIN_PODKOP_SHA_IPK="34e8413ccdc3bc843ed6ee943dbe0a646908494a123b4ee342229ab1c79131b2"
PIN_LUCI_IPK="luci-app-podkop-v0.7.24-r1-all.ipk";  PIN_LUCI_SHA_IPK="25adc2a91169872748ead4b70a27a4cd57de9601d291d97b263071595cbfcc3c"
PIN_RU_IPK="luci-i18n-podkop-ru-0.7.24.ipk";        PIN_RU_SHA_IPK="a2b0bfba9ede5cf8c939d38f0f2d36068918ae6582982c8e91dd675b461f42f2"
PIN_PODKOP_APK="podkop-0.7.24-r1.apk";              PIN_PODKOP_SHA_APK="a444a784a7dc22b2ba17336b773f75b27861daf3fb358fea21b31935a975318e"
PIN_LUCI_APK="luci-app-podkop-0.7.24-r1.apk";       PIN_LUCI_SHA_APK="96d662b2f19e514e3486e9cddf545af1ce104d518884e3c61e8f4030c6f52746"
PIN_RU_APK="luci-i18n-podkop-ru-0.7.24.apk";        PIN_RU_SHA_APK="898b89b7abee2348c950b210b8fc347a268ccba3b06664c68eb4df4e3da1740b"

ENGINE_REPO="podkop-net/podkop-engine"
PODKOP_REPO="itdoginfo/podkop"
ENGINE_ARCH="${ENGINE_ARCH:-aarch64_cortex-a53}"
ENGINE_INSTALLED_KB=22400

PODKOP_DEPS="curl jq kmod-nft-tproxy coreutils-base64 bind-dig ca-bundle"
STATS_PKGS="luci-app-vnstat2 vnstati2 vnstat2 luci-app-nlbwmon nlbwmon"

WORK=/tmp/podkop-engine-install
BACKUP=/root/podkop-engine-backup
LOG=/tmp/podkop-engine-install.log
REPORT=/tmp/podkop-engine-report.txt
MIXED_PROXY="http://127.0.0.1:4534"
TEST_URL="https://www.gstatic.com/generate_204"
# mirror for when downloads.openwrt.org (Fastly) stalls at some providers;
# apk/opkg verify signatures themselves, the mirror cannot substitute packages
OPENWRT_MIRROR="https://mirrors.cicku.me/openwrt"

PM=""               # opkg | apk, set in detect_pm
UI_LANG="${PE_LANG:-}"
ASSUME_YES=0
AUTO_ROLLBACK=1
USE_PINNED=0
CRITICAL=0          # 1 = sing-box already replaced, roll back on failure
OLD_SB_PKG=""       # sing-box / sing-box-tiny / podkop-engine
STEP=0
STEPS=6

# ---- output ----------------------------------------------------------------
if [ -t 1 ]; then
    C_R='\033[1;31m'; C_G='\033[1;32m'; C_Y='\033[1;33m'; C_B='\033[1;36m'; C_0='\033[0m'
else
    C_R=''; C_G=''; C_Y=''; C_B=''; C_0=''
fi
L() { if [ "$UI_LANG" = ru ]; then printf '%s' "$2"; else printf '%s' "$1"; fi; }   # L "english" "русский"
ts() { date '+%H:%M:%S'; }
log() { echo "[$(ts)] $*" >> "$LOG"; }
step() { STEP=$((STEP + 1)); printf "\n${C_B}[%s/%s] %s${C_0}\n" "$STEP" "$STEPS" "$*"; log "=== STEP $STEP: $*"; }
ok()   { printf "  ${C_G}✓${C_0} %s\n" "$*"; log "OK: $*"; }
info() { printf "  • %s\n" "$*"; log "INFO: $*"; }
warn() { printf "  ${C_Y}!${C_0} %s\n" "$*"; log "WARN: $*"; }
err()  { printf "  ${C_R}✗${C_0} %s\n" "$*"; log "ERROR: $*"; }

# command with output to the log only
run() { log "\$ $*"; "$@" >> "$LOG" 2>&1; rc=$?; [ $rc -ne 0 ] && log "(exit $rc)"; return $rc; }

# command with a time limit: run_to seconds command... (busybox timeout is not always present)
run_to() {
    t=$1; shift
    log "\$ (max ${t}s) $*"
    "$@" >> "$LOG" 2>&1 &
    cmd_pid=$!
    ( sleep "$t"; if kill -0 "$cmd_pid" 2>/dev/null; then echo "[$(date '+%H:%M:%S')] (killed by ${t}s timeout)" >> "$LOG"; kill "$cmd_pid" 2>/dev/null; fi ) &
    watch_pid=$!
    wait "$cmd_pid"; rc=$?
    kill "$watch_pid" 2>/dev/null; wait "$watch_pid" 2>/dev/null
    [ $rc -ne 0 ] && log "(exit $rc)"
    return $rc
}

have_tty() { [ -t 0 ] && [ -r /dev/tty ] && ( : < /dev/tty ) 2>/dev/null; }

# language menu: arrows ↑↓ (or 1/2), Enter; English by default
choose_lang() {
    [ -n "$UI_LANG" ] && return 0
    UI_LANG=en
    [ "$ASSUME_YES" -eq 1 ] && return 0
    have_tty || return 0
    esc=$(printf '\033'); sel=0
    printf "\n  Language / Язык  (↑↓, Enter)\n"
    draw_lang() {
        if [ $sel -eq 0 ]; then printf "  ${C_B}> English${C_0}\n    Русский\n"; else printf "    English\n  ${C_B}> Русский${C_0}\n"; fi
    }
    draw_lang
    while :; do
        IFS= read -rsn1 k < /dev/tty || break
        if [ "$k" = "$esc" ]; then
            IFS= read -rsn2 k2 < /dev/tty
            case "$k2" in "[A"|"[D") sel=0 ;; "[B"|"[C") sel=1 ;; esac
        elif [ -z "$k" ]; then break
        elif [ "$k" = 1 ] || [ "$k" = e ] || [ "$k" = E ]; then sel=0; break
        elif [ "$k" = 2 ] || [ "$k" = r ] || [ "$k" = R ]; then sel=1; break
        fi
        printf '\033[2A'; draw_lang
    done
    [ $sel -eq 1 ] && UI_LANG=ru
    printf '\033[2A'; draw_lang
    return 0
}

ask() { # ask "question" default(y|n); without a terminal the answer is always "no"
    [ "$ASSUME_YES" -eq 1 ] && { [ "$2" = y ]; return; }
    if [ "$2" = y ]; then hint="[Y/n]"; else hint="[y/N]"; fi
    printf "  ${C_Y}?${C_0} %s %s " "$1" "$hint"
    if ! read -r a < /dev/tty 2>/dev/null; then
        echo; log "ASK: $1 -> no terminal, answer no"; return 1
    fi
    log "ASK: $1 -> '$a'"
    case "$a" in
        [yYдД]*) return 0 ;;
        [nNнН]*) return 1 ;;
        *) [ "$2" = y ] ;;
    esac
}

fail() { # fail "message": stop; roll back if sing-box was already replaced
    err "$1"
    feeds_restore 2>/dev/null
    if [ "$CRITICAL" -eq 1 ]; then
        if [ "$AUTO_ROLLBACK" -eq 1 ]; then
            warn "$(L "Rolling back..." "Возвращаю всё как было...")"
            do_rollback
        else
            warn "$(L "Automatic rollback is off (--no-rollback). To roll back: sh $0 rollback" "Автооткат выключен (--no-rollback). Вернуть: sh $0 rollback")"
        fi
    fi
    finish_log
    if [ "$CMD" = check ]; then
        printf "\n${C_R}%s${C_0} %s %s\n" "$(L "Check failed." "Проверка не прошла.")" "$(L "Nothing was changed. Log:" "Ничего не менял. Лог:")" "$BACKUP/install.log"
    else
        printf "\n${C_R}%s${C_0} %s %s\n" "$(L "Installation failed." "Установка не удалась.")" "$(L "Log:" "Лог:")" "$BACKUP/install.log"
    fi
    printf "%s ${C_B}sh %s report${C_0}\n" "$(L "Diagnostics:" "Диагностика:")" "$0"
    exit 1
}

finish_log() { mkdir -p "$BACKUP" 2>/dev/null && cp "$LOG" "$BACKUP/install.log" 2>/dev/null; }

on_signal() {
    feeds_restore 2>/dev/null
    log "interrupted"
    printf "\n"
    fail "$(L "Interrupted." "Установка прервана.")"
}

# ---- OpenWrt feeds and network ---------------------------------------------
feeds_file() { if [ "$PM" = apk ]; then echo /etc/apk/repositories.d/distfeeds.list; else echo /etc/opkg/distfeeds.conf; fi; }
feeds_to_mirror() {
    f=$(feeds_file); [ -f "$f" ] || return 1
    grep -q "downloads.openwrt.org" "$f" || return 1
    mkdir -p "$WORK"; cp "$f" "$WORK/feeds.orig" || return 1
    sed -i -E "s#https?://downloads\.openwrt\.org#$OPENWRT_MIRROR#g" "$f"
    log "feeds temporarily switched to $OPENWRT_MIRROR"
}
feeds_restore() {
    [ -f "$WORK/feeds.orig" ] || return 0
    cp "$WORK/feeds.orig" "$(feeds_file)" && rm -f "$WORK/feeds.orig" && log "feeds restored to downloads.openwrt.org"
}

# package-manager network commands: OpenWrt server → mirror → podkop proxy; each attempt has a timeout.
# PM_NO_MIRROR=1: no mirror (for files that are later installed without signature checks)
pm_net() {
    run_to 90 "$PM" "$@" && return 0
    if [ "${PM_NO_MIRROR:-0}" != 1 ] && feeds_to_mirror; then
        info "$(L "OpenWrt server did not respond, trying the mirror..." "Сервер OpenWrt не ответил, пробую зеркало...")"
        run_to 90 "$PM" "$@"; rc=$?
        feeds_restore
        [ $rc -eq 0 ] && return 0
    fi
    if proxy_up; then
        log "$PM $* via podkop"
        ( export http_proxy="$MIXED_PROXY" https_proxy="$MIXED_PROXY"; run_to 90 "$PM" "$@" ) && return 0
    fi
    return 1
}

# ---- package manager: opkg (24.10) or apk (25.12) --------------------------
detect_pm() {
    if command -v apk >/dev/null 2>&1 && [ -d /etc/apk ]; then PM=apk; PKG_EXT=apk
    elif command -v opkg >/dev/null 2>&1; then PM=opkg; PKG_EXT=ipk
    else PM=""; PKG_EXT=""; fi
}

# pinned versions → working variables
use_pinned() {
    ENGINE_VER="$PIN_ENGINE_VER"; PODKOP_VER="$PIN_PODKOP_VER"
    ENGINE_FILE="podkop-engine_${ENGINE_VER}_openwrt_${ENGINE_ARCH}.$PKG_EXT"
    ENGINE_URL="https://github.com/$ENGINE_REPO/releases/download/v$ENGINE_VER/$ENGINE_FILE"
    pb="https://github.com/$PODKOP_REPO/releases/download/$PODKOP_VER"
    if [ "$PM" = apk ]; then
        ENGINE_SHA="$PIN_ENGINE_SHA_APK"
        PODKOP_FILE="$PIN_PODKOP_APK"; PODKOP_SHA="$PIN_PODKOP_SHA_APK"
        LUCI_FILE="$PIN_LUCI_APK";     LUCI_SHA="$PIN_LUCI_SHA_APK"
        RU_FILE="$PIN_RU_APK";         RU_SHA="$PIN_RU_SHA_APK"
    else
        ENGINE_SHA="$PIN_ENGINE_SHA_IPK"
        PODKOP_FILE="$PIN_PODKOP_IPK"; PODKOP_SHA="$PIN_PODKOP_SHA_IPK"
        LUCI_FILE="$PIN_LUCI_IPK";     LUCI_SHA="$PIN_LUCI_SHA_IPK"
        RU_FILE="$PIN_RU_IPK";         RU_SHA="$PIN_RU_SHA_IPK"
    fi
    PODKOP_URL="$pb/$PODKOP_FILE"; LUCI_URL="$pb/$LUCI_FILE"; RU_URL="$pb/$RU_FILE"
    VERSION_SOURCE=pinned
    [ "$ENGINE_ARCH" = aarch64_cortex-a53 ] || PIN_ARCH_MISMATCH=1
}

api_get() { # GitHub API GET: via podkop if it works, otherwise direct
    command -v curl >/dev/null 2>&1 || return 1
    if proxy_up; then
        curl -fsSL --connect-timeout 10 --max-time 25 -x "$MIXED_PROXY" -H "Accept: application/vnd.github+json" "$1" 2>>"$LOG" && return 0
    fi
    curl -fsSL --connect-timeout 10 --max-time 25 -H "Accept: application/vnd.github+json" "$1" 2>>"$LOG"
}

# latest releases from GitHub (sha256 from the release asset digests); on any problem — pinned versions
resolve_versions() {
    use_pinned
    [ "$USE_PINNED" -eq 1 ] && { log "versions: pinned (--pinned)"; return 0; }
    command -v jq >/dev/null 2>&1 || { log "versions: no jq, pinned"; return 0; }

    # podkop-engine: highest release version that has a package for this arch and format
    rel=$(api_get "https://api.github.com/repos/$ENGINE_REPO/releases?per_page=20") || { log "versions: engine API failed"; VERSION_SOURCE=pinned-fallback; return 0; }
    line=$(printf '%s' "$rel" | jq -r --arg a "$ENGINE_ARCH" --arg e "$PKG_EXT" '
        .[] | select(.draft == false and .prerelease == false)
        | (.tag_name | ltrimstr("v")) as $v
        | .assets[] | select(.name == ("podkop-engine_" + $v + "_openwrt_" + $a + "." + $e))
        | "\($v) \(.digest // "") \(.browser_download_url)"' 2>>"$LOG" | grep ' sha256:' | sort -V | tail -n1)
    [ -n "$line" ] || { log "versions: no engine asset for $ENGINE_ARCH/$PKG_EXT"; VERSION_SOURCE=pinned-fallback; return 0; }

    # podkop: latest release, three packages of our format
    prel=$(api_get "https://api.github.com/repos/$PODKOP_REPO/releases/latest") || { log "versions: podkop API failed"; VERSION_SOURCE=pinned-fallback; return 0; }
    pver=$(printf '%s' "$prel" | jq -r '.tag_name' 2>>"$LOG" | sed 's/^v//')
    assets=$(printf '%s' "$prel" | jq -r '.assets[] | "\(.name) \(.digest // "") \(.browser_download_url)"' 2>>"$LOG")
    if [ "$PM" = apk ]; then
        p=$(echo "$assets" | grep -E "^podkop-v?$pver-r[0-9]+\.apk sha256:" | head -n1)
        l=$(echo "$assets" | grep -E "^luci-app-podkop-v?$pver-r[0-9]+\.apk sha256:" | head -n1)
        r=$(echo "$assets" | grep -E "^luci-i18n-podkop-ru-[^ ]*\.apk sha256:" | head -n1)
    else
        p=$(echo "$assets" | grep -E "^podkop-v?$pver-r[0-9]+(-all)?\.ipk sha256:" | head -n1)
        l=$(echo "$assets" | grep -E "^luci-app-podkop-v?$pver-r[0-9]+(-all)?\.ipk sha256:" | head -n1)
        r=$(echo "$assets" | grep -E "^luci-i18n-podkop-ru-[^ ]*\.ipk sha256:" | head -n1)
    fi
    { [ -n "$pver" ] && [ -n "$p" ] && [ -n "$l" ]; } || { log "versions: podkop assets not found for $pver"; VERSION_SOURCE=pinned-fallback; return 0; }

    set -- $line
    ENGINE_VER="$1"; ENGINE_SHA="${2#sha256:}"; ENGINE_URL="$3"; ENGINE_FILE=$(basename "$3")
    PODKOP_VER="$pver"
    set -- $p; PODKOP_FILE="$1"; PODKOP_SHA="${2#sha256:}"; PODKOP_URL="$3"
    set -- $l; LUCI_FILE="$1";   LUCI_SHA="${2#sha256:}";   LUCI_URL="$3"
    if [ -n "$r" ]; then set -- $r; RU_FILE="$1"; RU_SHA="${2#sha256:}"; RU_URL="$3"; else RU_FILE=""; fi
    VERSION_SOURCE=latest
    PIN_ARCH_MISMATCH=0
    log "versions: latest engine=$ENGINE_VER podkop=$PODKOP_VER"
}

# package installed under exactly this name (apk: sing-box-tiny does not count as sing-box)
pkg_installed() {
    if [ "$PM" = apk ]; then apk list -I "$1" 2>/dev/null | grep -q "^$1-[0-9]"
    else opkg status "$1" 2>/dev/null | grep -q '^Status:.* installed'; fi
}
pkg_ver() {
    if [ "$PM" = apk ]; then apk list -I "$1" 2>/dev/null | awk -v n="$1" 'index($1, n"-")==1 {print substr($1, length(n)+2); exit}'
    else opkg status "$1" 2>/dev/null | sed -n 's/^Version: //p'; fi
}
pkg_files() { # files of an installed package, one absolute path per line
    if [ "$PM" = apk ]; then apk info -L "$1" 2>/dev/null | grep -v ' contains:' | grep -v '^$' | sed 's#^/*#/#'
    else opkg files "$1" 2>/dev/null | grep '^/'; fi
}
# all architectures the system knows (apk may print several lines, opkg a list with priorities)
sys_archs() {
    {
        if [ "$PM" = apk ]; then apk --print-arch 2>/dev/null; cat /etc/apk/arch 2>/dev/null
        else opkg print-architecture 2>/dev/null | awk '{print $2}'; fi
        sed -n "s/^DISTRIB_ARCH='\(.*\)'/\1/p" /etc/openwrt_release 2>/dev/null
    } | tr -d '\r' | tr ' ' '\n' | grep -v '^$' | sort -u
}
pkg_arch_ok() { sys_archs | grep -qx "$ENGINE_ARCH"; }
pkg_update() { pm_net update; }
pkg_add_repo() { # install from the OpenWrt repository
    if [ "$PM" = apk ]; then run apk add "$@"; else run opkg install "$@"; fi
}
pkg_add_file() { # install/upgrade from a downloaded file
    if [ "$PM" = apk ]; then run apk add --allow-untrusted "$@"; else run opkg install "$@"; fi
}
pkg_remove() {
    if [ "$PM" = apk ]; then run apk del "$@"; else run opkg remove "$@"; fi
}
pkg_fetch() { # download a package from the repository: pkg_fetch dir name
    # the rollback copy is later installed from a file (apk --allow-untrusted / opkg without signature check),
    # so it is fetched only from the official OpenWrt server, never through the mirror
    if [ "$PM" = apk ]; then PM_NO_MIRROR=1 pm_net fetch -o "$1" "$2"
    else ( cd "$1" && PM_NO_MIRROR=1 pm_net download "$2" ); fi
}
# engine instead of sing-box. opkg: remove the old package, install the new one. apk: one transaction, but first
# remove stale entries from /etc/apk/world (otherwise a conflict: !sing-box blocks the engine itself,
# and sing-box installed from a local file stays pinned after a rollback)
engine_install() { # engine_install file old_package
    if [ "$PM" = apk ]; then
        cp /etc/apk/world "$BACKUP/apk-world.before" 2>/dev/null
        sed -i -E '/^(sing-box|sing-box-tiny)(><.*)?$/d; /^!(podkop-engine|sing-box|sing-box-tiny)$/d' /etc/apk/world
        log "apk world: $(tr '\n' ' ' < /etc/apk/world)"
        if ! run apk add --allow-untrusted "$1"; then
            cp "$BACKUP/apk-world.before" /etc/apk/world 2>/dev/null
            return 1
        fi
    else
        if [ "$2" != podkop-engine ]; then
            run opkg remove --force-depends "$2" || return 1
            info "$(L "$2 removed" "$2 снят")"
        fi
        run opkg install "$1"
    fi
}
# regular sing-box instead of engine: from a file or from the repository
engine_revert() { # engine_revert [file]
    if [ "$PM" = apk ]; then
        if [ -n "$1" ]; then run apk add --allow-untrusted "$1" '!podkop-engine'
        else run apk add sing-box-tiny '!podkop-engine'; fi
    else
        pkg_installed podkop-engine && run opkg remove --force-depends podkop-engine
        if [ -n "$1" ]; then run opkg install "$1"
        else pm_net update; run opkg install sing-box-tiny; fi
    fi
}

# ---- utilities -------------------------------------------------------------
ver_ge() { [ "$(printf '%s\n%s\n' "$2" "$1" | sort -V | head -n1)" = "$2" ]; } # $1 >= $2
mem_avail_mb() { awk '/^MemAvailable:/{print int($2/1024)}' /proc/meminfo; }
free_kb() { df -k "$1" 2>/dev/null | awk 'NR==2{print $4}'; }
singbox_rss_mb() { p=$(pidof sing-box | awk '{print $1}'); [ -n "$p" ] && awk '/VmRSS/{print int($2/1024)}' "/proc/$p/status"; }

proxy_up() { # is podkop's mixed inbound listening
    pidof sing-box >/dev/null && netstat -lnt 2>/dev/null | grep -q '127.0.0.1:4534 '
}

proxy_test() { # does the proxy through podkop work
    command -v curl >/dev/null 2>&1 || return 1
    code=$(curl -s -o /dev/null -w '%{http_code}' --connect-timeout 8 --max-time 15 -x "$MIXED_PROXY" "$TEST_URL" 2>/dev/null)
    log "proxy test -> $code"
    [ "$code" = 204 ]
}

dns_fakeip_ok() { nslookup fakeip.podkop.fyi 127.0.0.1 2>/dev/null | grep -q 'Address.*198\.1[89]\.'; }
dns_direct_ok() { nslookup openwrt.org 127.0.0.1 2>/dev/null | grep -qE 'Address.*[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' ; }

download() { # download url file sha256
    url="$1"; dst="$2"; sha="$3"; name=$(basename "$dst")
    for try in 1 2 3; do
        if proxy_up; then
            log "download via podkop: $url"
            curl -fsSL --connect-timeout 15 --max-time 300 -x "$MIXED_PROXY" -o "$dst" "$url" >> "$LOG" 2>&1
        fi
        if [ ! -s "$dst" ]; then
            log "download direct: $url"
            if command -v curl >/dev/null 2>&1; then
                curl -fsSL --connect-timeout 15 --max-time 600 -o "$dst" "$url" >> "$LOG" 2>&1
            else
                wget -q -T 30 -O "$dst" "$url" >> "$LOG" 2>&1
            fi
        fi
        if [ -s "$dst" ]; then
            got=$(sha256sum "$dst" | awk '{print $1}')
            if [ "$got" = "$sha" ]; then ok "$(L "Downloaded $name (checksum OK)" "Скачан $name (контрольная сумма совпала)")"; return 0; fi
            warn "$(L "Checksum mismatch for $name (attempt $try)" "Контрольная сумма $name не совпала (попытка $try)")"
            log "sha256 got=$got want=$sha"
        else
            warn "$(L "Could not download $name (attempt $try)" "Не удалось скачать $name (попытка $try)")"
        fi
        rm -f "$dst"; sleep 3
    done
    return 1
}

# ---- rollback --------------------------------------------------------------
# last-resort copy of the current sing-box files in RAM (when the package itself could not be saved)
snapshot_sb() {
    snap="$WORK/sb-snapshot"; rm -rf "$snap"; mkdir -p "$snap"
    files=$(pkg_files "$OLD_SB_PKG")
    [ -n "$files" ] || return 1
    need=0
    for f in $files; do [ -f "$f" ] && need=$((need + $(du -k "$f" | awk '{print $1}'))); done
    [ "$(free_kb /tmp)" -gt $((need + 15000)) ] || { log "snapshot: not enough /tmp for ${need}KB"; rm -rf "$snap"; return 1; }
    for f in $files; do
        [ -f "$f" ] || continue
        mkdir -p "$snap$(dirname "$f")" && cp -p "$f" "$snap$f" || { rm -rf "$snap"; return 1; }
    done
    log "snapshot: $OLD_SB_PKG files saved to $snap (${need}KB)"
}
restore_snapshot() {
    snap="$WORK/sb-snapshot"; [ -d "$snap" ] || return 1
    run /etc/init.d/podkop-engine stop
    run /etc/init.d/podkop-engine disable
    cp -a "$snap/." / || return 1
    log "snapshot restored"
}

do_rollback() {
    log "=== ROLLBACK"
    trap '' INT TERM HUP
    run /etc/init.d/podkop stop
    info "$(L "podkop stopped, internet works without the proxy" "podkop остановлен, интернет работает без VPN")"
    run /etc/init.d/podkop-engine stop
    pkgf=$(ls "$BACKUP"/sing-box*."$PKG_EXT" "$WORK"/rollback/sing-box*."$PKG_EXT" 2>/dev/null | head -n1)
    if [ -n "$pkgf" ]; then
        engine_revert "$pkgf" && ok "$(L "Restored $(basename "$pkgf")" "Вернул $(basename "$pkgf")")"
    else
        info "$(L "No saved package, installing sing-box from the OpenWrt repository..." "Сохранённого пакета нет, ставлю sing-box из репозитория OpenWrt...")"
        [ "$PM" = apk ] && pm_net update
        engine_revert && ok "$(L "Restored sing-box-tiny from the repository" "Вернул sing-box-tiny из репозитория")"
    fi
    if { ! sing-box version >/dev/null 2>&1 || sing-box version 2>/dev/null | head -n1 | grep -q pdk; } && restore_snapshot; then
        warn "$(L "Restored the previous sing-box files from the RAM copy. The package database may still list podkop-engine; reinstall sing-box later." "Вернул файлы прежнего sing-box из копии в памяти. В базе пакетов может числиться podkop-engine — позже переустанови sing-box.")"
    fi
    if ! sing-box version >/dev/null 2>&1 || sing-box version 2>/dev/null | head -n1 | grep -q pdk; then
        err "$(L "Could not restore the regular sing-box. podkop is stopped, internet works without the proxy." "Не получилось вернуть обычный sing-box. podkop выключен, интернет работает без VPN.")"
        err "$(L "Diagnostics: sh $0 report" "Диагностика: sh $0 report")"
        return 1
    fi
    run /etc/init.d/sing-box stop
    run /etc/init.d/sing-box disable
    [ -f "$BACKUP/sing-box.config" ] && cp "$BACKUP/sing-box.config" /etc/config/sing-box && log "restored /etc/config/sing-box"
    run /etc/init.d/podkop start
    sleep 10
    if pidof sing-box >/dev/null; then ok "$(L "podkop is running on the regular sing-box again" "podkop снова запущен на обычном sing-box")"
    else warn "$(L "sing-box did not start, check podkop in LuCI" "sing-box не поднялся — проверь podkop в LuCI")"; fi
    CRITICAL=0
    return 0
}

# ---- report ----------------------------------------------------------------
redact() {
    sed -E \
        -e "s#^(podkop\.[^.]+\.(outbound_json|proxy_string|urltest_proxy_links|urltest_fallback_links|selector_proxy_links|interface_private_key|wireguard_[a-z_]*key[a-z_]*))=.*#\1='***'#" \
        -e 's#("(id|uuid|password|psk|private_key|pre_shared_key|public_key|short_id|auth_str|obfs_password)"[[:space:]]*:[[:space:]]*")[^"]*#\1***#g' \
        -e 's#(vless|vmess|trojan|ss|ssr|hysteria2|hy2|tuic|socks[45]?|anytls|naive\+https)://[^ "'"'"']*#\1://***#g' \
        -e 's#[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}#<uuid>#g' \
        -e 's#((password|passwd|psk|private_key|public_key|short_id|pbk|sid|obfs-password|auth)[" =:]+)[^ ",&]+#\1***#gI' \
        -e 's#(yacd_secret_key=)[^ ]*#\1***#g'
}

do_report() {
    {
        echo "==== podkop-engine report $(date '+%Y-%m-%d %H:%M:%S') (script $SCRIPT_VERSION)"
        echo "Model: $(cat /tmp/sysinfo/model 2>/dev/null)"
        grep -E 'DISTRIB_(RELEASE|ARCH)' /etc/openwrt_release
        echo "Package manager: $PM"
        [ "$PM" = apk ] && echo "apk world: $(grep -E 'sing-box|podkop' /etc/apk/world | sed 's/><.*//' | tr '\n' ' ')"
        echo "Uptime: $(uptime)"
        echo; echo "---- versions"
        for p in podkop luci-app-podkop luci-i18n-podkop-ru podkop-engine sing-box sing-box-tiny; do
            v=$(pkg_ver "$p"); [ -n "$v" ] && echo "$p $v"
        done
        sing-box version 2>&1 | head -n 5
        echo; echo "---- memory and flash"
        free -m 2>/dev/null || head -5 /proc/meminfo
        df -h / /overlay /tmp 2>/dev/null
        echo "sing-box RSS: $(singbox_rss_mb) MB"
        echo "Largest processes (MB):"
        for s in /proc/[0-9]*/status; do awk '/^Name:/{n=$2} /^VmRSS:/{print int($2/1024), n}' "$s" 2>/dev/null; done | sort -rn | head -n 6
        echo "OOM kills: $(awk '/^oom_kill /{print $2}' /proc/vmstat)"
        echo; echo "---- services"
        for s in podkop sing-box podkop-engine; do
            [ -x /etc/init.d/$s ] && echo "$s: autostart=$(/etc/init.d/$s enabled && echo yes || echo no)"
        done
        echo "sing-box process: $(pidof sing-box >/dev/null && echo running || echo NOT running)"
        netstat -lntp 2>/dev/null | grep -E 'sing-box|dnsmasq' | grep -v 'fe80'
        echo; echo "---- checks"
        dns_fakeip_ok && echo "DNS fakeip: OK" || echo "DNS fakeip: FAIL"
        dns_direct_ok && echo "DNS direct: OK" || echo "DNS direct: FAIL"
        if proxy_up; then proxy_test && echo "Proxy via podkop: OK" || echo "Proxy via podkop: FAIL"; else echo "Proxy via podkop: not listening"; fi
        echo; echo "---- uci podkop / sing-box / dnsmasq"
        uci show podkop 2>/dev/null
        uci show sing-box 2>/dev/null
        uci show dhcp 2>/dev/null | grep -E '@dnsmasq\[0\]\.(server|noresolv|cachesize)'
        echo; echo "---- system log (podkop / sing-box)"
        logread 2>/dev/null | grep -E 'podkop|sing-box' | tail -n 80
        echo; echo "---- podkop global_check"
        /usr/bin/podkop global_check 2>&1 | tail -n 80
        if [ -f "$BACKUP/install.log" ]; then echo; echo "---- install log (tail)"; tail -n 60 "$BACKUP/install.log"; fi
    } 2>&1 | redact > "$REPORT"
    cat "$REPORT"
    printf "\n${C_G}%s${C_0} %s\n" "$(L "Report saved:" "Отчёт сохранён:")" "$REPORT"
    L "Proxy links, keys, passwords and UUIDs are replaced with ***. External IP and domains from logs remain." "Ссылки на прокси, ключи, пароли и UUID в нём заменены на ***. Внешний IP и домены из журналов остаются."; echo
}

# ---- install steps ---------------------------------------------------------
check_router() {
    step "$(L "Checking the router" "Проверяю роутер")"
    [ "$(id -u)" = 0 ] || fail "$(L "Run as root (ssh root@192.168.1.1)." "Запусти от root (ssh root@192.168.1.1).")"

    model=$(cat /tmp/sysinfo/model 2>/dev/null)
    rel=$(sed -n "s/^DISTRIB_RELEASE='\(.*\)'/\1/p" /etc/openwrt_release)
    info "$(L "Router: ${model:-unknown}, OpenWrt $rel" "Роутер: ${model:-неизвестно}, OpenWrt $rel")"
    [ -n "$PM" ] || fail "$(L "Neither opkg nor apk found — is this OpenWrt?" "Не нашёл ни opkg, ни apk — это точно OpenWrt?")"
    case "$rel" in
        24.*|25.*) ok "$(L "OpenWrt $rel, packages via $PM" "OpenWrt $rel, пакеты через $PM")" ;;
        *SNAPSHOT*|*snapshot*) warn "$(L "OpenWrt snapshot ($rel) — tested on 24.10 and 25.12 only" "Снапшот OpenWrt ($rel) — скрипт проверялся на 24.10 и 25.12, могут быть сюрпризы")" ;;
        *) fail "$(L "Supported: OpenWrt 24.10 and 25.12, found $rel." "Скрипт рассчитан на OpenWrt 24.10 и 25.12, а стоит $rel.")" ;;
    esac
    log "system archs: $(sys_archs | tr '\n' ' ')"
    pkg_arch_ok || fail "$(L "Architecture is not $ENGINE_ARCH (system reports: $(sys_archs | tr '\n' ' '))." "Архитектура не $ENGINE_ARCH (система сообщает: $(sys_archs | tr '\n' ' ')).")"
    ok "$(L "Architecture $ENGINE_ARCH" "Архитектура $ENGINE_ARCH")"

    [ -x /usr/bin/podkop ] || fail "$(L "podkop is not installed. Install and configure podkop first." "podkop не установлен. Сначала поставь и настрой podkop.")"
    PODKOP_CUR=$(pkg_ver podkop | sed 's/^v//; s/-r[0-9]*$//')
    ver_ge "$PODKOP_CUR" "0.7.0" || fail "$(L "podkop $PODKOP_CUR is too old (0.7+ required). Update podkop with its official script." "podkop $PODKOP_CUR слишком старый (нужен 0.7+). Обнови podkop официальным скриптом.")"
    ok "podkop $PODKOP_CUR"
    uci show podkop 2>/dev/null | grep -q "connection_type='proxy'" && PODKOP_HAS_PROXY=1 || PODKOP_HAS_PROXY=0
    [ "$PODKOP_HAS_PROXY" -eq 1 ] || warn "$(L "No proxy sections in podkop — the proxy check will be skipped" "В podkop нет секций с прокси — проверка VPN будет пропущена")"

    for p in podkop-engine sing-box-tiny sing-box; do
        if pkg_installed "$p"; then OLD_SB_PKG="$p"; break; fi
    done
    [ -n "$OLD_SB_PKG" ] || fail "$(L "No installed sing-box found." "Не нашёл установленный sing-box.")"
    OLD_SB_VER=$(pkg_ver "$OLD_SB_PKG")
    info "$(L "Installed: $OLD_SB_PKG $OLD_SB_VER" "Сейчас: $OLD_SB_PKG $OLD_SB_VER")"

    resolve_versions
    case "$VERSION_SOURCE" in
        latest) info "$(L "Latest releases: podkop-engine $ENGINE_VER, podkop $PODKOP_VER" "Последние версии: podkop-engine $ENGINE_VER, podkop $PODKOP_VER")" ;;
        pinned) info "$(L "Tested versions (--pinned): podkop-engine $ENGINE_VER, podkop $PODKOP_VER" "Проверенные версии (--pinned): podkop-engine $ENGINE_VER, podkop $PODKOP_VER")" ;;
        *) warn "$(L "GitHub API unavailable — using tested versions: podkop-engine $ENGINE_VER, podkop $PODKOP_VER" "GitHub API недоступен — беру проверенные версии: podkop-engine $ENGINE_VER, podkop $PODKOP_VER")" ;;
    esac
    [ "${PIN_ARCH_MISMATCH:-0}" -eq 1 ] && fail "$(L "Built-in checksums are for aarch64_cortex-a53 only; for $ENGINE_ARCH the GitHub API must be reachable." "Встроенные контрольные суммы только для aarch64_cortex-a53; для $ENGINE_ARCH нужен доступ к GitHub API.")"

    # update only: never downgrade
    ENGINE_NEWER=0
    if [ "$OLD_SB_PKG" = podkop-engine ] && ver_ge "$OLD_SB_VER" "$ENGINE_VER"; then
        NEED_ENGINE=0; [ "$OLD_SB_VER" != "$ENGINE_VER" ] && ENGINE_NEWER=1
    else
        NEED_ENGINE=1
    fi
    if ver_ge "$PODKOP_CUR" "$PODKOP_VER"; then NEED_PODKOP=0; else NEED_PODKOP=1; fi
    if [ "$NEED_ENGINE" -eq 0 ] && [ "$NEED_PODKOP" -eq 0 ]; then
        ok "$(L "Already up to date: podkop-engine $OLD_SB_VER, podkop $PODKOP_CUR." "Уже стоит podkop-engine $OLD_SB_VER и podkop $PODKOP_CUR — ставить нечего.")"
        info "$(L "Status: sh $0 report" "Проверить состояние: sh $0 report")"
        exit 0
    fi

    pkg_installed https-dns-proxy && fail "$(L "https-dns-proxy is installed and conflicts with podkop. Remove it and run again." "Стоит https-dns-proxy — он конфликтует с podkop. Удали его и запусти снова.")"

    mem=$(mem_avail_mb); rss=$(singbox_rss_mb)
    info "$(L "Free memory: ${mem} MB (sing-box uses ${rss:-0} MB)" "Свободно памяти: ${mem} МБ (sing-box сейчас занимает ${rss:-0} МБ)")"
    [ "$((mem + ${rss:-0}))" -ge 50 ] || fail "$(L "Not enough free memory ($mem MB, at least 50 including sing-box)." "Слишком мало свободной памяти ($mem МБ, нужно не меньше 50 с учётом sing-box).")"

    # space freed by the old sing-box: size of the binary itself (opkg status has no installed size)
    old_kb=$(du -k /usr/bin/sing-box 2>/dev/null | awk '{print $1}'); old_kb=${old_kb:-0}
    fl=$(free_kb /overlay)
    need=$((ENGINE_INSTALLED_KB - old_kb + 3000))
    [ "$OLD_SB_PKG" = podkop-engine ] && need=3000
    info "$(L "Free flash: $((fl / 1024)) MB" "Свободно на флеше: $((fl / 1024)) МБ")"
    [ "$fl" -ge "$need" ] || fail "$(L "Not enough flash: $(( (need - fl) / 1024 + 1 )) MB more needed." "Мало места на флеше: нужно ещё $(( (need - fl) / 1024 + 1 )) МБ.")"
    FLASH_FOR_BACKUP=$(( fl - need ))

    [ "$(free_kb /tmp)" -ge 25000 ] || fail "$(L "Not enough space in /tmp (25 MB needed)." "Мало места в /tmp (нужно 25 МБ).")"

    if [ "$(date +%Y)" -lt 2025 ]; then
        info "$(L "Router clock is wrong, syncing..." "Часы роутера сбиты, синхронизирую...")"
        run ntpd -q -n -p 162.159.200.1 -p 216.239.35.0
    fi

    dns_direct_ok || fail "$(L "DNS does not work on the router. Check the internet connection and run again." "На роутере не работает DNS. Проверь интернет и запусти снова.")"
    ok "$(L "Internet OK" "Интернет есть")"

    BASELINE_PROXY=0
    if [ "$PODKOP_HAS_PROXY" -eq 1 ] && proxy_up && proxy_test; then
        BASELINE_PROXY=1; ok "$(L "Proxy via podkop works" "VPN через podkop сейчас работает")"
    elif [ "$PODKOP_HAS_PROXY" -eq 1 ]; then
        warn "$(L "Proxy via podkop does NOT work right now. This will not count as an error after installation." "VPN через podkop сейчас НЕ работает. После установки это тоже не будет считаться ошибкой.")"
    fi
}

plan_and_confirm() {
    echo
    echo "  $(L "Plan:" "Что будет сделано:")"
    [ "$OLD_SB_PKG" != podkop-engine ] && echo "   - $OLD_SB_PKG $OLD_SB_VER → podkop-engine $ENGINE_VER $(L "(old package kept for rollback)" "(копия старого — для отката)")"
    [ "$OLD_SB_PKG" = podkop-engine ] && [ "$NEED_ENGINE" -eq 1 ] && echo "   - podkop-engine $OLD_SB_VER → $ENGINE_VER"
    [ "$ENGINE_NEWER" -eq 1 ] && echo "   - $(L "podkop-engine $OLD_SB_VER is newer than $ENGINE_VER — left as is" "podkop-engine $OLD_SB_VER новее $ENGINE_VER — не трогаю")"
    [ "$NEED_PODKOP" -eq 1 ] && echo "   - podkop $PODKOP_CUR → $PODKOP_VER $(L "(+ LuCI app)" "(+ интерфейс LuCI)")"
    echo "   - $(L "podkop settings and keys are not changed" "настройки и ключи podkop не меняются")"
    echo "   - $(L "the proxy will be down for about 1–2 minutes" "интернет через podkop пропадёт примерно на 1–2 минуты")"
    echo
    ask "$(L "Start?" "Начинаем?")" y || { info "$(L "Cancelled, nothing changed." "Отменено, ничего не менял.")"; exit 0; }

    REMOVE_STATS=0
    present=""
    for p in vnstat2 nlbwmon; do pkg_installed $p && present="$present $p"; done
    if [ -n "$present" ]; then
        ask "$(L "Remove traffic statistics ($present ) to free ~4 MB of RAM?" "Удалить статистику трафика ($present ) — освободит ~4 МБ памяти?")" n && REMOVE_STATS=1
    fi
}

download_all() {
    step "$(L "Downloading packages and dependencies" "Скачиваю пакеты и докачиваю зависимости")"
    rm -rf "$WORK"; mkdir -p "$WORK/rollback" "$BACKUP"
    trap on_signal INT TERM     # Ctrl+C here is safe: feeds are restored, nothing is changed

    LISTS_FRESH=0
    missing=""
    for d in $PODKOP_DEPS; do pkg_installed "$d" || missing="$missing $d"; done
    if [ -n "$missing" ]; then
        info "$(L "Missing:$missing — updating OpenWrt package lists (up to 3 minutes)..." "Не хватает:$missing — обновляю список пакетов OpenWrt (до 3 минут)...")"
        pkg_update && LISTS_FRESH=1 || fail "$(L "OpenWrt package server does not respond — cannot install:$missing. Try later." "Сервер пакетов OpenWrt не отвечает — не могу поставить:$missing. Попробуй позже.")"
        info "$(L "Installing:$missing" "Ставлю недостающее:$missing")"
        pkg_add_repo $missing || fail "$(L "Dependencies failed to install:$missing" "Не поставились зависимости:$missing")"
    fi
    ok "$(L "Dependencies present" "Зависимости на месте")"
    if [ "$NEED_ENGINE" -eq 1 ]; then
        download "$ENGINE_URL" "$WORK/$ENGINE_FILE" "$ENGINE_SHA" || fail "$(L "podkop-engine download failed. Nothing was changed." "Не скачался podkop-engine. Ничего не менял — всё работает как раньше.")"
    fi
    if [ "$NEED_PODKOP" -eq 0 ]; then
        info "$(L "podkop $PODKOP_CUR is up to date" "podkop $PODKOP_CUR актуален — не трогаю")"
    else
        download "$PODKOP_URL" "$WORK/$PODKOP_FILE" "$PODKOP_SHA" || fail "$(L "podkop download failed." "Не скачался podkop.")"
        download "$LUCI_URL" "$WORK/$LUCI_FILE" "$LUCI_SHA" || fail "$(L "luci-app-podkop download failed." "Не скачался luci-app-podkop.")"
        if [ -n "$RU_FILE" ] && pkg_installed luci-i18n-podkop-ru; then
            download "$RU_URL" "$WORK/$RU_FILE" "$RU_SHA" && NEED_RU=1
        fi
    fi

    if [ "$OLD_SB_PKG" != podkop-engine ]; then
        saved=$(ls "$BACKUP"/"$OLD_SB_PKG"[-_][0-9]*."$PKG_EXT" 2>/dev/null | head -n1)
        if [ -z "$saved" ]; then
            info "$(L "Saving a copy of $OLD_SB_PKG for rollback (up to 3 minutes)..." "Сохраняю копию $OLD_SB_PKG для отката (до 3 минут)...")"
            pkg_fetch "$WORK/rollback" "$OLD_SB_PKG" || {
                [ "$LISTS_FRESH" -eq 0 ] && pkg_update && pkg_fetch "$WORK/rollback" "$OLD_SB_PKG"
            }
        fi
        rb=$(ls "$WORK"/rollback/"$OLD_SB_PKG"[-_][0-9]*."$PKG_EXT" 2>/dev/null | head -n1)
        if [ -n "$saved" ]; then
            ok "$(L "Rollback package already saved: $(basename "$saved")" "Пакет $OLD_SB_PKG для отката уже сохранён: $(basename "$saved")")"
        elif [ -n "$rb" ]; then
            ok "$(L "Saved $OLD_SB_PKG package for rollback" "Сохранил пакет $OLD_SB_PKG для отката")"
        elif snapshot_sb; then
            warn "$(L "Could not download the $OLD_SB_PKG package; its current files are copied to RAM for an automatic rollback during this run." "Не смог скачать пакет $OLD_SB_PKG; его текущие файлы скопированы в память для автоотката в этом запуске.")"
        else
            warn "$(L "No rollback copy of $OLD_SB_PKG. If something goes wrong, sing-box will be installed from the repository." "Нет копии $OLD_SB_PKG для отката. Если что-то пойдёт не так, sing-box поставится из репозитория.")"
            ask "$(L "Continue without a rollback copy?" "Продолжить без копии для отката?")" y || { info "$(L "Cancelled, nothing changed." "Отменено, ничего не менял.")"; exit 0; }
        fi
    fi
}

make_backup() {
    step "$(L "Backing up settings" "Сохраняю настройки")"
    stamp=$(date +%Y%m%d-%H%M%S)
    extra=""; [ "$PM" = apk ] && extra="/etc/apk/world"
    tar czf "$BACKUP/config-$stamp.tar.gz" /etc/config/podkop /etc/config/sing-box /etc/config/dhcp /etc/sing-box $extra 2>> "$LOG" \
        && ok "$(L "Settings: $BACKUP/config-$stamp.tar.gz" "Настройки: $BACKUP/config-$stamp.tar.gz")" \
        || warn "$(L "Settings archive was not created" "Архив настроек не создался")"
    [ -f /etc/config/sing-box ] && cp /etc/config/sing-box "$BACKUP/sing-box.config"
    rb=$(ls "$WORK"/rollback/*."$PKG_EXT" 2>/dev/null | head -n1)
    if [ -n "$rb" ]; then
        sz=$(( $(wc -c < "$rb") / 1024 ))
        if [ "${FLASH_FOR_BACKUP:-0}" -gt $((sz + 2000)) ]; then
            rm -f "$BACKUP"/sing-box*.ipk "$BACKUP"/sing-box*.apk
            cp "$rb" "$BACKUP/" && ok "$(L "Rollback package stored in $BACKUP (survives reboot)" "Пакет для отката лежит в $BACKUP (переживёт перезагрузку)")"
        else
            info "$(L "Rollback package kept in RAM ($WORK) — not enough flash" "Пакет для отката оставлен в памяти ($WORK) — на флеше мало места")"
        fi
    fi
}

install_all() {
    step "$(L "Installing" "Устанавливаю")"
    trap '' HUP                 # a dropped SSH session does not interrupt the installation
    trap on_signal INT TERM
    info "$(L "If SSH disconnects, installation continues; log: $BACKUP/install.log" "Если SSH оборвётся — установка всё равно закончится, лог: $BACKUP/install.log")"

    run /etc/init.d/podkop stop
    ok "$(L "podkop stopped (internet works without the proxy)" "podkop остановлен (интернет пока работает без VPN)")"

    if [ "$NEED_ENGINE" -eq 1 ]; then
        CRITICAL=1
        engine_install "$WORK/$ENGINE_FILE" "$OLD_SB_PKG" || fail "$(L "podkop-engine failed to install (see log)" "Не установился podkop-engine (подробности в логе)")"
        # the package starts sing-box with the old config itself; podkop will start it properly
        run /etc/init.d/sing-box stop
        run /etc/init.d/sing-box disable
        sing-box version 2>/dev/null | head -n1 | grep -q pdk || fail "$(L "Installed sing-box does not look like podkop-engine" "После установки sing-box не похож на podkop-engine")"
        ok "$(L "podkop-engine $ENGINE_VER installed" "podkop-engine $ENGINE_VER установлен")"
    fi

    if [ "$NEED_PODKOP" -eq 1 ]; then
        CRITICAL=1
        pkg_add_file "$WORK/$PODKOP_FILE" || fail "$(L "podkop $PODKOP_VER failed to install" "Не установился podkop $PODKOP_VER")"
        pkg_add_file "$WORK/$LUCI_FILE" || warn "$(L "LuCI app was not updated (podkop itself works)" "Не обновился интерфейс LuCI (podkop при этом работает)")"
        [ "${NEED_RU:-0}" -eq 1 ] && { pkg_add_file "$WORK/$RU_FILE" || warn "$(L "Russian LuCI translation was not updated" "Не обновился русский язык LuCI")"; }
        ok "$(L "podkop $PODKOP_VER installed" "podkop $PODKOP_VER установлен")"
    fi

    if [ "${REMOVE_STATS:-0}" -eq 1 ]; then
        for p in $STATS_PKGS; do pkg_installed "$p" && pkg_remove "$p"; done
        ok "$(L "Traffic statistics removed" "Статистика трафика удалена")"
    fi

    rm -f /tmp/luci-indexcache* /tmp/luci-modulecache/* 2>/dev/null
    run /etc/init.d/rpcd reload
    run /etc/init.d/podkop-engine enable
    run /etc/init.d/podkop-engine restart
    logger -t podkop-engine-installer "podkop start"
    run /etc/init.d/podkop start
    ok "$(L "podkop started" "podkop запущен")"
}

verify() {
    step "$(L "Verifying (up to 2 minutes)" "Проверяю, что всё работает (до 2 минут)")"
    t=0; sb=0; fk=0; dd=0; px=0
    while [ $t -lt 120 ]; do
        [ $sb -eq 0 ] && pidof sing-box >/dev/null && { sb=1; ok "$(L "sing-box is running" "sing-box запущен")"; }
        [ $sb -eq 1 ] && [ $fk -eq 0 ] && dns_fakeip_ok && { fk=1; ok "$(L "podkop DNS answers" "DNS podkop отвечает")"; }
        [ $dd -eq 0 ] && dns_direct_ok && { dd=1; ok "$(L "Regular DNS works" "Обычный DNS работает")"; }
        if [ "$BASELINE_PROXY" -eq 1 ] && [ $px -eq 0 ] && proxy_up && proxy_test; then px=1; ok "$(L "Proxy via podkop works" "VPN через podkop работает")"; fi
        if [ $sb -eq 1 ] && [ $fk -eq 1 ] && [ $dd -eq 1 ] && { [ "$BASELINE_PROXY" -eq 0 ] || [ $px -eq 1 ]; }; then
            break
        fi
        sleep 4; t=$((t + 4))
    done
    log "verify: sb=$sb fakeip=$fk direct=$dd proxy=$px baseline=$BASELINE_PROXY t=$t"
    # sing-box errors only after our podkop start
    fatal=$(logread 2>/dev/null | sed -n '/podkop-engine-installer: podkop start/,$p' | grep -E 'sing-box.*(FATAL|panic)' | tail -n 3)
    if [ -n "$fatal" ]; then
        log "fatal after start: $fatal"
        if [ $sb -eq 1 ]; then
            warn "$(L "sing-box crashed once at start but restarted and is running (see log)" "sing-box один раз упал при запуске, но перезапустился и работает (подробности в логе)")"
        else
            echo "$fatal" | while read -r l; do err "$l"; done
        fi
    fi
    [ $sb -eq 1 ] || fail "$(L "sing-box did not start" "sing-box не запустился")"
    [ $fk -eq 1 ] || fail "$(L "podkop DNS does not answer" "DNS podkop не отвечает")"
    [ $dd -eq 1 ] || fail "$(L "Regular DNS does not work" "Обычный DNS не работает")"
    [ "$BASELINE_PROXY" -eq 1 ] && [ $px -eq 0 ] && fail "$(L "Proxy via podkop stopped working (it worked before installation)" "VPN через podkop перестал работать (до установки работал)")"
    CRITICAL=0
}

summary() {
    step "$(L "Done" "Готово")"
    rm -rf "$WORK"
    finish_log
    printf "  ${C_G}%s${C_0}\n" "$(L "Everything works." "Всё работает.")"
    info "sing-box: $(sing-box version 2>/dev/null | head -n1 | awk '{print $3}'), $(L "memory" "память"): $(singbox_rss_mb) MB, $(L "free" "свободно"): $(mem_avail_mb) MB"
    info "podkop: $(pkg_ver podkop)"
    sing-box version 2>/dev/null | grep -q 'xhttp' && info "$(L "xhttp links can now be added to podkop" "Теперь в podkop можно добавлять ключи с транспортом xhttp")"
    info "$(L "Enabled: provider DNS fallback, download check before switching, sing-box crash protection" "Включено: запасной DNS провайдера, проверка сервера скачиванием, защита от зависания sing-box")"
    echo
    echo "  $(L "If something is wrong:" "Если что-то не так:")"
    echo "    sh $0 report     — $(L "diagnostic report (no secrets)" "отчёт для диагностики (без ключей)")"
    echo "    sh $0 rollback   — $(L "back to the regular sing-box" "вернуть обычный sing-box")"
    echo "  $(L "Install log:" "Лог установки:") $BACKUP/install.log"
}

usage() {
    if [ "$UI_LANG" = ru ]; then
        cat <<EOF
Установщик podkop-engine для OpenWrt 24.10/25.12 с настроенным podkop.

  sh pe.sh             установить / обновить до последних версий
  sh pe.sh check       только проверка, без изменений
  sh pe.sh rollback    вернуть обычный sing-box
  sh pe.sh report      отчёт для диагностики (секреты вырезаются)
  sh pe.sh help        эта справка

Ключи:
  -y, --yes            без вопросов (ответы по умолчанию)
  --pinned             проверенные версии из скрипта вместо последних
  --no-rollback        не откатывать автоматически
  --lang en|ru         язык без меню выбора
EOF
    else
        cat <<EOF
podkop-engine installer for OpenWrt 24.10/25.12 with podkop configured.

  sh pe.sh             install / update to the latest releases
  sh pe.sh check       check only, change nothing
  sh pe.sh rollback    back to the regular sing-box
  sh pe.sh report      diagnostic report (secrets redacted)
  sh pe.sh help        this help

Options:
  -y, --yes            no questions (default answers)
  --pinned             tested versions built into the script instead of the latest
  --no-rollback        no automatic rollback
  --lang en|ru         language without the selection menu
EOF
    fi
}

# ---- main ------------------------------------------------------------------
CMD=install
SHOW_HELP=0
next_is_lang=0
for a in "$@"; do
    if [ "$next_is_lang" -eq 1 ]; then UI_LANG="$a"; next_is_lang=0; continue; fi
    case "$a" in
        -y|--yes) ASSUME_YES=1 ;;
        --no-rollback) AUTO_ROLLBACK=0 ;;
        --pinned) USE_PINNED=1 ;;
        --lang) next_is_lang=1 ;;
        --lang=*) UI_LANG="${a#--lang=}" ;;
        install|check|report|rollback) CMD=$a ;;
        help|-h|--help) SHOW_HELP=1 ;;
        *) echo "Unknown option / Неизвестный параметр: $a"; UI_LANG=${UI_LANG:-en}; usage; exit 1 ;;
    esac
done
case "$UI_LANG" in en|ru|"") ;; *) UI_LANG=en ;; esac
[ "$SHOW_HELP" -eq 1 ] && { UI_LANG=${UI_LANG:-en}; usage; exit 0; }

: > "$LOG"
detect_pm

# without a terminal nothing can be confirmed: refuse instead of answering "yes" silently
if [ "$CMD" = install ] || [ "$CMD" = rollback ]; then
    if [ "$ASSUME_YES" -eq 0 ] && ! have_tty; then
        echo "No terminal for questions: run in an interactive SSH session, or add -y to accept the defaults."
        echo "Нет терминала для вопросов: запусти в обычной SSH-сессии или добавь -y, чтобы принять ответы по умолчанию."
        exit 1
    fi
fi
[ "$CMD" = report ] && UI_LANG=${UI_LANG:-en}
choose_lang
log "podkop-engine installer $SCRIPT_VERSION, cmd=$CMD, args=$*, pm=$PM, lang=$UI_LANG"

case "$CMD" in
    report) do_report ;;
    check)
        STEPS=1
        printf "${C_B}%s${C_0}\n" "$(L "podkop-engine installer $SCRIPT_VERSION — check" "Установщик podkop-engine $SCRIPT_VERSION — проверка")"
        check_router
        printf "\n${C_G}%s${C_0} %s sh %s\n" "$(L "Router is suitable." "Роутер подходит.")" "$(L "Nothing was changed. To install:" "Ничего не менял. Установить:")" "$0" ;;
    rollback)
        printf "${C_B}%s${C_0}\n" "$(L "Switching back to the regular sing-box" "Возврат обычного sing-box")"
        ask "$(L "Replace podkop-engine with the regular sing-box?" "Вернуть обычный sing-box вместо podkop-engine?")" y || exit 0
        mkdir -p "$BACKUP" "$WORK"; CRITICAL=1; do_rollback; rc=$?; finish_log; exit $rc ;;
    install)
        printf "${C_B}%s${C_0}\n" "$(L "podkop-engine installer $SCRIPT_VERSION" "Установщик podkop-engine $SCRIPT_VERSION")"
        check_router
        plan_and_confirm
        download_all
        make_backup
        install_all
        verify
        summary ;;
esac
