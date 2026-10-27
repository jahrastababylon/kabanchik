-- =====================================================================
-- Tropami — SQL v9: testowe powiadomienie push (po v8)
-- Uruchom raz: Supabase → SQL Editor → New query → Run. Nic nie usuwa.
-- GitHub → Actions → Push reminders → Run workflow → tryb „test”
-- wysyła próbne powiadomienie na wszystkie aktywne subskrypcje (z pominięciem reguł i limitów).
-- =====================================================================
create or replace function dk_push_test()
returns table (sub_id bigint, user_id uuid, kind text, channel text, endpoint text, p256dh text, auth text, lang text, n int)
language sql stable security definer set search_path = public, extensions
as $$
  select s.id, s.user_id, 'test', s.kind, s.endpoint, s.p256dh, s.auth, s.lang, 0
  from push.subscriptions s
  where s.disabled_at is null
  order by s.last_seen_at desc
  limit 50;
$$;
revoke execute on function dk_push_test() from public, anon, authenticated;
grant execute on function dk_push_test() to service_role;

-- Sprawdzenie: ile urządzeń ma włączone powiadomienia
select kind, count(*) as devices from push.subscriptions where disabled_at is null group by kind;
