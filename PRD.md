# PRD — Menubar Calendar Widget (macOS)

## 1. Cel

Natywna aplikacja macOS żyjąca **wyłącznie w pasku menu** (bez okna, bez ikony w Docku), która pokazuje **najbliższe nadchodzące wydarzenie** z kalendarza użytkownika wraz z odliczaniem czasu do jego rozpoczęcia. Kliknięcie rozwija listę kilku kolejnych wydarzeń.

Przykład etykiety w pasku: `Standup… in 27m`

## 2. Stack techniczny

- **Język:** Swift
- **UI:** SwiftUI, `MenuBarExtra` (macOS 13+)
- **Kalendarz:** EventKit (`EKEventStore`) lub Google Calendar API (wybór w Ustawieniach — patrz docs/superpowers/specs/2026-10-02-google-api-event-source-design.md)
- **Minimalny target:** macOS 14 (Sonoma) — używamy `requestFullAccessToEvents()`
- **Autostart:** `ServiceManagement` (`SMAppService.mainApp`)
- **Trwałe ustawienia:** `UserDefaults` (wybrane kalendarze, przełącznik autostartu, przełącznik all-day)
- Brak zależności zewnętrznych (żadnych third-party packages)

## 3. Wymagania funkcjonalne

### 3.1 Etykieta w pasku menu
- Pokazuje tytuł najbliższego wydarzenia (przycięty do ~20 znaków + „…") oraz czas do startu.
- Format odliczania:
  - `< 60 min` → `in 27m`
  - `>= 60 min` → `in 2h 15m`
- Gdy brak nadchodzących wydarzeń → `Brak wydarzeń`.
- Etykieta odświeża odliczanie automatycznie **co 30 sekund**.

### 3.2 Rozwijane okienko (po kliknięciu)
- Styl `.window` (własny widok SwiftUI, nie klasyczne menu).
- Lista **najbliższych 5 wydarzeń** na najbliższe 7 dni.
- Każdy wiersz: tytuł, godzina rozpoczęcia (np. `14:30`), opcjonalnie nazwa kalendarza / kolorowa kropka koloru kalendarza.
- Wydarzenia całodniowe (all-day) są uwzględniane — patrz 3.4.
- Na dole: przycisk **„Odśwież"**, wejście do **Ustawień** (3.5) i przycisk **„Quit"**.

### 3.3 Dostęp do kalendarza
- Przy pierwszym uruchomieniu prośba o dostęp przez `requestFullAccessToEvents()`.
- Jeśli użytkownik odmówi → w okienku komunikat z linkiem do Ustawień systemowych (Prywatność → Kalendarze).
- Nasłuch na `.EKEventStoreChanged` — po zmianie w Kalendarzu lista się przeładowuje.

### 3.4 Wydarzenia całodniowe (all-day)
- All-day są uwzględniane zarówno w liście, jak i w kandydatach do etykiety.
- W wierszu listy zamiast godziny pokazujemy etykietę `Cały dzień` (i datę, jeśli nie jest to dzisiaj, np. `jutro`).
- W pasku menu, gdy najbliższym elementem jest wydarzenie all-day rozpoczynające się dziś, etykieta ma postać `Tytuł… (dziś)` zamiast odliczania w minutach. Dla all-day w kolejnych dniach → `Tytuł… (jutro)` / `Tytuł… (pt)`.
- Reguła pierwszeństwa: jeśli tego samego dnia jest event z konkretną godziną, ma on priorytet w etykiecie nad all-day (all-day traktujemy jako „tło dnia").
- Przełącznik w Ustawieniach: **„Pokazuj wydarzenia całodniowe"** (domyślnie włączony).

### 3.5 Wybór kalendarzy
- W Ustawieniach lista wszystkich kalendarzy z `store.calendars(for: .event)`, każdy z checkboxem i kropką w kolorze kalendarza.
- Domyślnie zaznaczone wszystkie.
- Zapytania EventKit ograniczamy do zaznaczonych kalendarzy (parametr `calendars:` w predykacie zamiast `nil`).
- Wybór zapisywany w `UserDefaults` po identyfikatorach (`calendarIdentifier`), odczytywany przy starcie.
- Zmiana zaznaczenia natychmiast przeładowuje listę i etykietę.

### 3.6 Autostart przy logowaniu
- Realizacja przez `SMAppService.mainApp` (nie stare login items / helper app).
- Przełącznik w Ustawieniach: **„Uruchamiaj przy logowaniu"**.
  - Włączenie → `try SMAppService.mainApp.register()`
  - Wyłączenie → `try SMAppService.mainApp.unregister()`
- Stan przełącznika odzwierciedla `SMAppService.mainApp.status` (użytkownik mógł zmienić to w Ustawieniach systemowych → Elementy logowania).
- Obsłużyć błąd rejestracji (np. pokazać krótki komunikat), nie crashować.

## 4. Logika wyboru „najbliższego wydarzenia"

1. Zapytanie o wydarzenia od `teraz` do `teraz + 7 dni`, **tylko z zaznaczonych kalendarzy** (3.5).
2. Filtr:
   - wydarzenia z godziną: `startDate > teraz`,
   - all-day: uwzględniane, jeśli kończą się dziś lub później **i** przełącznik all-day (3.4) jest włączony.
3. Sortowanie rosnąco po `startDate`; przy równych datach wydarzenie z godziną przed all-day.
4. Etykieta w pasku:
   - jeśli jest nadchodzące wydarzenie z godziną → tytuł + odliczanie,
   - w przeciwnym razie, jeśli jest dzisiejsze all-day → tytuł + `(dziś)`,
   - inaczej pierwsze all-day z oznaczeniem dnia.
5. Lista = pierwsze 5 elementów po sortowaniu.

## 5. Konfiguracja projektu (krytyczne)

Bez tego appka się nie zbuduje lub crashuje:

- **Info.plist:** klucz `NSCalendarsFullAccessUsageDescription` z opisem po polsku, np. *„Aplikacja potrzebuje dostępu do kalendarza, aby pokazywać najbliższe wydarzenie w pasku menu."*
- **LSUIElement = YES** (w Xcode: *Application is agent (UIElement)*) — brak okna głównego i ikony w Docku.
- Jeśli włączony App Sandbox: entitlement `com.apple.security.personal-information.calendars`.

## 6. Struktura kodu (sugerowana)

```
MenubarCalendarApp.swift   // @main, MenuBarExtra
CalendarViewModel.swift    // EventKit, timer, publikowany stan
EventListView.swift        // widok rozwijanego okienka
SettingsView.swift         // wybór kalendarzy, all-day, autostart
AppSettings.swift          // UserDefaults: wybrane kalendarze, przełączniki
LoginItemManager.swift     // opakowanie SMAppService
Models/EventRow.swift      // model wiersza (tytuł, czas/all-day, kolor)
```

- `CalendarViewModel` jako `@MainActor final class ... ObservableObject`.
- Publikowane property: `menuBarTitle: String`, `upcomingEvents: [EKEvent]`, `accessDenied: Bool`.
- `AppSettings` przechowuje `selectedCalendarIDs: Set<String>`, `showAllDay: Bool`, `launchAtLogin: Bool`.

## 7. Poza zakresem MVP (na później)

- Kolorowy pasek/kropka statusu „za chwilę start" (wymaga przejścia na `NSStatusItem` z własnym rysowaniem).
- Kliknięcie w wydarzenie → otwarcie w aplikacji Kalendarz.
- Konfigurowalna długość okna czasowego i format godziny.

## 8. Kryteria akceptacji (MVP done)

- [ ] Po zbudowaniu appka pojawia się w pasku menu, nie ma jej w Docku.
- [ ] Przy pierwszym uruchomieniu pojawia się systemowy prompt o dostęp do kalendarza.
- [ ] Etykieta pokazuje tytuł + poprawne odliczanie do najbliższego eventu.
- [ ] Odliczanie aktualizuje się bez klikania (co ≤30 s).
- [ ] Kliknięcie otwiera okienko z listą najbliższych wydarzeń.
- [ ] Dodanie/przesunięcie eventu w Kalendarzu odświeża widget.
- [ ] Odmowa dostępu pokazuje sensowny komunikat, a nie pusty ekran.
- [ ] Wydarzenia all-day pojawiają się na liście z etykietą „Cały dzień", a w pasku z oznaczeniem dnia (`dziś`/`jutro`).
- [ ] W Ustawieniach można odznaczyć kalendarz i znika on natychmiast z listy i etykiety.
- [ ] Wybór kalendarzy i przełączniki przeżywają restart aplikacji (UserDefaults).
- [ ] Przełącznik „Uruchamiaj przy logowaniu" faktycznie rejestruje/wyrejestrowuje appkę (widać w Ustawieniach systemowych → Elementy logowania).
- [ ] Przełącznik autostartu odzwierciedla realny stan `SMAppService` po ponownym otwarciu Ustawień.
