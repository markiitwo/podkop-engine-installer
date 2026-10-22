#!/bin/sh
# Установка podkop-engine (сборка sing-box для podkop) + обновление podkop
# для Xiaomi AX3000T на OpenWrt 24.10 (opkg) и 25.12 (apk) с уже настроенным podkop.
#
#   wget -O /root/pe.sh https://raw.githubusercontent.com/markiitwo/podkop-engine-installer/main/install.sh
#   sh /root/pe.sh            установить / обновить
#   sh /root/pe.sh check      только проверить роутер, ничего не меняя
#   sh /root/pe.sh report     собрать отчёт для помощи (ключи вырезаются)
#   sh /root/pe.sh rollback   вернуть обычный sing-box
#   sh /root/pe.sh help
#
# Ключи: -y (не задавать вопросов), --no-rollback (не откатывать при неудачной проверке)

SCRIPT_VERSION="2.4"

# ---- проверенные версии (обновлять вместе) ---------------------------------
ENGINE_VER="1.14.2-r14"
ENGINE_ARCH="${ENGINE_ARCH:-aarch64_cortex-a53}"
ENGINE_BASE="https://github.com/FiyeroT/podkop-engine/releases/download/v${ENGINE_VER}"
ENGINE_SHA_IPK="04a97287d556562c28304bc5f246d855a240d1a800e3830f693c363c7b71d643"
ENGINE_SHA_APK="8956c62696ee292902960cbdb198339527d5d7946a677cf26616afc8632a1f63"
ENGINE_INSTALLED_KB=22400

PODKOP_VER="0.7.24"
PODKOP_BASE="https://github.com/itdoginfo/podkop/releases/download/${PODKOP_VER}"
# opkg (OpenWrt 24.10)
PODKOP_IPK="podkop-v${PODKOP_VER}-r1-all.ipk";             PODKOP_SHA_IPK="34e8413ccdc3bc843ed6ee943dbe0a646908494a123b4ee342229ab1c79131b2"
LUCI_IPK="luci-app-podkop-v${PODKOP_VER}-r1-all.ipk";      LUCI_SHA_IPK="25adc2a91169872748ead4b70a27a4cd57de9601d291d97b263071595cbfcc3c"
RU_IPK="luci-i18n-podkop-ru-${PODKOP_VER}.ipk";            RU_SHA_IPK="a2b0bfba9ede5cf8c939d38f0f2d36068918ae6582982c8e91dd675b461f42f2"
# apk (OpenWrt 25.12)
PODKOP_APK="podkop-${PODKOP_VER}-r1.apk";                  PODKOP_SHA_APK="a444a784a7dc22b2ba17336b773f75b27861daf3fb358fea21b31935a975318e"
LUCI_APK="luci-app-podkop-${PODKOP_VER}-r1.apk";           LUCI_SHA_APK="96d662b2f19e514e3486e9cddf545af1ce104d518884e3c61e8f4030c6f52746"
RU_APK="luci-i18n-podkop-ru-${PODKOP_VER}.apk";            RU_SHA_APK="898b89b7abee2348c950b210b8fc347a268ccba3b06664c68eb4df4e3da1740b"

PODKOP_DEPS="curl jq kmod-nft-tproxy coreutils-base64 bind-dig ca-bundle"
STATS_PKGS="luci-app-vnstat2 vnstati2 vnstat2 luci-app-nlbwmon nlbwmon"

WORK=/tmp/podkop-engine-install
BACKUP=/root/podkop-engine-backup
LOG=/tmp/podkop-engine-install.log
REPORT=/tmp/podkop-engine-report.txt
MIXED_PROXY="http://127.0.0.1:4534"
TEST_URL="https://www.gstatic.com/generate_204"

PM=""               # opkg | apk — выбирается в detect_pm
ASSUME_YES=0
AUTO_ROLLBACK=1
CRITICAL=0          # 1 = старый sing-box уже снят, при сбое нужен откат
OLD_SB_PKG=""       # sing-box / sing-box-tiny / podkop-engine
STEP=0
STEPS=6

# ---- вывод -----------------------------------------------------------------
if [ -t 1 ]; then
    C_R='\033[1;31m'; C_G='\033[1;32m'; C_Y='\033[1;33m'; C_B='\033[1;36m'; C_0='\033[0m'
else
    C_R=''; C_G=''; C_Y=''; C_B=''; C_0=''
fi
ts() { date '+%H:%M:%S'; }
log() { echo "[$(ts)] $*" >> "$LOG"; }
step() { STEP=$((STEP + 1)); printf "\n${C_B}[%s/%s] %s${C_0}\n" "$STEP" "$STEPS" "$*"; log "=== STEP $STEP: $*"; }
ok()   { printf "  ${C_G}✓${C_0} %s\n" "$*"; log "OK: $*"; }
info() { printf "  • %s\n" "$*"; log "INFO: $*"; }
warn() { printf "  ${C_Y}!${C_0} %s\n" "$*"; log "WARN: $*"; }
err()  { printf "  ${C_R}✗${C_0} %s\n" "$*"; log "ERROR: $*"; }

# команда с выводом только в лог
run() { log "\$ $*"; "$@" >> "$LOG" 2>&1; rc=$?; [ $rc -ne 0 ] && log "(код $rc)"; return $rc; }

# команда с ограничением по времени: run_to секунд команда... (busybox timeout есть не везде)
run_to() {
    t=$1; shift
    log "\$ (до ${t}с) $*"
    "$@" >> "$LOG" 2>&1 &
    cmd_pid=$!
    ( sleep "$t"; if kill -0 "$cmd_pid" 2>/dev/null; then echo "[$(date '+%H:%M:%S')] (прервано по тайм-ауту ${t}с)" >> "$LOG"; kill "$cmd_pid" 2>/dev/null; fi ) &
    watch_pid=$!
    wait "$cmd_pid"; rc=$?
    kill "$watch_pid" 2>/dev/null; wait "$watch_pid" 2>/dev/null
    [ $rc -ne 0 ] && log "(код $rc)"
    return $rc
}

# зеркало на случай, когда downloads.openwrt.org (Fastly) у провайдера тормозит или режется;
# подписи пакетов apk/opkg проверяют сами, зеркало ничего подменить не может
OPENWRT_MIRROR="https://mirrors.cicku.me/openwrt"
feeds_file() { if [ "$PM" = apk ]; then echo /etc/apk/repositories.d/distfeeds.list; else echo /etc/opkg/distfeeds.conf; fi; }
feeds_to_mirror() {
    f=$(feeds_file); [ -f "$f" ] || return 1
    grep -q "downloads.openwrt.org" "$f" || return 1
    cp "$f" "$WORK/feeds.orig" || return 1
    sed -i -E "s#https?://downloads\.openwrt\.org#$OPENWRT_MIRROR#g" "$f"
    log "фиды временно переключены на зеркало $OPENWRT_MIRROR"
}
feeds_restore() {
    [ -f "$WORK/feeds.orig" ] || return 0
    cp "$WORK/feeds.orig" "$(feeds_file)" && rm -f "$WORK/feeds.orig" && log "фиды возвращены на downloads.openwrt.org"
}

# сетевые команды менеджера пакетов: сервер OpenWrt → зеркало → через VPN podkop; у каждой попытки тайм-аут.
# PM_NO_MIRROR=1 — без зеркала (для скачивания файлов, которые потом ставятся без проверки подписи)
pm_net() {
    run_to 90 "$PM" "$@" && return 0
    if [ "${PM_NO_MIRROR:-0}" != 1 ] && feeds_to_mirror; then
        info "Сервер OpenWrt не ответил, пробую зеркало..."
        run_to 90 "$PM" "$@"; rc=$?
        feeds_restore
        [ $rc -eq 0 ] && return 0
    fi
    if proxy_up; then
        log "$PM $* через podkop"
        ( export http_proxy="$MIXED_PROXY" https_proxy="$MIXED_PROXY"; run_to 90 "$PM" "$@" ) && return 0
    fi
    return 1
}

ask() { # ask "вопрос" default(y|n)
    [ "$ASSUME_YES" -eq 1 ] && { [ "$2" = y ]; return; }
    if [ "$2" = y ]; then hint="[Д/н]"; else hint="[д/Н]"; fi
    printf "  ${C_Y}?${C_0} %s %s " "$1" "$hint"
    read -r a < /dev/tty 2>/dev/null || a=""
    log "ASK: $1 -> '$a'"
    case "$a" in
        [yYдД]*) return 0 ;;
        [nNнН]*) return 1 ;;
        *) [ "$2" = y ] ;;
    esac
}

fail() { # fail "сообщение" — остановка; откат, если уже меняли sing-box
    err "$1"
    feeds_restore 2>/dev/null
    if [ "$CRITICAL" -eq 1 ]; then
        if [ "$AUTO_ROLLBACK" -eq 1 ]; then
            warn "Возвращаю всё как было..."
            do_rollback
        else
            warn "Автооткат выключен (--no-rollback). Вернуть: sh $0 rollback"
        fi
    fi
    finish_log
    if [ "$CMD" = check ]; then
        printf "\n${C_R}Проверка не прошла.${C_0} Ничего не менял. Лог: %s\n" "$BACKUP/install.log"
    else
        printf "\n${C_R}Установка не удалась.${C_0} Лог: %s\n" "$BACKUP/install.log"
    fi
    printf "Диагностика: ${C_B}sh %s report${C_0}\n" "$0"
    exit 1
}

finish_log() { mkdir -p "$BACKUP" 2>/dev/null && cp "$LOG" "$BACKUP/install.log" 2>/dev/null; }

on_signal() {
    feeds_restore 2>/dev/null
    log "получен сигнал прерывания"
    printf "\n"
    fail "Установка прервана."
}

# ---- менеджер пакетов: opkg (24.10) или apk (25.12) ------------------------
detect_pm() {
    if command -v apk >/dev/null 2>&1 && [ -d /etc/apk ]; then PM=apk; PKG_EXT=apk
    elif command -v opkg >/dev/null 2>&1; then PM=opkg; PKG_EXT=ipk
    else PM=""; PKG_EXT=""; fi
    if [ "$PM" = apk ]; then
        ENGINE_FILE="podkop-engine_${ENGINE_VER}_openwrt_${ENGINE_ARCH}.apk"; ENGINE_SHA="$ENGINE_SHA_APK"
        PODKOP_FILE="$PODKOP_APK"; PODKOP_SHA="$PODKOP_SHA_APK"
        LUCI_FILE="$LUCI_APK";     LUCI_SHA="$LUCI_SHA_APK"
        RU_FILE="$RU_APK";         RU_SHA="$RU_SHA_APK"
    else
        ENGINE_FILE="podkop-engine_${ENGINE_VER}_openwrt_${ENGINE_ARCH}.ipk"; ENGINE_SHA="$ENGINE_SHA_IPK"
        PODKOP_FILE="$PODKOP_IPK"; PODKOP_SHA="$PODKOP_SHA_IPK"
        LUCI_FILE="$LUCI_IPK";     LUCI_SHA="$LUCI_SHA_IPK"
        RU_FILE="$RU_IPK";         RU_SHA="$RU_SHA_IPK"
    fi
    ENGINE_URL="$ENGINE_BASE/$ENGINE_FILE"
}

# установлен ли пакет именно с этим именем (apk: sing-box-tiny не считается за sing-box)
pkg_installed() {
    if [ "$PM" = apk ]; then apk list -I "$1" 2>/dev/null | grep -q "^$1-[0-9]"
    else opkg status "$1" 2>/dev/null | grep -q '^Status:.* installed'; fi
}
pkg_ver() {
    if [ "$PM" = apk ]; then apk list -I "$1" 2>/dev/null | awk -v n="$1" 'index($1, n"-")==1 {print substr($1, length(n)+2); exit}'
    else opkg status "$1" 2>/dev/null | sed -n 's/^Version: //p'; fi
}
# все архитектуры, которые знает система (apk может выдавать несколько строк, opkg — список с приоритетами)
sys_archs() {
    {
        if [ "$PM" = apk ]; then apk --print-arch 2>/dev/null; cat /etc/apk/arch 2>/dev/null
        else opkg print-architecture 2>/dev/null | awk '{print $2}'; fi
        sed -n "s/^DISTRIB_ARCH='\(.*\)'/\1/p" /etc/openwrt_release 2>/dev/null
    } | tr -d '\r' | tr ' ' '\n' | grep -v '^$' | sort -u
}
pkg_arch_ok() { sys_archs | grep -qx "$ENGINE_ARCH"; }
pkg_update() { pm_net update; }
pkg_add_repo() { # поставить из репозитория OpenWrt
    if [ "$PM" = apk ]; then run apk add "$@"; else run opkg install "$@"; fi
}
pkg_add_file() { # поставить/обновить из скачанного файла
    if [ "$PM" = apk ]; then run apk add --allow-untrusted "$@"; else run opkg install "$@"; fi
}
pkg_remove() {
    if [ "$PM" = apk ]; then run apk del "$@"; else run opkg remove "$@"; fi
}
pkg_fetch() { # скачать пакет из репозитория в каталог: pkg_fetch каталог имя
    # копия для отката потом ставится из файла (apk --allow-untrusted / opkg без проверки подписи),
    # поэтому качаем её только с официального сервера OpenWrt, никогда через зеркало
    if [ "$PM" = apk ]; then PM_NO_MIRROR=1 pm_net fetch -o "$1" "$2"
    else ( cd "$1" && PM_NO_MIRROR=1 pm_net download "$2" ); fi
}
# engine вместо sing-box. opkg: снять старый, поставить новый. apk: одной транзакцией, но сначала
# убрать из /etc/apk/world старые записи (иначе конфликт: !sing-box блокирует сам engine,
# а sing-box из локального файла намертво закрепляется после отката)
engine_install() { # engine_install файл старый_пакет
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
            info "$2 снят"
        fi
        run opkg install "$1"
    fi
}
# обычный sing-box вместо engine: из файла или из репозитория
engine_revert() { # engine_revert [файл]
    if [ "$PM" = apk ]; then
        if [ -n "$1" ]; then run apk add --allow-untrusted "$1" '!podkop-engine'
        else run apk add sing-box-tiny '!podkop-engine'; fi
    else
        pkg_installed podkop-engine && run opkg remove --force-depends podkop-engine
        if [ -n "$1" ]; then run opkg install "$1"
        else pm_net update; run opkg install sing-box-tiny; fi
    fi
}

# ---- утилиты ---------------------------------------------------------------
ver_ge() { [ "$(printf '%s\n%s\n' "$2" "$1" | sort -V | head -n1)" = "$2" ]; } # $1 >= $2
mem_avail_mb() { awk '/^MemAvailable:/{print int($2/1024)}' /proc/meminfo; }
free_kb() { df -k "$1" 2>/dev/null | awk 'NR==2{print $4}'; }
singbox_rss_mb() { p=$(pidof sing-box | awk '{print $1}'); [ -n "$p" ] && awk '/VmRSS/{print int($2/1024)}' "/proc/$p/status"; }

proxy_up() { # слушает ли mixed-вход podkop
    pidof sing-box >/dev/null && netstat -lnt 2>/dev/null | grep -q '127.0.0.1:4534 '
}

proxy_test() { # работает ли VPN через podkop
    command -v curl >/dev/null 2>&1 || return 1
    code=$(curl -s -o /dev/null -w '%{http_code}' --connect-timeout 8 --max-time 15 -x "$MIXED_PROXY" "$TEST_URL" 2>/dev/null)
    log "proxy test -> $code"
    [ "$code" = 204 ]
}

dns_fakeip_ok() { nslookup fakeip.podkop.fyi 127.0.0.1 2>/dev/null | grep -q 'Address.*198\.1[89]\.'; }
dns_direct_ok() { nslookup openwrt.org 127.0.0.1 2>/dev/null | grep -qE 'Address.*[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' ; }

download() { # download url файл sha256
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
            if [ "$got" = "$sha" ]; then ok "Скачан $name (контрольная сумма совпала)"; return 0; fi
            warn "Контрольная сумма $name не совпала (попытка $try)"
            log "sha256 got=$got want=$sha"
        else
            warn "Не удалось скачать $name (попытка $try)"
        fi
        rm -f "$dst"; sleep 3
    done
    return 1
}

# ---- откат -----------------------------------------------------------------
do_rollback() {
    log "=== ROLLBACK"
    trap '' INT TERM HUP
    run /etc/init.d/podkop stop
    info "podkop остановлен, интернет работает без VPN"
    run /etc/init.d/podkop-engine stop
    pkgf=$(ls "$BACKUP"/sing-box*."$PKG_EXT" "$WORK"/rollback/sing-box*."$PKG_EXT" 2>/dev/null | head -n1)
    if [ -n "$pkgf" ]; then
        engine_revert "$pkgf" && ok "Вернул $(basename "$pkgf")"
    else
        info "Сохранённого пакета нет, ставлю sing-box из репозитория OpenWrt..."
        [ "$PM" = apk ] && pm_net update
        engine_revert && ok "Вернул sing-box-tiny из репозитория"
    fi
    if ! sing-box version >/dev/null 2>&1 || sing-box version 2>/dev/null | head -n1 | grep -q pdk; then
        err "Не получилось вернуть обычный sing-box. podkop выключен, интернет работает без VPN."
        err "Диагностика: sh $0 report"
        return 1
    fi
    run /etc/init.d/sing-box stop
    run /etc/init.d/sing-box disable
    [ -f "$BACKUP/sing-box.config" ] && cp "$BACKUP/sing-box.config" /etc/config/sing-box && log "restored /etc/config/sing-box"
    run /etc/init.d/podkop start
    sleep 10
    if pidof sing-box >/dev/null; then ok "podkop снова запущен на обычном sing-box"; else warn "sing-box не поднялся — проверь podkop в LuCI"; fi
    CRITICAL=0
    return 0
}

# ---- отчёт -----------------------------------------------------------------
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
        echo "==== podkop-engine report $(date '+%Y-%m-%d %H:%M:%S') (скрипт $SCRIPT_VERSION)"
        echo "Модель: $(cat /tmp/sysinfo/model 2>/dev/null)"
        grep -E 'DISTRIB_(RELEASE|ARCH)' /etc/openwrt_release
        echo "Менеджер пакетов: $PM"
        [ "$PM" = apk ] && echo "apk world: $(grep -E 'sing-box|podkop' /etc/apk/world | sed 's/><.*//' | tr '\n' ' ')"
        echo "Аптайм: $(uptime)"
        echo; echo "---- версии"
        for p in podkop luci-app-podkop luci-i18n-podkop-ru podkop-engine sing-box sing-box-tiny; do
            v=$(pkg_ver "$p"); [ -n "$v" ] && echo "$p $v"
        done
        sing-box version 2>&1 | head -n 5
        echo; echo "---- память и флеш"
        free -m 2>/dev/null || cat /proc/meminfo | head -5
        df -h / /overlay /tmp 2>/dev/null
        echo "sing-box RSS: $(singbox_rss_mb) МБ"
        echo "Крупнейшие процессы:"
        for s in /proc/[0-9]*/status; do awk '/^Name:/{n=$2} /^VmRSS:/{print int($2/1024), n}' "$s" 2>/dev/null; done | sort -rn | head -n 6
        echo "OOM kills: $(awk '/^oom_kill /{print $2}' /proc/vmstat)"
        echo; echo "---- службы"
        for s in podkop sing-box podkop-engine; do
            [ -x /etc/init.d/$s ] && echo "$s: автозапуск=$(/etc/init.d/$s enabled && echo да || echo нет)"
        done
        echo "Процесс sing-box: $(pidof sing-box >/dev/null && echo запущен || echo НЕ запущен)"
        netstat -lntp 2>/dev/null | grep -E 'sing-box|dnsmasq' | grep -v 'fe80'
        echo; echo "---- проверки"
        dns_fakeip_ok && echo "DNS fakeip: OK" || echo "DNS fakeip: FAIL"
        dns_direct_ok && echo "DNS прямой: OK" || echo "DNS прямой: FAIL"
        if proxy_up; then proxy_test && echo "VPN через podkop: OK" || echo "VPN через podkop: FAIL"; else echo "VPN через podkop: прокси не слушает"; fi
        echo; echo "---- uci podkop / sing-box / dnsmasq"
        uci show podkop 2>/dev/null
        uci show sing-box 2>/dev/null
        uci show dhcp 2>/dev/null | grep -E '@dnsmasq\[0\]\.(server|noresolv|cachesize)'
        echo; echo "---- лог системы (podkop / sing-box)"
        logread 2>/dev/null | grep -E 'podkop|sing-box' | tail -n 80
        echo; echo "---- podkop global_check"
        /usr/bin/podkop global_check 2>&1 | tail -n 80
        if [ -f "$BACKUP/install.log" ]; then echo; echo "---- лог установки (хвост)"; tail -n 60 "$BACKUP/install.log"; fi
    } 2>&1 | redact > "$REPORT"
    cat "$REPORT"
    printf "\n${C_G}Отчёт сохранён:${C_0} %s\n" "$REPORT"
    echo "Ссылки на прокси, ключи, пароли и UUID в нём заменены на ***. Внешний IP и домены из журналов остаются."
}

# ---- шаги установки ----------------------------------------------------------
check_router() {
    step "Проверяю роутер"
    [ "$(id -u)" = 0 ] || fail "Запусти от root (ssh root@192.168.1.1)."

    model=$(cat /tmp/sysinfo/model 2>/dev/null)
    rel=$(sed -n "s/^DISTRIB_RELEASE='\(.*\)'/\1/p" /etc/openwrt_release)
    info "Роутер: ${model:-неизвестно}, OpenWrt $rel"
    [ -n "$PM" ] || fail "Не нашёл ни opkg, ни apk — это точно OpenWrt?"
    case "$rel" in
        24.*|25.*) ok "OpenWrt $rel, пакеты через $PM" ;;
        *SNAPSHOT*|*snapshot*) warn "Снапшот OpenWrt ($rel) — скрипт проверялся на 24.10 и 25.12, могут быть сюрпризы" ;;
        *) fail "Скрипт рассчитан на OpenWrt 24.10 и 25.12, а стоит $rel." ;;
    esac
    log "архитектуры системы: $(sys_archs | tr '\n' ' ')"
    pkg_arch_ok || fail "Архитектура не $ENGINE_ARCH (система сообщает: $(sys_archs | tr '\n' ' ')) — скрипт только для Xiaomi AX3000T и подобных."
    case "$model" in *AX3000T*) ok "Модель подходит" ;; *) warn "Скрипт проверялся на Xiaomi AX3000T, у тебя «$model» (архитектура подходит)" ;; esac

    [ -x /usr/bin/podkop ] || fail "podkop не установлен. Сначала поставь и настрой podkop."
    PODKOP_CUR=$(pkg_ver podkop | sed 's/^v//; s/-r[0-9]*$//')
    ver_ge "$PODKOP_CUR" "0.7.0" || fail "podkop $PODKOP_CUR слишком старый (нужен 0.7+). Обнови podkop официальным скриптом."
    ok "podkop $PODKOP_CUR"
    uci show podkop 2>/dev/null | grep -q "connection_type='proxy'" && PODKOP_HAS_PROXY=1 || PODKOP_HAS_PROXY=0
    [ "$PODKOP_HAS_PROXY" -eq 1 ] || warn "В podkop нет секций с прокси — проверка VPN будет пропущена"

    for p in podkop-engine sing-box-tiny sing-box; do
        if pkg_installed "$p"; then OLD_SB_PKG="$p"; break; fi
    done
    [ -n "$OLD_SB_PKG" ] || fail "Не нашёл установленный sing-box."
    OLD_SB_VER=$(pkg_ver "$OLD_SB_PKG")
    info "Сейчас: $OLD_SB_PKG $OLD_SB_VER"

    if [ "$OLD_SB_PKG" = podkop-engine ] && [ "$OLD_SB_VER" = "$ENGINE_VER" ] && ver_ge "$PODKOP_CUR" "$PODKOP_VER"; then
        ok "Уже стоит podkop-engine $ENGINE_VER и podkop $PODKOP_CUR — ставить нечего."
        info "Проверить состояние: sh $0 report"
        exit 0
    fi

    pkg_installed https-dns-proxy && fail "Стоит https-dns-proxy — он конфликтует с podkop. Удали его и запусти снова."

    mem=$(mem_avail_mb); rss=$(singbox_rss_mb)
    info "Свободно памяти: ${mem} МБ (sing-box сейчас занимает ${rss:-0} МБ)"
    [ "$((mem + ${rss:-0}))" -ge 50 ] || fail "Слишком мало свободной памяти ($mem МБ, нужно не меньше 50 с учётом sing-box)."

    # сколько освободит старый sing-box: размер самого бинарника (opkg status размер не сообщает)
    old_kb=$(du -k /usr/bin/sing-box 2>/dev/null | awk '{print $1}'); old_kb=${old_kb:-0}
    fl=$(free_kb /overlay)
    need=$((ENGINE_INSTALLED_KB - old_kb + 3000))
    [ "$OLD_SB_PKG" = podkop-engine ] && need=3000
    info "Свободно на флеше: $((fl / 1024)) МБ"
    [ "$fl" -ge "$need" ] || fail "Мало места на флеше: нужно ещё $(( (need - fl) / 1024 + 1 )) МБ."
    FLASH_FOR_BACKUP=$(( fl - need ))

    [ "$(free_kb /tmp)" -ge 25000 ] || fail "Мало места в /tmp (нужно 25 МБ)."

    if [ "$(date +%Y)" -lt 2025 ]; then
        info "Часы роутера сбиты, синхронизирую..."
        run ntpd -q -n -p 162.159.200.1 -p 216.239.35.0
    fi

    dns_direct_ok || fail "На роутере не работает DNS. Проверь интернет и запусти снова."
    ok "Интернет есть"

    BASELINE_PROXY=0
    if [ "$PODKOP_HAS_PROXY" -eq 1 ] && proxy_up && proxy_test; then
        BASELINE_PROXY=1; ok "VPN через podkop сейчас работает"
    elif [ "$PODKOP_HAS_PROXY" -eq 1 ]; then
        warn "VPN через podkop сейчас НЕ работает. После установки это тоже не будет считаться ошибкой."
    fi
}

plan_and_confirm() {
    echo
    echo "  Что будет сделано:"
    [ "$OLD_SB_PKG" != podkop-engine ] && echo "   - $OLD_SB_PKG $OLD_SB_VER → podkop-engine $ENGINE_VER (копия старого — для отката)"
    [ "$OLD_SB_PKG" = podkop-engine ] && echo "   - podkop-engine $OLD_SB_VER → $ENGINE_VER"
    ver_ge "$PODKOP_CUR" "$PODKOP_VER" || echo "   - podkop $PODKOP_CUR → $PODKOP_VER (+ интерфейс LuCI)"
    echo "   - настройки и ключи podkop не меняются"
    echo "   - интернет пропадёт примерно на 1–2 минуты"
    echo
    ask "Начинаем?" y || { info "Отменено, ничего не менял."; exit 0; }

    REMOVE_STATS=0
    present=""
    for p in vnstat2 nlbwmon; do pkg_installed $p && present="$present $p"; done
    if [ -n "$present" ]; then
        ask "Удалить статистику трафика ($present ) — освободит ~4 МБ памяти?" n && REMOVE_STATS=1
    fi
}

download_all() {
    step "Скачиваю пакеты и докачиваю зависимости"
    rm -rf "$WORK"; mkdir -p "$WORK/rollback" "$BACKUP"
    trap on_signal INT TERM     # Ctrl+C здесь безопасен: вернём фиды и выйдем, ничего не меняя

    LISTS_FRESH=0
    missing=""
    for d in $PODKOP_DEPS; do pkg_installed "$d" || missing="$missing $d"; done
    if [ -n "$missing" ]; then
        info "Не хватает:$missing — обновляю список пакетов OpenWrt (до 3 минут)..."
        pkg_update && LISTS_FRESH=1 || fail "Сервер пакетов OpenWrt не отвечает — не могу поставить:$missing. Попробуй позже."
        info "Ставлю недостающее:$missing"
        pkg_add_repo $missing || fail "Не поставились зависимости:$missing"
    fi
    ok "Зависимости на месте"
    if [ "$OLD_SB_PKG" != podkop-engine ] || [ "$OLD_SB_VER" != "$ENGINE_VER" ]; then
        download "$ENGINE_URL" "$WORK/$ENGINE_FILE" "$ENGINE_SHA" || fail "Не скачался podkop-engine. Интернет не трогал — всё работает как раньше."
        NEED_ENGINE=1
    else NEED_ENGINE=0; fi
    if ver_ge "$PODKOP_CUR" "$PODKOP_VER"; then
        NEED_PODKOP=0; info "podkop $PODKOP_CUR новее или равен $PODKOP_VER — не трогаю"
    else
        NEED_PODKOP=1
        download "$PODKOP_BASE/$PODKOP_FILE" "$WORK/$PODKOP_FILE" "$PODKOP_SHA" || fail "Не скачался podkop."
        download "$PODKOP_BASE/$LUCI_FILE" "$WORK/$LUCI_FILE" "$LUCI_SHA" || fail "Не скачался luci-app-podkop."
        if pkg_installed luci-i18n-podkop-ru || ask "Поставить русский язык для podkop в LuCI?" y; then
            download "$PODKOP_BASE/$RU_FILE" "$WORK/$RU_FILE" "$RU_SHA" && NEED_RU=1
        fi
    fi


    if [ "$OLD_SB_PKG" != podkop-engine ]; then
        saved=$(ls "$BACKUP"/"$OLD_SB_PKG"[-_][0-9]*."$PKG_EXT" 2>/dev/null | head -n1)
        if [ -z "$saved" ]; then
            info "Сохраняю копию $OLD_SB_PKG для отката (до 3 минут)..."
            pkg_fetch "$WORK/rollback" "$OLD_SB_PKG" || {
                [ "$LISTS_FRESH" -eq 0 ] && pkg_update && pkg_fetch "$WORK/rollback" "$OLD_SB_PKG"
            }
        fi
        rb=$(ls "$WORK"/rollback/"$OLD_SB_PKG"[-_][0-9]*."$PKG_EXT" 2>/dev/null | head -n1)
        if [ -n "$saved" ]; then
            ok "Пакет $OLD_SB_PKG для отката уже сохранён: $(basename "$saved")"
        elif [ -n "$rb" ]; then
            ok "Сохранил пакет $OLD_SB_PKG для отката"
        else
            warn "Не смог скачать $OLD_SB_PKG для отката. Если что-то пойдёт не так, его скачаем после выключения podkop."
            ask "Продолжить без сохранённой копии?" y || { info "Отменено, ничего не менял."; exit 0; }
        fi
    fi
}

make_backup() {
    step "Сохраняю настройки"
    stamp=$(date +%Y%m%d-%H%M%S)
    extra=""; [ "$PM" = apk ] && extra="/etc/apk/world"
    tar czf "$BACKUP/config-$stamp.tar.gz" /etc/config/podkop /etc/config/sing-box /etc/config/dhcp /etc/sing-box $extra 2>> "$LOG" \
        && ok "Настройки: $BACKUP/config-$stamp.tar.gz" || warn "Архив настроек не создался"
    [ -f /etc/config/sing-box ] && cp /etc/config/sing-box "$BACKUP/sing-box.config"
    rb=$(ls "$WORK"/rollback/*."$PKG_EXT" 2>/dev/null | head -n1)
    if [ -n "$rb" ]; then
        sz=$(( $(wc -c < "$rb") / 1024 ))
        if [ "${FLASH_FOR_BACKUP:-0}" -gt $((sz + 2000)) ]; then
            rm -f "$BACKUP"/sing-box*.ipk "$BACKUP"/sing-box*.apk; cp "$rb" "$BACKUP/" && ok "Пакет для отката лежит в $BACKUP (переживёт перезагрузку)"
        else
            info "Пакет для отката оставлен в памяти ($WORK) — на флеше мало места"
        fi
    fi
}

install_all() {
    step "Устанавливаю"
    trap '' HUP                 # обрыв SSH не прерывает установку
    trap on_signal INT TERM
    info "Если SSH оборвётся — установка всё равно закончится, лог: $BACKUP/install.log"

    run /etc/init.d/podkop stop
    ok "podkop остановлен (интернет пока работает без VPN)"

    if [ "$NEED_ENGINE" -eq 1 ]; then
        CRITICAL=1
        engine_install "$WORK/$ENGINE_FILE" "$OLD_SB_PKG" || fail "Не установился podkop-engine (подробности в логе)"
        # пакет сам запускает sing-box со старым конфигом — podkop запустит его правильно
        run /etc/init.d/sing-box stop
        run /etc/init.d/sing-box disable
        sing-box version 2>/dev/null | head -n1 | grep -q pdk || fail "После установки sing-box не похож на podkop-engine"
        ok "podkop-engine $ENGINE_VER установлен"
    fi

    if [ "$NEED_PODKOP" -eq 1 ]; then
        CRITICAL=1
        pkg_add_file "$WORK/$PODKOP_FILE" || fail "Не установился podkop $PODKOP_VER"
        pkg_add_file "$WORK/$LUCI_FILE" || warn "Не обновился интерфейс LuCI (podkop при этом работает)"
        [ "${NEED_RU:-0}" -eq 1 ] && { pkg_add_file "$WORK/$RU_FILE" || warn "Не встал русский язык LuCI"; }
        ok "podkop $PODKOP_VER установлен"
    fi

    if [ "${REMOVE_STATS:-0}" -eq 1 ]; then
        for p in $STATS_PKGS; do pkg_installed "$p" && pkg_remove "$p"; done
        ok "Статистика трафика удалена"
    fi

    rm -f /tmp/luci-indexcache* /tmp/luci-modulecache/* 2>/dev/null
    run /etc/init.d/rpcd reload
    run /etc/init.d/podkop-engine enable
    run /etc/init.d/podkop-engine restart
    logger -t podkop-engine-installer "podkop start"
    run /etc/init.d/podkop start
    ok "podkop запущен"
}

verify() {
    step "Проверяю, что всё работает (до 2 минут)"
    t=0; sb=0; fk=0; dd=0; px=0
    while [ $t -lt 120 ]; do
        [ $sb -eq 0 ] && pidof sing-box >/dev/null && { sb=1; ok "sing-box запущен"; }
        [ $sb -eq 1 ] && [ $fk -eq 0 ] && dns_fakeip_ok && { fk=1; ok "DNS podkop отвечает"; }
        [ $dd -eq 0 ] && dns_direct_ok && { dd=1; ok "Обычный DNS работает"; }
        if [ "$BASELINE_PROXY" -eq 1 ] && [ $px -eq 0 ] && proxy_up && proxy_test; then px=1; ok "VPN через podkop работает"; fi
        if [ $sb -eq 1 ] && [ $fk -eq 1 ] && [ $dd -eq 1 ] && { [ "$BASELINE_PROXY" -eq 0 ] || [ $px -eq 1 ]; }; then
            break
        fi
        sleep 4; t=$((t + 4))
    done
    log "verify: sb=$sb fakeip=$fk direct=$dd proxy=$px baseline=$BASELINE_PROXY t=$t"
    # ошибки sing-box только после нашего запуска podkop
    fatal=$(logread 2>/dev/null | sed -n '/podkop-engine-installer: podkop start/,$p' | grep -E 'sing-box.*(FATAL|panic)' | tail -n 3)
    if [ -n "$fatal" ]; then
        log "fatal after start: $fatal"
        if [ $sb -eq 1 ]; then
            warn "sing-box один раз упал при запуске, но перезапустился и работает (подробности в логе)"
        else
            echo "$fatal" | while read -r l; do err "$l"; done
        fi
    fi
    [ $sb -eq 1 ] || fail "sing-box не запустился"
    [ $fk -eq 1 ] || fail "DNS podkop не отвечает"
    [ $dd -eq 1 ] || fail "Обычный DNS не работает"
    [ "$BASELINE_PROXY" -eq 1 ] && [ $px -eq 0 ] && fail "VPN через podkop перестал работать (до установки работал)"
    CRITICAL=0
}

summary() {
    step "Готово"
    rm -rf "$WORK"
    finish_log
    printf "  ${C_G}Всё работает.${C_0}\n"
    info "sing-box: $(sing-box version 2>/dev/null | head -n1 | awk '{print $3}'), память: $(singbox_rss_mb) МБ, свободно: $(mem_avail_mb) МБ"
    info "podkop: $(pkg_ver podkop)"
    sing-box version 2>/dev/null | grep -q 'xhttp' && info "Теперь в podkop можно добавлять ключи с транспортом xhttp"
    info "Включено: запасной DNS провайдера, проверка сервера скачиванием, защита от зависания sing-box"
    echo
    echo "  Если что-то не так:"
    echo "    sh $0 report     — отчёт для диагностики (без ключей)"
    echo "    sh $0 rollback   — вернуть обычный sing-box"
    echo "  Лог установки: $BACKUP/install.log"
}

usage() {
    sed -n '2,14p' "$0" | sed 's/^# \{0,1\}//'
}

# ---- запуск ----------------------------------------------------------------
CMD=install
for a in "$@"; do
    case "$a" in
        -y|--yes) ASSUME_YES=1 ;;
        --no-rollback) AUTO_ROLLBACK=0 ;;
        install|check|report|rollback) CMD=$a ;;
        help|-h|--help) usage; exit 0 ;;
        *) echo "Неизвестный параметр: $a"; usage; exit 1 ;;
    esac
done

: > "$LOG"
detect_pm
log "podkop-engine installer $SCRIPT_VERSION, cmd=$CMD, args=$*, pm=$PM"

case "$CMD" in
    report) do_report ;;
    check)
        STEPS=1
        printf "${C_B}Проверка роутера перед установкой podkop-engine %s${C_0}\n" "$ENGINE_VER"
        check_router
        printf "\n${C_G}Роутер подходит.${C_0} Ничего не менял. Установить: sh %s\n" "$0" ;;
    rollback)
        printf "${C_B}Возврат обычного sing-box${C_0}\n"
        ask "Вернуть обычный sing-box вместо podkop-engine?" y || exit 0
        mkdir -p "$BACKUP"; CRITICAL=1; do_rollback; rc=$?; finish_log; exit $rc ;;
    install)
        printf "${C_B}Установка podkop-engine %s для podkop${C_0} (скрипт %s)\n" "$ENGINE_VER" "$SCRIPT_VERSION"
        check_router
        plan_and_confirm
        download_all
        make_backup
        install_all
        verify
        summary ;;
esac
