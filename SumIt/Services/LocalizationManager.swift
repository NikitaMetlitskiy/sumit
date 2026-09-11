import SwiftUI
import Combine

// MARK: — Global localization function
/// Free function — implicitly nonisolated. Backed by `LocalizationManager.translate(_:)`
/// which reads only Sendable static state, so it's safe to call from models / actors.
func L(_ key: String) -> String {
    LocalizationManager.translate(key)
}

// MARK: — Supported languages
enum AppLanguage: String, CaseIterable, Codable {
    case en = "en"
    case uk = "uk"
    case ru = "ru"
    case es = "es"
    case de = "de"
    case pl = "pl"

    var displayName: String {
        switch self {
        case .en: return "English"
        case .uk: return "Українська"
        case .ru: return "Русский"
        case .es: return "Español"
        case .de: return "Deutsch"
        case .pl: return "Polski"
        }
    }

    var flag: String {
        switch self {
        case .en: return "🇬🇧"
        case .uk: return "🇺🇦"
        case .ru: return "🇷🇺"
        case .es: return "🇪🇸"
        case .de: return "🇩🇪"
        case .pl: return "🇵🇱"
        }
    }
}

// MARK: — Localization Manager
/// Hybrid:
///   • MainActor `ObservableObject` so SwiftUI views react to language changes via `current`.
///   • Nonisolated static API (`translate`, `currentLanguageRaw`, `translationsData`) so
///     SwiftData @Model accessors and actors can call `L(_:)` without hopping to MainActor.
/// The single source of truth — `translationsData` — is a Sendable immutable dictionary.
@MainActor
final class LocalizationManager: ObservableObject {
    static let shared = LocalizationManager()
    @Published var current: AppLanguage {
        didSet { LocalizationManager.currentLanguageRaw = current.rawValue }
    }

    /// Sendable cache of the current language code so `L(_:)` works from any actor.
    /// Updated by `current.didSet` and by the initializer.
    nonisolated(unsafe) static var currentLanguageRaw: String = {
        if let saved = UserDefaults.standard.string(forKey: "app_language") { return saved }
        let preferred = Locale.preferredLanguages.first ?? "en"
        return String(preferred.prefix(2))
    }()

    private let storageKey = "app_language"

    private init() {
        if let saved = UserDefaults.standard.string(forKey: storageKey),
           let lang = AppLanguage(rawValue: saved) {
            self.current = lang
        } else {
            let preferred = Locale.preferredLanguages.first ?? "en"
            let code = String(preferred.prefix(2))
            self.current = AppLanguage(rawValue: code) ?? .en
        }
        LocalizationManager.currentLanguageRaw = self.current.rawValue
    }

    func setLanguage(_ lang: AppLanguage) {
        current = lang
        UserDefaults.standard.set(lang.rawValue, forKey: storageKey)
        LocalizationManager.currentLanguageRaw = lang.rawValue
    }

    func t(_ k: String) -> String { LocalizationManager.translate(k) }

    /// Nonisolated lookup used by `L(_:)`. Reads only static immutable data + the Sendable string cache.
    nonisolated static func translate(_ key: String) -> String {
        translationsData[key]?[currentLanguageRaw] ?? translationsData[key]?["en"] ?? key
    }

    /// Backwards-compatible accessor so existing call sites (`LocalizationManager.shared.translations`) continue to work.
    nonisolated var translations: [String: [String: String]] { LocalizationManager.translationsData }

    // MARK: — All translations (Sendable static dict — see `translations` computed accessor above)
    nonisolated static let translationsData: [String: [String: String]] = [
        // MARK: General
        "app_name": ["en":"SumIt","uk":"SumIt","ru":"SumIt","es":"SumIt","de":"SumIt","pl":"SumIt"],
        "financial_assistant": ["en":"Financial Assistant","uk":"Фінансовий асистент","ru":"Финансовый ассистент","es":"Asistente financiero","de":"Finanzassistent","pl":"Asystent finansowy"],
        "save": ["en":"Save","uk":"Зберегти","ru":"Сохранить","es":"Guardar","de":"Speichern","pl":"Zapisz"],
        "cancel": ["en":"Cancel","uk":"Скасувати","ru":"Отмена","es":"Cancelar","de":"Abbrechen","pl":"Anuluj"],
        "close": ["en":"Close","uk":"Закрити","ru":"Закрыть","es":"Cerrar","de":"Schließen","pl":"Zamknij"],
        "delete": ["en":"Delete","uk":"Видалити","ru":"Удалить","es":"Eliminar","de":"Löschen","pl":"Usuń"],
        "edit": ["en":"Edit","uk":"Редагувати","ru":"Изменить","es":"Editar","de":"Bearbeiten","pl":"Edytuj"],
        "done": ["en":"Done","uk":"Готово","ru":"Готово","es":"Listo","de":"Fertig","pl":"Gotowe"],
        "reorder": ["en":"Reorder","uk":"Змінити порядок","ru":"Изменить порядок","es":"Reordenar","de":"Neu ordnen","pl":"Zmień kolejność"],
        "add": ["en":"Add","uk":"Додати","ru":"Добавить","es":"Añadir","de":"Hinzufügen","pl":"Dodaj"],
        "back": ["en":"Back","uk":"Назад","ru":"Назад","es":"Atrás","de":"Zurück","pl":"Wstecz"],
        "yes": ["en":"Yes","uk":"Так","ru":"Да","es":"Sí","de":"Ja","pl":"Tak"],
        "no": ["en":"No","uk":"Ні","ru":"Нет","es":"No","de":"Nein","pl":"Nie"],
        "error": ["en":"Error","uk":"Помилка","ru":"Ошибка","es":"Error","de":"Fehler","pl":"Błąd"],
        "version": ["en":"Version","uk":"Версія","ru":"Версия","es":"Versión","de":"Version","pl":"Wersja"],
        "today": ["en":"Today","uk":"Сьогодні","ru":"Сегодня","es":"Hoy","de":"Heute","pl":"Dzisiaj"],
        "yesterday": ["en":"Yesterday","uk":"Вчора","ru":"Вчера","es":"Ayer","de":"Gestern","pl":"Wczoraj"],

        // MARK: Tabs
        "tab_chat": ["en":"Chat","uk":"Чат","ru":"Чат","es":"Chat","de":"Chat","pl":"Czat"],
        "tab_reports": ["en":"Reports","uk":"Звіти","ru":"Отчёты","es":"Informes","de":"Berichte","pl":"Raporty"],
        "tab_settings": ["en":"Settings","uk":"Налаштування","ru":"Настройки","es":"Ajustes","de":"Einstellungen","pl":"Ustawienia"],

        // MARK: Chat
        "chat_placeholder": ["en":"500 UAH taxi or $20 coffee...","uk":"500 грн таксі або $20 кава...","ru":"500 грн такси или $20 кофе...","es":"500 UAH taxi o $20 café...","de":"500 UAH Taxi oder $20 Kaffee...","pl":"500 UAH taxi lub $20 kawa..."],
        "chat_welcome": [
            "en":"Hi! I'm SumIt 👋\n\nRecord expenses and income:\n• \"500 UAH taxi\"\n• \"$20 coffee yesterday\"\n• \"salary 45000 UAH\"\n• \"100 USDC to Binance\"\n\nI'll recognize and offer to save 💰",
            "uk":"Привіт! Я SumIt 👋\n\nЗаписуй витрати та доходи:\n• «500 грн таксі»\n• «$20 кава вчора»\n• «зарплата 45000 грн»\n• «100 USDC на Binance»\n\nЯ розпізнаю і запропоную зберегти 💰",
            "ru":"Привет! Я SumIt 👋\n\nЗаписывай расходы и доходы:\n• «500 грн такси»\n• «$20 кофе вчера»\n• «зарплата 45000 грн»\n• «100 USDC на Binance»\n\nЯ распознаю и предложу сохранить 💰",
            "es":"¡Hola! Soy SumIt 👋\n\nRegistra gastos e ingresos:\n• \"500 UAH taxi\"\n• \"$20 café ayer\"\n• \"salario 45000 UAH\"\n• \"100 USDC a Binance\"\n\nReconoceré y ofreceré guardar 💰",
            "de":"Hallo! Ich bin SumIt 👋\n\nAusgaben und Einnahmen erfassen:\n• \"500 UAH Taxi\"\n• \"$20 Kaffee gestern\"\n• \"Gehalt 45000 UAH\"\n• \"100 USDC an Binance\"\n\nIch erkenne und biete an zu speichern 💰",
            "pl":"Cześć! Jestem SumIt 👋\n\nZapisuj wydatki i przychody:\n• \"500 UAH taxi\"\n• \"$20 kawa wczoraj\"\n• \"pensja 45000 UAH\"\n• \"100 USDC na Binance\"\n\nRozpoznam i zaproponuję zapisanie 💰"
        ],
        "chat_empty_title": ["en":"Start managing finances","uk":"Почни вести фінанси","ru":"Начни вести финансы","es":"Empieza a gestionar finanzas","de":"Beginne mit der Finanzverwaltung","pl":"Zacznij zarządzać finansami"],
        "chat_recognized": ["en":"Recognized transaction ⬇️ Check and confirm:","uk":"Розпізнав транзакцію ⬇️ Перевір і підтверди:","ru":"Распознал транзакцию ⬇️ Проверь и подтверди:","es":"Transacción reconocida ⬇️ Verifica y confirma:","de":"Transaktion erkannt ⬇️ Prüfen und bestätigen:","pl":"Rozpoznano transakcję ⬇️ Sprawdź i potwierdź:"],
        "chat_recognized_multi": ["en":"Recognized %d transactions ⬇️ Confirm one by one:","uk":"Розпізнав %d транзакцій ⬇️ Підтверди по черзі:","ru":"Распознал %d транзакций ⬇️ Подтверди по очереди:","es":"Reconocidas %d transacciones ⬇️ Confirma una por una:","de":"%d Transaktionen erkannt ⬇️ Einzeln bestätigen:","pl":"Rozpoznano %d transakcji ⬇️ Potwierdź kolejno:"],
        "chat_saved": ["en":"Saved!","uk":"Збережено!","ru":"Сохранено!","es":"¡Guardado!","de":"Gespeichert!","pl":"Zapisano!"],
        "chat_cancelled": ["en":"Cancelled 👍 Write again when ready.","uk":"Скасовано 👍 Напиши знову коли будеш готовий.","ru":"Отменено 👍 Напиши снова когда будешь готов.","es":"Cancelado 👍 Escribe de nuevo cuando estés listo.","de":"Abgebrochen 👍 Schreib erneut wenn bereit.","pl":"Anulowano 👍 Napisz ponownie gdy będziesz gotowy."],
        "chat_next_tx": ["en":"Next transaction ⬇️","uk":"Наступна транзакція ⬇️","ru":"Следующая транзакция ⬇️","es":"Siguiente transacción ⬇️","de":"Nächste Transaktion ⬇️","pl":"Następna transakcja ⬇️"],
        "chat_skipped_next": ["en":"Skipped. Next ⬇️","uk":"Пропущено. Далі ⬇️","ru":"Пропущено. Следующая ⬇️","es":"Omitido. Siguiente ⬇️","de":"Übersprungen. Nächste ⬇️","pl":"Pominięto. Następna ⬇️"],
        "chat_photo_receipt": ["en":"📷 Receipt photo","uk":"📷 Фото чека","ru":"📷 Фото чека","es":"📷 Foto del recibo","de":"📷 Quittungsfoto","pl":"📷 Zdjęcie paragonu"],
        "chat_analyzing": ["en":"Analyzing receipt... 🔍","uk":"Аналізую чек... 🔍","ru":"Анализирую чек... 🔍","es":"Analizando recibo... 🔍","de":"Beleg wird analysiert... 🔍","pl":"Analizuję paragon... 🔍"],
        "chat_recognized_receipt": ["en":"Recognized receipt ⬇️ Check and confirm:","uk":"Розпізнав чек ⬇️ Перевір і підтверди:","ru":"Распознал чек ⬇️ Проверь и подтверди:","es":"Recibo reconocido ⬇️ Verifica y confirma:","de":"Beleg erkannt ⬇️ Prüfen und bestätigen:","pl":"Paragon rozpoznany ⬇️ Sprawdź i potwierdź:"],
        "chat_receipt_fail": ["en":"Couldn't recognize receipt 🤔\nTry clearer or type manually: \"500 UAH coffee\"","uk":"Не зміг розпізнати чек 🤔\nСпробуй чіткіше або введи вручну: «500 грн кава»","ru":"Не смог распознать чек 🤔\nПопробуй чётче или введи вручную: «500 грн кофе»","es":"No pude reconocer el recibo 🤔\nIntenta más claro o escribe: \"500 UAH café\"","de":"Beleg nicht erkannt 🤔\nVersuche deutlicher oder tippe: \"500 UAH Kaffee\"","pl":"Nie rozpoznano paragonu 🤔\nSpróbuj wyraźniej lub wpisz: \"500 UAH kawa\""],
        "chat_parse_fail": ["en":"Could not parse expenses 🤔\nTry one at a time: \"500 UAH taxi\"","uk":"Не зміг розпізнати витрати 🤔\nСпробуй по одній: «500 грн таксі»","ru":"Не смог распознать траты 🤔\nПопробуй по одной: «500 грн такси»","es":"No pude analizar gastos 🤔\nIntenta uno a la vez: \"500 UAH taxi\"","de":"Ausgaben nicht erkannt 🤔\nVersuche einzeln: \"500 UAH Taxi\"","pl":"Nie rozpoznano wydatków 🤔\nSpróbuj pojedynczo: \"500 UAH taxi\""],
        "chat_im_assistant": ["en":"I'm a financial assistant 💰\n\nI only record expenses and income:\n• \"500 UAH taxi\"\n• \"$20 coffee\"\n• \"salary 45000 UAH\"\n• \"100 USDC to Binance\"","uk":"Я фінансовий асистент 💰\n\nЗаписую лише витрати і доходи:\n• «500 грн таксі»\n• «$20 кава»\n• «зарплата 45000 грн»\n• «100 USDC на Binance»","ru":"Я финансовый ассистент 💰\n\nПишу только расходы и доходы:\n• «500 грн такси»\n• «$20 кофе»\n• «зарплата 45000 грн»\n• «100 USDC на Binance»","es":"Soy un asistente financiero 💰\n\nSolo registro gastos e ingresos:\n• \"500 UAH taxi\"\n• \"$20 café\"\n• \"salario 45000 UAH\"\n• \"100 USDC a Binance\"","de":"Ich bin ein Finanzassistent 💰\n\nIch erfasse nur Ausgaben und Einnahmen:\n• \"500 UAH Taxi\"\n• \"$20 Kaffee\"\n• \"Gehalt 45000 UAH\"\n• \"100 USDC an Binance\"","pl":"Jestem asystentem finansowym 💰\n\nRejestruję tylko wydatki i przychody:\n• \"500 UAH taxi\"\n• \"$20 kawa\"\n• \"pensja 45000 UAH\"\n• \"100 USDC na Binance\""],
        "speak": ["en":"Speak...","uk":"Говори...","ru":"Говори...","es":"Habla...","de":"Sprich...","pl":"Mów..."],
        "take_photo": ["en":"Take photo","uk":"Зняти фото","ru":"Снять фото","es":"Tomar foto","de":"Foto aufnehmen","pl":"Zrób zdjęcie"],
        "choose_gallery": ["en":"Choose from gallery","uk":"Вибрати з галереї","ru":"Выбрать из галереи","es":"Elegir de galería","de":"Aus Galerie wählen","pl":"Wybierz z galerii"],
        "add_receipt_photo": ["en":"Add receipt photo","uk":"Додати фото чека","ru":"Добавить фото чека","es":"Añadir foto del recibo","de":"Belegfoto hinzufügen","pl":"Dodaj zdjęcie paragonu"],
        "no_mic_access": ["en":"No microphone access","uk":"Немає доступу до мікрофона","ru":"Нет доступа к микрофону","es":"Sin acceso al micrófono","de":"Kein Mikrofonzugriff","pl":"Brak dostępu do mikrofonu"],
        "allow_mic_settings": ["en":"Allow microphone access in Settings","uk":"Дозволь доступ до мікрофона в Налаштуваннях","ru":"Разреши доступ к микрофону в Настройках","es":"Permite el acceso al micrófono en Ajustes","de":"Erlaube Mikrofonzugriff in Einstellungen","pl":"Zezwól na dostęp do mikrofonu w Ustawieniach"],
        "open_settings": ["en":"Settings","uk":"Налаштування","ru":"Настройки","es":"Ajustes","de":"Einstellungen","pl":"Ustawienia"],

        // MARK: Confirmation Card
        "expense": ["en":"Expense","uk":"Витрата","ru":"Расход","es":"Gasto","de":"Ausgabe","pl":"Wydatek"],
        "income": ["en":"Income","uk":"Дохід","ru":"Доход","es":"Ingreso","de":"Einnahme","pl":"Przychód"],
        "transfer": ["en":"Transfer","uk":"Переказ","ru":"Перевод","es":"Transferencia","de":"Überweisung","pl":"Przelew"],
        "category": ["en":"Category","uk":"Категорія","ru":"Категория","es":"Categoría","de":"Kategorie","pl":"Kategoria"],
        "merchant": ["en":"Merchant","uk":"Продавець","ru":"Продавец","es":"Comercio","de":"Händler","pl":"Sprzedawca"],
        "date": ["en":"Date","uk":"Дата","ru":"Дата","es":"Fecha","de":"Datum","pl":"Data"],
        "note": ["en":"Note","uk":"Нотатка","ru":"Заметка","es":"Nota","de":"Notiz","pl":"Notatka"],
        "wallet": ["en":"Wallet","uk":"Гаманець","ru":"Кошелёк","es":"Cartera","de":"Wallet","pl":"Portfel"],
        "not_selected": ["en":"Not selected","uk":"Не обрано","ru":"Не выбран","es":"No seleccionado","de":"Nicht ausgewählt","pl":"Nie wybrano"],
        "check_data": ["en":"We recommend checking the data","uk":"Рекомендуємо перевірити дані","ru":"Рекомендуем проверить данные","es":"Recomendamos verificar los datos","de":"Wir empfehlen die Daten zu prüfen","pl":"Zalecamy sprawdzenie danych"],

        // MARK: Settings
        "settings_title": ["en":"Settings","uk":"Налаштування","ru":"Настройки","es":"Ajustes","de":"Einstellungen","pl":"Ustawienia"],
        "edit_profile": ["en":"Edit profile","uk":"Редагувати профіль","ru":"Редактировать профиль","es":"Editar perfil","de":"Profil bearbeiten","pl":"Edytuj profil"],
        "setup_profile": ["en":"Set up profile","uk":"Налаштувати профіль","ru":"Настроить профиль","es":"Configurar perfil","de":"Profil einrichten","pl":"Skonfiguruj profil"],
        "user_default": ["en":"User","uk":"Користувач","ru":"Пользователь","es":"Usuario","de":"Benutzer","pl":"Użytkownik"],
        "preferences": ["en":"Settings","uk":"Налаштування","ru":"Настройки","es":"Ajustes","de":"Einstellungen","pl":"Ustawienia"],
        "currency": ["en":"Currency","uk":"Валюта","ru":"Валюта","es":"Moneda","de":"Währung","pl":"Waluta"],
        "language": ["en":"Language","uk":"Мова","ru":"Язык","es":"Idioma","de":"Sprache","pl":"Język"],
        "finance": ["en":"Finance","uk":"Фінанси","ru":"Финансы","es":"Finanzas","de":"Finanzen","pl":"Finanse"],
        "categories": ["en":"Categories","uk":"Категорії","ru":"Категории","es":"Categorías","de":"Kategorien","pl":"Kategorie"],
        "wallets": ["en":"Wallets","uk":"Гаманці","ru":"Кошельки","es":"Carteras","de":"Wallets","pl":"Portfele"],
        "notifications": ["en":"Notifications","uk":"Сповіщення","ru":"Уведомления","es":"Notificaciones","de":"Benachrichtigungen","pl":"Powiadomienia"],
        "daily_reminder": ["en":"Daily reminder 10:00","uk":"Щоденне нагадування 10:00","ru":"Напоминание 10:00","es":"Recordatorio diario 10:00","de":"Tägliche Erinnerung 10:00","pl":"Codzienne przypomnienie 10:00"],
        "weekly_report": ["en":"Weekly report","uk":"Щотижневий звіт","ru":"Еженедельный отчёт","es":"Informe semanal","de":"Wochenbericht","pl":"Raport tygodniowy"],
        "security": ["en":"Security","uk":"Безпека","ru":"Безопасность","es":"Seguridad","de":"Sicherheit","pl":"Bezpieczeństwo"],
        "face_id": ["en":"Face ID / Touch ID","uk":"Face ID / Touch ID","ru":"Face ID / Touch ID","es":"Face ID / Touch ID","de":"Face ID / Touch ID","pl":"Face ID / Touch ID"],
        "change_pin": ["en":"Change PIN","uk":"Змінити PIN","ru":"Изменить PIN","es":"Cambiar PIN","de":"PIN ändern","pl":"Zmień PIN"],
        "disable_pin": ["en":"Disable PIN","uk":"Вимкнути PIN","ru":"Отключить PIN","es":"Desactivar PIN","de":"PIN deaktivieren","pl":"Wyłącz PIN"],
        "set_pin": ["en":"Set PIN","uk":"Встановити PIN","ru":"Установить PIN","es":"Establecer PIN","de":"PIN einrichten","pl":"Ustaw PIN"],
        "about": ["en":"About","uk":"Про додаток","ru":"О приложении","es":"Acerca de","de":"Über","pl":"O aplikacji"],
        "support": ["en":"Support","uk":"Підтримка","ru":"Поддержка","es":"Soporte","de":"Support","pl":"Wsparcie"],
        "privacy": ["en":"Privacy","uk":"Конфіденційність","ru":"Конфиденциальность","es":"Privacidad","de":"Datenschutz","pl":"Prywatność"],
        "system_cat": ["en":"System","uk":"Системна","ru":"Системная","es":"Sistema","de":"System","pl":"Systemowa"],

        // MARK: Profile & Account
        "profile": ["en":"Profile","uk":"Профіль","ru":"Профиль","es":"Perfil","de":"Profil","pl":"Profil"],
        "profile_photo": ["en":"Profile photo","uk":"Фото профілю","ru":"Фото профиля","es":"Foto de perfil","de":"Profilfoto","pl":"Zdjęcie profilowe"],
        "name": ["en":"Name","uk":"Ім'я","ru":"Имя","es":"Nombre","de":"Name","pl":"Imię"],
        "your_name": ["en":"Your name","uk":"Твоє ім'я","ru":"Твоё имя","es":"Tu nombre","de":"Dein Name","pl":"Twoje imię"],
        "account_sync": ["en":"Account and sync","uk":"Акаунт і синхронізація","ru":"Аккаунт и синхронизация","es":"Cuenta y sincronización","de":"Konto und Synchronisierung","pl":"Konto i synchronizacja"],
        "sync_enabled": ["en":"Sync enabled","uk":"Синхронізація увімкнена","ru":"Синхронизация включена","es":"Sincronización activada","de":"Synchronisierung aktiviert","pl":"Synchronizacja włączona"],
        "sign_in_sync": ["en":"Sign in to sync between devices","uk":"Увійди для синхронізації між пристроями","ru":"Войди для синхронизации между устройствами","es":"Inicia sesión para sincronizar entre dispositivos","de":"Anmelden um Geräte zu synchronisieren","pl":"Zaloguj się aby synchronizować między urządzeniami"],
        "sign_out": ["en":"Sign out","uk":"Вийти з акаунту","ru":"Выйти из аккаунта","es":"Cerrar sesión","de":"Abmelden","pl":"Wyloguj się"],
        "sign_out_q": ["en":"Sign out?","uk":"Вийти з акаунту?","ru":"Выйти из аккаунта?","es":"¿Cerrar sesión?","de":"Abmelden?","pl":"Wylogować się?"],
        "sign_out_msg": ["en":"Data will remain on device. Sign in again to sync.","uk":"Дані залишаться на пристрої. Увійди знову для синхронізації.","ru":"Данные останутся на устройстве. Для синхронизации нужно войти снова.","es":"Los datos permanecerán en el dispositivo. Inicia sesión de nuevo para sincronizar.","de":"Daten bleiben auf dem Gerät. Erneut anmelden zum Synchronisieren.","pl":"Dane pozostaną na urządzeniu. Zaloguj się ponownie aby zsynchronizować."],
        "no_account": ["en":"No account","uk":"Немає акаунту","ru":"Нет аккаунта","es":"Sin cuenta","de":"Kein Konto","pl":"Brak konta"],

        // MARK: Reports
        "reports_title": ["en":"Reports","uk":"Звіти","ru":"Отчёты","es":"Informes","de":"Berichte","pl":"Raporty"],
        "overview": ["en":"Overview","uk":"Огляд","ru":"Обзор","es":"Resumen","de":"Übersicht","pl":"Przegląd"],
        "expenses": ["en":"Expenses","uk":"Витрати","ru":"Расходы","es":"Gastos","de":"Ausgaben","pl":"Wydatki"],
        "incomes": ["en":"Income","uk":"Доходи","ru":"Доходы","es":"Ingresos","de":"Einnahmen","pl":"Przychody"],
        "balance": ["en":"Balance","uk":"Баланс","ru":"Баланс","es":"Saldo","de":"Saldo","pl":"Saldo"],
        "transactions_count": ["en":"Transactions","uk":"Транзакцій","ru":"Транзакций","es":"Transacciones","de":"Transaktionen","pl":"Transakcji"],
        "pcs": ["en":"pcs","uk":"шт.","ru":"шт.","es":"uds.","de":"Stk.","pl":"szt."],
        "top": ["en":"Top","uk":"Топ","ru":"Топ","es":"Top","de":"Top","pl":"Top"],
        "recent": ["en":"Recent","uk":"Останні","ru":"Последние","es":"Recientes","de":"Letzte","pl":"Ostatnie"],
        "no_data": ["en":"No data","uk":"Немає даних","ru":"Нет данных","es":"Sin datos","de":"Keine Daten","pl":"Brak danych"],
        "add_expenses_chat": ["en":"Add expenses in chat","uk":"Додай витрати у чаті","ru":"Добавь расходы в чате","es":"Añade gastos en el chat","de":"Füge Ausgaben im Chat hinzu","pl":"Dodaj wydatki w czacie"],
        "flow": ["en":"Income/Expenses","uk":"Доходи/Витрати","ru":"Доходы/Расходы","es":"Ingresos/Gastos","de":"Einnahmen/Ausgaben","pl":"Przychody/Wydatki"],
        "charts": ["en":"Charts","uk":"Графіки","ru":"Графики","es":"Gráficos","de":"Diagramme","pl":"Wykresy"],
        "total": ["en":"Total","uk":"Разом","ru":"Итого","es":"Total","de":"Gesamt","pl":"Razem"],
        "expenses_by_day": ["en":"Expenses by day","uk":"Витрати за день","ru":"Расходы по дням","es":"Gastos por día","de":"Ausgaben pro Tag","pl":"Wydatki dzienne"],
        "period_week": ["en":"7 days","uk":"7 днів","ru":"7 дней","es":"7 días","de":"7 Tage","pl":"7 dni"],
        "period_month": ["en":"Month","uk":"Місяць","ru":"Месяц","es":"Mes","de":"Monat","pl":"Miesiąc"],
        "period_year": ["en":"Year","uk":"Рік","ru":"Год","es":"Año","de":"Jahr","pl":"Rok"],

        // MARK: Wallets
        "no_wallets": ["en":"No wallets","uk":"Немає гаманців","ru":"Нет кошельков","es":"Sin carteras","de":"Keine Wallets","pl":"Brak portfeli"],
        "add_wallet": ["en":"Add wallet","uk":"Додати гаманець","ru":"Добавить кошелёк","es":"Añadir cartera","de":"Wallet hinzufügen","pl":"Dodaj portfel"],
        "add_bank_exchange": ["en":"Add bank account, exchange or crypto wallet","uk":"Додай банківський рахунок, біржу або криптогаманець","ru":"Добавь банковский счёт, биржу или криптокошелёк","es":"Añade cuenta bancaria, exchange o cripto cartera","de":"Bankkonto, Börse oder Krypto-Wallet hinzufügen","pl":"Dodaj konto bankowe, giełdę lub portfel krypto"],
        "new_wallet": ["en":"New wallet","uk":"Новий гаманець","ru":"Новый кошелёк","es":"Nueva cartera","de":"Neues Wallet","pl":"Nowy portfel"],
        "wallet_name_placeholder": ["en":"e.g. Monobank","uk":"Наприклад: Monobank","ru":"Например: Monobank","es":"Ej: Monobank","de":"z.B. Monobank","pl":"Np. Monobank"],
        "wallet_type": ["en":"Wallet type","uk":"Тип гаманця","ru":"Тип кошелька","es":"Tipo de cartera","de":"Wallet-Typ","pl":"Typ portfela"],
        "wallet_manage": ["en":"Manage wallets","uk":"Управління гаманцями","ru":"Управление кошельками","es":"Gestionar carteras","de":"Wallets verwalten","pl":"Zarządzaj portfelami"],
        "wallet_type_bank": ["en":"Bank","uk":"Банк","ru":"Банк","es":"Banco","de":"Bank","pl":"Bank"],
        "wallet_type_exchange": ["en":"Exchange","uk":"Біржа","ru":"Биржа","es":"Exchange","de":"Börse","pl":"Giełda"],
        "wallet_type_crypto": ["en":"Crypto exchange","uk":"Криптобіржа","ru":"Криптобиржа","es":"Criptoexchange","de":"Kryptobörse","pl":"Giełda krypto"],
        "wallet_type_cash": ["en":"Cash","uk":"Готівка","ru":"Наличные","es":"Efectivo","de":"Bargeld","pl":"Gotówka"],
        "wallet_type_custom": ["en":"Other","uk":"Інше","ru":"Другое","es":"Otro","de":"Sonstige","pl":"Inne"],

        // MARK: Transaction types
        "type_expense": ["en":"Expense","uk":"Витрата","ru":"Расход","es":"Gasto","de":"Ausgabe","pl":"Wydatek"],
        "type_income": ["en":"Income","uk":"Дохід","ru":"Доход","es":"Ingreso","de":"Einnahme","pl":"Przychód"],
        "type_transfer": ["en":"Transfer","uk":"Переказ","ru":"Перевод","es":"Transferencia","de":"Überweisung","pl":"Przelew"],
        "type_label": ["en":"Operation type","uk":"Тип операції","ru":"Тип операции","es":"Tipo de operación","de":"Transaktionstyp","pl":"Typ operacji"],
        "amount_currency": ["en":"Amount and currency","uk":"Сума та валюта","ru":"Сумма и валюта","es":"Monto y moneda","de":"Betrag und Währung","pl":"Kwota i waluta"],
        "details": ["en":"Details","uk":"Деталі","ru":"Детали","es":"Detalles","de":"Details","pl":"Szczegóły"],
        "merchant_store": ["en":"Merchant / store","uk":"Продавець / магазин","ru":"Продавец / магазин","es":"Comercio / tienda","de":"Händler / Geschäft","pl":"Sprzedawca / sklep"],
        "note_optional": ["en":"Note (optional)","uk":"Нотатка (необов'язково)","ru":"Заметка (опционально)","es":"Nota (opcional)","de":"Notiz (optional)","pl":"Notatka (opcjonalnie)"],

        // MARK: PIN Screen
        "enter_code": ["en":"Enter code","uk":"Введи код","ru":"Введи код","es":"Ingresa el código","de":"Code eingeben","pl":"Wprowadź kod"],
        "wrong_code": ["en":"Wrong code. Try again","uk":"Невірний код. Спробуй знову","ru":"Неверный код. Попробуй снова","es":"Código incorrecto. Inténtalo de nuevo","de":"Falscher Code. Erneut versuchen","pl":"Błędny kod. Spróbuj ponownie"],
        "enter_new_pin": ["en":"Enter new PIN","uk":"Введи новий PIN","ru":"Введи новый PIN","es":"Ingresa nuevo PIN","de":"Neue PIN eingeben","pl":"Wprowadź nowy PIN"],
        "repeat_pin": ["en":"Repeat PIN","uk":"Повтори PIN","ru":"Повтори PIN","es":"Repite el PIN","de":"PIN wiederholen","pl":"Powtórz PIN"],
        "pins_mismatch": ["en":"PINs don't match","uk":"PIN-коди не збігаються","ru":"PIN-коды не совпадают","es":"Los PINs no coinciden","de":"PINs stimmen nicht überein","pl":"Kody PIN nie pasują"],
        "pin_code": ["en":"PIN code","uk":"PIN-код","ru":"PIN-код","es":"Código PIN","de":"PIN-Code","pl":"Kod PIN"],

        // MARK: Categories
        "new_category": ["en":"New category","uk":"Нова категорія","ru":"Новая категория","es":"Nueva categoría","de":"Neue Kategorie","pl":"Nowa kategoria"],
        "category_name_hint": ["en":"e.g. Sports","uk":"Наприклад: Спорт","ru":"Например: Спорт","es":"Ej: Deportes","de":"z.B. Sport","pl":"Np. Sport"],
        "icon": ["en":"Icon","uk":"Іконка","ru":"Иконка","es":"Icono","de":"Symbol","pl":"Ikona"],
        "color": ["en":"Color","uk":"Колір","ru":"Цвет","es":"Color","de":"Farbe","pl":"Kolor"],

        // MARK: Subscription
        "subscription": ["en":"Subscription","uk":"Підписка","ru":"Подписка","es":"Suscripción","de":"Abonnement","pl":"Subskrypcja"],
        "active": ["en":"Active","uk":"Активна","ru":"Активна","es":"Activa","de":"Aktiv","pl":"Aktywna"],
        "unlimited_access": ["en":"Unlimited access","uk":"Безлімітний доступ","ru":"Безлимитный доступ","es":"Acceso ilimitado","de":"Unbegrenzter Zugang","pl":"Nieograniczony dostęp"],
        "upgrade_to_pro": ["en":"Upgrade to Pro","uk":"Перейти на Pro","ru":"Перейти на Pro","es":"Actualizar a Pro","de":"Auf Pro upgraden","pl":"Przejdź na Pro"],
        "subscribe_plan": ["en":"Get subscription","uk":"Оформити підписку","ru":"Оформить подписку","es":"Obtener suscripción","de":"Abonnement abschließen","pl":"Wykup subskrypcję"],
        "subscribe_btn": ["en":"Subscribe","uk":"Підписатись","ru":"Подписаться","es":"Suscribirse","de":"Abonnieren","pl":"Subskrybuj"],
        "restore_purchases": ["en":"Restore purchases","uk":"Відновити покупки","ru":"Восстановить покупки","es":"Restaurar compras","de":"Käufe wiederherstellen","pl":"Przywróć zakupy"],
        "auto_renew_note": ["en":"Subscription renews automatically. Cancel in Apple ID settings.","uk":"Підписка поновлюється автоматично. Скасувати можна в налаштуваннях Apple ID.","ru":"Подписка продлевается автоматически. Отменить можно в настройках Apple ID.","es":"La suscripción se renueva automáticamente. Cancela en ajustes de Apple ID.","de":"Abonnement verlängert sich automatisch. Kündigung in Apple-ID-Einstellungen.","pl":"Subskrypcja odnawia się automatycznie. Anuluj w ustawieniach Apple ID."],
        "choose_plan": ["en":"Choose a plan to manage your finances","uk":"Вибери план для управління фінансами","ru":"Выбери план для управления финансами","es":"Elige un plan para gestionar tus finanzas","de":"Wähle einen Plan zur Finanzverwaltung","pl":"Wybierz plan do zarządzania finansami"],
        "best_choice": ["en":"BEST CHOICE","uk":"НАЙКРАЩИЙ ВИБІР","ru":"ЛУЧШИЙ ВЫБОР","es":"MEJOR OPCIÓN","de":"BESTE WAHL","pl":"NAJLEPSZY WYBÓR"],
        "per_month": ["en":"/ month","uk":"/ місяць","ru":"/ месяц","es":"/ mes","de":"/ Monat","pl":"/ miesiąc"],
        "parses_left": ["en":"left","uk":"залишилось","ru":"осталось","es":"restantes","de":"übrig","pl":"pozostało"],

        // MARK: Default categories
        "cat_food": ["en":"Food","uk":"Їжа","ru":"Еда","es":"Comida","de":"Essen","pl":"Jedzenie"],
        "cat_transport": ["en":"Transport","uk":"Транспорт","ru":"Транспорт","es":"Transporte","de":"Transport","pl":"Transport"],
        "cat_shopping": ["en":"Shopping","uk":"Покупки","ru":"Покупки","es":"Compras","de":"Einkaufen","pl":"Zakupy"],
        "cat_health": ["en":"Health","uk":"Здоров'я","ru":"Здоровье","es":"Salud","de":"Gesundheit","pl":"Zdrowie"],
        "cat_entertainment": ["en":"Entertainment","uk":"Розваги","ru":"Развлечения","es":"Entretenimiento","de":"Unterhaltung","pl":"Rozrywka"],
        "cat_education": ["en":"Education","uk":"Освіта","ru":"Образование","es":"Educación","de":"Bildung","pl":"Edukacja"],
        "cat_housing": ["en":"Housing","uk":"Житло","ru":"Жильё","es":"Vivienda","de":"Wohnen","pl":"Mieszkanie"],
        "cat_bills": ["en":"Bills","uk":"Рахунки","ru":"Счета","es":"Facturas","de":"Rechnungen","pl":"Rachunki"],
        "cat_travel": ["en":"Travel","uk":"Подорожі","ru":"Путешествия","es":"Viajes","de":"Reisen","pl":"Podróże"],
        "cat_subscriptions": ["en":"Subscriptions","uk":"Підписки","ru":"Подписки","es":"Suscripciones","de":"Abonnements","pl":"Subskrypcje"],
        "cat_salary": ["en":"Salary","uk":"Зарплата","ru":"Зарплата","es":"Salario","de":"Gehalt","pl":"Pensja"],
        "cat_freelance": ["en":"Freelance","uk":"Фріланс","ru":"Фриланс","es":"Freelance","de":"Freelance","pl":"Freelance"],
        "cat_other": ["en":"Other","uk":"Інше","ru":"Другое","es":"Otro","de":"Sonstiges","pl":"Inne"],

        // MARK: Notification
        "notif_title": ["en":"SumIt 💰","uk":"SumIt 💰","ru":"SumIt 💰","es":"SumIt 💰","de":"SumIt 💰","pl":"SumIt 💰"],
        "notif_body": ["en":"Don't forget to record expenses and income — stay on track!","uk":"Не забудь записати витрати та доходи — тримай фінанси під контролем!","ru":"Не забудь записать расходы и доходы — оставайся на верном пути!","es":"¡No olvides registrar gastos e ingresos — mantén el rumbo!","de":"Vergiss nicht Ausgaben und Einnahmen zu erfassen — bleib auf Kurs!","pl":"Nie zapomnij zapisać wydatków i przychodów — bądź na bieżąco!"],

        // MARK: Empty state examples
        "example_taxi": ["en":"500 UAH taxi","uk":"500 грн таксі","ru":"500 грн такси","es":"500 UAH taxi","de":"500 UAH Taxi","pl":"500 UAH taxi"],
        "example_coffee": ["en":"$20 coffee yesterday","uk":"$20 кава вчора","ru":"$20 кофе вчера","es":"$20 café ayer","de":"$20 Kaffee gestern","pl":"$20 kawa wczoraj"],
        "example_salary": ["en":"salary 45000 UAH","uk":"зарплата 45000 грн","ru":"зарплата 45000 грн","es":"salario 45000 UAH","de":"Gehalt 45000 UAH","pl":"pensja 45000 UAH"],
        "example_crypto": ["en":"100 USDC to Binance","uk":"100 USDC на Binance","ru":"100 USDC на Binance","es":"100 USDC a Binance","de":"100 USDC an Binance","pl":"100 USDC na Binance"],

        // MARK: Paywall features
        "feat_gpt_mini": ["en":"GPT-4o-mini parsing","uk":"GPT-4o-mini парсинг","ru":"GPT-4o-mini парсинг","es":"Análisis GPT-4o-mini","de":"GPT-4o-mini Parsing","pl":"Parsowanie GPT-4o-mini"],
        "feat_100_parses": ["en":"100 parses / month","uk":"100 парсингів / міс","ru":"100 парсингов / мес","es":"100 análisis / mes","de":"100 Parsings / Monat","pl":"100 parsowań / mies."],
        "feat_500_tx": ["en":"500 transactions","uk":"500 транзакцій","ru":"500 транзакций","es":"500 transacciones","de":"500 Transaktionen","pl":"500 transakcji"],
        "feat_basic_reports": ["en":"Basic reports","uk":"Базові звіти","ru":"Базовые отчёты","es":"Informes básicos","de":"Basisberichte","pl":"Podstawowe raporty"],
        "feat_sync": ["en":"Sync","uk":"Синхронізація","ru":"Синхронизация","es":"Sincronización","de":"Synchronisierung","pl":"Synchronizacja"],
        "feat_gpt_pro": ["en":"GPT-4o — more accurate, smarter","uk":"GPT-4o — точніше, розумніше","ru":"GPT-4o — точнее, умнее","es":"GPT-4o — más preciso","de":"GPT-4o — genauer, smarter","pl":"GPT-4o — dokładniejszy"],
        "feat_unlimited_parses": ["en":"Unlimited parses","uk":"Безлімітний парсинг","ru":"Безлимит парсингов","es":"Análisis ilimitados","de":"Unbegrenzte Parsings","pl":"Nieograniczone parsowanie"],
        "feat_unlimited_tx": ["en":"Unlimited transactions","uk":"Безлімітні транзакції","ru":"Безлимит транзакций","es":"Transacciones ilimitadas","de":"Unbegrenzte Transaktionen","pl":"Nieograniczone transakcje"],
        "feat_analytics": ["en":"Advanced analytics","uk":"Розширена аналітика","ru":"Расширенная аналитика","es":"Analítica avanzada","de":"Erweiterte Analysen","pl":"Zaawansowana analityka"],
        "feat_export": ["en":"Data export","uk":"Експорт даних","ru":"Экспорт данных","es":"Exportar datos","de":"Datenexport","pl":"Eksport danych"],
        "product_unavailable": ["en":"Product unavailable","uk":"Продукт недоступний","ru":"Продукт недоступен","es":"Producto no disponible","de":"Produkt nicht verfügbar","pl":"Produkt niedostępny"],
        "token_error": ["en":"Could not get token","uk":"Не вдалося отримати токен","ru":"Не удалось получить токен","es":"No se pudo obtener el token","de":"Token konnte nicht abgerufen werden","pl":"Nie udało się pobrać tokenu"],
        "period": ["en":"Period","uk":"Період","ru":"Период","es":"Período","de":"Zeitraum","pl":"Okres"],

        // MARK: Currencies
        "cur_usd": ["en":"US Dollar","uk":"Долар США","ru":"Доллар США","es":"Dólar estadounidense","de":"US-Dollar","pl":"Dolar amerykański"],
        "cur_eur": ["en":"Euro","uk":"Євро","ru":"Евро","es":"Euro","de":"Euro","pl":"Euro"],
        "cur_uah": ["en":"Hryvnia","uk":"Гривня","ru":"Гривна","es":"Grivna","de":"Hrywnja","pl":"Hrywna"],
        "cur_gbp": ["en":"British Pound","uk":"Фунт стерлінгів","ru":"Фунт стерлингов","es":"Libra esterlina","de":"Britisches Pfund","pl":"Funt szterling"],
        "cur_pln": ["en":"Zloty","uk":"Злотий","ru":"Злотый","es":"Zloty","de":"Zloty","pl":"Złoty"],
        "cur_czk": ["en":"Czech Koruna","uk":"Чеська крона","ru":"Чешская крона","es":"Corona checa","de":"Tschechische Krone","pl":"Korona czeska"],
        "cur_cad": ["en":"Canadian Dollar","uk":"Канадський долар","ru":"Канадский доллар","es":"Dólar canadiense","de":"Kanadischer Dollar","pl":"Dolar kanadyjski"],
        "cur_chf": ["en":"Swiss Franc","uk":"Швейцарський франк","ru":"Швейцарский франк","es":"Franco suizo","de":"Schweizer Franken","pl":"Frank szwajcarski"],
        "cur_rub": ["en":"Russian Ruble","uk":"Російський рубль","ru":"Российский рубль","es":"Rublo ruso","de":"Russischer Rubel","pl":"Rubel rosyjski"],
        "cur_kzt": ["en":"Kazakh Tenge","uk":"Казахстанський тенге","ru":"Казахстанский тенге","es":"Tenge kazajo","de":"Kasachischer Tenge","pl":"Tenge kazachskie"],
        "cur_jpy": ["en":"Japanese Yen","uk":"Японська єна","ru":"Японская иена","es":"Yen japonés","de":"Japanischer Yen","pl":"Jen japoński"],
        "cur_usdc": ["en":"USD Coin","uk":"USD Coin","ru":"USD Coin","es":"USD Coin","de":"USD Coin","pl":"USD Coin"],
        "cur_usdt": ["en":"Tether","uk":"Tether","ru":"Tether","es":"Tether","de":"Tether","pl":"Tether"],
        "cur_btc": ["en":"Bitcoin","uk":"Біткойн","ru":"Биткойн","es":"Bitcoin","de":"Bitcoin","pl":"Bitcoin"],
        "cur_eth": ["en":"Ethereum","uk":"Ethereum","ru":"Ethereum","es":"Ethereum","de":"Ethereum","pl":"Ethereum"],

        // MARK: PIN brute-force lockout
        "pin_locked_min": ["en":"Too many tries — wait %dm %02ds","uk":"Забагато спроб — зачекай %dхв %02dс","ru":"Слишком много попыток — подожди %dм %02dс","es":"Demasiados intentos — espera %dm %02ds","de":"Zu viele Versuche — warte %dm %02ds","pl":"Za dużo prób — czekaj %dm %02ds"],
        "pin_locked_sec": ["en":"Too many tries — wait %ds","uk":"Забагато спроб — зачекай %dс","ru":"Слишком много попыток — подожди %dс","es":"Demasiados intentos — espera %ds","de":"Zu viele Versuche — warte %ds","pl":"Za dużo prób — czekaj %ds"],

        // MARK: Auth errors
        "auth_invalid_token": ["en":"Invalid sign-in token","uk":"Недійсний токен входу","ru":"Недействительный токен входа","es":"Token de inicio inválido","de":"Ungültiges Anmelde-Token","pl":"Nieprawidłowy token logowania"],
        "auth_invalid_url": ["en":"Service unavailable","uk":"Сервіс недоступний","ru":"Сервис недоступен","es":"Servicio no disponible","de":"Dienst nicht verfügbar","pl":"Usługa niedostępna"],
        "auth_network_error": ["en":"Network error — check connection","uk":"Помилка мережі — перевір з'єднання","ru":"Ошибка сети — проверь соединение","es":"Error de red — comprueba la conexión","de":"Netzwerkfehler — Verbindung prüfen","pl":"Błąd sieci — sprawdź połączenie"],
        "auth_server_error": ["en":"Server error — please retry","uk":"Помилка сервера — спробуй ще раз","ru":"Ошибка сервера — попробуй снова","es":"Error del servidor — reintenta","de":"Serverfehler — bitte erneut versuchen","pl":"Błąd serwera — spróbuj ponownie"],
        "auth_invalid_response": ["en":"Unexpected server response","uk":"Несподівана відповідь сервера","ru":"Неожиданный ответ сервера","es":"Respuesta inesperada del servidor","de":"Unerwartete Serverantwort","pl":"Nieoczekiwana odpowiedź serwera"],
        "auth_required": ["en":"Please sign in first","uk":"Спочатку увійди","ru":"Сначала войди в аккаунт","es":"Inicia sesión primero","de":"Bitte zuerst anmelden","pl":"Najpierw zaloguj się"],

        // MARK: Backend errors
        "backend_bad_url": ["en":"Service unavailable","uk":"Сервіс недоступний","ru":"Сервис недоступен","es":"Servicio no disponible","de":"Dienst nicht verfügbar","pl":"Usługa niedostępna"],
        "backend_server_error": ["en":"Server error (%d)","uk":"Помилка сервера (%d)","ru":"Ошибка сервера (%d)","es":"Error del servidor (%d)","de":"Serverfehler (%d)","pl":"Błąd serwera (%d)"],
        "backend_parse_failed": ["en":"Could not parse — try rephrasing","uk":"Не вдалося розпізнати — спробуй інакше","ru":"Не удалось распознать — попробуй иначе","es":"No se pudo analizar — reformula","de":"Konnte nicht erkennen — anders formulieren","pl":"Nie rozpoznano — spróbuj inaczej"],
        "backend_no_amount": ["en":"Couldn't find an amount","uk":"Не знайшов суми","ru":"Не нашёл сумму","es":"No se encontró un monto","de":"Betrag nicht gefunden","pl":"Nie znaleziono kwoty"],
        "backend_unknown_currency": ["en":"Unsupported currency: %@","uk":"Валюта не підтримується: %@","ru":"Валюта не поддерживается: %@","es":"Moneda no soportada: %@","de":"Währung nicht unterstützt: %@","pl":"Waluta nieobsługiwana: %@"],
        "backend_image_too_large": ["en":"Image is too large","uk":"Зображення завелике","ru":"Изображение слишком большое","es":"La imagen es demasiado grande","de":"Bild ist zu groß","pl":"Obraz jest za duży"],

        // MARK: StoreKit
        "purchase_pending": ["en":"Purchase pending approval","uk":"Очікує підтвердження покупки","ru":"Покупка ожидает подтверждения","es":"Compra pendiente de aprobación","de":"Kauf wartet auf Genehmigung","pl":"Zakup oczekuje na zatwierdzenie"],
        "restore_failed": ["en":"Could not restore purchases","uk":"Не вдалося відновити покупки","ru":"Не удалось восстановить покупки","es":"No se pudieron restaurar las compras","de":"Käufe konnten nicht wiederhergestellt werden","pl":"Nie udało się przywrócić zakupów"],

        // MARK: Chat subscription gating
        "chat_subscription_required": ["en":"Subscription required to use AI parsing — tap to upgrade.","uk":"Потрібна підписка для AI-розпізнавання — натисни щоб оформити.","ru":"Нужна подписка для AI-распознавания — нажми чтобы оформить.","es":"Se requiere suscripción para usar IA — toca para suscribirte.","de":"Abo erforderlich für KI — tippe zum Upgrade.","pl":"Wymagana subskrypcja AI — kliknij, aby przejść."],
        "chat_limit_reached": ["en":"Monthly parse limit reached — upgrade to Pro for unlimited.","uk":"Місячний ліміт вичерпано — Pro дає безліміт.","ru":"Месячный лимит исчерпан — Pro даёт безлимит.","es":"Límite mensual alcanzado — pasa a Pro para ilimitado.","de":"Monatliches Limit erreicht — Pro für unbegrenzt.","pl":"Miesięczny limit wyczerpany — Pro daje brak limitu."],

        // MARK: Parses-left UI string
        "parses_left_month": ["en":"%d parses left this month","uk":"%d розпізнавань цього місяця","ru":"%d распознаваний в этом месяце","es":"%d análisis este mes","de":"%d Erkennungen diesen Monat","pl":"%d rozpoznań w tym miesiącu"],

        // MARK: Sign-out flow
        "sign_out_wipe_q": ["en":"Sign out and wipe data?","uk":"Вийти та очистити дані?","ru":"Выйти и очистить данные?","es":"¿Cerrar sesión y borrar datos?","de":"Abmelden und Daten löschen?","pl":"Wylogować i wyczyścić dane?"],
        "sign_out_wipe_msg": ["en":"Choose whether to keep your transactions on this device or remove them on sign-out.","uk":"Обери, чи зберегти транзакції на цьому пристрої, чи видалити при виході.","ru":"Выбери: оставить транзакции на устройстве или удалить при выходе.","es":"Decide si conservar las transacciones en este dispositivo o eliminarlas al cerrar sesión.","de":"Entscheide, ob die Transaktionen auf dem Gerät bleiben oder beim Abmelden gelöscht werden.","pl":"Zdecyduj, czy zachować transakcje na urządzeniu, czy je usunąć."],
        "sign_out_keep": ["en":"Keep on device","uk":"Залишити на пристрої","ru":"Оставить на устройстве","es":"Conservar en el dispositivo","de":"Auf Gerät behalten","pl":"Zachowaj na urządzeniu"],
        "sign_out_wipe": ["en":"Sign out & wipe","uk":"Вийти і видалити","ru":"Выйти и удалить","es":"Cerrar sesión y borrar","de":"Abmelden und löschen","pl":"Wyloguj i usuń"],

        // MARK: Delete transaction confirmation
        "delete_tx_q": ["en":"Delete this message?","uk":"Видалити повідомлення?","ru":"Удалить это сообщение?","es":"¿Eliminar este mensaje?","de":"Diese Nachricht löschen?","pl":"Usunąć tę wiadomość?"],
        "delete_tx_msg": ["en":"This will also remove the saved transaction and revert your wallet balance.","uk":"Транзакцію також буде видалено, баланс гаманця повернеться.","ru":"Также удалится транзакция, баланс кошелька вернётся.","es":"Esto eliminará la transacción y revertirá el saldo de la cartera.","de":"Die Transaktion wird entfernt und der Walletsaldo zurückgesetzt.","pl":"Spowoduje to usunięcie transakcji i przywrócenie salda portfela."],
        "delete_msg_only": ["en":"Delete message only","uk":"Видалити лише повідомлення","ru":"Удалить только сообщение","es":"Eliminar solo el mensaje","de":"Nur Nachricht löschen","pl":"Usuń tylko wiadomość"],
        "delete_tx_yes": ["en":"Delete both","uk":"Видалити обидва","ru":"Удалить оба","es":"Eliminar ambos","de":"Beide löschen","pl":"Usuń oba"],

        // MARK: Misc
        "parses_left_chip": ["en":"%d left","uk":"%d залишилось","ru":"%d осталось","es":"%d restantes","de":"%d übrig","pl":"%d pozostało"],
        "upgrade_to_pro_cta": ["en":"Upgrade to Pro","uk":"Перейти на Pro","ru":"Перейти на Pro","es":"Actualizar a Pro","de":"Auf Pro upgraden","pl":"Przejdź na Pro"],
        "subscribe_subtitle": ["en":"Basic or Pro — pick your plan","uk":"Basic або Pro — обери план","ru":"Basic или Pro — выбери план","es":"Basic o Pro — elige tu plan","de":"Basic oder Pro — Plan wählen","pl":"Basic lub Pro — wybierz plan"],

        // MARK: Home (Figma redesign)
        "home_greeting_named": ["en":"Hey %@, what are you looking for today?","uk":"Привіт, %@! Що шукаєш сьогодні?","ru":"Привет, %@! Что ищешь сегодня?","es":"Hola %@, ¿qué buscas hoy?","de":"Hallo %@, was suchst du heute?","pl":"Hej %@, czego dziś szukasz?"],
        "home_greeting_anon": ["en":"Hey, what are you looking for today?","uk":"Привіт! Що шукаєш сьогодні?","ru":"Привет! Что ищешь сегодня?","es":"Hola, ¿qué buscas hoy?","de":"Hallo, was suchst du heute?","pl":"Hej, czego dziś szukasz?"],
        "home_total_balance": ["en":"Total Balance:","uk":"Загальний баланс:","ru":"Общий баланс:","es":"Saldo total:","de":"Gesamtsaldo:","pl":"Saldo całkowite:"],
        "home_composer_placeholder": ["en":"Type any expense...","uk":"Введи будь-яку витрату...","ru":"Введи любую трату...","es":"Escribe cualquier gasto...","de":"Beliebige Ausgabe eingeben...","pl":"Wpisz dowolny wydatek..."],
        "home_composer_footer": ["en":"Just type any expense — I'll handle the rest","uk":"Просто введи витрату — решта на мені","ru":"Просто введи трату — остальное за мной","es":"Solo escribe el gasto — yo me encargo","de":"Tippe einfach Ausgabe — ich mache den Rest","pl":"Wpisz wydatek — resztą zajmę się ja"],

        // MARK: Home suggestion chips
        "home_chip_coffee": ["en":"☕️ Coffee $4.50","uk":"☕️ Кава $4.50","ru":"☕️ Кофе $4.50","es":"☕️ Café $4.50","de":"☕️ Kaffee $4.50","pl":"☕️ Kawa $4.50"],
        "home_chip_lunch_combo": ["en":"🥗 Lunch $12 and coffee $3","uk":"🥗 Обід $12 і кава $3","ru":"🥗 Обед $12 и кофе $3","es":"🥗 Comida $12 y café $3","de":"🥗 Mittag $12 und Kaffee $3","pl":"🥗 Lunch $12 i kawa $3"],
        "home_chip_uber": ["en":"🚕 Uber $18","uk":"🚕 Uber $18","ru":"🚕 Uber $18","es":"🚕 Uber $18","de":"🚕 Uber $18","pl":"🚕 Uber $18"],
        "home_chip_groceries": ["en":"🛒 Groceries $67","uk":"🛒 Продукти $67","ru":"🛒 Продукты $67","es":"🛒 Compras $67","de":"🛒 Lebensmittel $67","pl":"🛒 Zakupy $67"],
        "home_chip_gym": ["en":"💪 Gym $40","uk":"💪 Спортзал $40","ru":"💪 Спортзал $40","es":"💪 Gimnasio $40","de":"💪 Fitness $40","pl":"💪 Siłownia $40"],

        // MARK: Confirmation card (redesign)
        "scan": ["en":"Scan","uk":"Сканувати","ru":"Сканировать","es":"Escanear","de":"Scannen","pl":"Skanuj"],
        "tx_all_correct": ["en":"All correct? Tap to edit if needed","uk":"Все вірно? Натисни щоб редагувати","ru":"Всё верно? Нажми чтобы редактировать","es":"¿Todo correcto? Toca para editar","de":"Alles korrekt? Tippe zum Bearbeiten","pl":"Wszystko ok? Stuknij, by edytować"],
        "add_wallet_to_save": ["en":"Add Wallet to Save","uk":"Додай гаманець, щоб зберегти","ru":"Добавь кошелёк, чтобы сохранить","es":"Añade cartera para guardar","de":"Wallet hinzufügen zum Speichern","pl":"Dodaj portfel, aby zapisać"],

        // MARK: Detail / Edit
        "cancel_editing": ["en":"Cancel editing","uk":"Скасувати редагування","ru":"Отменить редактирование","es":"Cancelar edición","de":"Bearbeiten abbrechen","pl":"Anuluj edycję"],
        "share": ["en":"Share","uk":"Поділитися","ru":"Поделиться","es":"Compartir","de":"Teilen","pl":"Udostępnij"],

        // MARK: Quick summary sheet
        "wallet_manage_short": ["en":"Manage","uk":"Керувати","ru":"Управление","es":"Gestionar","de":"Verwalten","pl":"Zarządzaj"],
        "savings": ["en":"Savings","uk":"Заощадження","ru":"Сбережения","es":"Ahorros","de":"Ersparnisse","pl":"Oszczędności"],
        "ai_powered_disclaimer": ["en":"AI-powered · Always double-check important entries","uk":"На основі AI · Перевіряй важливі записи","ru":"На основе AI · Проверяй важные записи","es":"Con IA · Revisa siempre los registros importantes","de":"KI-gestützt · Wichtige Einträge stets prüfen","pl":"AI · Zawsze weryfikuj ważne wpisy"],

        // MARK: Batch segmentation (P4)
        "chat_pending_batch_blocked": ["en":"Confirm or cancel the pending entries first — they won't be replaced automatically.","uk":"Спершу підтверди або скасуй незавершені записи — вони не зникнуть самі.","ru":"Сначала подтверди или отмени незавершённые записи — сами они не заменятся.","es":"Primero confirma o cancela las entradas pendientes: no se reemplazarán solas.","de":"Bestätige oder verwirf zuerst die offenen Einträge — sie werden nicht automatisch ersetzt.","pl":"Najpierw zatwierdź lub anuluj oczekujące wpisy — nie zostaną zastąpione automatycznie."],
        "chat_segments_failed": ["en":"%d entries could not be read. Their text is kept below.","uk":"Не вдалося розпізнати %d записів. Їхній текст збережено нижче.","ru":"Не удалось распознать %d записей. Их текст сохранён ниже.","es":"No se pudieron leer %d entradas. Su texto se conserva abajo.","de":"%d Einträge konnten nicht gelesen werden. Ihr Text steht unten.","pl":"Nie udało się odczytać %d wpisów. Ich tekst zachowano poniżej."],
        "chat_segment_failed_item": ["en":"Entry %d not recognized: %@","uk":"Запис %d не розпізнано: %@","ru":"Запись %d не распознана: %@","es":"Entrada %d no reconocida: %@","de":"Eintrag %d nicht erkannt: %@","pl":"Wpis %d nierozpoznany: %@"],
        "chat_too_many_segments": ["en":"That looks like %d separate entries; the limit is %d. Send them in smaller groups.","uk":"Це схоже на %d окремих записів, а ліміт — %d. Надішли меншими групами.","ru":"Похоже на %d отдельных записей, а лимит — %d. Отправь меньшими группами.","es":"Parecen %d entradas separadas; el límite es %d. Envíalas en grupos más pequeños.","de":"Das sind offenbar %d getrennte Einträge; das Limit ist %d. Bitte in kleineren Gruppen senden.","pl":"To wygląda na %d osobnych wpisów, a limit to %d. Wyślij mniejszymi grupami."],
        "chat_segment_too_long": ["en":"Entry %d is %d characters; the limit is %d. Nothing was sent or shortened.","uk":"Запис %d має %d символів, ліміт — %d. Нічого не надіслано й не скорочено.","ru":"Запись %d содержит %d символов, лимит — %d. Ничего не отправлено и не урезано.","es":"La entrada %d tiene %d caracteres; el límite es %d. No se envió ni se acortó nada.","de":"Eintrag %d hat %d Zeichen; das Limit ist %d. Es wurde nichts gesendet oder gekürzt.","pl":"Wpis %d ma %d znaków, limit to %d. Nic nie wysłano ani nie skrócono."],
        "chat_retry_failed": ["en":"Retry","uk":"Повторити","ru":"Повторить","es":"Reintentar","de":"Erneut","pl":"Ponów"],
        "chat_failed_banner": ["en":"%d entries not recognized","uk":"%d записів не розпізнано","ru":"%d записей не распознано","es":"%d entradas no reconocidas","de":"%d Einträge nicht erkannt","pl":"%d wpisów nierozpoznanych"],
        "chat_discard_failed": ["en":"Dismiss","uk":"Прибрати","ru":"Убрать","es":"Descartar","de":"Verwerfen","pl":"Odrzuć"],

        "chat_save_failed": ["en":"Couldn't save that entry on this device. Nothing was lost — try again.","uk":"Не вдалося зберегти запис на пристрої. Нічого не втрачено — спробуй ще раз.","ru":"Не удалось сохранить запись на устройстве. Ничего не потеряно — попробуй ещё раз.","es":"No se pudo guardar la entrada en este dispositivo. No se perdió nada: inténtalo de nuevo.","de":"Der Eintrag konnte auf diesem Gerät nicht gespeichert werden. Nichts ist verloren — bitte erneut versuchen.","pl":"Nie udało się zapisać wpisu na urządzeniu. Nic nie przepadło — spróbuj ponownie."],


        // MARK: Account scope and conflict resolution (P1/P6)
        "sync_issues_title": ["en":"Needs your decision","uk":"Потрібне твоє рішення","ru":"Нужно твоё решение","es":"Necesita tu decisión","de":"Deine Entscheidung nötig","pl":"Wymaga twojej decyzji"],
        "sync_issues_open": ["en":"Waiting for you","uk":"Чекають на тебе","ru":"Ждут тебя","es":"Esperando tu decisión","de":"Warten auf dich","pl":"Czekają na ciebie"],
        "sync_issues_resolved": ["en":"Decided","uk":"Вирішено","ru":"Решено","es":"Decididas","de":"Entschieden","pl":"Rozstrzygnięte"],
        "sync_issues_empty": ["en":"Nothing needs your decision right now.","uk":"Зараз нічого вирішувати не треба.","ru":"Сейчас решать нечего.","es":"Ahora mismo no hay nada que decidir.","de":"Im Moment ist nichts zu entscheiden.","pl":"Na razie nie ma nic do rozstrzygnięcia."],
        "conflict_title": ["en":"Two versions of one record","uk":"Дві версії одного запису","ru":"Две версии одной записи","es":"Dos versiones de un registro","de":"Zwei Versionen eines Eintrags","pl":"Dwie wersje jednego wpisu"],
        "conflict_explain": ["en":"This record was changed on another device before your change was sent. Choose which version to keep — nothing is combined automatically.","uk":"Цей запис змінили на іншому пристрої раніше, ніж надіслали твою зміну. Обери, яку версію лишити — нічого не об'єднується автоматично.","ru":"Эту запись изменили на другом устройстве раньше, чем отправилась твоя правка. Выбери, какую версию оставить — ничего не объединяется автоматически.","es":"Este registro se cambió en otro dispositivo antes de enviarse tu cambio. Elige qué versión conservar: nada se combina automáticamente.","de":"Dieser Eintrag wurde auf einem anderen Gerät geändert, bevor deine Änderung gesendet wurde. Wähle die Version, die bleiben soll — nichts wird automatisch zusammengeführt.","pl":"Ten wpis zmieniono na innym urządzeniu, zanim wysłano twoją zmianę. Wybierz, którą wersję zachować — nic nie jest łączone automatycznie."],
        "conflict_your_version": ["en":"Your version","uk":"Твоя версія","ru":"Твоя версия","es":"Tu versión","de":"Deine Version","pl":"Twoja wersja"],
        "conflict_server_version": ["en":"Version on the server","uk":"Версія на сервері","ru":"Версия на сервере","es":"Versión en el servidor","de":"Version auf dem Server","pl":"Wersja na serwerze"],
        "conflict_use_server": ["en":"Keep the server's version","uk":"Лишити версію сервера","ru":"Оставить версию сервера","es":"Conservar la versión del servidor","de":"Server-Version behalten","pl":"Zachowaj wersję z serwera"],
        "conflict_keep_local": ["en":"Keep my version","uk":"Лишити мою версію","ru":"Оставить мою версию","es":"Conservar mi versión","de":"Meine Version behalten","pl":"Zachowaj moją wersję"],
        "conflict_save_as_new": ["en":"Save mine as a new record","uk":"Зберегти мою як новий запис","ru":"Сохранить мою как новую запись","es":"Guardar la mía como registro nuevo","de":"Meine als neuen Eintrag speichern","pl":"Zapisz moją jako nowy wpis"],
        "conflict_dismiss": ["en":"Remove from this list","uk":"Прибрати зі списку","ru":"Убрать из списка","es":"Quitar de la lista","de":"Aus der Liste entfernen","pl":"Usuń z listy"],
        "conflict_no_merge_note": ["en":"Amounts are never merged. One whole version is kept.","uk":"Суми ніколи не змішуються. Лишається одна цілісна версія.","ru":"Суммы никогда не смешиваются. Остаётся одна целая версия.","es":"Los importes nunca se fusionan. Se conserva una versión completa.","de":"Beträge werden nie zusammengeführt. Es bleibt eine vollständige Version.","pl":"Kwoty nigdy nie są łączone. Zostaje jedna cała wersja."],
        "conflict_resolved_note": ["en":"The version you didn't choose is still stored here until you remove the entry.","uk":"Версія, яку ти не обрав, зберігається тут, доки не прибереш запис.","ru":"Версия, которую ты не выбрал, хранится здесь, пока не уберёшь запись.","es":"La versión que no elegiste sigue guardada aquí hasta que quites la entrada.","de":"Die nicht gewählte Version bleibt hier gespeichert, bis du den Eintrag entfernst.","pl":"Wersja, której nie wybrano, jest tu przechowywana, dopóki nie usuniesz wpisu."],
        "conflict_server_deleted": ["en":"Deleted on the server","uk":"Видалено на сервері","ru":"Удалено на сервере","es":"Eliminado en el servidor","de":"Auf dem Server gelöscht","pl":"Usunięte na serwerze"],
        "conflict_field_amount": ["en":"Amount","uk":"Сума","ru":"Сумма","es":"Importe","de":"Betrag","pl":"Kwota"],
        "conflict_field_wallet": ["en":"Wallet","uk":"Гаманець","ru":"Кошелёк","es":"Cartera","de":"Konto","pl":"Portfel"],
        "conflict_field_merchant": ["en":"Place","uk":"Місце","ru":"Место","es":"Lugar","de":"Ort","pl":"Miejsce"],
        "conflict_field_date": ["en":"Date","uk":"Дата","ru":"Дата","es":"Fecha","de":"Datum","pl":"Data"],
        "conflict_field_name": ["en":"Name","uk":"Назва","ru":"Название","es":"Nombre","de":"Name","pl":"Nazwa"],
        "conflict_field_revision": ["en":"Server revision","uk":"Ревізія сервера","ru":"Ревизия сервера","es":"Revisión del servidor","de":"Server-Revision","pl":"Rewizja serwera"],
        "conflict_field_recorded": ["en":"Noticed","uk":"Помічено","ru":"Замечено","es":"Detectado","de":"Bemerkt","pl":"Zauważono"],
        "conflict_unsent": ["en":"not sent yet","uk":"ще не надіслано","ru":"ещё не отправлено","es":"aún sin enviar","de":"noch nicht gesendet","pl":"jeszcze nie wysłano"],
        "conflict_no_wallet": ["en":"None","uk":"Немає","ru":"Нет","es":"Ninguna","de":"Keines","pl":"Brak"],
        "conflict_unknown_wallet": ["en":"A wallet not on this device","uk":"Гаманець, якого немає на пристрої","ru":"Кошелёк, которого нет на устройстве","es":"Una cartera que no está en este dispositivo","de":"Ein Konto, das nicht auf diesem Gerät ist","pl":"Portfel, którego nie ma na tym urządzeniu"],
        "conflict_action_failed": ["en":"That decision couldn't be applied. Nothing was changed.","uk":"Не вдалося застосувати рішення. Нічого не змінено.","ru":"Не удалось применить решение. Ничего не изменено.","es":"No se pudo aplicar la decisión. No se cambió nada.","de":"Die Entscheidung konnte nicht angewendet werden. Nichts wurde geändert.","pl":"Nie udało się zastosować decyzji. Nic nie zmieniono."],
        "sync_issue_legacy_title": ["en":"Older data needs attention","uk":"Старі дані потребують уваги","ru":"Старые данные требуют внимания","es":"Datos antiguos requieren atención","de":"Ältere Daten brauchen Aufmerksamkeit","pl":"Starsze dane wymagają uwagi"],
        "sync_issue_invalid_title": ["en":"A record from the server was refused","uk":"Запис із сервера відхилено","ru":"Запись с сервера отклонена","es":"Se rechazó un registro del servidor","de":"Ein Datensatz vom Server wurde abgelehnt","pl":"Odrzucono wpis z serwera"],
        "sync_issue_missing_wallet": ["en":"This entry points to a wallet that hasn't arrived on this device yet. The entry is kept as it is.","uk":"Цей запис посилається на гаманець, який ще не з'явився на пристрої. Запис збережено без змін.","ru":"Эта запись ссылается на кошелёк, который ещё не появился на устройстве. Запись сохранена как есть.","es":"Esta entrada apunta a una cartera que aún no ha llegado a este dispositivo. La entrada se conserva tal cual.","de":"Dieser Eintrag verweist auf ein Konto, das noch nicht auf diesem Gerät ist. Der Eintrag bleibt unverändert.","pl":"Ten wpis wskazuje portfel, którego jeszcze nie ma na tym urządzeniu. Wpis pozostaje bez zmian."],
        "sync_issue_awaiting_import": ["en":"Entries recorded before you signed in are still on this device. They were not added to this account automatically.","uk":"Записи, зроблені до входу, лишаються на пристрої. Їх не додано до цього акаунта автоматично.","ru":"Записи, сделанные до входа, остались на устройстве. Они не добавлены в этот аккаунт автоматически.","es":"Las entradas creadas antes de iniciar sesión siguen en este dispositivo. No se añadieron a esta cuenta automáticamente.","de":"Einträge von vor der Anmeldung liegen weiterhin auf dem Gerät. Sie wurden diesem Konto nicht automatisch hinzugefügt.","pl":"Wpisy sprzed logowania pozostają na urządzeniu. Nie dodano ich automatycznie do tego konta."],
        "sync_issue_generic": ["en":"Something needs a decision before it can continue.","uk":"Щось потребує рішення, щоб рухатися далі.","ru":"Что-то требует решения, чтобы продолжить.","es":"Algo necesita una decisión para poder continuar.","de":"Etwas braucht eine Entscheidung, um fortzufahren.","pl":"Coś wymaga decyzji, aby kontynuować."],
        "sync_issues_row": ["en":"Sync decisions","uk":"Рішення щодо синхронізації","ru":"Решения по синхронизации","es":"Decisiones de sincronización","de":"Sync-Entscheidungen","pl":"Decyzje synchronizacji"],


        // MARK: Exact write path and editors (P2/P3/P4/P5)
        "err_generic": ["en":"That couldn't be saved. Nothing was changed.","uk":"Не вдалося зберегти. Нічого не змінено.","ru":"Не удалось сохранить. Ничего не изменено.","es":"No se pudo guardar. No se cambió nada.","de":"Konnte nicht gespeichert werden. Nichts wurde geändert.","pl":"Nie udało się zapisać. Nic nie zmieniono."],
        "err_invalid_amount": ["en":"That isn't a number this app can record exactly.","uk":"Це не число, яке застосунок може записати точно.","ru":"Это не число, которое приложение может записать точно.","es":"Eso no es un número que la app pueda registrar con exactitud.","de":"Das ist keine Zahl, die exakt erfasst werden kann.","pl":"To nie jest liczba, którą można zapisać dokładnie."],
        "err_non_finite_amount": ["en":"That amount isn't a finite number.","uk":"Ця сума не є скінченним числом.","ru":"Эта сумма не является конечным числом.","es":"Ese importe no es un número finito.","de":"Dieser Betrag ist keine endliche Zahl.","pl":"Ta kwota nie jest liczbą skończoną."],
        "err_amount_out_of_range": ["en":"That amount is too large to record.","uk":"Ця сума завелика для запису.","ru":"Эта сумма слишком велика для записи.","es":"Ese importe es demasiado grande para registrarlo.","de":"Dieser Betrag ist zu groß zum Erfassen.","pl":"Ta kwota jest zbyt duża, aby ją zapisać."],
        "err_excess_precision": ["en":"That amount has more decimal places than this currency uses.","uk":"У сумі більше знаків після коми, ніж має ця валюта.","ru":"В сумме больше знаков после запятой, чем есть у этой валюты.","es":"Ese importe tiene más decimales de los que usa esta moneda.","de":"Der Betrag hat mehr Nachkommastellen, als diese Währung nutzt.","pl":"Kwota ma więcej miejsc po przecinku, niż używa ta waluta."],
        "err_arithmetic_failure": ["en":"That amount couldn't be calculated exactly.","uk":"Цю суму не вдалося обчислити точно.","ru":"Эту сумму не удалось вычислить точно.","es":"Ese importe no se pudo calcular con exactitud.","de":"Dieser Betrag konnte nicht exakt berechnet werden.","pl":"Tej kwoty nie udało się obliczyć dokładnie."],
        "err_unsupported_currency": ["en":"That currency isn't supported.","uk":"Ця валюта не підтримується.","ru":"Эта валюта не поддерживается.","es":"Esa moneda no es compatible.","de":"Diese Währung wird nicht unterstützt.","pl":"Ta waluta nie jest obsługiwana."],
        "err_unknown_wallet": ["en":"That wallet no longer exists.","uk":"Такого гаманця вже немає.","ru":"Такого кошелька больше нет.","es":"Esa cartera ya no existe.","de":"Dieses Konto existiert nicht mehr.","pl":"Ten portfel już nie istnieje."],
        "err_archived_wallet": ["en":"That wallet is archived. Its history is kept, but new entries can't use it.","uk":"Цей гаманець в архіві. Історія лишається, але нові записи в нього не можна.","ru":"Этот кошелёк в архиве. История сохраняется, но новые записи в него нельзя.","es":"Esa cartera está archivada. Su historial se conserva, pero no admite entradas nuevas.","de":"Dieses Konto ist archiviert. Die Historie bleibt, neue Einträge sind nicht möglich.","pl":"Ten portfel jest zarchiwizowany. Historia zostaje, ale nowe wpisy są niemożliwe."],
        "err_transfer_to_same_wallet": ["en":"A transfer needs two different wallets.","uk":"Переказ потребує двох різних гаманців.","ru":"Перевод требует двух разных кошельков.","es":"Una transferencia necesita dos carteras distintas.","de":"Eine Übertragung braucht zwei verschiedene Konten.","pl":"Przelew wymaga dwóch różnych portfeli."],
        "err_incomplete_transfer": ["en":"Choose both wallets and both amounts for a transfer.","uk":"Обери обидва гаманці та обидві суми для переказу.","ru":"Выбери оба кошелька и обе суммы для перевода.","es":"Elige ambas carteras y ambos importes para la transferencia.","de":"Wähle beide Konten und beide Beträge für die Übertragung.","pl":"Wybierz oba portfele i obie kwoty przelewu."],
        "err_non_positive_amount": ["en":"That amount has to be greater than zero.","uk":"Ця сума має бути більшою за нуль.","ru":"Эта сумма должна быть больше нуля.","es":"Ese importe tiene que ser mayor que cero.","de":"Dieser Betrag muss größer als null sein.","pl":"Ta kwota musi być większa od zera."],
        "err_destination_on_non_transfer": ["en":"Only a transfer has a destination wallet.","uk":"Гаманець призначення є лише в переказу.","ru":"Кошелёк назначения есть только у перевода.","es":"Solo una transferencia tiene cartera de destino.","de":"Nur eine Übertragung hat ein Zielkonto.","pl":"Tylko przelew ma portfel docelowy."],
        "err_wallet_amount_mismatch": ["en":"Enter the exact amount that leaves the wallet.","uk":"Вкажи точну суму, що виходить із гаманця.","ru":"Укажи точную сумму, которая уходит из кошелька.","es":"Introduce el importe exacto que sale de la cartera.","de":"Gib den genauen Betrag an, der das Konto verlässt.","pl":"Podaj dokładną kwotę, która wychodzi z portfela."],
        "err_same_currency_effect_mismatch": ["en":"In the same currency the wallet amount has to match the amount.","uk":"У тій самій валюті сума гаманця має збігатися із сумою.","ru":"В той же валюте сумма кошелька должна совпадать с суммой.","es":"En la misma moneda el importe de la cartera debe coincidir con el importe.","de":"In derselben Währung muss der Kontobetrag dem Betrag entsprechen.","pl":"W tej samej walucie kwota portfela musi być równa kwocie."],
        "err_unequal_same_currency_legs": ["en":"Between wallets of one currency both amounts have to be equal. Record a fee as its own entry.","uk":"Між гаманцями однієї валюти обидві суми мають бути рівні. Комісію запиши окремо.","ru":"Между кошельками одной валюты обе суммы должны быть равны. Комиссию запиши отдельно.","es":"Entre carteras de una misma moneda ambos importes deben ser iguales. Registra la comisión aparte.","de":"Zwischen Konten einer Währung müssen beide Beträge gleich sein. Erfasse eine Gebühr separat.","pl":"Między portfelami jednej waluty obie kwoty muszą być równe. Prowizję zapisz osobno."],
        "err_transfer_currency_mismatch": ["en":"The amount has to be in the source wallet's currency.","uk":"Сума має бути у валюті гаманця-джерела.","ru":"Сумма должна быть в валюте кошелька-источника.","es":"El importe debe estar en la moneda de la cartera de origen.","de":"Der Betrag muss in der Währung des Quellkontos sein.","pl":"Kwota musi być w walucie portfela źródłowego."],
        "err_wrong_scope": ["en":"That belongs to a different account.","uk":"Це належить іншому акаунту.","ru":"Это принадлежит другому аккаунту.","es":"Eso pertenece a otra cuenta.","de":"Das gehört zu einem anderen Konto.","pl":"To należy do innego konta."],
        "err_storage_unavailable": ["en":"Your data isn't open yet. Nothing was saved.","uk":"Дані ще не відкриті. Нічого не збережено.","ru":"Данные ещё не открыты. Ничего не сохранено.","es":"Tus datos aún no están abiertos. No se guardó nada.","de":"Deine Daten sind noch nicht geöffnet. Nichts wurde gespeichert.","pl":"Dane nie są jeszcze otwarte. Nic nie zapisano."],
        "err_save_failed": ["en":"Couldn't save on this device. Nothing was lost — try again.","uk":"Не вдалося зберегти на пристрої. Нічого не втрачено — спробуй ще раз.","ru":"Не удалось сохранить на устройстве. Ничего не потеряно — попробуй ещё раз.","es":"No se pudo guardar en este dispositivo. No se perdió nada: inténtalo de nuevo.","de":"Konnte auf diesem Gerät nicht gespeichert werden. Nichts ist verloren — erneut versuchen.","pl":"Nie udało się zapisać na urządzeniu. Nic nie przepadło — spróbuj ponownie."],
        "err_missing_entity": ["en":"That entry no longer exists.","uk":"Цього запису вже немає.","ru":"Этой записи больше нет.","es":"Esa entrada ya no existe.","de":"Dieser Eintrag existiert nicht mehr.","pl":"Ten wpis już nie istnieje."],
        "err_duplicate_entity": ["en":"That entry has already been saved.","uk":"Цей запис уже збережено.","ru":"Эта запись уже сохранена.","es":"Esa entrada ya se guardó.","de":"Dieser Eintrag wurde bereits gespeichert.","pl":"Ten wpis został już zapisany."],
        "editor_transfer": ["en":"Transfer","uk":"Переказ","ru":"Перевод","es":"Transferencia","de":"Übertragung","pl":"Przelew"],
        "editor_wallet_source": ["en":"From wallet","uk":"З гаманця","ru":"Из кошелька","es":"Desde la cartera","de":"Von Konto","pl":"Z portfela"],
        "editor_wallet_destination": ["en":"To wallet","uk":"До гаманця","ru":"В кошелёк","es":"A la cartera","de":"Auf Konto","pl":"Do portfela"],
        "editor_wallet_none": ["en":"No wallet","uk":"Без гаманця","ru":"Без кошелька","es":"Sin cartera","de":"Kein Konto","pl":"Bez portfela"],
        "editor_wallet_archived": ["en":"archived","uk":"в архіві","ru":"в архиве","es":"archivada","de":"archiviert","pl":"zarchiwizowany"],
        "editor_amount_in": ["en":"Amount in %@","uk":"Сума у %@","ru":"Сумма в %@","es":"Importe en %@","de":"Betrag in %@","pl":"Kwota w %@"],
        "editor_opening_balance": ["en":"Opening balance","uk":"Початковий баланс","ru":"Начальный баланс","es":"Saldo inicial","de":"Anfangsbestand","pl":"Saldo początkowe"],
        "editor_current_balance": ["en":"Current balance","uk":"Поточний баланс","ru":"Текущий баланс","es":"Saldo actual","de":"Aktueller Stand","pl":"Saldo bieżące"],
        "editor_currency_locked": ["en":"Currency can't change while entries point at this wallet.","uk":"Валюту не змінити, доки на гаманець посилаються записи.","ru":"Валюту нельзя изменить, пока на кошелёк ссылаются записи.","es":"No se puede cambiar la moneda mientras haya entradas que apunten a esta cartera.","de":"Die Währung kann nicht geändert werden, solange Einträge auf dieses Konto zeigen.","pl":"Nie można zmienić waluty, dopóki wpisy wskazują ten portfel."],
        "editor_archive_wallet": ["en":"Archive wallet","uk":"Архівувати гаманець","ru":"Архивировать кошелёк","es":"Archivar cartera","de":"Konto archivieren","pl":"Zarchiwizuj portfel"],
        "editor_archive_explains": ["en":"Archiving hides it from new entries. Its history stays.","uk":"Архівування ховає його для нових записів. Історія лишається.","ru":"Архивирование скрывает его для новых записей. История остаётся.","es":"Archivar lo oculta para entradas nuevas. Su historial permanece.","de":"Archivieren blendet es für neue Einträge aus. Die Historie bleibt.","pl":"Archiwizacja ukrywa go dla nowych wpisów. Historia zostaje."],
        "status_saved_on_device": ["en":"Saved on this device","uk":"Збережено на пристрої","ru":"Сохранено на устройстве","es":"Guardado en este dispositivo","de":"Auf diesem Gerät gespeichert","pl":"Zapisano na tym urządzeniu"],
        "status_waiting_to_sync": ["en":"Waiting to sync","uk":"Чекає на синхронізацію","ru":"Ждёт синхронизации","es":"Esperando sincronización","de":"Wartet auf Synchronisierung","pl":"Czeka na synchronizację"],

        "err_invalid_wallet_name": ["en":"Give the wallet a name.","uk":"Дай гаманцю назву.","ru":"Дай кошельку название.","es":"Ponle un nombre a la cartera.","de":"Gib dem Konto einen Namen.","pl":"Nadaj portfelowi nazwę."],
        "err_invalid_category_name": ["en":"Give the category a name.","uk":"Дай категорії назву.","ru":"Дай категории название.","es":"Ponle un nombre a la categoría.","de":"Gib der Kategorie einen Namen.","pl":"Nadaj kategorii nazwę."],
        "err_wallet_currency_is_locked": ["en":"Entries already point at this wallet, so its currency can't change.","uk":"На цей гаманець уже посилаються записи, тож валюту не змінити.","ru":"На этот кошелёк уже ссылаются записи, поэтому валюту нельзя изменить.","es":"Ya hay entradas que apuntan a esta cartera, así que su moneda no puede cambiar.","de":"Es zeigen bereits Einträge auf dieses Konto, daher kann die Währung nicht geändert werden.","pl":"Wpisy już wskazują ten portfel, więc waluty nie można zmienić."],

        "backend_malformed_response": ["en":"The reply couldn't be read exactly, so nothing was filled in. Try again, or enter it by hand.","uk":"Відповідь не вдалося прочитати точно, тож нічого не заповнено. Спробуй ще раз або введи вручну.","ru":"Ответ не удалось прочитать точно, поэтому ничего не заполнено. Попробуй ещё раз или введи вручную.","es":"No se pudo leer la respuesta con exactitud, así que no se rellenó nada. Inténtalo de nuevo o introdúcelo a mano.","de":"Die Antwort konnte nicht exakt gelesen werden, daher wurde nichts ausgefüllt. Versuche es erneut oder gib es manuell ein.","pl":"Nie udało się dokładnie odczytać odpowiedzi, więc nic nie wypełniono. Spróbuj ponownie lub wpisz ręcznie."],
        "about_rate_sources": ["en":"Exchange rates","uk":"Курси валют","ru":"Курсы валют","es":"Tipos de cambio","de":"Wechselkurse","pl":"Kursy walut"],
        "about_rate_sources_note": ["en":"Fiat: central-bank reference rates via Frankfurter. Crypto: CoinGecko. Rates are references, not the price you paid.","uk":"Фіат: довідкові курси центробанків через Frankfurter. Крипто: CoinGecko. Це довідкові курси, а не ціна вашої операції.","ru":"Фиат: справочные курсы центробанков через Frankfurter. Крипто: CoinGecko. Это справочные курсы, а не цена вашей операции.","es":"Fiat: tipos de referencia de bancos centrales vía Frankfurter. Cripto: CoinGecko. Son referencias, no el precio que pagaste.","de":"Fiat: Referenzkurse von Zentralbanken über Frankfurter. Krypto: CoinGecko. Referenzwerte, nicht dein tatsächlicher Preis.","pl":"Fiat: kursy referencyjne banków centralnych przez Frankfurter. Krypto: CoinGecko. To kursy referencyjne, nie cena Twojej transakcji."],

        // MARK: Rates, valuation and reports (P7)
        "valuation_section": ["en":"Conversion to USD","uk":"Конвертація в USD","ru":"Конвертация в USD","es":"Conversión a USD","de":"Umrechnung in USD","pl":"Przeliczenie na USD"],
        "valuation_usd_native": ["en":"The amount is in USD — no conversion needed.","uk":"Сума в USD — конвертація не потрібна.","ru":"Сумма в USD — конвертация не нужна.","es":"El importe está en USD: no hace falta convertir.","de":"Der Betrag ist in USD — keine Umrechnung nötig.","pl":"Kwota jest w USD — przeliczenie niepotrzebne."],
        "valuation_loading": ["en":"Getting the rate…","uk":"Отримуємо курс…","ru":"Получаем курс…","es":"Obteniendo el tipo…","de":"Kurs wird geladen…","pl":"Pobieranie kursu…"],
        "valuation_use_quote": ["en":"Use this rate","uk":"Використати цей курс","ru":"Использовать этот курс","es":"Usar este tipo","de":"Diesen Kurs verwenden","pl":"Użyj tego kursu"],
        "valuation_use_stale": ["en":"Use this older rate","uk":"Використати старіший курс","ru":"Использовать старый курс","es":"Usar este tipo antiguo","de":"Älteren Kurs verwenden","pl":"Użyj starszego kursu"],
        "valuation_stale": ["en":"The latest rate is from %@.","uk":"Останній курс — від %@.","ru":"Последний курс — от %@.","es":"El último tipo es del %@.","de":"Der letzte Kurs ist vom %@.","pl":"Ostatni kurs jest z %@."],
        "valuation_unavailable": ["en":"No rate: %@","uk":"Курсу немає: %@","ru":"Курса нет: %@","es":"Sin tipo: %@","de":"Kein Kurs: %@","pl":"Brak kursu: %@"],
        "valuation_enter_manual": ["en":"Enter a rate yourself","uk":"Ввести курс вручну","ru":"Ввести курс вручную","es":"Introducir el tipo a mano","de":"Kurs selbst eingeben","pl":"Wpisz kurs ręcznie"],
        "valuation_manual_placeholder": ["en":"USD for 1 %@","uk":"USD за 1 %@","ru":"USD за 1 %@","es":"USD por 1 %@","de":"USD für 1 %@","pl":"USD za 1 %@"],
        "valuation_save_unvalued": ["en":"Save without conversion","uk":"Зберегти без конвертації","ru":"Сохранить без конвертации","es":"Guardar sin convertir","de":"Ohne Umrechnung speichern","pl":"Zapisz bez przeliczenia"],
        "valuation_keep_existing": ["en":"Keep the current rate","uk":"Лишити поточний курс","ru":"Оставить текущий курс","es":"Mantener el tipo actual","de":"Aktuellen Kurs behalten","pl":"Zachowaj obecny kurs"],
        "valuation_using_manual": ["en":"Using the rate you entered","uk":"Використовується ваш курс","ru":"Используется ваш курс","es":"Se usa el tipo que introdujiste","de":"Dein eingegebener Kurs wird verwendet","pl":"Używany jest wpisany kurs"],
        "valuation_chosen_unvalued": ["en":"Saved without conversion to USD","uk":"Зберігається без конвертації в USD","ru":"Сохраняется без конвертации в USD","es":"Se guarda sin convertir a USD","de":"Wird ohne Umrechnung in USD gespeichert","pl":"Zapis bez przeliczenia na USD"],
        "valuation_unchanged": ["en":"The saved rate stays as it is","uk":"Збережений курс не змінюється","ru":"Сохранённый курс не меняется","es":"El tipo guardado no cambia","de":"Der gespeicherte Kurs bleibt","pl":"Zapisany kurs się nie zmienia"],
        "valuation_source_manual": ["en":"manual","uk":"вручну","ru":"вручную","es":"manual","de":"manuell","pl":"ręcznie"],
        "valuation_legacy_short": ["en":"old built-in rate, unverified","uk":"старий вбудований курс, не перевірено","ru":"старый встроенный курс, не проверен","es":"tipo interno antiguo, sin verificar","de":"alter eingebauter Kurs, ungeprüft","pl":"stary wbudowany kurs, niezweryfikowany"],
        "rate_reason_provider_access": ["en":"the rate provider refused access","uk":"постачальник курсів відмовив у доступі","ru":"поставщик курсов отказал в доступе","es":"el proveedor de tipos denegó el acceso","de":"der Kursanbieter hat den Zugriff verweigert","pl":"dostawca kursów odmówił dostępu"],
        "rate_reason_provider_limit": ["en":"too many requests — try again shortly","uk":"забагато запитів — спробуй трохи згодом","ru":"слишком много запросов — попробуй чуть позже","es":"demasiadas solicitudes: inténtalo en breve","de":"zu viele Anfragen — gleich erneut versuchen","pl":"zbyt wiele zapytań — spróbuj za chwilę"],
        "rate_reason_provider_failure": ["en":"the rate provider didn't answer","uk":"постачальник курсів не відповів","ru":"поставщик курсов не ответил","es":"el proveedor de tipos no respondió","de":"der Kursanbieter hat nicht geantwortet","pl":"dostawca kursów nie odpowiedział"],
        "rate_reason_missing_currency": ["en":"this currency isn't in the provider's data","uk":"цієї валюти немає в даних постачальника","ru":"этой валюты нет в данных поставщика","es":"esta moneda no está en los datos del proveedor","de":"diese Währung fehlt in den Anbieterdaten","pl":"tej waluty nie ma w danych dostawcy"],
        "rate_reason_invalid_quote": ["en":"the provider's rate didn't pass checks","uk":"курс постачальника не пройшов перевірку","ru":"курс поставщика не прошёл проверку","es":"el tipo del proveedor no superó la verificación","de":"der Anbieterkurs hat die Prüfung nicht bestanden","pl":"kurs dostawcy nie przeszedł weryfikacji"],
        "rate_reason_historical_unavailable": ["en":"no rate for that date","uk":"немає курсу на цю дату","ru":"нет курса на эту дату","es":"no hay tipo para esa fecha","de":"kein Kurs für dieses Datum","pl":"brak kursu na tę datę"],
        "rate_reason_cache_failure": ["en":"the rate couldn't be stored for verification","uk":"курс не вдалося зберегти для перевірки","ru":"курс не удалось сохранить для проверки","es":"no se pudo guardar el tipo para verificarlo","de":"der Kurs konnte zur Prüfung nicht gespeichert werden","pl":"nie udało się zapisać kursu do weryfikacji"],
        "rate_reason_refresh_in_progress": ["en":"the rate is being refreshed — try again shortly","uk":"курс оновлюється — спробуй трохи згодом","ru":"курс обновляется — попробуй чуть позже","es":"el tipo se está actualizando: inténtalo en breve","de":"der Kurs wird aktualisiert — gleich erneut versuchen","pl":"kurs jest odświeżany — spróbuj za chwilę"],
        "rate_reason_offline": ["en":"no connection","uk":"немає з'єднання","ru":"нет соединения","es":"sin conexión","de":"keine Verbindung","pl":"brak połączenia"],
        "rate_reason_not_signed_in": ["en":"sign in to get rates","uk":"увійди, щоб отримувати курси","ru":"войди, чтобы получать курсы","es":"inicia sesión para obtener tipos","de":"melde dich an, um Kurse zu erhalten","pl":"zaloguj się, aby pobierać kursy"],
        "rate_reason_service_unavailable": ["en":"the rate service is unavailable","uk":"сервіс курсів недоступний","ru":"сервис курсов недоступен","es":"el servicio de tipos no está disponible","de":"der Kursdienst ist nicht erreichbar","pl":"usługa kursów jest niedostępna"],
        "rate_reason_unknown": ["en":"the rate is unavailable","uk":"курс недоступний","ru":"курс недоступен","es":"el tipo no está disponible","de":"der Kurs ist nicht verfügbar","pl":"kurs jest niedostępny"],
        "err_valuation_decision_required": ["en":"The currency or date changed. Choose a rate: keep the current one, use a new one, enter one, or save without conversion.","uk":"Змінилася валюта або дата. Обери курс: лишити поточний, взяти новий, ввести вручну або зберегти без конвертації.","ru":"Изменилась валюта или дата. Выбери курс: оставить текущий, взять новый, ввести вручную или сохранить без конвертации.","es":"Cambió la moneda o la fecha. Elige un tipo: mantener el actual, usar uno nuevo, introducirlo o guardar sin convertir.","de":"Währung oder Datum wurde geändert. Wähle einen Kurs: behalten, neu verwenden, eingeben oder ohne Umrechnung speichern.","pl":"Zmieniła się waluta lub data. Wybierz kurs: zachowaj obecny, użyj nowego, wpisz ręcznie lub zapisz bez przeliczenia."],
        "err_invalid_rate": ["en":"That rate isn't a positive number with at most 18 decimal places.","uk":"Цей курс не є додатним числом із максимум 18 знаками після коми.","ru":"Этот курс не является положительным числом с не более чем 18 знаками после запятой.","es":"Ese tipo no es un número positivo con como máximo 18 decimales.","de":"Dieser Kurs ist keine positive Zahl mit höchstens 18 Nachkommastellen.","pl":"Ten kurs nie jest liczbą dodatnią z najwyżej 18 miejscami po przecinku."],
        "err_base_amount_rounds_to_zero": ["en":"At that rate the USD value rounds to zero. Use a different rate or save without conversion.","uk":"За цим курсом сума в USD округлюється до нуля. Візьми інший курс або збережи без конвертації.","ru":"По этому курсу сумма в USD округляется до нуля. Возьми другой курс или сохрани без конвертации.","es":"Con ese tipo el valor en USD se redondea a cero. Usa otro tipo o guarda sin convertir.","de":"Bei diesem Kurs wird der USD-Wert auf null gerundet. Anderen Kurs wählen oder ohne Umrechnung speichern.","pl":"Przy tym kursie wartość w USD zaokrąla się do zera. Użyj innego kursu lub zapisz bez przeliczenia."],
        "receipt_unconverted": ["en":"no USD conversion","uk":"без конвертації в USD","ru":"без конвертации в USD","es":"sin conversión a USD","de":"ohne USD-Umrechnung","pl":"bez przeliczenia na USD"],
        "report_display_conversion": ["en":"Shown in %@ at the rate of %@. Booked values stay in USD.","uk":"Показано в %@ за курсом від %@. Облікові суми лишаються в USD.","ru":"Показано в %@ по курсу от %@. Учётные суммы остаются в USD.","es":"Mostrado en %@ al tipo del %@. Los valores registrados siguen en USD.","de":"In %@ zum Kurs vom %@ angezeigt. Gebuchte Werte bleiben in USD.","pl":"Pokazano w %@ po kursie z %@. Zaksięgowane wartości pozostają w USD."],
        "report_display_stale": ["en":"older rate","uk":"старіший курс","ru":"старый курс","es":"tipo antiguo","de":"älterer Kurs","pl":"starszy kurs"],
        "report_display_unavailable": ["en":"No current %@ rate — shown in USD.","uk":"Немає поточного курсу %@ — показано в USD.","ru":"Нет текущего курса %@ — показано в USD.","es":"No hay tipo actual de %@: se muestra en USD.","de":"Kein aktueller %@-Kurs — in USD angezeigt.","pl":"Brak bieżącego kursu %@ — pokazano w USD."],
        "report_unconverted_count": ["en":"%d entries have no USD value and are not in these totals.","uk":"%d записів не мають суми в USD і не входять у ці підсумки.","ru":"%d записей не имеют суммы в USD и не входят в эти итоги.","es":"%d entradas no tienen valor en USD y no están en estos totales.","de":"%d Einträge haben keinen USD-Wert und sind nicht in diesen Summen.","pl":"%d wpisów nie ma wartości w USD i nie ma ich w tych sumach."],
        "report_legacy_count": ["en":"%d entries use old built-in rates (unverified).","uk":"%d записів використовують старі вбудовані курси (не перевірено).","ru":"%d записей используют старые встроенные курсы (не проверено).","es":"%d entradas usan tipos internos antiguos (sin verificar).","de":"%d Einträge verwenden alte eingebaute Kurse (ungeprüft).","pl":"%d wpisów używa starych wbudowanych kursów (niezweryfikowane)."],
        "report_unreadable_count": ["en":"%d entries couldn't be read and are not in these totals.","uk":"%d записів не вдалося прочитати, їх немає в підсумках.","ru":"%d записей не удалось прочитать, их нет в итогах.","es":"%d entradas no se pudieron leer y no están en estos totales.","de":"%d Einträge konnten nicht gelesen werden und fehlen in den Summen.","pl":"%d wpisów nie dało się odczytać i nie ma ich w sumach."],
        "report_native_totals": ["en":"In original currencies","uk":"В оригінальних валютах","ru":"В исходных валютах","es":"En monedas originales","de":"In Originalwährungen","pl":"W walutach oryginalnych"],

        // MARK: Storage recovery (P8)
        "storage_error_title": ["en":"Can't open your data","uk":"Не вдається відкрити дані","ru":"Не удаётся открыть данные","es":"No se pueden abrir tus datos","de":"Daten können nicht geöffnet werden","pl":"Nie można otworzyć danych"],
        "storage_error_incompatible": ["en":"This database was written by a different version of SumIt. Updating the app may fix it.","uk":"Цю базу створила інша версія SumIt. Оновлення застосунку може допомогти.","ru":"Эта база создана другой версией SumIt. Обновление приложения может помочь.","es":"Esta base de datos la escribió otra versión de SumIt. Actualizar la app puede solucionarlo.","de":"Diese Datenbank stammt von einer anderen SumIt-Version. Ein App-Update kann helfen.","pl":"Ta baza pochodzi z innej wersji SumIt. Aktualizacja aplikacji może pomóc."],
        "storage_error_disk_full": ["en":"There isn't enough free space on this device to open your data.","uk":"На пристрої бракує вільного місця, щоб відкрити дані.","ru":"На устройстве не хватает свободного места, чтобы открыть данные.","es":"No hay espacio libre suficiente en este dispositivo para abrir tus datos.","de":"Auf diesem Gerät ist nicht genug freier Speicher, um die Daten zu öffnen.","pl":"Na urządzeniu brakuje wolnego miejsca, aby otworzyć dane."],
        "storage_error_permissions": ["en":"SumIt can't read its own database file.","uk":"SumIt не може прочитати власний файл бази.","ru":"SumIt не может прочитать собственный файл базы.","es":"SumIt no puede leer su propio archivo de base de datos.","de":"SumIt kann seine eigene Datenbankdatei nicht lesen.","pl":"SumIt nie może odczytać własnego pliku bazy."],
        "storage_error_unknown": ["en":"Your data couldn't be opened.","uk":"Не вдалося відкрити дані.","ru":"Не удалось открыть данные.","es":"No se pudieron abrir tus datos.","de":"Die Daten konnten nicht geöffnet werden.","pl":"Nie udało się otworzyć danych."],
        "storage_data_preserved": ["en":"Nothing has been deleted. Your database is still on this device and no new entries can be recorded until it opens.","uk":"Нічого не видалено. База лишається на пристрої, і нові записи неможливі, доки вона не відкриється.","ru":"Ничего не удалено. База осталась на устройстве, и новые записи невозможны, пока она не откроется.","es":"No se ha borrado nada. Tu base de datos sigue en el dispositivo y no se pueden registrar entradas hasta que se abra.","de":"Es wurde nichts gelöscht. Deine Datenbank liegt weiterhin auf dem Gerät; bis sie sich öffnet, sind keine neuen Einträge möglich.","pl":"Nic nie zostało usunięte. Baza pozostaje na urządzeniu, a nowe wpisy są niemożliwe, dopóki się nie otworzy."],
        "storage_retry": ["en":"Try again","uk":"Спробувати ще","ru":"Повторить","es":"Reintentar","de":"Erneut versuchen","pl":"Spróbuj ponownie"],
        "storage_save_copy": ["en":"Save a copy of the database","uk":"Зберегти копію бази","ru":"Сохранить копию базы","es":"Guardar una copia de la base de datos","de":"Kopie der Datenbank sichern","pl":"Zapisz kopię bazy"],
        "storage_copy_failed": ["en":"The copy couldn't be created.","uk":"Не вдалося створити копію.","ru":"Не удалось создать копию.","es":"No se pudo crear la copia.","de":"Die Kopie konnte nicht erstellt werden.","pl":"Nie udało się utworzyć kopii."],

        // MARK: Reports (redesign)
        "total_wealth": ["en":"Total wealth","uk":"Загальний капітал","ru":"Общий капитал","es":"Patrimonio total","de":"Gesamtvermögen","pl":"Cały majątek"],
        "statistics": ["en":"Statistics","uk":"Статистика","ru":"Статистика","es":"Estadísticas","de":"Statistik","pl":"Statystyki"],
        "overview_short": ["en":"Overview","uk":"Огляд","ru":"Обзор","es":"Resumen","de":"Übersicht","pl":"Przegląd"],
        "statistic": ["en":"Statistic","uk":"Статистика","ru":"Статистика","es":"Estadística","de":"Statistik","pl":"Statystyka"],
        "saved": ["en":"Saved","uk":"Накопичено","ru":"Накоплено","es":"Ahorrado","de":"Gespart","pl":"Zaoszczędzono"],
        "spent": ["en":"Spent","uk":"Витрачено","ru":"Потрачено","es":"Gastado","de":"Ausgegeben","pl":"Wydano"]
    ]
}
