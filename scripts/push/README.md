# Push-напоминания

`send.mjs` запускает GitHub Actions каждый час (`.github/workflows/push.yml`).
Кому и что отправить, решает база (`dk_push_due` в `supabase/supabase_v8_accounts.sql`):

| Тип | Когда | Пример |
|---|---|---|
| confirm | кто-то подтвердил вашу отметку | «🤝 Ktoś potwierdził Twoją obserwację» |
| streak | вчера была отметка, сегодня нет, после 17:00 | «🔥 Seria: 4 dni z rzędu» |
| inactive | не заходил 3, потом 7, потом 14 дней | «🦊 12 nowych obserwacji w Twojej okolicy» |
| weekly | понедельник 10–12, активен за 30 дней | «🏁 Nowe wyzwania tygodnia» |

Ограничения: только 10:00–19:59 по местному времени, не чаще 1 раза в 20 часов, после 3 напоминаний о возвращении — тишина, пока человек сам не откроет приложение.

Настройка секретов — `supabase/SETUP_v8.md`, раздел 3. Проверка без отправки: Actions → Push reminders → Run workflow.

Локально: `npm ci && DRY_RUN=1 SUPABASE_URL=… SUPABASE_SERVICE_ROLE_KEY=… node send.mjs`
