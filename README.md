# OpenCode Mobile — iPhone

<p align="center">
  <img src="Resources/Assets.xcassets/AppIcon.appiconset/AppIcon-1024.png" width="112" alt="OpenCode">
</p>

<p align="center"><b>OpenCode-агент, который живёт на iPhone. Без компьютера, без сервера, без proot.</b></p>

---

## Что это

Автономный порт идеи [OpenCode Mobile](https://github.com/lovereplit-bit/OCM) на iOS. Внутри приложения:

- **Рабочая папка `OpenCode`** — видна в приложении «Файлы» → «На iPhone» → «OpenCode». Кладите туда проекты, агент читает и меняет их.
- **AI-агент** — чат с историей, сессиями, инструментами чтения/записи/поиска файлов и списком задач.
- **Настоящий Unix-терминал** — `ls`, `cat`, `grep`, `sed`, `awk`, `find`, `sort`, `uniq`, `wc`, `diff`, `cp`, `mv`, `rm`, `mkdir`, `tar`, `gzip` и другие команды через [ios_system](https://github.com/holzschu/ios_system) (движок a-Shell). Без эмуляции и без ПК.
- **OpenCode Zen** — бесплатный режим `Bearer public`, вход в аккаунт OpenCode через device-flow (Google/GitHub в Safari) или свой API-ключ.
- **Мобильный интерфейс OpenCode** — чат, дерево файлов, редактор, изменения, модели, темы. UI из Android-версии, адаптированный под WKWebView.

## Чего здесь нет и почему

iOS не разрешает запускать произвольные бинарники и фоновые Linux-процессы. Поэтому:

- нет `opencode serve` и proot внутри приложения;
- нет Node.js/npm, Python, git и компиляторов;
- агент не запускает `npm test`, `cargo build` или `git commit`;
- вместо этого — встроенный Unix-набор `ios_system` и файловые инструменты;
- приложение не работает в фоне как сервер (iOS усыпляет процесс).

Это не «настоящий бинарник opencode», а максимально близкий автономный агент в рамках песочницы iOS.

## Бесплатные модели

Приложение сначала пробует анонимный режим OpenCode Zen: `Authorization: Bearer public` — ровно тот же sentinel, который использует официальный клиент. Если серверная квота для вашего IP ещё не исчерпана, всё работает сразу после установки.

Если приходит `429 Free usage limit reached`:

- **Войти в аккаунт OpenCode** — Настройки → Аккаунт opencode → «Войти через Google / GitHub». Откроется страница opencode.ai, код уже подставлен. Это даёт личную квоту.
- **Свой API-ключ** — Настройки → Модели → Подключить провайдера → OpenCode Zen, либо Настройки → Аккаунт opencode.
- **OpenCode Go** — если нужен стабильный лимит.

Квота считается на стороне OpenCode; подделка заголовков клиента её не создаёт.

## Установка

Скачайте `OpenCode-iOS-*.ipa` из [Releases](https://github.com/SanekYo-tech/ocm-ios/releases/latest).

`.ipa` **без подписи**. iOS не устанавливает неподписанный код, поэтому подпишите его своим Apple ID:

- **Sideloadly** (Windows/macOS) — самый простой разовый вариант;
- **AltStore / SideStore** — переподпись на устройстве;
- **Feather** — если есть сертификат Apple Developer;
- **TrollStore** — только iOS 14.0–17.0 (не 18/26).

Бесплатный Apple ID: приложение работает 7 дней, потом переподписать. Данные сохраняются при том же bundle ID.

Требования: iOS 15+, arm64.

## Сборка

GitHub Actions, macOS-раннер, Xcode 26, [XcodeGen](https://github.com/yonaskolb/XcodeGen):

```bash
xcodegen generate
xcodebuild archive -project OpenCodeMobile.xcodeproj -scheme OpenCodeMobile \
  -configuration Release -destination 'generic/platform=iOS' \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY=""
```

Затем `Payload/OpenCodeMobile.app` упаковывается в `.ipa`. Workflow: `.github/workflows/ios.yml`.

## Структура

```
Sources/
  AgentEngine.swift      мини-opencode API: сессии, сообщения, SSE, файлы, prompt loop
  AgentStore.swift       workspace, JSON-хранилище сессий, diff'ов, todo
  ZenClient.swift        OpenCode Zen: модели, device-flow, стриминг, tool calls
  ShellShim.m            мост к ios_system (stdout/stderr, песочница)
  ShellRunner.swift      последовательный запуск Unix-команд
  WebBridge.swift        синхронный JS↔Swift мост (window.prompt)
  StaticServer.swift     локальный HTTP-сервер для UI (WKWebView)
  ContentView.swift      WKWebView + загрузка UI
Resources/ui/            мобильный интерфейс OpenCode
Vendor/                  ios_system, files, shell, text, awk, tar (xcframework)
```

## Лицензии

- Код приложения — MIT (`LICENSE`).
- UI OpenCode Mobile — MIT, © opencode / OpenCode Mobile contributors.
- [ios_system](https://github.com/holzschu/ios_system) и command frameworks — BSD-3-Clause, © Nicolas Holzschuch. См. `THIRD_PARTY.md`.
- OpenCode — MIT, © Anomaly / opencode contributors. Проект не связан с командой OpenCode.

## Сообщество

- Telegram Android-версии: [t.me/OpenCodeMob](https://t.me/OpenCodeMob)
- Официальный OpenCode: [opencode.ai](https://opencode.ai)

---

**Сделано для He.** ❤️