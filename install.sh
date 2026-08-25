#!/usr/bin/env bash
#===============================================================================
# Telegram Web Proxy Auto-Installer
# Created by: xanka
#
# Устанавливает официальный стек WEB-прокси Telegram:
#   Caddy (:80/:443) -> tproxy-server (127.0.0.1:8080) -> MTProxy (127.0.0.1:2398)
#
# Скрипт является обёрткой над официальным установщиком
# github.com/telegramdesktop/tproxy-server (deploy/install.sh):
# все загрузки там проверяются по контрольным суммам, конфиги валидируются,
# а сервисы проверяются на готовность.
#===============================================================================

set -Eeuo pipefail
umask 022

GREEN='\033[0;32m'
BLUE='\033[0;34m'
RED='\033[1;31m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
RESET='\033[0m'

UPSTREAM_REPO="https://github.com/telegramdesktop/tproxy-server.git"
SRC_DIR=/opt/tproxy-server-src
INFO_FILE=/root/telegram_webproxy_info.txt
SITE_DIR_DEFAULT=/srv/tproxy-site

step()    { echo -e "\n${YELLOW}========================================\n$1\n========================================${RESET}"; }
success() { echo -e "${GREEN}[+] $1${RESET}"; }
warn()    { echo -e "${YELLOW}[!] $1${RESET}"; }
info()    { echo -e "${BLUE}[*] $1${RESET}"; }
error()   { echo -e "${RED}[-] $1${RESET}" >&2; exit 1; }

PHASE=preflight

on_error() {
    local code=$?
    echo -e "\n${RED}========================================${RESET}" >&2
    echo -e "${RED} УСТАНОВКА ПРЕРВАНА (код $code)${RESET}" >&2
    echo -e "${RED}========================================${RESET}" >&2
    if [[ "$PHASE" == install ]]; then
        echo -e "${YELLOW}Диагностика:${RESET}" >&2
        for unit in caddy tproxy-firewall mtproxy tproxy-server; do
            if [[ -f "/etc/systemd/system/$unit.service" ]]; then
                echo -e "\n--- $unit ---" >&2
                systemctl --no-pager --full status "$unit" 2>&1 | head -n 12 >&2 || true
                journalctl -u "$unit" --no-pager -n 15 2>&1 | head -n 15 >&2 || true
            fi
        done
    fi
    echo -e "\n${YELLOW}Повторный запуск скрипта безопасен: он продолжит с того же места" >&2
    echo -e "и переиспользует уже сгенерированный секрет.${RESET}" >&2
    exit "$code"
}
trap on_error ERR

clear 2>/dev/null || true
echo -e "${CYAN}========================================================================${RESET}"
echo -e "${GREEN} __        __   _         ____                           ${RESET}"
echo -e "${GREEN} \ \      / /__| |__     |  _ \ _ __ _____  ___   _      ${RESET}"
echo -e "${GREEN}  \ \ /\ / / _ \ '_ \    | |_) | '__/ _ \ \/ / | | |     ${RESET}"
echo -e "${GREEN}   \ V  V /  __/ |_) |   |  __/| | | (_) >  <| |_| |     ${RESET}"
echo -e "${GREEN}    \_/\_/ \___|_.__/    |_|   |_|  \___/_/\_\\\__, |     ${RESET}"
echo -e "${GREEN}                                              |___/      ${RESET}"
echo -e "${CYAN}========================================================================${RESET}"
echo -e "${YELLOW}                 AUTO-INSTALLER by @sacoq                  ${RESET}"
echo -e "${CYAN}========================================================================${RESET}"
echo ""

#------------------------------------------------------------------------------
# Аргументы
#------------------------------------------------------------------------------
DOMAIN="${DOMAIN:-}"
EMAIL="${EMAIL:-}"
SECRET="${SECRET:-}"
SITE_DIR=""
SITE_UPSTREAM=""
FORCE_SITE=""
WORKERS="${WORKERS:-1}"
MAX_CONNECTIONS="${MAX_CONNECTIONS:-4096}"

usage() {
    cat >&2 <<USAGE
Использование:
  bash install.sh <домен> [опции]

Опции:
  --email  EMAIL          контактный e-mail для Let's Encrypt (по умолчанию admin@<домен>)
  --secret HEX            32 hex-символа; по умолчанию генерируется автоматически
  --site-dir DIR          каталог вашего сайта-заглушки (должен содержать index.html)
  --site-upstream URL     вместо статики проксировать локальное приложение, напр. http://127.0.0.1:3000
  --force-site            перегенерировать сайт-заглушку, даже если он уже установлен
                          (прежний каталог сохраняется рядом с меткой времени)
  --workers N             воркеров MTProxy (по умолчанию 1)
  --max-connections N     соединений на воркер (по умолчанию 4096)
USAGE
    exit 2
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --email)           EMAIL="${2:-}"; shift 2 ;;
        --secret)          SECRET="${2:-}"; shift 2 ;;
        --site-dir)        SITE_DIR="${2:-}"; shift 2 ;;
        --site-upstream)   SITE_UPSTREAM="${2:-}"; shift 2 ;;
        --force-site)      FORCE_SITE=1; shift ;;
        --workers)         WORKERS="${2:-}"; shift 2 ;;
        --max-connections) MAX_CONNECTIONS="${2:-}"; shift 2 ;;
        -h|--help)         usage ;;
        -*)                echo "Неизвестная опция: $1" >&2; usage ;;
        *)                 if [[ -z "$DOMAIN" ]]; then DOMAIN="$1"; shift; else usage; fi ;;
    esac
done

#------------------------------------------------------------------------------
# Проверки окружения
#------------------------------------------------------------------------------
step "Проверка окружения..."

[[ $EUID -eq 0 ]] || error "Скрипт должен быть запущен от имени root (используйте sudo)"

if [[ "$(uname -s)" != "Linux" ]]; then
    error "Поддерживается только Linux"
fi

if [[ "$(uname -m)" != "x86_64" ]]; then
    error "Официальное ядро MTProxy собирается только под x86_64 (у вас: $(uname -m)).
       ARM-серверы (Oracle Ampere, Hetzner CAX, Raspberry Pi) не подходят."
fi

[[ -d /run/systemd/system ]] || error "Требуется systemd"
command -v apt-get >/dev/null 2>&1 || error "Требуется Debian 12+ или Ubuntu 22.04+ (apt-get не найден)"

if [[ -r /etc/os-release ]]; then
    . /etc/os-release
    case "${ID:-}:${VERSION_ID:-}" in
        debian:1[01]|debian:1[01].*) warn "Debian ${VERSION_ID} устарел; официально поддерживается Debian 12+." ;;
        ubuntu:2[01].*|ubuntu:1*)    warn "Ubuntu ${VERSION_ID} устарел; официально поддерживается Ubuntu 22.04+." ;;
    esac
    success "Система: ${PRETTY_NAME:-unknown}"
fi

#------------------------------------------------------------------------------
# Домен
#------------------------------------------------------------------------------
if [[ -z "$DOMAIN" ]]; then
    read -rp "$(echo -e "${BLUE}Введите ВАШ домен для прокси (А-запись должна указывать на этот сервер): ${RESET}")" DOMAIN
fi

DOMAIN="$(echo "$DOMAIN" | tr '[:upper:]' '[:lower:]' | sed -E 's#^https?://##; s#/.*$##; s#:.*$##')"

if [[ -z "$DOMAIN" || "$DOMAIN" == "proxy.example.com" ]]; then
    error "Нужен ваш реальный домен, а не пример. Установка прервана."
fi
if [[ ! "$DOMAIN" =~ ^[a-z0-9]([a-z0-9.-]*[a-z0-9])?$ ]] || [[ "$DOMAIN" != *.* ]]; then
    error "Некорректное доменное имя: $DOMAIN"
fi

[[ -n "$EMAIL" ]] || EMAIL="admin@${DOMAIN}"
if [[ ! "$EMAIL" =~ ^[A-Za-z0-9._+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$ ]]; then
    error "Некорректный e-mail: $EMAIL"
fi

#------------------------------------------------------------------------------
# Секрет: переиспользуем существующий, чтобы повторный запуск был безопасен
#------------------------------------------------------------------------------
if [[ -z "$SECRET" && -f /etc/tproxy-server/profiles.json ]]; then
    SECRET="$(sed -nE 's/.*"secret"[[:space:]]*:[[:space:]]*"([0-9a-f]{32})".*/\1/p' \
        /etc/tproxy-server/profiles.json | head -n1)"
    [[ -n "$SECRET" ]] && info "Найдена предыдущая установка — секрет переиспользован."
fi
if [[ -z "$SECRET" ]]; then
    command -v openssl >/dev/null 2>&1 || { apt-get update -qq; apt-get install -y -qq openssl; }
    SECRET="$(openssl rand -hex 16)"
fi
if [[ ! "$SECRET" =~ ^([0-9a-f]{32}|dd[0-9a-f]{32})$ ]]; then
    error "Секрет должен состоять из 32 hex-символов в нижнем регистре"
fi

if [[ ! "$WORKERS" =~ ^[1-9][0-9]*$ ]];         then error "--workers должен быть положительным числом"; fi
if [[ ! "$MAX_CONNECTIONS" =~ ^[1-9][0-9]*$ ]]; then error "--max-connections должен быть положительным числом"; fi

success "Домен:  $DOMAIN"
success "Email:  $EMAIL"
success "Secret: $SECRET"

#------------------------------------------------------------------------------
# Зависимости
#------------------------------------------------------------------------------
step "Установка базовых зависимостей..."
export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=a
apt-get update
apt-get install -y --no-install-recommends ca-certificates curl git openssl iproute2
success "Зависимости установлены"

#------------------------------------------------------------------------------
# Предполётные проверки сети (не блокирующие)
#------------------------------------------------------------------------------
step "Проверка DNS и портов..."

SERVER_IP="$(curl -fsS --max-time 10 https://api.ipify.org 2>/dev/null || true)"
[[ -n "$SERVER_IP" ]] || SERVER_IP="$(ip -4 route get 1.1.1.1 2>/dev/null | sed -nE 's/.* src ([0-9.]+).*/\1/p' | head -n1 || true)"
DOMAIN_IP="$(getent ahostsv4 "$DOMAIN" 2>/dev/null | awk 'NR==1{print $1}' || true)"

if [[ -z "$DOMAIN_IP" ]]; then
    warn "Домен $DOMAIN не резолвится. Caddy не сможет получить сертификат Let's Encrypt."
    warn "Добавьте A-запись $DOMAIN -> ${SERVER_IP:-IP_сервера} и дождитесь распространения DNS."
elif [[ -n "$SERVER_IP" && "$DOMAIN_IP" != "$SERVER_IP" ]]; then
    warn "A-запись $DOMAIN указывает на $DOMAIN_IP, а IP этого сервера — $SERVER_IP."
    warn "Если это не Cloudflare/балансировщик, выпуск сертификата не удастся."
else
    success "DNS в порядке: $DOMAIN -> $DOMAIN_IP"
fi

caddy_running=""
for port in 80 443; do
    holder="$(ss -lntpH "sport = :$port" 2>/dev/null | sed -nE 's/.*users:\(\("([^"]+)".*/\1/p' | head -n1 || true)"
    if [[ -n "$holder" && "$holder" != "caddy" ]]; then
        error "Порт $port уже занят процессом «$holder» (nginx/apache?).
       Остановите его: systemctl disable --now $holder"
    fi
    [[ "$holder" == "caddy" ]] && caddy_running=1
done
if [[ -n "$caddy_running" ]]; then
    info "Порты 80/443 держит Caddy от предыдущей установки — он будет перенастроен."
else
    success "Порты 80/443 свободны"
fi

#------------------------------------------------------------------------------
# Исходники официального релея
#------------------------------------------------------------------------------
step "Получение официальных исходников tproxy-server..."

if [[ -d "$SRC_DIR/.git" ]]; then
    git -C "$SRC_DIR" fetch --depth 1 origin HEAD
    git -C "$SRC_DIR" reset --hard FETCH_HEAD
    git -C "$SRC_DIR" clean -fdx
else
    rm -rf "$SRC_DIR"
    git clone --depth 1 "$UPSTREAM_REPO" "$SRC_DIR"
fi
chmod +x "$SRC_DIR/deploy/install.sh" "$SRC_DIR/deploy/install-mtproxy.sh"

# Обходной путь для бага апстрима: deploy/install.sh выставляет `umask 077`, а затем
# запускает `go test ./...`. Тест TestLoadAcceptsSystemdCredentialReadPermissions создаёт
# profiles.json с режимом 0444 и ждёт, что Load его отвергнет как доступный на чтение
# группе и остальным. Под umask 077 файл получает режим 0400, Load его принимает,
# и тест падает — установка обрывается на исправном сервере.
# Прогоняем тесты под umask 022; на создание файлов установщиком это не влияет.
if grep -qE '^\(cd .* test \./\.\.\.\)$' "$SRC_DIR/deploy/install.sh"; then
    sed -i -E 's|^\(cd .* test \./\.\.\.\)$|(umask 022; &)|' "$SRC_DIR/deploy/install.sh"
    grep -q 'umask 022; (cd' "$SRC_DIR/deploy/install.sh" ||
        error "Не удалось применить обходной путь для тестов апстрима"
    success "Применён обходной путь для umask в тестах апстрима"
else
    warn "Строка запуска тестов апстрима не найдена — обходной путь не нужен или формат изменился."
fi

# Тот же баг во второй раз: install-mtproxy.sh наследует `umask 077` от deploy/install.sh,
# поэтому make создаёт objs/, objs/bin/ и сам бинарник с режимом 0700. Дерево затем
# отдаётся root:root, а юнит запускает mtproto-proxy от пользователя mtproxy — тот не может
# войти в каталог и systemd сообщает 203/EXEC. Собираем под umask 022.
if grep -q '^umask 022$' "$SRC_DIR/deploy/install-mtproxy.sh"; then
    :
elif grep -q '^set -euo pipefail$' "$SRC_DIR/deploy/install-mtproxy.sh"; then
    sed -i '/^set -euo pipefail$/a umask 022' "$SRC_DIR/deploy/install-mtproxy.sh"
    grep -q '^umask 022$' "$SRC_DIR/deploy/install-mtproxy.sh" ||
        error "Не удалось применить обходной путь для umask при сборке MTProxy"
    success "Применён обходной путь для umask при сборке MTProxy"
else
    warn "Формат install-mtproxy.sh изменился — обходной путь для umask не применён."
fi

# Установщик пропускает пересборку, если бинарник уже на месте, поэтому дерево,
# собранное прошлым запуском под umask 077, надо починить отдельно.
if [[ -d /opt/MTProxy ]]; then
    chmod -R a+rX /opt/MTProxy
    if id -u mtproxy >/dev/null 2>&1 &&
       ! runuser -u mtproxy -- test -x /opt/MTProxy/objs/bin/mtproto-proxy; then
        warn "Пользователь mtproxy всё ещё не может запустить mtproto-proxy."
        warn "Удаляем /opt/MTProxy — установщик пересоберёт его под корректным umask."
        ls -ld /opt/MTProxy /opt/MTProxy/objs /opt/MTProxy/objs/bin \
               /opt/MTProxy/objs/bin/mtproto-proxy 2>&1 | sed 's/^/    /' || true
        rm -rf /opt/MTProxy
    else
        success "Права на /opt/MTProxy в порядке"
    fi
fi

success "Исходники: $SRC_DIR ($(git -C "$SRC_DIR" rev-parse --short HEAD))"

#------------------------------------------------------------------------------
# Сайт-заглушка
#------------------------------------------------------------------------------
SITE_ARGS=()
if [[ -n "$SITE_UPSTREAM" ]]; then
    SITE_ARGS=(--site-upstream "$SITE_UPSTREAM")
elif [[ -n "$SITE_DIR" ]]; then
    SITE_ARGS=(--site-dir "$SITE_DIR")
elif [[ -f "$SITE_DIR_DEFAULT/index.html" && -z "$FORCE_SITE" ]]; then
    info "Используется уже установленный сайт в $SITE_DIR_DEFAULT"
    info "Чтобы сгенерировать новый, добавьте --force-site"
else
    step "Генерация сайта-заглушки (видеоплатформа)..."
    GEN_SITE=/opt/tproxy-site-default
    BRAND="${DOMAIN%%.*}"
    BRAND="${BRAND^}"
    ROOTDOMAIN="${DOMAIN#*.}"
    YEAR="$(date +%Y)"
    rm -rf "$GEN_SITE"
    mkdir -p "$GEN_SITE/assets"

    # Сайт детерминированно варьируется по домену: оттенок палитры, порядок и подбор
    # карточек. Иначе у всех, кто ставит этот скрипт, страница была бы побайтово
    # одинаковой — готовая сигнатура для активного сканирования.
    DHASH="$(printf '%s' "$DOMAIN" | cksum | cut -d' ' -f1)"
    HUE=$(( DHASH % 360 ))
    ROT=$(( DHASH % 16 ))

    titles=(
        "Harbor timelapse — fog rolling in before dawn"
        "Rebuilding a 1974 turntable, part 3: the tonearm"
        "Ambient set for deep work — three hours, no talking"
        "How we cut our build times from 14 minutes to 90 seconds"
        "Night market walk, 4K, binaural audio"
        "Sourdough from a cold starter: the honest version"
        "Field recording: rain on a tin roof, ten hours"
        "Repairing a cracked bowl with gold lacquer"
        "Every bridge in the old town, one continuous take"
        "Analog synth patch from scratch, no presets"
        "Winter cabin build — episode 12: the stove"
        "How a freight yard actually schedules itself"
        "Studio session: strings on a rainy afternoon"
        "Mountain pass in a single shot, sunrise to noon"
        "Restoring a water-damaged photograph, start to finish"
        "Slow TV: the 06:40 train, front window, full route"
    )
    channels=(
        "Northline Studio" "Corvid Workshop" "Salt and Static" "Low Orbit Media"
        "Pinehold Films" "Third Rail Audio" "Meridian Field" "Kestrel Lab"
    )
    durs=(
        "12:04" "48:31" "3:01:22" "18:47" "1:26:09" "27:15" "10:00:00" "22:38"
        "9:41" "1:04:53" "35:12" "2:11:40" "14:26" "5:52:18" "41:07" "7:33:00"
    )
    views=(
        "182K views" "41K views" "2.1M views" "96K views" "734K views" "58K views"
        "1.4M views" "23K views" "310K views" "67K views" "125K views" "88K views"
        "402K views" "51K views" "19K views" "955K views"
    )
    ages=(
        "3 days ago" "2 weeks ago" "1 month ago" "5 days ago" "3 weeks ago"
        "2 months ago" "6 days ago" "4 months ago" "9 days ago" "1 week ago"
        "2 days ago" "7 months ago" "3 months ago" "11 days ago" "5 weeks ago"
        "yesterday"
    )

    pick() { echo $(( (ROT + $1) % 16 )); }

    emit_card() {
        local slot="$1" idx badge
        idx="$(pick "$slot")"
        badge="$2"
        printf '          <a class="card" href="/watch">\n'
        printf '            <span class="thumb tb%d">' "$(( slot % 12 ))"
        if [[ -n "$badge" ]]; then
            printf '<span class="badge-live">LIVE</span><span class="dur watching">%s watching</span>' "$badge"
        else
            printf '<span class="dur">%s</span>' "${durs[idx]}"
        fi
        printf '</span>\n'
        printf '            <span class="cbody"><span class="av av%d">%s</span>' \
            "$(( idx % 6 ))" "${channels[$(( idx % 8 ))]:0:1}"
        printf '<span class="ctext"><span class="ctitle">%s</span>' "${titles[idx]}"
        printf '<span class="cmeta">%s</span>' "${channels[$(( idx % 8 ))]}"
        if [[ -n "$badge" ]]; then
            printf '<span class="cmeta">Live now</span>'
        else
            printf '<span class="cmeta">%s · %s</span>' "${views[idx]}" "${ages[idx]}"
        fi
        printf '</span></span>\n          </a>\n'
    }

    emit_mini() {
        local slot="$1" idx
        idx="$(pick "$slot")"
        printf '        <a class="card mini" href="/watch">\n'
        printf '          <span class="thumb tb%d"><span class="dur">%s</span></span>\n' \
            "$(( slot % 12 ))" "${durs[idx]}"
        printf '          <span class="ctext"><span class="ctitle">%s</span>' "${titles[idx]}"
        printf '<span class="cmeta">%s</span><span class="cmeta">%s</span></span>\n' \
            "${channels[$(( idx % 8 ))]}" "${views[idx]}"
        printf '        </a>\n'
    }

    page_open() {
        local title="$1" active="$2" item name href
        cat <<HEAD
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>$title · $BRAND</title>
<meta name="description" content="$BRAND is an independent video library: long-form field recordings, workshop documentaries and live studio streams.">
<link rel="icon" href="/favicon.svg" type="image/svg+xml">
<link rel="stylesheet" href="/styles.css">
</head>
<body>
<header class="topbar">
  <a class="brand" href="/">
    <svg class="mark" viewBox="0 0 32 32" aria-hidden="true"><rect width="32" height="32" rx="9"/><path d="M13 10.4v11.2l9.2-5.6z"/></svg>
    <span class="brandname">$BRAND</span>
  </a>
  <a class="search" href="/browse">
    <svg viewBox="0 0 24 24" aria-hidden="true"><circle cx="11" cy="11" r="7"/><path d="M16.5 16.5 21 21"/></svg>
    <span>Search the library</span>
  </a>
  <nav class="tnav"><a href="/browse">Browse</a><a href="/about">About</a></nav>
</header>
<div class="shell">
  <aside class="sidebar">
    <nav>
HEAD
        for item in "Home:/" "Browse:/browse" "Live streams:/browse"; do
            name="${item%%:*}"; href="${item#*:}"
            if [[ "$name" == "$active" ]]; then
                printf '      <a class="on" href="%s">%s</a>\n' "$href" "$name"
            else
                printf '      <a href="%s">%s</a>\n' "$href" "$name"
            fi
        done
        cat <<'HEAD2'
      <div class="sidegroup">Collections</div>
      <a href="/browse">Field recordings</a>
      <a href="/browse">Workshop</a>
      <a href="/browse">Slow TV</a>
      <a href="/browse">Studio sessions</a>
      <div class="sidegroup">Library</div>
      <a href="/about">About</a>
      <a href="/privacy">Privacy</a>
    </nav>
  </aside>
  <main>
HEAD2
    }

    page_close() {
        cat <<FOOT
  </main>
</div>
<footer class="foot"><div class="in">
  <span>&copy; $YEAR $BRAND — independent video library for $ROOTDOMAIN</span>
  <span><a href="/about">About</a> · <a href="/privacy">Privacy</a> · <a href="/browse">Browse</a></span>
</div></footer>
</body>
</html>
FOOT
    }

    # ---- styles.css -----------------------------------------------------------
    {
        cat <<CSS
:root{
  --h:$HUE;
  --bg:hsl(var(--h) 20% 7%);
  --bg-elev:hsl(var(--h) 17% 11%);
  --line:hsl(var(--h) 15% 19%);
  --fg:hsl(var(--h) 14% 96%);
  --muted:hsl(var(--h) 10% 63%);
  --accent:hsl(var(--h) 76% 63%);
  --accent-ink:hsl(var(--h) 45% 9%);
  --live:hsl(354 76% 55%);
  --radius:14px;
  --maxw:1280px;
}
CSS
        cat <<'CSS'
*,*::before,*::after{box-sizing:border-box}
body{margin:0;background:var(--bg);color:var(--fg);font:15px/1.55 system-ui,-apple-system,"Segoe UI",Roboto,Helvetica,Arial,sans-serif;-webkit-font-smoothing:antialiased}
a{color:inherit;text-decoration:none}
svg{display:block}
.topbar{position:sticky;top:0;z-index:20;display:grid;grid-template-columns:auto minmax(0,1fr) auto;align-items:center;gap:20px;padding:11px 20px;background:var(--bg-elev);border-bottom:1px solid var(--line)}
.brand{display:flex;align-items:center;gap:10px;font-weight:700;letter-spacing:-.3px}
.mark{width:28px;height:28px}
.mark rect{fill:var(--accent)}
.mark path{fill:var(--accent-ink)}
.brandname{font-size:17px}
.search{display:flex;align-items:center;gap:10px;width:100%;max-width:460px;padding:9px 15px;border:1px solid var(--line);border-radius:999px;background:var(--bg);color:var(--muted);font-size:14px}
.search:hover{border-color:var(--accent);color:var(--fg)}
.search svg{width:16px;height:16px;fill:none;stroke:currentColor;stroke-width:2;stroke-linecap:round}
.tnav{display:flex;gap:18px;color:var(--muted);font-size:14px}
.tnav a:hover{color:var(--fg)}
.shell{display:grid;grid-template-columns:212px minmax(0,1fr);gap:30px;max-width:var(--maxw);margin:0 auto;padding:26px 20px 56px}
.sidebar nav{position:sticky;top:80px;display:flex;flex-direction:column;gap:2px}
.sidebar a{padding:9px 12px;border-radius:10px;color:var(--muted);font-size:14px}
.sidebar a:hover{background:var(--bg-elev);color:var(--fg)}
.sidebar a.on{background:var(--bg-elev);color:var(--fg);box-shadow:inset 2px 0 0 var(--accent)}
.sidegroup{margin:20px 0 6px;padding:0 12px;font-size:11px;letter-spacing:.14em;text-transform:uppercase;color:var(--muted);opacity:.65}
h1{font-size:27px;letter-spacing:-.6px;margin:0 0 6px}
.lead{color:var(--muted);margin:0 0 8px;max-width:66ch}
.sec{display:flex;align-items:baseline;justify-content:space-between;margin:34px 0 14px}
.sec h2{font-size:17px;margin:0;letter-spacing:-.2px}
.sec a{font-size:13px;color:var(--accent)}
.rail{display:grid;grid-auto-flow:column;grid-auto-columns:minmax(296px,1fr);gap:16px;overflow-x:auto;padding-bottom:10px}
.grid{display:grid;grid-template-columns:repeat(auto-fill,minmax(256px,1fr));gap:24px 18px}
.card{display:block}
.thumb{position:relative;display:block;aspect-ratio:16/9;border-radius:var(--radius);overflow:hidden}
.thumb::after{content:"";position:absolute;inset:0;background:repeating-linear-gradient(115deg,rgba(255,255,255,.075) 0 2px,transparent 2px 24px)}
.card:hover .thumb{outline:2px solid var(--accent);outline-offset:2px}
.dur{position:absolute;right:8px;bottom:8px;z-index:2;padding:2px 7px;border-radius:6px;background:rgba(0,0,0,.78);color:#fff;font-size:12px;font-variant-numeric:tabular-nums}
.watching{background:rgba(0,0,0,.66)}
.badge-live{position:absolute;left:8px;top:8px;z-index:2;display:flex;align-items:center;gap:6px;padding:3px 8px;border-radius:6px;background:var(--live);color:#fff;font-size:11px;font-weight:700;letter-spacing:.08em}
.badge-live::before{content:"";width:6px;height:6px;border-radius:50%;background:#fff}
.cbody{display:flex;gap:12px;padding:12px 2px 0}
.av{flex:0 0 auto;width:34px;height:34px;border-radius:50%;display:grid;place-items:center;font-weight:700;font-size:14px;color:var(--accent-ink)}
.ctext{display:flex;flex-direction:column;gap:3px;min-width:0}
.ctitle{font-weight:600;line-height:1.35;display:-webkit-box;-webkit-line-clamp:2;-webkit-box-orient:vertical;overflow:hidden}
.cmeta{color:var(--muted);font-size:13px}
.watch{display:grid;grid-template-columns:minmax(0,1fr) 336px;gap:30px;align-items:start}
.player{position:relative;aspect-ratio:16/9;border-radius:18px;overflow:hidden;display:grid;place-items:center}
.play{position:relative;z-index:2;width:76px;height:76px;border-radius:50%;background:rgba(0,0,0,.5);border:1px solid rgba(255,255,255,.4);display:grid;place-items:center}
.play svg{width:26px;height:26px;fill:#fff;margin-left:4px}
.vtitle{font-size:21px;letter-spacing:-.3px;margin:18px 0 6px}
.vmeta{color:var(--muted);font-size:14px}
.chips{display:flex;flex-wrap:wrap;gap:8px;margin:16px 0 0}
.chip{padding:5px 11px;border:1px solid var(--line);border-radius:999px;font-size:12.5px;color:var(--muted);background:var(--bg-elev)}
.desc{background:var(--bg-elev);border:1px solid var(--line);border-radius:14px;padding:17px 19px;margin-top:18px;color:var(--muted)}
.desc p{margin:0 0 10px}
.desc b{color:var(--fg);font-weight:600}
.chapters{list-style:none;margin:12px 0 0;padding:0;display:flex;flex-direction:column;gap:7px;font-size:14px}
.chapters i{color:var(--accent);font-style:normal;font-variant-numeric:tabular-nums;margin-right:12px}
.mini{display:grid;grid-template-columns:154px minmax(0,1fr);gap:11px;align-items:start}
.mini .thumb{border-radius:10px}
.mini .ctitle{font-size:13.5px}
.mini .cmeta{font-size:12.5px}
.side-list{display:flex;flex-direction:column;gap:15px;margin-top:14px}
.cats{display:flex;flex-wrap:wrap;gap:9px;margin:0 0 26px}
.cat{padding:7px 14px;border-radius:999px;border:1px solid var(--line);background:var(--bg-elev);font-size:13.5px;color:var(--muted)}
.cat:hover,.cat.on{background:var(--accent);border-color:var(--accent);color:var(--accent-ink);font-weight:600}
.prose{max-width:65ch}
.prose h2{margin:30px 0 8px;font-size:17px}
.prose p{color:var(--muted)}
.prose ul{color:var(--muted);padding-left:20px}
.big{font-size:72px;line-height:1;letter-spacing:-3px;margin:8px 0 10px;color:var(--accent)}
.foot{border-top:1px solid var(--line);padding:22px 20px 44px;color:var(--muted);font-size:13px}
.foot .in{max-width:var(--maxw);margin:0 auto;display:flex;flex-wrap:wrap;gap:14px;justify-content:space-between}
.foot a:hover{color:var(--fg)}
@media (max-width:900px){
  .shell{grid-template-columns:minmax(0,1fr);padding-top:20px}
  .sidebar{display:none}
  .watch{grid-template-columns:minmax(0,1fr)}
  .search{display:none}
  .topbar{grid-template-columns:auto minmax(0,1fr);gap:12px}
  .tnav{justify-content:flex-end}
}
CSS
        i=0
        while [[ $i -lt 12 ]]; do
            printf '.tb%d{background:linear-gradient(%ddeg,hsl(calc(var(--h) + %d) 58%% 17%%),hsl(calc(var(--h) + %d) 70%% 45%%))}\n' \
                "$i" "$(( 100 + (i * 31) % 160 ))" "$(( (i * 29) % 360 ))" "$(( (i * 29 + 58) % 360 ))"
            i=$(( i + 1 ))
        done
        i=0
        while [[ $i -lt 6 ]]; do
            printf '.av%d{background:hsl(calc(var(--h) + %d) 62%% 58%%)}\n' "$i" "$(( (i * 57) % 360 ))"
            i=$(( i + 1 ))
        done
    } > "$GEN_SITE/styles.css"

    # ---- favicon / robots -----------------------------------------------------
    cat > "$GEN_SITE/favicon.svg" <<SVG
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 32 32">
  <rect width="32" height="32" rx="9" fill="hsl($HUE 76% 63%)"/>
  <path d="M13 10.4v11.2l9.2-5.6z" fill="hsl($HUE 45% 9%)"/>
</svg>
SVG
    printf 'User-agent: *\nDisallow:\n' > "$GEN_SITE/robots.txt"

    # ---- index.html -----------------------------------------------------------
    {
        page_open "Home" "Home"
        cat <<INDEX
    <h1>Everything we filmed this month</h1>
    <p class="lead">$BRAND publishes long-form video: field recordings, workshop
    documentaries and unedited studio sessions. Most of the library is 4K, and
    nothing here is cut down to fit a feed.</p>
    <div class="sec"><h2>Live now</h2><a href="/browse">All streams</a></div>
    <div class="rail">
INDEX
        emit_card 0 "1,204"
        emit_card 1 "318"
        emit_card 2 "2,976"
        cat <<'INDEX2'
    </div>
    <div class="sec"><h2>Recently added</h2><a href="/browse">Browse the library</a></div>
    <div class="grid">
INDEX2
        for n in 3 4 5 6 7 8 9 10; do emit_card "$n" ""; done
        cat <<'INDEX3'
    </div>
    <div class="sec"><h2>Long-form &amp; overnight</h2><a href="/browse">More</a></div>
    <div class="grid">
INDEX3
        for n in 11 12 13 14; do emit_card "$n" ""; done
        printf '    </div>\n'
        page_close
    } > "$GEN_SITE/index.html"

    # ---- browse.html ----------------------------------------------------------
    {
        page_open "Browse" "Browse"
        cat <<'BROWSE'
    <h1>Browse the library</h1>
    <p class="lead">412 titles, 1,860 hours. Sorted by most recently added.</p>
    <div class="cats">
      <a class="cat on" href="/browse">All</a>
      <a class="cat" href="/browse">Field recordings</a>
      <a class="cat" href="/browse">Workshop</a>
      <a class="cat" href="/browse">Slow TV</a>
      <a class="cat" href="/browse">Studio sessions</a>
      <a class="cat" href="/browse">Live</a>
      <a class="cat" href="/browse">4K</a>
    </div>
    <div class="grid">
BROWSE
        for n in 0 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do emit_card "$n" ""; done
        printf '    </div>\n'
        page_close
    } > "$GEN_SITE/browse.html"

    # ---- watch.html -----------------------------------------------------------
    # Рекомендуемое видео берём только из длинных — иначе хронометраж в чипсах
    # противоречил бы главам и абзацу про гигабайты трафика.
    LONGS=(2 4 6 9 11 13 15)
    FEAT="${LONGS[$(( DHASH % 7 ))]}"
    {
        page_open "Watch" "Home"
        cat <<WATCH
    <div class="watch">
      <div>
        <div class="player tb$(( FEAT % 12 ))"><span class="play"><svg viewBox="0 0 24 24" aria-hidden="true"><path d="M8 5v14l11-7z"/></svg></span></div>
        <h1 class="vtitle">${titles[FEAT]}</h1>
        <p class="vmeta">${channels[$(( FEAT % 8 ))]} · ${views[FEAT]} · ${ages[FEAT]}</p>
        <div class="chips">
          <span class="chip">2160p60</span>
          <span class="chip">AV1 / H.264</span>
          <span class="chip">Stereo 48 kHz</span>
          <span class="chip">${durs[FEAT]}</span>
          <span class="chip">Chapters</span>
        </div>
        <div class="desc">
          <p>Recorded in one pass, uploaded uncut. We publish the full-length master
          at up to 2160p60 alongside a 1080p and a 720p ladder, so the same title is
          available whether you are on fibre or a phone on the train.</p>
          <p><b>Playback note.</b> Long-form titles are streamed in segments and the
          player keeps a wide buffer, which is why a single session can move several
          gigabytes. If your connection is metered, drop to 720p in the quality menu.</p>
          <ul class="chapters">
            <li><i>00:00</i> Setting up, first light</li>
            <li><i>18:42</i> The tide turns</li>
            <li><i>46:05</i> Weather closing in</li>
            <li><i>1:12:30</i> Packing down</li>
          </ul>
        </div>
      </div>
      <aside>
        <div class="sec"><h2>Up next</h2></div>
        <div class="side-list">
WATCH
        for n in 1 2 3 4 5 7; do emit_mini "$n"; done
        cat <<'WATCH2'
        </div>
      </aside>
    </div>
WATCH2
        page_close
    } > "$GEN_SITE/watch.html"

    # ---- about.html -----------------------------------------------------------
    {
        page_open "About" "About"
        cat <<ABOUT
    <div class="prose">
      <h1>About $BRAND</h1>
      <p class="lead">A small independent library of long-form video, hosted on
      our own infrastructure at $ROOTDOMAIN.</p>
      <h2>What we publish</h2>
      <p>Field recordings, workshop documentaries, slow TV and unedited studio
      sessions. Titles run from twelve minutes to ten hours. Nothing is trimmed to
      suit a recommendation algorithm, and we do not insert mid-roll breaks.</p>
      <h2>How it is served</h2>
      <p>Every title is encoded into a small ladder — 2160p60, 1080p and 720p —
      and served directly from this host over HTTPS. There is no third-party CDN,
      no player embedded from anyone else, and no tracking script. That also means
      the bandwidth is ours: a busy evening moves a considerable amount of data
      through this one hostname.</p>
      <h2>Contact</h2>
      <p>Programming and rights enquiries: <a href="mailto:$EMAIL">$EMAIL</a></p>
    </div>
ABOUT
        page_close
    } > "$GEN_SITE/about.html"

    # ---- privacy.html ---------------------------------------------------------
    {
        page_open "Privacy" "Privacy"
        cat <<PRIVACY
    <div class="prose">
      <h1>Privacy</h1>
      <p class="lead">Short version: we do not track you.</p>
      <h2>What this site stores</h2>
      <p>Nothing. $BRAND sets no cookies, uses no local storage, and loads no
      analytics, fonts, players or images from any other host. Every asset you
      receive comes from this hostname.</p>
      <h2>Server logs</h2>
      <p>Our web server keeps ordinary operational logs for a short period so we
      can size capacity for long-form playback. They are not shared with anyone
      and are not used to build a profile.</p>
      <h2>Contact</h2>
      <p>Questions: <a href="mailto:$EMAIL">$EMAIL</a></p>
    </div>
PRIVACY
        page_close
    } > "$GEN_SITE/privacy.html"

    # ---- 404.html -------------------------------------------------------------
    {
        page_open "Not found" ""
        cat <<'NOTFOUND'
    <div class="prose">
      <p class="big">404</p>
      <h1>That title is not here</h1>
      <p class="lead">The link may be old, or the video may have been re-published
      under a different slug. The library index is the fastest way to find it.</p>
      <p><a class="cat" href="/browse">Browse the library</a></p>
    </div>
NOTFOUND
        page_close
    } > "$GEN_SITE/404.html"

    chmod 0755 "$GEN_SITE" "$GEN_SITE/assets"
    chmod 0644 "$GEN_SITE"/*.html "$GEN_SITE"/*.css "$GEN_SITE"/*.svg "$GEN_SITE"/robots.txt

    # Установщик апстрима сохраняет уже развёрнутый /srv/tproxy-site и не перезапишет его,
    # поэтому прежний каталог отодвигаем — не удаляя, вдруг там настоящий сайт.
    if [[ -e "$SITE_DIR_DEFAULT" ]]; then
        SITE_BACKUP="$SITE_DIR_DEFAULT.before-$(date +%Y%m%d%H%M%S)"
        mv "$SITE_DIR_DEFAULT" "$SITE_BACKUP"
        warn "Прежний $SITE_DIR_DEFAULT сохранён в $SITE_BACKUP"
    fi

    SITE_ARGS=(--site-dir "$GEN_SITE")
    success "Сайт-заглушка сгенерирован: $GEN_SITE ($(ls "$GEN_SITE"/*.html | wc -l) страниц, оттенок $HUE)"
    warn "Это всё же общий шаблон. Он различается по доменам (палитра и подбор карточек),"
    warn "но для серьёзной маскировки замените /srv/tproxy-site настоящим сайтом"
fi

#------------------------------------------------------------------------------
# Официальный установщик
#------------------------------------------------------------------------------
PHASE=install
step "Запуск официального установщика (Caddy + MTProxy + tproxy-server)..."
info "Это займёт 5–15 минут: сборка MTProxy, установка Go, сборка релея и тесты."

# Секрет передаётся через stdin, а не через argv, чтобы не светиться в ps.
printf '%s\n' "$SECRET" | "$SRC_DIR/deploy/install.sh" \
    --hostname "$DOMAIN" \
    --email "$EMAIL" \
    --mtproxy-workers "$WORKERS" \
    --mtproxy-max-connections "$MAX_CONNECTIONS" \
    ${SITE_ARGS[@]+"${SITE_ARGS[@]}"}

#------------------------------------------------------------------------------
# Проверка результата
#------------------------------------------------------------------------------
step "Проверка сервисов..."

# Апстрим делает `enable --now` для релея, что не перезапускает уже работающий
# процесс от прошлой установки — он остался бы со старым бинарником и конфигом.
systemctl try-restart tproxy-server.service || true

failed=()
for unit in tproxy-firewall mtproxy tproxy-server caddy; do
    if systemctl is-active --quiet "$unit"; then
        success "$unit: active"
    else
        failed+=("$unit")
        echo -e "${RED}[-] $unit: $(systemctl is-active "$unit" 2>&1)${RESET}"
    fi
done
[[ ${#failed[@]} -eq 0 ]] || error "Не запустились сервисы: ${failed[*]}
       Логи: journalctl -u ${failed[0]} -n 50 --no-pager"

if curl -fsS --max-time 10 http://127.0.0.1:8081/readyz >/dev/null; then
    success "Релей готов (127.0.0.1:8081/readyz)"
fi

echo -e "${BLUE}[*] Ожидание выпуска TLS-сертификата Let's Encrypt...${RESET}"
tls_ok=""
for _ in $(seq 1 30); do
    if curl -fsS --max-time 10 -o /dev/null "https://$DOMAIN/"; then tls_ok=1; break; fi
    sleep 4
done
if [[ -n "$tls_ok" ]]; then
    success "HTTPS работает: https://$DOMAIN/"
else
    warn "https://$DOMAIN/ пока не отвечает. Обычно причина — DNS или закрытые порты 80/443."
    warn "Смотрите: journalctl -u caddy -n 50 --no-pager"
fi

#------------------------------------------------------------------------------
# Итог
#------------------------------------------------------------------------------
install -m 0600 /dev/null "$INFO_FILE"
cat > "$INFO_FILE" <<EOF
========================================
       Telegram WEB Proxy by xanka
========================================

Установленные компоненты:
- MTProxy (официальное ядро на C, 127.0.0.1:2398)
- tproxy-server (веб-ретранслятор на Go, 127.0.0.1:8080)
- Caddy (HTTPS-сервер, :80/:443)
- nftables (закрывает порты 2398 и 8888 снаружи)

Параметры для клиента Telegram (тип прокси: WEB):
Hostname: $DOMAIN
Secret:   $SECRET

Ссылка для подключения:
https://t.me/webproxy?server=$DOMAIN&secret=$SECRET
tg://webproxy?server=$DOMAIN&secret=$SECRET

Полезные команды:
systemctl --no-pager --full status caddy tproxy-firewall mtproxy tproxy-server
journalctl -u tproxy-server -n 50 --no-pager
curl --fail http://127.0.0.1:8081/readyz

Сайт-заглушка: /srv/tproxy-site (после правок: systemctl restart tproxy-server)
Исходники:     $SRC_DIR
Переустановка: bash install.sh $DOMAIN   (секрет сохранится)
EOF
chmod 0600 "$INFO_FILE"

trap - ERR
echo -e "\n${GREEN}========================================${RESET}"
echo -e "${GREEN}      УСТАНОВКА УСПЕШНО ЗАВЕРШЕНА!      ${RESET}"
echo -e "${GREEN}========================================${RESET}"
cat "$INFO_FILE"
echo -e "\n${CYAN}Данные сохранены в $INFO_FILE${RESET}"
