# Tropami — Android i iOS

Natywne „opakowania” (Capacitor 8) dla aplikacji webowej z katalogu `app/`.
Aplikacja ładuje stronę `https://tropami.com/app/`, więc każda zmiana w `app/` trafia do użytkowników od razu, bez nowej wersji APK.

- Android: identyfikator `com.tropami.app` (stały — nie zmieniać po publikacji w Google Play)
- iOS: bundle id `com.tropami.app`

## Android — budowanie

Buduje GitHub Actions (`.github/workflows/android.yml`) przy każdej zmianie w `mobile/`,
albo ręcznie: GitHub → Actions → „Android build” → Run workflow.

Wynik: wydanie GitHub z plikami
- `tropami.apk` — instalacja ze strony (link „Pobierz dla Androida”),
- `tropami.aab` — do wgrania w Google Play Console.

Stały link do najnowszego APK:
`https://github.com/jahrastababylon/kabanchik/releases/latest/download/tropami.apk`

### Klucz podpisu (jednorazowo)

Bez klucza powstaje **wersja testowa** — każda kolejna wymaga odinstalowania poprzedniej.
Żeby wydawać stabilne wersje, dodaj w GitHub → Settings → Secrets and variables → Actions:

| Sekret | Wartość |
|---|---|
| `ANDROID_KEYSTORE_BASE64` | plik klucza zakodowany base64 |
| `ANDROID_KEYSTORE_PASSWORD` | hasło magazynu kluczy |
| `ANDROID_KEY_ALIAS` | `tropami` |
| `ANDROID_KEY_PASSWORD` | hasło klucza |

Klucz trzymaj poza repozytorium (menedżer haseł). Utrata klucza = brak aktualizacji dla osób z APK.

### Google Play

1. Konto Google Play Console (opłata jednorazowa 25 USD, weryfikacja tożsamości).
2. Konto osobiste: wymagany test zamknięty z min. 12 testerami przez 14 dni przed publikacją.
   Konto organizacji (np. fundacji) — inne zasady, wymaga numeru D-U-N-S.
3. Utwórz aplikację, wgraj `tropami.aab`, włącz „Play App Signing”.
4. Polityka prywatności: `https://tropami.com/privacy.html`.

## iOS

Projekt jest w `mobile/ios` (Swift Package Manager). Do zbudowania potrzebne są:
- Mac z Xcode (albo runner macOS w GitHub Actions),
- konto Apple Developer (99 USD/rok).

Kroki na Macu:
```
cd mobile
npm ci
npx cap sync ios
npx cap open ios      # Xcode → Signing & Capabilities → wybierz zespół → Product → Archive
```
Dystrybucja: TestFlight (testerzy) → App Store.

Instalacja ze strony na iPhonie jest możliwa tylko jako aplikacja webowa (Safari → Udostępnij → Do ekranu początkowego).
Apple pozwala na „Web Distribution” w UE tylko wydawcom spełniającym wysokie progi (np. 1 mln instalacji albo organizacja non-profit zwolniona z opłat).

## Domena

Strona i aplikacja działają pod `https://tropami.com` (plik `CNAME` w katalogu głównym repozytorium, DNS w Namecheap).
Stary adres `jahrastababylon.github.io/kabanchik/` przekierowuje na domenę. APK zbudowane przed zmianą domeny
trzeba zaktualizować — otwierają stary adres, a przekierowanie na inną domenę Android otwiera w przeglądarce.
