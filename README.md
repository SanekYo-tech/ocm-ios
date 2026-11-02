# OpenCode Mobile — iPhone

Нативный OpenCode-агент для iPhone: SwiftUI, Liquid Glass на iOS 26, локальный workspace, терминал, Git и Python. Без компьютера и без proot.

## Возможности

- **Нативный интерфейс** — SwiftUI + Liquid Glass на iOS 26, material-fallback на iOS 17–25. Чаты, сессии, модели, файлы, редактор, терминал и настройки.
- **Рабочая папка** — `Файлы → На iPhone → OpenCode`. Туда кладутся проекты; агент читает и меняет файлы на устройстве.
- **AI-агент** — потоковые ответы, размышления, tool-cards, diff, todo, история сессий.
- **Unix-терминал** — `ls`, `cat`, `grep`, `sed`, `awk`, `find`, `sort`, `uniq`, `wc`, `diff`, `cp`, `mv`, `rm`, `mkdir`, `tar`, `gzip` и другие команды через [ios_system](https://github.com/holzschu/ios_system).
- **Git** — libgit2: `init`, `status`, `add`, `reset`, `commit -m`, `log`, `diff`, `branch`, `checkout`, `rev-parse`, `remote`, `config`, `clone`.
- **Python 3.13 (beta)** — `python3 script.py`, `python3 -c "..."`. Рантайм загружается динамически: если он несовместим с устройством, приложение показывает ошибку вместо падения. Есть стандартная библиотека, `ssl`, `sqlite3` и бинарные модули; без pip.
- **OpenCode Zen** — анонимный режим `Bearer public`, вход в аккаунт OpenCode по device-flow (Google/GitHub в Safari) или свой API-ключ.
- **`config.json`** — редактируется в «Файлах» или в Настройках: `model`, `agents`, `permissions`, `instructions`, `providers` и остальная структура OpenCode.

## Установка

Скачай `OpenCode-iOS-*.ipa` из [Releases](https://github.com/SanekYo-tech/ocm-ios/releases/latest).

IPA **без подписи**. Подпиши своим Apple ID через **Sideloadly**, **AltStore** или **SideStore**:

1. Включи Developer Mode и доверь профиль разработчика.
2. Бесплатный Apple ID: приложение живёт 7 дней, затем переподписать.
3. TrollStore — только iOS 14.0–17.0.

Требования: **iOS 17+**, arm64. Liquid Glass — на iOS 26; на iOS 17–25 используется material-fallback.

## Бесплатная квота

Приложение не делает запрос к модели, пока ты не отправишь сообщение. Если приходит `429 FreeUsageLimitError`, это ответ сервера OpenCode: анонимная квота исчерпана.

- **Войти в аккаунт** — Настройки → Аккаунт opencode → Google/GitHub. Код входа подставляется автоматически.
- **Свой ключ** — Настройки → Аккаунт opencode → API-ключ.
- **Проверка** — Настройки → Диагностика: счётчик модельных запросов, режим авторизации и кнопка «Проверить бесплатный доступ».

Квота считается на стороне OpenCode; подмена заголовков её не создаёт. Приложение отправляет официальный User-Agent OpenCode для совместимости с Console.

## config.json

Файл лежит в `OpenCode/config.json` и виден в приложении «Файлы».

- `model`, `small_model`, `default_agent`;
- `agents` / `agent` — свои агенты, `system`/`prompt`, `model`, `mode`;
- `permissions` / `permission` — запрет `bash`, `edit`, `read`, `webfetch`;
- `instructions` + `AGENTS.md` — правила проекта;
- `providers.opencode.options.apiKey` — ключ OpenCode Console;
- `mcp`, `plugins`, `compaction`, `watcher`, `snapshots` — структура сохраняется; приложение читает то, что умеет;
- JSONC-комментарии поддерживаются.

## Ограничения

- Нет Node.js/npm и компиляторов.
- Python beta: нет pip, ssl, sqlite3 и нативных пакетов.
- Git: нет `pull`/`push`; `clone` работает через HTTPS.
- iOS не разрешает фоновый сервер и произвольные бинарники.

## Сборка

GitHub Actions, macOS-раннер, Xcode 26, [XcodeGen](https://github.com/yonaskolb/XcodeGen):

```bash
xcodegen generate
xcodebuild archive -project OpenCodeMobile.xcodeproj -scheme OpenCodeMobile \
  -configuration Release -destination 'generic/platform=iOS' \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY=""
```

`Payload/OpenCodeMobile.app` упаковывается в `.ipa`. Workflow: `.github/workflows/ios.yml`.

## Лицензии

- Код приложения — MIT (`LICENSE`).
- [ios_system](https://github.com/holzschu/ios_system) и command frameworks — BSD-3-Clause, © Nicolas Holzschuch.
- libgit2 — GPL-2.0 с linking exception.
- OpenSSL — Apache 2.0 / OpenSSL License; libssh2 — BSD-3-Clause.
- CPython — Python Software Foundation License 2.
- OpenCode — MIT, © Anomaly / opencode contributors. Проект не связан с командой OpenCode.