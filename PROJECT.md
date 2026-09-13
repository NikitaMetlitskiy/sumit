# SumIt — обзор проекта

> Обновлено 2026-09-13 по состоянию `main` на коммите `5e56e3f`.
> Первая версия этого обзора описывала коммит `2022499` (2026-09-09) — состояние до работы
> по аудиту и плану надёжности. С тех пор переписаны деньги, хранение, синхронизация,
> курсы валют и отчёты; ниже — текущее положение дел.

AI-трекер личных финансов для iOS. Пользователь пишет (или диктует / фотографирует чек)
в чат на любом языке — «500 грн такси», «$20 coffee yesterday», «100 USDC to Binance» —
GPT разбирает строку в структурированную транзакцию, пользователь подтверждает её карточкой,
запись сохраняется на устройстве и отправляется в Supabase через устойчивую очередь.

---

## 1. Структура репозитория

```
SumIt/                            iOS-приложение (SwiftUI + SwiftData)
  SumItApp.swift                  @main, запуск хранилища, блокировка, сплэш
  Models/                         SwiftData-модели, версионированная схема, DTO протокола
  Services/                       деньги, ledger, синхронизация, курсы, сеть, локализация
  ViewModels/ChatViewModel.swift
  Views/                          чат, отчёты, настройки, кошельки, конфликты, восстановление
SumItTests/                       291 юнит-тест (21 файл)
SumItUITests/                     2 UI-теста
SumIt.xcodeproj/
Backend/
  vercel-project/                 бэкенд на Vercel (Node, ESM), деплоится из main
    api/                          parse, parse-image, rates, health, storekit/*
    api/_lib/                     auth, usage, openai, transaction-contract, parse-response, rates
    test/                         66 тестов на встроенном раннере Node + сохранённые ответы провайдеров
  migrations/                     миграции ledger-а и их соответствие применённым в проде (README.md)
  tests/                          SQL-тесты миграций на синтетических аккаунтах
  supabase_migration.sql          ранняя реконструкция схемы (не точная копия прода)
docs/
  plans/sumit-ledger-reliability-2026-09-09/   план надёжности: дизайн, 21 задача, приёмочные тесты
  reports/                        аудит, отчёт по каждой задаче, записи о прод-изменениях
```

## 2. Стек

| Слой | Технологии |
|---|---|
| iOS | SwiftUI, SwiftData, StoreKit 2, Sign in with Apple, LocalAuthentication, Speech |
| Swift | Swift 5.0 language mode, `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`, iOS 17.0+; 0 предупреждений в приложении и тестах |
| Бэкенд | Vercel serverless (Node ≥ 20, ESM), `jose` (JWKS), `@supabase/supabase-js`, `openai` |
| Данные | Supabase Postgres, RLS на каждой таблице, запись ledger-а через RPC под ролью без BYPASSRLS |
| Auth | Sign in with Apple → Supabase Auth → JWT в iOS Keychain |
| AI | GPT-4o-mini (Basic) / GPT-4o (Pro), контракт разбора v2 |
| Курсы | Frankfurter v2 (фиат), CoinGecko Demo API (крипта) |

Прод:
- Бэкенд: `https://sumit-puce.vercel.app` — Vercel-проект `sumit`, Root Directory `Backend/vercel-project`, собирается на каждый push в `main`.
- Supabase: `https://mjhosrblavjdxirayvqt.supabase.co` (project ref `mjhosrblavjdxirayvqt`).
- Старый Vercel-проект `sumit-backend` приложением не используется.

## 3. Архитектура iOS

`SumItApp` открывает хранилище через `StorageBootstrap` (`opening` → `ready` / `failed`).
При ошибке показывается `StorageRecoveryView` — без `ModelContext`, с кнопками «Повторить» и
«Сохранить копию базы»; подмены на in-memory хранилище больше нет. Поверх всего —
`LockScreenView` (`AppLockManager`: PIN и биометрия) и сплэш. `RootView` пересоздаётся при смене
аккаунта (`.id(auth.scopeEpoch)`) и содержит `TabView`:

| Вкладка | Экран | Что делает |
|---|---|---|
| Чат | `Views/Chat/ChatRootView.swift` | текст/голос/фото, лента, карточка подтверждения с оценкой в USD |
| Отчёты | `Views/Reports/ReportsView.swift` | итоги в `Decimal`, счётчики неоценённых записей, балансы кошельков в их валюте |
| Настройки | `Views/Settings/SettingsView.swift` | профиль, категории, кошельки, PIN, язык, валюта, решения по синхронизации, источники курсов |

### Модели

- **Схема версионирована.** `SumItSchemaV1` заморожена копией моделей до изменений, `SumItSchemaV2` — текущая, переход через `SumItMigrationPlan`.
- **`Transaction`.**
  - Точная сумма — строкой (`amountExact`); кошелёк и получатель перевода — по UUID с точными количествами.
  - Оценка в USD: `baseAmountExact`, `rateExact`, `valuationState`, `quoteJSON` с провенансом.
  - Служебное: `serverRevision` и `localGeneration`; `deletedAt` — надгробие вместо удаления; `migrationState` отличает legacy-строки.
  - Поля `Double` остались только как зеркала для совместимости.
- **`Wallet`.** Начальный баланс `openingBalanceExact`; текущий баланс не хранится, а выводится из записей. Архивирование через `deletedAt`, валюта заблокирована, если на кошелёк ссылаются записи.
- **`Category`, `ChatMessage`.** У пользовательских категорий и сообщений есть владелец (`ownerID`).
- **Синхронизация.** `PendingMutation` — устойчивая очередь с замороженными байтами запроса; `SyncCheckpoint` — курсор ленты; `SyncIssue` — конфликты и проблемы, требующие решения; `CachedRateQuote` — локальный кэш котировок.
- **`ParsedTransaction`.** Результат разбора до подтверждения: точная сумма, кошельки по ID, выбранная оценка.

### Сервисы (`SumIt/Services/`)

| Файл | Роль |
|---|---|
| `money-value.swift` | `MoneyCodec`: канонические десятичные строки, точность по валютам, half-even округление |
| `amount-parser.swift` | разбор суммы целиком по локали приложения, без префиксов и экспонент |
| `transaction-input-segmenter.swift` | деление пакета: запятая между цифрами — часть числа, а не граница |
| `storage-bootstrap.swift` | открытие хранилища, типизированные ошибки, копия базы с WAL/SHM |
| `ledger-store.swift` | атомарные команды (сохранить, изменить, удалить, кошельки, категории) + запись в очередь |
| `wallet-ledger.swift` | единая формула баланса, эффекты расходов/доходов/переводов |
| `ledger-sync-coordinator.swift` | отправка очереди: один диспетчер, заморозка перед отправкой, бэкофф 2/10/30/120/300 с, операции не выбрасываются |
| `ledger-pull-merge.swift` | чтение ленты изменений страницами, слияние по UUID, страница и курсор — одним коммитом |
| `ledger-conflict-resolution.swift` | явный выбор при конфликте: версия сервера, своя версия, сохранить как новую |
| `ledger-scope.swift` | фильтр всех списков по владельцу и надгробиям |
| `transaction-editor.swift` | редактор держит текст и черновик, а не живую запись; правила оценки (VAL) |
| `parsed-transaction-draft.swift` | `ParsedTransaction` → черновик: кошелёк только при однозначном совпадении, переводы — только по выбранным ID |
| `parse-response-decoder.swift` | запрос и ответ контракта v2, контекст пользователя, помеченный legacy-путь |
| `rate-service.swift` | котировки через `/api/rates`, офлайн-кэш, ручной курс |
| `report-valuation.swift` | итоги отчётов в `Decimal`, конверсия в валюту отображения только для показа |
| `ledger-error-copy.swift` | машинные коды ошибок → понятный текст на шести языках |
| `AppStore.swift` | фасад над командами ledger-а, запуск pull/push, legacy-восстановление, производные балансы |
| `AuthService.swift` | Sign in with Apple, сессия в Keychain, `scopeEpoch` на смену аккаунта, отбрасывание запоздалых refresh |
| `SupabaseService.swift` | транспорт ledger-а: `apply_ledger_mutation_v1`, `read_ledger_changes_v1`, типизированные ошибки |
| `BackendService.swift` | `/api/parse`, `/api/parse-image`, `/api/rates` с Supabase JWT |
| `CurrencyService.swift` | список поддерживаемых валют — только метаданные, таблицы курсов больше нет |
| `LocalizationManager.swift` | en, uk, ru, es, de, pl; функция `L("key")` |
| `StoreKitManager`, `KeychainHelper`, `SecurityHelper`, `VoiceInputManager`, `ImageProcessor`, `AppConfig` | подписки, Keychain, PBKDF2 для PIN, речь, даунскейл фото, конфигурация |

### Ключевые флаги (`AppConfig.swift`)
- `paywallEnabled = false` — пейволл выключен, всё бесплатно.
- `maxParseInputChars = 500`, `maxImageUploadBytes = 2 MB`, `imageMaxEdge = 1600`.
- PIN: 5 попыток, затем блокировки 30 с / 2 мин / 10 мин / 1 ч.

## 4. Как устроены деньги и синхронизация

- **Деньги — строки и `Decimal`.** Никакого `Double` при сохранении. Точность новых записей зависит от валюты: фиат — 2 знака, JPY — 0, USDC/USDT — 6, BTC — 8, ETH — 18. Лишние знаки отклоняются, а не округляются. Предел суммы — 1e12, без молчаливого обрезания.
- **Запись.** `LedgerStore` в одной транзакции сохраняет запись и кладёт операцию в `PendingMutation`. Ответ сервера подтверждается отдельной устойчивой записью; повтор отправляет те же байты с тем же `operation_id`.
- **Сервер.**
  - `apply_ledger_mutation_v1(p_request jsonb)` — идемпотентная запись со сверкой ревизий, выполняется ролью `sumit_ledger_executor` без BYPASSRLS. Идентичность UUID сравнивается без учёта регистра.
  - `read_ledger_changes_v1` — ограниченная лента изменений со стабильной отметкой.
- **Конфликты не решаются сами.** Обе версии сохраняются в `SyncIssue`, решает пользователь в «Решениях по синхронизации».
- **Аккаунты.** Данные одного аккаунта не видны и не отправляются под другим. Записи, сделанные до входа, остаются на устройстве и не присваиваются молча тому, кто вошёл.
- **Legacy-строки.** 70 транзакций, созданных до ledger-а, имеют `ledger_revision = 0`, и лента их не отдаёт. Поэтому пока работает `restoreLegacyRowsFromCloud` — со сравнением UUID по значению. Перенос этих строк в ledger — задача 18.

## 5. AI-разбор (контракт v2)

- **Запрос.** Клиент отправляет `contract_version: 2`, свою дату, часовой пояс, локаль приложения и `segment_index`. Сервер проверяет контекст до лимитов и до обращения к модели.
- **Ответ модели.** Модель возвращает `amount_decimal` строкой. Её проверяет один валидатор для текста и фото (`api/_lib/transaction-contract.js`): грамматика, точность по валюте, тип, валюта, дата, уверенность. Нарушение контракта — `422` с кодом причины, в квоту не засчитывается.
- **Старые клиенты.** Запрос без `contract_version` получает прежний ответ v1 без изменений. Клиент распознаёт ответ старого сервера через помеченный путь `LegacyParseCompatibility`.

## 6. Курсы и оценка в USD

- **`GET /api/rates?currencies=…&date=…`** требует входа. Фиат (EUR, UAH, GBP, PLN, CZK, CAD, CHF, RUB, KZT, JPY) идёт из Frankfurter и всегда запрашивается с явной датой. Крипта (BTC, ETH, USDC, USDT) — из CoinGecko по ID из реестра. USD — тождество, без обращения к провайдеру.
- **Нормализация.** Число провайдера нормализуется один раз (`toPrecision(15)`), обратный курс считается через BigInt с half-even до 18 знаков. Котировка возвращается только после записи в `rate_quotes` — с её `quote_id`, и RPC записи сверяет её с этой строкой.
- **Никогда не подставляется** 1, 0 или сегодняшний курс для прошлой даты. Недоступность сообщается с причиной.
- **Оценка на клиенте.**
  - Новая запись не в USD получает свежую котировку, если она пришла, иначе сохраняется без конвертации.
  - Правка суммы оставляет подтверждённый курс; смена валюты или даты требует явного решения.
  - Можно ввести курс вручную.
- **Отчёты.** Суммируют сохранённые значения в USD и показывают, сколько записей в итог не вошло. Валюта отображения — только для показа, с датой курса.
- **Проверено на проде 2026-09-11.** С Vercel пришли реальные котировки EUR от Frankfurter (1.161980013943760167 USD, то есть 1/0.8606) и BTC от CoinGecko (77114 USD), с провенансом.

## 7. Бэкенд (`Backend/vercel-project/`)

| Эндпоинт | Что делает |
|---|---|
| `POST /api/parse` | текст → транзакция; контракт v1 или v2; JWT, лимиты, до 500 символов |
| `POST /api/parse-image` | фото чека → транзакция; тот же валидатор |
| `GET /api/rates` | котировки с провенансом, кэш и аренда обновления |
| `GET /api/health` | проверка окружения |
| `POST /api/storekit/verify` | проверка чека App Store, запись тарифа от service_role |
| `POST /api/storekit/notifications` | вебхук App Store Server Notifications v2 |

- **Переменные окружения.** В проде: `SUPABASE_URL`, `SUPABASE_SERVICE_ROLE_KEY`, `OPENAI_API_KEY`, `COINGECKO_DEMO_API_KEY`. По шаблону `.env.example` также: `APPSTORE_*`, `PARSE_LIMIT_BASIC`, `ALLOW_ANONYMOUS_PARSE`, `PAYWALL_ENABLED`. Значения только в Vercel, в репозитории их нет.
- **Тесты.** `npm test` в `Backend/vercel-project` — встроенный раннер Node и моки модулей, без установки зависимостей и сети, 66 тестов.

## 8. База данных (Supabase)

- **Таблицы.**
  - Продуктовые: `transactions`, `wallets`, `categories`, `profiles`.
  - Ledger: `ledger_sync_state`, `ledger_mutation_receipts`, `ledger_change_log`, `rate_quotes`, `rate_refresh_leases`.
- **Миграции.** Лежат в `Backend/migrations/`, соответствие применённым в проде версиям расписано в `Backend/migrations/README.md`.
- **Прод-изменение 2026-09-11.** С `increment_parse_count` и `reset_monthly_parses` сняты права `anon`/`authenticated`, закреплён `search_path` (см. `docs/reports/production-security-2026-09-11.md`).
- **История инцидента** с первой миграцией — `docs/reports/production-incident-2026-09-09.md`.

## 9. Модель безопасности

- **PIN** хранится как PBKDF2 (100k итераций SHA256 + 16-байтная соль) в Keychain. Приложение блокируется только если его есть чем разблокировать. Состояние «PIN включён без хеша» лечится при запуске; смена биометрии объясняется на экране, а не молча оставляет приложение закрытым.
- **Сессия Supabase** — в Keychain (`kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`). Apple Sign-In использует свежий `nonce` на каждый запрос.
- **Сервер.** RLS на каждой таблице; тариф и счётчики пишет только сервер. Anon-ключ в приложении публичен по замыслу.
- **Секреты** — только в env Vercel. Ключ App Store Connect хранится вне репозитория.
- **Отложено:** certificate pinning (`NSPinnedDomains`) — нужен план ротации.

## 10. Сборка, тесты, деплой

- **iOS.** Открыть `SumIt.xcodeproj` в Xcode (проверено на 26.6), симулятор или устройство iOS 17+, ⌘R. TestFlight — Product → Archive → Distribute → Upload. Bundle ID `com.mykyta.SumIt`, Team `J98SU5UHZZ`. Подписки: `com.mykyta.SumIt.basic.monthly`, `com.mykyta.SumIt.pro.monthly` (локальный конфиг — `SumIt/SumItProducts.storekit`).
- **Тесты iOS.** ⌘U или `xcodebuild … test` — 291 юнит-тест и 2 UI-теста, все зелёные.
- **Бэкенд.** Деплой происходит сам при push в `main` (Vercel-проект `sumit`); можно и вручную — `vercel deploy --prod` из корня репозитория, `.vercelignore` отдаёт только бэкенд.
- **База.** Миграции применяются через Supabase; порядок и статус — в `Backend/migrations/README.md`.

## 11. Состояние и что дальше

План надёжности: закрыто **99 из 140** пунктов (`docs/plans/sumit-ledger-reliability-2026-09-09/implementation-plan.md`).
Полностью выполнены задачи 01, 03–05, 08, 09, 11–14, 17; частично — 02, 06, 07, 10, 15, 16; не начаты — 18–21.

1. **Подтвердить первую реальную отправку.** До коммита `5e56e3f` каждая отправка в прод получала 404: клиент не передавал аргумент `p_request`. Исправлено, но запись с устройства, дошедшая до `ledger_mutation_receipts`, пока не наблюдалась.
2. **Задача 18 — перенос 70 legacy-транзакций в ledger** с возможностью отката. После этого можно убрать legacy-восстановление.
3. **Задачи 19–21:** доступ к восстановленным записям и ошибкам синхронизации, полный набор сбоев и жизненного цикла, пилот.
4. **Тесты конкурентного доступа** (CONC-01…04) не запускались — нужен отдельный одноразовый проект Supabase.
5. **CoinGecko:** условия API запрещают хранить данные и требуют удалять их после прекращения использования, а ledger хранит котировку при записи бессрочно. Нужно решение владельца.
6. **Пейволл:** создать SKU, выставить `APPSTORE_*` в Vercel, включить `PAYWALL_ENABLED` с обеих сторон.
7. **Certificate pinning** — отложен.

## 12. История коммитов

```
5e56e3f  Name the write RPC's argument, so a push can reach the server
469ad3a  Remove every main-actor isolation warning
9958cf1  Fix an app lock that could not be opened
3c11917  Docs: reliability plan, execution reports and production records
69df0b3  iOS: exact money ledger, durable sync, account scope, dated valuation
1e31298  Backend: parse contract v2 and GET /api/rates
e6e5732  Database: ledger schema, write RPC, change feed, parse-count hardening
2022499  Revert Figma redesign — restore TabView home, original confirmation card
cf48409  AppStore: explicit self in Log.info autoclosure
1479b20  Last two compile errors
2faebcc  Final compile fixes: VerificationResult.jws, init isolation, autoclosure
34da717  Fix remaining Swift 6 errors and warnings
d9fe5d7  Wire new files into Xcode target + fix Swift 6 concurrency errors
faa83e3  Redesign UI to match Figma: orb home, new card, detail/edit, reports
0d4ac1a  Point iOS to new hardened backend (sumit-puce.vercel.app)
02a044a  Add hardened iOS app and Vercel backend
d8e32b8  Initial Commit
```
