# Настройка v8: аккаунты, аналитика, push

Все шаги делаются один раз в панели Supabase (https://supabase.com/dashboard → проект `jxvjurltvjgcqxvhbfhx`).
Пока шаги не выполнены, приложение работает как раньше: без аккаунтов, ник и XP хранятся анонимно на устройстве.

## 1. SQL (2 минуты)

SQL Editor → New query → вставить `supabase_v8_accounts.sql` → Run.
Внизу должно появиться 3 строки `avatars / analytics / push — true`.
Предупреждение «destructive operations» — нормально (там `create or replace` и `revoke`), данные не удаляются.

## 2. Вход по e-mail (5 минут)

**Authentication → Sign In / Providers**
- **Email** — включено, «Confirm email» — включено.
- **Allow anonymous sign-ins** — включено (уже было).
- **Allow manual linking** — включить. Нужно, чтобы анонимный пользователь мог «привязать» e-mail и сохранить свой прогресс.

**Authentication → Emails → Templates** — в двух шаблонах нужен 6-значный код (`{{ .Token }}`), потому что в приложении Android ссылка из письма открылась бы в браузере, а не в приложении.

*Magic Link* — тема: `Twój kod Tropami / Your Tropami code`
```html
<h2 style="color:#2D5843">Tropami</h2>
<p>Twój kod logowania / Your sign-in code:</p>
<p style="font-size:32px;font-weight:800;letter-spacing:6px;color:#14221A">{{ .Token }}</p>
<p style="color:#55665B">Kod jest ważny przez godzinę. Jeśli to nie Ty — zignoruj tę wiadomość.<br>
The code is valid for one hour. If this wasn't you, just ignore this email.</p>
```

*Change Email Address* — тема: `Potwierdź e-mail w Tropami / Confirm your email`
```html
<h2 style="color:#2D5843">Tropami</h2>
<p>Kod potwierdzający / Confirmation code:</p>
<p style="font-size:32px;font-weight:800;letter-spacing:6px;color:#14221A">{{ .Token }}</p>
<p style="color:#55665B">Wpisz go w aplikacji, żeby zapisać postępy na koncie {{ .NewEmail }}.<br>
Enter it in the app to save your progress to {{ .NewEmail }}.</p>
```

**Отправка писем (SMTP).** Встроенная почта Supabase шлёт письма только участникам команды проекта и максимум 2 в час.
- **Чтобы проверить прямо сейчас:** Organization → Team → пригласить свой второй e-mail (или использовать свой). На эти адреса коды придут без настройки SMTP.
- **Для всех пользователей:** подключить свой SMTP — Authentication → Emails → SMTP Settings → Enable custom SMTP.
  Подходит Brevo (бесплатный тариф): host `smtp-relay.brevo.com`, port `587`, user — логин Brevo, password — SMTP-ключ из Brevo → Settings → SMTP & API.
  Отправитель лучше на своём домене (например `hello@tropami.eu`) с записями SPF/DKIM — поэтому удобно сделать после покупки домена. С адреса gmail письма часто уходят в спам.
- После SMTP: Authentication → Rate Limits → «emails per hour» = 30 (по умолчанию) — для старта хватит.

## 3. Push-уведомления (10 минут)

Отправляет GitHub Actions каждый час (`.github/workflows/push.yml`). Нужны секреты в GitHub:
**Settings → Secrets and variables → Actions → New repository secret**

| Секрет | Где взять |
|---|---|
| `SUPABASE_SERVICE_ROLE_KEY` | Supabase → Project Settings → API Keys → вкладка «Legacy API keys» → `service_role` (длинный ключ `eyJ…`; секретный — только в GitHub) |
| `VAPID_PRIVATE_KEY` | из присланного файла `tropami-push-keys.txt` |
| `FCM_SERVICE_ACCOUNT` | только для приложения Android, см. ниже |
| `GOOGLE_SERVICES_JSON` | только для приложения Android, см. ниже |

После добавления: Actions → «Push reminders» → Run workflow (галочка «Tylko pokaż» = пробный запуск, ничего не шлёт).

**Android-приложение (Firebase), по желанию:**
1. https://console.firebase.google.com → Add project «Tropami» (Analytics можно выключить).
2. Add app → Android → package name `eu.tropami.app` → скачать `google-services.json`.
   Содержимое файла целиком → секрет `GOOGLE_SERVICES_JSON`.
3. Project settings → Service accounts → Generate new private key → JSON.
   Содержимое целиком → секрет `FCM_SERVICE_ACCOUNT`.
4. Actions → «Android build» → Run workflow. В новом APK уведомления заработают.

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
