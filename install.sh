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

success "Исходники: $SRC_DIR ($(git -C "$SRC_DIR" rev-parse --short HEAD))"

#------------------------------------------------------------------------------
# Сайт-заглушка
#------------------------------------------------------------------------------
SITE_ARGS=()
if [[ -n "$SITE_UPSTREAM" ]]; then
    SITE_ARGS=(--site-upstream "$SITE_UPSTREAM")
elif [[ -n "$SITE_DIR" ]]; then
    SITE_ARGS=(--site-dir "$SITE_DIR")
elif [[ -f "$SITE_DIR_DEFAULT/index.html" ]]; then
    info "Используется уже установленный сайт в $SITE_DIR_DEFAULT"
else
    step "Генерация сайта-заглушки..."
    GEN_SITE=/opt/tproxy-site-default
    BRAND="${DOMAIN%%.*}"
    BRAND="${BRAND^}"
    ROOTDOMAIN="${DOMAIN#*.}"
    YEAR="$(date +%Y)"
    mkdir -p "$GEN_SITE"

    cat > "$GEN_SITE/styles.css" <<CSS
:root { color-scheme: light dark; }
* { box-sizing: border-box; }
body {
    margin: 0; min-height: 100vh;
    font: 16px/1.65 -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, Helvetica, Arial, sans-serif;
    background: #f6f7f9; color: #24292f;
    display: flex; flex-direction: column;
}
header, main, footer { width: 100%; max-width: 760px; margin: 0 auto; padding: 0 24px; }
header { display: flex; align-items: center; gap: 12px; padding-top: 32px; padding-bottom: 8px; }
.logo { width: 34px; height: 34px; border-radius: 8px; background: #2c6fbb; }
.brand { font-weight: 600; font-size: 18px; }
main { flex: 1; padding-top: 32px; padding-bottom: 48px; }
h1 { font-size: 30px; line-height: 1.25; margin: 0 0 16px; }
h2 { font-size: 20px; margin: 32px 0 8px; }
p { color: #4a5560; }
nav a { color: #2c6fbb; text-decoration: none; margin-right: 18px; }
nav a:hover { text-decoration: underline; }
footer { border-top: 1px solid #e2e6ea; padding-top: 16px; padding-bottom: 32px; font-size: 13px; color: #8a939c; }
@media (prefers-color-scheme: dark) {
    body { background: #14171a; color: #e6e9ec; }
    p { color: #a7b1bb; }
    footer { border-color: #262b31; color: #6f7883; }
}
CSS

    cat > "$GEN_SITE/index.html" <<HTML
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>${BRAND} — infrastructure status</title>
<link rel="stylesheet" href="/styles.css">
</head>
<body>
<header><div class="logo"></div><div class="brand">${BRAND}</div></header>
<main>
<h1>Infrastructure services for ${ROOTDOMAIN}</h1>
<p>This host serves internal tooling and scheduled jobs. There is no public
application on this endpoint. If you reached this page from a link, the
resource has probably been moved.</p>
<h2>Contact</h2>
<p>Operational questions: <a href="mailto:${EMAIL}">${EMAIL}</a></p>
<nav><a href="/about">About</a><a href="/privacy">Privacy</a></nav>
</main>
<footer>&copy; ${YEAR} ${BRAND}. All rights reserved.</footer>
</body>
</html>
HTML

    cat > "$GEN_SITE/about.html" <<HTML
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>About — ${BRAND}</title>
<link rel="stylesheet" href="/styles.css">
</head>
<body>
<header><div class="logo"></div><div class="brand">${BRAND}</div></header>
<main>
<h1>About</h1>
<p>${BRAND} maintains hosting and automation for ${ROOTDOMAIN}. This node handles
background processing and health endpoints only.</p>
<nav><a href="/">Home</a><a href="/privacy">Privacy</a></nav>
</main>
<footer>&copy; ${YEAR} ${BRAND}. All rights reserved.</footer>
</body>
</html>
HTML

    cat > "$GEN_SITE/privacy.html" <<HTML
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Privacy — ${BRAND}</title>
<link rel="stylesheet" href="/styles.css">
</head>
<body>
<header><div class="logo"></div><div class="brand">${BRAND}</div></header>
<main>
<h1>Privacy</h1>
<p>This site sets no cookies, embeds no third-party resources, and does not
collect analytics.</p>
<nav><a href="/">Home</a><a href="/about">About</a></nav>
</main>
<footer>&copy; ${YEAR} ${BRAND}. All rights reserved.</footer>
</body>
</html>
HTML

    cat > "$GEN_SITE/404.html" <<HTML
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Not found — ${BRAND}</title>
<link rel="stylesheet" href="/styles.css">
</head>
<body>
<header><div class="logo"></div><div class="brand">${BRAND}</div></header>
<main><h1>Page not found</h1><p><a href="/">Return to the home page</a></p></main>
<footer>&copy; ${YEAR} ${BRAND}. All rights reserved.</footer>
</body>
</html>
HTML

    SITE_ARGS=(--site-dir "$GEN_SITE")
    success "Сайт-заглушка сгенерирован: $GEN_SITE"
    warn "Заглушка одинакова у всех, кто пользуется этим скриптом — это признак для активного"
    warn "сканирования. Позже замените содержимое /srv/tproxy-site своим настоящим сайтом"
    warn "и выполните: systemctl restart tproxy-server"
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
