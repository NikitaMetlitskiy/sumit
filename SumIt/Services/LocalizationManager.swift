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

        // MARK: Reports (redesign)
        "total_wealth": ["en":"Total wealth","uk":"Загальний капітал","ru":"Общий капитал","es":"Patrimonio total","de":"Gesamtvermögen","pl":"Cały majątek"],
        "statistics": ["en":"Statistics","uk":"Статистика","ru":"Статистика","es":"Estadísticas","de":"Statistik","pl":"Statystyki"],
        "overview_short": ["en":"Overview","uk":"Огляд","ru":"Обзор","es":"Resumen","de":"Übersicht","pl":"Przegląd"],
        "statistic": ["en":"Statistic","uk":"Статистика","ru":"Статистика","es":"Estadística","de":"Statistik","pl":"Statystyka"],
        "saved": ["en":"Saved","uk":"Накопичено","ru":"Накоплено","es":"Ahorrado","de":"Gespart","pl":"Zaoszczędzono"],
        "spent": ["en":"Spent","uk":"Витрачено","ru":"Потрачено","es":"Gastado","de":"Ausgegeben","pl":"Wydano"]
    ]
}
