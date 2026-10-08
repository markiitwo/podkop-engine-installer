#!/bin/sh
# Установка podkop-engine (сборка sing-box для podkop) + обновление podkop
# для Xiaomi AX3000T на OpenWrt 24.10 с уже настроенным podkop.
#
#   wget -O /root/pe.sh https://raw.githubusercontent.com/markiitwo/podkop-engine-installer/main/install.sh
#   sh /root/pe.sh            установить / обновить
#   sh /root/pe.sh check      только проверить роутер, ничего не меняя
#   sh /root/pe.sh report     собрать отчёт для помощи (ключи вырезаются)
#   sh /root/pe.sh rollback   вернуть обычный sing-box
#   sh /root/pe.sh help
#
# Ключи: -y (не задавать вопросов), --no-rollback (не откатывать при неудачной проверке)

SCRIPT_VERSION="1.2"

# ---- проверенные версии (обновлять вместе) ---------------------------------
ENGINE_VER="1.14.2-r12"
ENGINE_ARCH="aarch64_cortex-a53"
ENGINE_FILE="podkop-engine_${ENGINE_VER}_openwrt_${ENGINE_ARCH}.ipk"
ENGINE_URL="https://github.com/FiyeroT/podkop-engine/releases/download/v${ENGINE_VER}/${ENGINE_FILE}"
ENGINE_SHA="e06cbcd3e1e91d657ab86f817a7cf012b522c5591e809fe9f49f13f6f04b58b0"
ENGINE_INSTALLED_KB=22400

PODKOP_VER="0.7.23"
PODKOP_BASE="https://github.com/itdoginfo/podkop/releases/download/${PODKOP_VER}"
PODKOP_FILE="podkop-v${PODKOP_VER}-r1-all.ipk"
PODKOP_SHA="7dc233d3d5fd98245109b7a9539609d7f98f8eea3422c4a867a74f2b0aec55e0"
LUCI_FILE="luci-app-podkop-v${PODKOP_VER}-r1-all.ipk"
LUCI_SHA="5f9edd1da5498056ab5d1ddb42d21317d3c412e0d9fe3a93ffaa1b37961037d6"
RU_FILE="luci-i18n-podkop-ru-${PODKOP_VER}.ipk"
RU_SHA="e92aea80d6fbfbb890853f0af2fde05afdffc585710e40ccccc74061173681e4"

PODKOP_DEPS="curl jq kmod-nft-tproxy coreutils-base64 bind-dig ca-bundle"
STATS_PKGS="luci-app-vnstat2 vnstati2 vnstat2 luci-app-nlbwmon nlbwmon"

WORK=/tmp/podkop-engine-install
BACKUP=/root/podkop-engine-backup
LOG=/tmp/podkop-engine-install.log
REPORT=/tmp/podkop-engine-report.txt
MIXED_PROXY="http://127.0.0.1:4534"
TEST_URL="https://www.gstatic.com/generate_204"

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

# opkg update/download с повторами; при неудаче — через VPN podkop
opkg_net() {
    for try in 1 2; do run opkg "$@" && return 0; sleep 3; done
    if proxy_up; then
        log "opkg $* через podkop"
        ( export http_proxy="$MIXED_PROXY" https_proxy="$MIXED_PROXY"; run opkg "$@" ) && return 0
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
    if [ "$CRITICAL" -eq 1 ]; then
        if [ "$AUTO_ROLLBACK" -eq 1 ]; then
            warn "Возвращаю всё как было..."
            do_rollback
        else
            warn "Автооткат выключен (--no-rollback). Вернуть: sh $0 rollback"
        fi
    fi
    finish_log
    printf "\n${C_R}Установка не удалась.${C_0} Лог: %s\n" "$BACKUP/install.log"
    printf "Для помощи: ${C_B}sh %s report${C_0} — и пришли результат.\n" "$0"
    exit 1
}

finish_log() { mkdir -p "$BACKUP" 2>/dev/null && cp "$LOG" "$BACKUP/install.log" 2>/dev/null; }

on_signal() {
    log "получен сигнал прерывания"
    printf "\n"
    fail "Установка прервана."
}

# ---- утилиты ---------------------------------------------------------------
pkg_ver() { opkg status "$1" 2>/dev/null | sed -n 's/^Version: //p'; }
pkg_installed() { opkg status "$1" 2>/dev/null | grep -q '^Status:.* installed'; }
ver_ge() { [ "$(printf '%s\n%s\n' "$2" "$1" | sort -V | head -n1)" = "$2" ]; } # $1 >= $2
mem_avail_mb() { awk '/^MemAvailable:/{print int($2/1024)}' /proc/meminfo; }
free_kb() { df -k "$1" 2>/dev/null | awk 'NR==2{print $4}'; }
singbox_rss_mb() { p=$(pidof sing-box | awk '{print $1}'); [ -n "$p" ] && awk '/VmRSS/{print int($2/1024)}' "/proc/$p/status"; }

proxy_up() { # слушает ли mixed-вход podkop
    pidof sing-box >/dev/null && netstat -lnt 2>/dev/null | grep -q '127.0.0.1:4534 '
}

proxy_test() { # работает ли VPN через podkop
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
            curl -fsSL --connect-timeout 15 --max-time 600 -o "$dst" "$url" >> "$LOG" 2>&1
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
    ipk=$(ls "$BACKUP"/sing-box*.ipk "$WORK"/rollback/sing-box*.ipk 2>/dev/null | head -n1)
    if [ -z "$ipk" ]; then
        info "Сохранённого пакета нет, скачиваю sing-box из репозитория OpenWrt..."
        mkdir -p "$WORK/rollback" && cd "$WORK/rollback" || return 1
        run opkg update
        run opkg download sing-box-tiny || run opkg download sing-box
        ipk=$(ls "$WORK"/rollback/sing-box*.ipk 2>/dev/null | head -n1)
        cd / || true
    fi
    if [ -z "$ipk" ]; then
        err "Не нашёл пакет sing-box для отката. podkop оставлен выключенным — интернет работает, но без VPN."
        err "Напиши Никите и пришли: sh $0 report"
        return 1
    fi
    pkg_installed podkop-engine && run opkg remove --force-depends podkop-engine
    run /etc/init.d/podkop-engine stop
    if run opkg install "$ipk"; then
        ok "Вернул $(basename "$ipk")"
    else
        err "Не смог поставить $(basename "$ipk"). podkop выключен, интернет работает без VPN."
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
    echo "Ключи, пароли и UUID в нём заменены звёздочками. Скопируй текст выше или файл и пришли Никите."
}

# ---- шаги установки ----------------------------------------------------------
check_router() {
    step "Проверяю роутер"
    [ "$(id -u)" = 0 ] || fail "Запусти от root (ssh root@192.168.1.1)."

    model=$(cat /tmp/sysinfo/model 2>/dev/null)
    rel=$(sed -n "s/^DISTRIB_RELEASE='\(.*\)'/\1/p" /etc/openwrt_release)
    info "Роутер: ${model:-неизвестно}, OpenWrt $rel"
    command -v opkg >/dev/null || fail "Нет opkg. Скрипт рассчитан на OpenWrt 24.10 (не 25.x)."
    case "$rel" in 24.*) ;; *) fail "Нужен OpenWrt 24.10, а стоит $rel." ;; esac
    opkg print-architecture | grep -q " $ENGINE_ARCH " || fail "Архитектура не $ENGINE_ARCH — скрипт только для Xiaomi AX3000T и подобных."
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
    [ "$((mem + ${rss:-0}))" -ge 50 ] || fail "Слишком мало свободной памяти ($mem МБ). Пришли Никите: sh $0 report"

    old_kb=$(opkg status "$OLD_SB_PKG" | sed -n 's/^Installed-Size: //p'); old_kb=$(( ${old_kb:-0} / 1024 ))
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

    info "Обновляю список пакетов OpenWrt..."
    if opkg_net update; then ok "Список пакетов обновлён"; else warn "Список пакетов обновился не полностью (сервер OpenWrt не отвечал) — продолжаю, если всё нужное уже есть"; fi
    missing=""
    for d in $PODKOP_DEPS; do pkg_installed "$d" || missing="$missing $d"; done
    if [ -n "$missing" ]; then
        info "Ставлю недостающее:$missing"
        run opkg install $missing || fail "Не поставились зависимости:$missing"
    fi
    ok "Зависимости на месте"

    if [ "$OLD_SB_PKG" != podkop-engine ]; then
        saved=$(ls "$BACKUP"/"$OLD_SB_PKG"_*.ipk 2>/dev/null | head -n1)
        if [ -z "$saved" ]; then
            cd "$WORK/rollback" || fail "Нет $WORK/rollback"
            opkg_net download "$OLD_SB_PKG"
            cd / || true
        fi
        rb=$(ls "$WORK"/rollback/"$OLD_SB_PKG"_*.ipk 2>/dev/null | head -n1)
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
    tar czf "$BACKUP/config-$stamp.tar.gz" /etc/config/podkop /etc/config/sing-box /etc/config/dhcp /etc/sing-box 2>> "$LOG" \
        && ok "Настройки: $BACKUP/config-$stamp.tar.gz" || warn "Архив настроек не создался"
    [ -f /etc/config/sing-box ] && cp /etc/config/sing-box "$BACKUP/sing-box.config"
    rb=$(ls "$WORK"/rollback/*.ipk 2>/dev/null | head -n1)
    if [ -n "$rb" ]; then
        sz=$(( $(wc -c < "$rb") / 1024 ))
        if [ "${FLASH_FOR_BACKUP:-0}" -gt $((sz + 2000)) ]; then
            rm -f "$BACKUP"/sing-box*.ipk; cp "$rb" "$BACKUP/" && ok "Пакет для отката лежит в $BACKUP (переживёт перезагрузку)"
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
        if [ "$OLD_SB_PKG" != podkop-engine ]; then
            run opkg remove --force-depends "$OLD_SB_PKG" || fail "Не удалось снять $OLD_SB_PKG"
            info "$OLD_SB_PKG снят"
        fi
        run opkg install "$WORK/$ENGINE_FILE" || fail "Не установился podkop-engine (подробности в логе)"
        # пакет сам запускает sing-box со старым конфигом — podkop запустит его правильно
        run /etc/init.d/sing-box stop
        run /etc/init.d/sing-box disable
        sing-box version 2>/dev/null | head -n1 | grep -q pdk || fail "После установки sing-box не похож на podkop-engine"
        ok "podkop-engine $ENGINE_VER установлен"
    fi

    if [ "$NEED_PODKOP" -eq 1 ]; then
        CRITICAL=1
        run opkg install "$WORK/$PODKOP_FILE" || fail "Не установился podkop $PODKOP_VER"
        run opkg install "$WORK/$LUCI_FILE" || warn "Не обновился интерфейс LuCI (podkop при этом работает)"
        [ "${NEED_RU:-0}" -eq 1 ] && { run opkg install "$WORK/$RU_FILE" || warn "Не встал русский язык LuCI"; }
        ok "podkop $PODKOP_VER установлен"
    fi

    if [ "${REMOVE_STATS:-0}" -eq 1 ]; then
        for p in $STATS_PKGS; do pkg_installed "$p" && run opkg remove "$p"; done
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
    echo "    sh $0 report     — отчёт для Никиты (без ключей)"
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
log "podkop-engine installer $SCRIPT_VERSION, cmd=$CMD, args=$*"

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
        CRITICAL=1; do_rollback; rc=$?; finish_log; exit $rc ;;
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
