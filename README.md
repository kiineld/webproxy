# Telegram Web Proxy Installer by xanka

Автоматический установщик **Telegram WEB Proxy**. Трафик Telegram идёт внутри обычного
HTTPS/WebSocket на порт `443`, поэтому выглядит как посещение обычного сайта и переживает
блокировки, которые ломают классический MTProto-прокси.

Скрипт разворачивает официальный стек проекта
[`telegramdesktop/tproxy-server`](https://github.com/telegramdesktop/tproxy-server):

```text
Интернет :80/:443 -> Caddy -> 127.0.0.1:8080 tproxy-server -> 127.0.0.1:2398 MTProxy
```

Наружу слушает только Caddy. Порты MTProxy (`2398`, `8888`) и релея (`8080`, `8081`)
закрываются правилом nftables.

## Требования

- **x86_64** сервер (официальное ядро MTProxy собирается только под x86_64 — ARM не подойдёт);
- **Ubuntu 22.04+** или **Debian 12+**, systemd, root-доступ;
- домен или поддомен, A-запись которого указывает на IP сервера;
- открытые входящие TCP **80** и **443**, свободные от nginx/apache;
- ~15 минут (собирается MTProxy на C и релей на Go).

## Установка

```bash
bash <(curl -sL https://raw.githubusercontent.com/kiineld/webproxy/main/install.sh) proxy.example.com
```

Секрет генерируется автоматически. Скрипт **идемпотентен**: если что-то упало, просто
запустите его ещё раз — он продолжит с того же места и переиспользует уже выданный секрет.

### Опции

| Опция | Назначение |
|---|---|
| `--email EMAIL` | контакт для Let's Encrypt (по умолчанию `admin@<домен>`) |
| `--secret HEX` | свой секрет, 32 hex-символа |
| `--site-dir DIR` | ваш собственный сайт-заглушка (нужен `index.html`) |
| `--site-upstream URL` | проксировать локальное приложение, напр. `http://127.0.0.1:3000` |
| `--workers N` | воркеров MTProxy (по умолчанию 1) |
| `--max-connections N` | соединений на воркер (по умолчанию 4096) |

## Подключение

После установки данные лежат в `/root/telegram_webproxy_info.txt`. В клиенте Telegram
выберите тип прокси **WEB** и введите два значения:

```text
Hostname: proxy.example.com
Secret:   <32 hex-символа>
```

Ссылка: `https://t.me/webproxy?server=proxy.example.com&secret=<секрет>`
(`t.me` этот маршрут пока не публикует, ссылку нужно открывать прямо в клиенте;
эквивалентная форма — `tg://webproxy?...`).

WEB-прокси поддерживают Telegram Desktop и экспериментальные сборки Android/iOS —
это proof-of-concept, обычный мобильный Telegram из стора его пока не умеет.

## Проверка

```bash
systemctl --no-pager --full status caddy tproxy-firewall mtproxy tproxy-server
```

```bash
curl --fail http://127.0.0.1:8081/readyz
```

Снаружи порты `2398`, `8888`, `8080`, `8081` должны быть недоступны.

## Свой сайт-заглушка

Если `--site-dir` не задан, генерируется простая заглушка на основе имени домена.
Одинаковая у всех заглушка — это сигнатура для активного сканирования, поэтому лучше
положить в `/srv/tproxy-site` настоящий сайт и перезапустить релей:

```bash
systemctl restart tproxy-server
```

## Если что-то не работает

| Симптом | Причина и что делать |
|---|---|
| `требуется x86_64` | ARM-сервер (Oracle Ampere, Hetzner CAX). Возьмите x86_64. |
| Порт 80/443 занят | `systemctl disable --now nginx` (или apache2). |
| Нет сертификата | A-запись не указывает на сервер, либо 80/443 закрыты фаерволом провайдера. `journalctl -u caddy -n 50` |
| `mtproxy` не стартует | `journalctl -u mtproxy -n 50`; проверьте `/etc/mtproxy/proxy-multi.conf`. |
| Прокси перестал работать через недели | Конфигурация DC Telegram обновляется таймером `refresh-mtproxy-config.timer` — проверьте `systemctl status refresh-mtproxy-config.timer`. |

## Что было исправлено в этой версии

Прошлая версия скрипта не работала на типовом VPS. Основные причины:

1. **`apt-get install golang`** ставил Go 1.18 (Ubuntu 22.04) или 1.19 (Debian 12), а релею
   нужен Go ≥ 1.20 — сборка падала. Теперь Go 1.26 ставится официальным установщиком
   с проверкой контрольной суммы.
2. **`/var/lib/caddy` оставался root:root** — Caddy не мог записать сертификаты, HTTPS не поднимался.
3. **В `mtproxy.service` не было секции `[Install]`** — `systemctl enable` падал, автозапуск не работал,
   `Restart=` отсутствовал.
4. **`systemctl start ... || true`** глушил все ошибки: скрипт печатал «УСТАНОВКА УСПЕШНО ЗАВЕРШЕНА»,
   даже когда не работало ничего.
5. **Файл `/root/telegram_webproxy_info.txt` писался при любом исходе**, а его наличие блокировало
   повторный запуск — после неудачной установки починить её было нельзя.
6. **nftables-правило устанавливалось, но не включалось** — порты MTProxy `2398` и `8888` торчали наружу.
7. **Отсутствовал таймер обновления** `proxy-multi.conf` — прокси деградировал со временем.
8. **`curl` без `--fail`** мог записать HTML-страницу ошибки вместо бинарника Caddy и сделать её исполняемой.
9. **Не было проверок** архитектуры, DNS, занятости портов и готовности сервисов.

## Лицензия и происхождение

MIT. Форк установщика [sacoq/web-proxy-tg-installer](https://github.com/sacoq/web-proxy-tg-installer)
с исправленной установкой; разворачивает официальный
[telegramdesktop/tproxy-server](https://github.com/telegramdesktop/tproxy-server).
