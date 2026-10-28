# Настройка v8: аккаунты, аналитика, push

Все шаги делаются один раз (Supabase: https://supabase.com/dashboard → проект `jxvjurltvjgcqxvhbfhx`).
Пока шаги не выполнены, приложение работает как раньше: без входа, ник и XP хранятся на устройстве.

## 1. SQL (2 минуты)

SQL Editor → New query → вставить `supabase_v8_accounts.sql` → Run.
Внизу должно появиться 3 строки `avatars / analytics / push — true`.
Предупреждение «destructive operations» — нормально (там `create or replace` и `revoke`), данные не удаляются.

## 2. Вход (по желанию пользователя): Google, Apple, e-mail

Без входа всё работает: ник (придумывается сам, если человек его не ввёл), фото, XP и отметки хранятся на устройстве.
Вход нужен только чтобы не потерять прогресс при смене телефона. При входе прогресс с устройства присоединяется к аккаунту.
Кнопки входа появляются в приложении сами — когда соответствующий способ включён в Supabase.

### 2.1 Адреса возврата (1 минута, нужно для Google и Apple)
Supabase → **Authentication → URL Configuration**
- **Site URL:** `https://tropami.com/app/`
- **Redirect URLs** → Add URL, по одному:
  - `https://tropami.com/app/**`
  - `https://jahrastababylon.github.io/kabanchik/app/**` (старый адрес — можно оставить)
  - `com.tropami.app://auth`  ← возврат в Android-приложение

### 2.2 Google (10–15 минут, бесплатно)
1. https://console.cloud.google.com → вверху выбор проекта → **New project** → «Tropami» → Create.
2. Меню → **APIs & Services → OAuth consent screen** (может называться **Google Auth Platform**) → Get started:
   App name `Tropami`, support email — свой, Audience — **External**, contact email — свой → Create.
   В **Branding → Authorized domains** добавить `supabase.co`.
   В **Audience** нажать **Publish app** (иначе войти смогут только тестовые аккаунты). Для входа нужны только e-mail и имя — проверка Google не требуется.
3. **Clients → Create client** → Application type **Web application**, имя `Tropami web`:
   - Authorized JavaScript origins: `https://tropami.com`
   - Authorized redirect URIs: `https://jxvjurltvjgcqxvhbfhx.supabase.co/auth/v1/callback`
   → Create → откроется окно с **Client ID** и **Client secret**.
4. Supabase → **Authentication → Sign In / Providers → Google** → Enable →
   вставить Client ID и Client secret → Save.

### 2.3 Apple (позже)
Нужен платный Apple Developer Program (99 $/год): Services ID + ключ «Sign in with Apple».
Потом Supabase → Providers → Apple → Enable. Кнопка в приложении появится сама.

### 2.4 E-mail с кодом (по желанию, нужен свой почтовый сервер)
1. **SMTP** (без него Supabase не даёт менять шаблоны писем): Brevo (бесплатно ~300 писем в день) →
   Senders/Domains (свой домен `tropami.com` с DNS-записями) → SMTP & API → Generate SMTP key.
   Supabase → **Authentication → Emails → SMTP Settings → Enable custom SMTP**:
   Sender email = подтверждённый в Brevo адрес, Sender name `Tropami`, Host `smtp-relay.brevo.com`, Port `587`,
   Username = **Login** со страницы SMTP в Brevo, Password = SMTP-ключ.
2. **Шаблоны** (Authentication → Emails → Templates) — в **Magic Link** и **Confirm signup**:
   Subject: `Your Tropami code`
   ```html
   <h2 style="color:#2D5843">Tropami</h2>
   <p>Your sign-in code:</p>
   <p style="font-size:32px;font-weight:800;letter-spacing:6px;color:#14221A">{{ .Token }}</p>
   <p style="color:#55665B">The code is valid for one hour. If this wasn't you, just ignore this email.</p>
   ```
3. Написать Claude «почта готова» — в приложении включится кнопка «Продолжить с e-mail» (`CONFIG.AUTH_EMAIL = true`).

## 3. Push-уведомления (10 минут)

Отправляет GitHub Actions каждый час (`.github/workflows/push.yml`). Нужны секреты в GitHub:
**Settings → Secrets and variables → Actions → New repository secret**

| Секрет | Где взять |
|---|---|
| `SUPABASE_SERVICE_ROLE_KEY` | Supabase → Project Settings → API Keys → вкладка «Legacy API keys» → `service_role` (длинный ключ `eyJ…`; секретный — только в GitHub) |
| `VAPID_PRIVATE_KEY` | из присланного файла `tropami-push-keys.txt` |
| `FCM_SERVICE_ACCOUNT` | только для приложения Android, см. ниже |
| `GOOGLE_SERVICES_JSON` | только для приложения Android, см. ниже |

После добавления: Actions → «Push reminders» → Run workflow → режим:
- **test** — пробное уведомление на все устройства, где включены уведомления (нужен `supabase_v9_push_test.sql`);
- **próba** — показать, кому ушли бы напоминания по правилам, ничего не отправляя;
- **wyślij** — отправить по правилам (то же, что делает расписание каждый час).

**Android-приложение (Firebase), по желанию:**
1. https://console.firebase.google.com → Add project «Tropami» (Analytics можно выключить).
2. Add app → Android → package name `com.tropami.app` → скачать `google-services.json`.
   Содержимое файла целиком → секрет `GOOGLE_SERVICES_JSON`.
3. Project settings → Service accounts → Generate new private key → JSON.
   Содержимое целиком → секрет `FCM_SERVICE_ACCOUNT`.
4. Actions → «Android build» → Run workflow. В новом APK уведомления заработают.

**Надёжнее вставлять файлы как base64** (одна длинная строка — ничего не испортится при копировании):
- Mac (Терминал): `base64 -i ~/Downloads/google-services.json | pbcopy` → вставить в секрет (Cmd+V)
- Windows (PowerShell): `[Convert]::ToBase64String([IO.File]::ReadAllBytes("$HOME\Downloads\google-services.json")) | Set-Clipboard`
Так же можно и для `FCM_SERVICE_ACCOUNT` (подставить имя второго файла). Сборка понимает оба варианта: обычный JSON и base64.

Без Firebase уведомления работают в браузере, в приложении, установленном из Chrome («Установить приложение»), и на iPhone (после «На экран Домой»).

## Как смотреть аналитику

SQL Editor:
```sql
select * from analytics.daily;            -- активные, новые, отметки, аккаунты по дням
select * from analytics.retention;        -- % вернувшихся через 1 / 7 / 30 дней
select * from analytics.funnel_new_user;  -- где отваливаются новички
select * from analytics.funnel_report;    -- начали отметку → выбрали вид → отправили
select * from analytics.users;            -- пользователи: уровень, платформа, язык, город (~10 км)
select * from analytics.top_events;       -- самые частые события за неделю
select name, props, created_at from analytics.events order by id desc limit 100;
```
Схема `analytics` не видна из приложения — только из панели Supabase.

## v10: открытые данные, частые виды, опыт за редкость, ежедневный вход

1. SQL Editor → `supabase/supabase_v10_open_data_xp.sql` → Run (после v8 и v9).
2. Тестовые данные: `supabase/cleanup_test_data.sql` → Run (удаляет все отметки из приложения, тестовую статистику).
   Фото: Storage → `photos` → выделить всё → Delete (по желанию и `avatars`).
3. GitHub → Actions → **Import open data** → Run workflow (сначала можно с галочкой «Tylko pokaż»).
   Настоящие наблюдения из GBIF/iNaturalist (CC0, CC BY) по ~40 городам Европы за последние 60 дней,
   с реальными датами и авторами. Дальше — автоматически по понедельникам.
