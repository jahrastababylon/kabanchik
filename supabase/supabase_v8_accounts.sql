-- =====================================================================
-- Tropami — SQL v8: konta i profil, analityka, powiadomienia push
-- Uruchom raz w Supabase → SQL Editor → New query → Run (po v4–v7).
-- Nic nie usuwa z istniejących danych. Bezpieczne do powtórzenia.
--
--  1) Profil: zdjęcie (avatar), prywatne dane (telefon, zgody) — tylko dla właściciela
--  2) Konto e-mail: przeniesienie postępów z anonimowego urządzenia po zalogowaniu
--  3) Usunięcie konta (RODO, wymóg Google Play)
--  4) Analityka: zdarzenia w osobnym schemacie „analytics” (niewidocznym z aplikacji)
--  5) Powiadomienia push: subskrypcje + wybór, komu i co wysłać (wywołuje GitHub Actions)
-- =====================================================================

set search_path = public, extensions;

-- ---------------------------------------------------------------------
-- 1) PROFIL
-- ---------------------------------------------------------------------
alter table profiles add column if not exists avatar_url text;
alter table profiles add column if not exists updated_at timestamptz default now();

-- Dane widoczne tylko dla właściciela (tabela bez dostępu z API — tylko przez funkcje niżej)
create table if not exists profile_private (
  id            uuid primary key references auth.users(id) on delete cascade,
  phone         text,
  marketing_ok  boolean not null default false,   -- zgoda na kontakt w sprawie nagród/akcji
  analytics_ok  boolean not null default true,    -- statystyki użycia (można wyłączyć w aplikacji)
  updated_at    timestamptz not null default now()
);
alter table profile_private enable row level security;
revoke all on profile_private from anon, authenticated;

-- Zdjęcia profilowe: publiczne, max 512 KB, tylko obrazki; wgrywanie tylko do własnego folderu
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('avatars', 'avatars', true, 524288, array['image/jpeg','image/png','image/webp'])
on conflict (id) do update
  set public = excluded.public, file_size_limit = excluded.file_size_limit, allowed_mime_types = excluded.allowed_mime_types;

do $$
begin
  if not exists (select 1 from pg_policies where schemaname = 'storage' and tablename = 'objects' and policyname = 'tropami avatars: upload own') then
    create policy "tropami avatars: upload own" on storage.objects for insert to authenticated
      with check (bucket_id = 'avatars' and (storage.foldername(name))[1] = auth.uid()::text);
  end if;
  if not exists (select 1 from pg_policies where schemaname = 'storage' and tablename = 'objects' and policyname = 'tropami avatars: delete own') then
    create policy "tropami avatars: delete own" on storage.objects for delete to authenticated
      using (bucket_id = 'avatars' and (storage.foldername(name))[1] = auth.uid()::text);
  end if;
end $$;

-- Czy bieżąca sesja jest anonimowa (Supabase dodaje is_anonymous do tokenu)
create or replace function dk_is_anon() returns boolean
language sql stable set search_path = public, extensions
as $$ select coalesce((auth.jwt() ->> 'is_anonymous')::boolean, false) $$;

-- Profil zalogowanej osoby (pseudonim, zdjęcie, telefon, zgody)
create or replace function dk_get_profile()
returns table (nickname text, avatar_url text, phone text, marketing_ok boolean, analytics_ok boolean)
language sql stable security definer set search_path = public, extensions
as $$
  select p.nickname, p.avatar_url, pp.phone, coalesce(pp.marketing_ok, false), coalesce(pp.analytics_ok, true)
  from (select auth.uid() as id) me
  left join profiles p on p.id = me.id
  left join profile_private pp on pp.id = me.id
  where me.id is not null;
$$;

-- Zapis profilu. Puste pole = bez zmian; '-' w telefonie/zdjęciu = usuń.
create or replace function dk_save_profile(
  p_nickname     text    default null,
  p_avatar_url   text    default null,
  p_phone        text    default null,
  p_marketing_ok boolean default null,
  p_analytics_ok boolean default null
) returns void
language plpgsql security definer set search_path = public, extensions
as $$
declare
  v_uid  uuid := auth.uid();
  v_nick text := nullif(btrim(p_nickname), '');
  v_av   text := nullif(btrim(p_avatar_url), '');
  v_ph   text := nullif(regexp_replace(coalesce(p_phone, ''), '[^0-9+]', '', 'g'), '');
begin
  if v_uid is null then raise exception 'Brak sesji'; end if;
  if v_nick is not null and (length(v_nick) < 2 or length(v_nick) > 24) then
    raise exception 'Pseudonim musi mieć 2–24 znaki';
  end if;
  -- zdjęcie tylko z naszego magazynu i z własnego folderu
  if v_av is not null and v_av <> '-' and v_av !~ ('/storage/v1/object/public/avatars/' || v_uid::text || '/[A-Za-z0-9._-]+$') then
    raise exception 'Nieprawidłowe zdjęcie profilowe';
  end if;
  if p_phone is not null and btrim(p_phone) not in ('', '-') and (v_ph is null or v_ph !~ '^\+?[0-9]{6,15}$') then
    raise exception 'Nieprawidłowy numer telefonu';
  end if;

  insert into profiles (id) values (v_uid) on conflict (id) do nothing;
  update profiles set
    nickname   = coalesce(v_nick, nickname),
    avatar_url = case when v_av = '-' then null when v_av is not null then v_av else avatar_url end,
    updated_at = now()
  where id = v_uid;

  insert into profile_private (id) values (v_uid) on conflict (id) do nothing;
  update profile_private set
    phone        = case when btrim(coalesce(p_phone, '')) = '-' then null when v_ph is not null then v_ph else phone end,
    marketing_ok = coalesce(p_marketing_ok, marketing_ok),
    analytics_ok = coalesce(p_analytics_ok, analytics_ok),
    updated_at   = now()
  where id = v_uid;
end;
$$;

-- ---------------------------------------------------------------------
-- 2) KONTO E-MAIL: przeniesienie postępów z anonimowego urządzenia
--    Telefon bez konta → „Zaloguj się” → (a) jako anonim dostaje bilet,
--    (b) po zalogowaniu kodem z e-maila oddaje bilet i dane przechodzą na konto.
-- ---------------------------------------------------------------------
create table if not exists account_merge_tickets (
  ticket     uuid primary key default gen_random_uuid(),
  anon_id    uuid not null,
  created_at timestamptz not null default now(),
  used_at    timestamptz
);
alter table account_merge_tickets enable row level security;
revoke all on account_merge_tickets from anon, authenticated;

create or replace function dk_merge_start() returns uuid
language plpgsql security definer set search_path = public, extensions
as $$
declare v uuid;
begin
  if auth.uid() is null then raise exception 'Brak sesji'; end if;
  if not dk_is_anon() then return null; end if;          -- konto stałe nie potrzebuje biletu
  delete from account_merge_tickets where anon_id = auth.uid() or created_at < now() - interval '1 day';
  insert into account_merge_tickets (anon_id) values (auth.uid()) returning ticket into v;
  return v;
end;
$$;

create or replace function dk_merge_finish(p_ticket uuid) returns int
language plpgsql security definer set search_path = public, extensions
as $$
declare
  v_new uuid := auth.uid();
  v_old uuid;
  v_n   int := 0;
begin
  if v_new is null or dk_is_anon() then raise exception 'Najpierw zaloguj się e-mailem'; end if;
  select anon_id into v_old from account_merge_tickets
   where ticket = p_ticket and used_at is null and created_at > now() - interval '2 hours'
   for update;
  if v_old is null or v_old = v_new then return 0; end if;

  -- potwierdzenia: bez duplikatów i bez potwierdzania własnych obserwacji po połączeniu
  delete from confirmations c where c.user_id = v_old and (
    exists (select 1 from confirmations c2 where c2.sighting_id = c.sighting_id and c2.user_id = v_new)
    or exists (select 1 from sightings s where s.id = c.sighting_id and s.created_by = v_new));
  delete from confirmations c where c.user_id = v_new
    and exists (select 1 from sightings s where s.id = c.sighting_id and s.created_by = v_old);
  update confirmations set user_id = v_new where user_id = v_old;

  update sightings set created_by = v_new where created_by = v_old;
  get diagnostics v_n = row_count;

  -- profil: pseudonim/zdjęcie z konta mają pierwszeństwo, braki uzupełniamy z urządzenia
  insert into profiles (id) values (v_new) on conflict (id) do nothing;
  update profiles p set nickname = coalesce(p.nickname, o.nickname), avatar_url = coalesce(p.avatar_url, o.avatar_url), updated_at = now()
    from profiles o where p.id = v_new and o.id = v_old;
  insert into profile_private (id, phone, marketing_ok, analytics_ok)
    select v_new, phone, marketing_ok, analytics_ok from profile_private where id = v_old
    on conflict (id) do update set phone = coalesce(profile_private.phone, excluded.phone);

  update analytics.events set user_id = v_new where user_id = v_old;
  update push.subscriptions set user_id = v_new where user_id = v_old;

  delete from profile_private where id = v_old;
  delete from profiles where id = v_old;
  update account_merge_tickets set used_at = now() where ticket = p_ticket;
  begin
    delete from auth.users where id = v_old and is_anonymous;   -- sprzątanie pustego konta anonimowego
  exception when others then null;
  end;
  return v_n;
end;
$$;

-- ---------------------------------------------------------------------
-- 3) USUNIĘCIE KONTA: obserwacje zostają na mapie bez autora (wartość naukowa),
--    wszystko inne znika: pseudonim, zdjęcie, telefon, potwierdzenia, push, statystyki.
-- ---------------------------------------------------------------------
create or replace function dk_delete_me() returns void
language plpgsql security definer set search_path = public, extensions
as $$
declare v uuid := auth.uid();
begin
  if v is null then raise exception 'Brak sesji'; end if;
  delete from confirmations where user_id = v;
  update sightings set created_by = null where created_by = v;
  delete from push.subscriptions where user_id = v;
  delete from analytics.events where user_id = v;
  delete from profile_private where id = v;
  delete from profiles where id = v;
  begin
    delete from storage.objects where bucket_id = 'avatars' and (storage.foldername(name))[1] = v::text;
  exception when others then null;
  end;
  begin
    delete from auth.users where id = v;
  exception when others then null;
  end;
end;
$$;

-- Ranking ze zdjęciami profilowymi (stara wersja dk_leaderboard zostaje dla starszych aplikacji)
create or replace function dk_leaderboard_v2(
  p_since    timestamptz      default null,
  p_lat      double precision default null,
  p_lng      double precision default null,
  p_radius_m double precision default null
)
returns table (nickname text, avatar_url text, xp int, sightings int, species int, is_me boolean)
language sql stable security definer set search_path = public, extensions
as $$
  with scope as (
    select * from sightings
    where p_lat is null or p_lng is null
       or st_dwithin(location, st_setsrid(st_makepoint(p_lng, p_lat), 4326)::geography, coalesce(p_radius_m, 25000))
  ), s as (
    select created_by uid, count(*) n, count(*) filter (where photo_url is not null) ph, count(distinct species_id) sp
    from scope where created_by is not null and (p_since is null or seen_at >= p_since) group by created_by
  ), cg as (
    select c.user_id uid, count(*) n from confirmations c join scope si on si.id = c.sighting_id
    where p_since is null or c.created_at >= p_since group by c.user_id
  ), cr as (
    select si.created_by uid, count(*) n from confirmations c join scope si on si.id = c.sighting_id
    where p_since is null or c.created_at >= p_since group by si.created_by
  ), u as (select uid from s union select uid from cg union select uid from cr)
  select coalesce(p.nickname, 'Tropiciel #' || left(u.uid::text, 4)), p.avatar_url,
         (coalesce(s.n,0)*10 + coalesce(s.ph,0)*10 + coalesce(s.sp,0)*25 + coalesce(cg.n,0)*5 + coalesce(cr.n,0)*5)::int as xp,
         coalesce(s.n,0)::int, coalesce(s.sp,0)::int, u.uid = auth.uid()
  from u left join s using (uid) left join cg using (uid) left join cr using (uid)
  left join profiles p on p.id = u.uid
  where u.uid is not null
  order by xp desc limit 50;
$$;

-- ---------------------------------------------------------------------
-- 4) ANALITYKA — schemat „analytics” nie jest wystawiony w API Supabase,
--    aplikacja tylko dopisuje zdarzenia przez dk_track(); czytasz w SQL Editor.
-- ---------------------------------------------------------------------
create schema if not exists analytics;
revoke all on schema analytics from anon, authenticated;

create table if not exists analytics.events (
  id           bigint generated always as identity primary key,
  created_at   timestamptz not null default now(),
  client_ts    timestamptz,
  user_id      uuid,
  is_anonymous boolean,
  session_id   text,
  name         text not null,
  props        jsonb not null default '{}'::jsonb,
  platform     text,
  app_version  text,
  lang         text,
  tz           text
);
alter table analytics.events enable row level security;   -- dostęp tylko przez funkcje; z API niewidoczna
create index if not exists events_created_idx on analytics.events (created_at);
create index if not exists events_name_idx    on analytics.events (name, created_at);
create index if not exists events_user_idx    on analytics.events (user_id, created_at);

create or replace function analytics.try_ts(t text) returns timestamptz
language plpgsql immutable as $$
begin return t::timestamptz; exception when others then return null; end;
$$;

create or replace function dk_track(p_events jsonb) returns int
language plpgsql security definer set search_path = public, extensions
as $$
declare v_uid uuid := auth.uid(); v_n int;
begin
  if v_uid is null or jsonb_typeof(p_events) <> 'array' then return 0; end if;
  if jsonb_array_length(p_events) > 50 then raise exception 'Za dużo zdarzeń naraz'; end if;
  if exists (select 1 from profile_private where id = v_uid and not analytics_ok) then return 0; end if;
  -- ochrona przed zalewem: max 600 zdarzeń na użytkownika na godzinę
  if (select count(*) from analytics.events where user_id = v_uid and created_at > now() - interval '1 hour') > 600 then return 0; end if;

  insert into analytics.events (client_ts, user_id, is_anonymous, session_id, name, props, platform, app_version, lang, tz)
  select
    case when analytics.try_ts(e->>'ts') between now() - interval '7 days' and now() + interval '10 minutes'
         then analytics.try_ts(e->>'ts') end,
    v_uid, dk_is_anon(),
    left(e->>'sid', 40),
    e->>'name',
    case when jsonb_typeof(e->'props') = 'object' and pg_column_size(e->'props') < 4000 then e->'props' else '{}'::jsonb end,
    left(e->>'platform', 24), left(e->>'v', 16), left(e->>'lang', 8), left(e->>'tz', 40)
  from jsonb_array_elements(p_events) e
  where (e->>'name') ~ '^[a-z][a-z0-9_]{1,39}$';
  get diagnostics v_n = row_count;
  return v_n;
end;
$$;

-- Gotowe zestawienia (SQL Editor: select * from analytics.daily;)
create or replace view analytics.daily as
  with f as (select user_id, min(created_at)::date d0 from analytics.events group by user_id)
  select e.created_at::date as day,
         count(distinct e.user_id)                                              as active_users,
         count(distinct e.user_id) filter (where f.d0 = e.created_at::date)     as new_users,
         count(distinct e.session_id)                                           as sessions,
         count(*) filter (where e.name = 'report_submit')                       as sightings,
         count(*) filter (where e.name = 'account_verified')                    as accounts,
         count(*) filter (where e.name = 'push_subscribed')                     as push_optins
  from analytics.events e join f using (user_id)
  group by 1 order by 1 desc;

-- Retencja: jaki % nowych użytkowników wrócił po 1, 7 i 30 dniach
create or replace view analytics.retention as
  with f as (select user_id, min(created_at)::date d0 from analytics.events group by user_id),
       a as (select distinct user_id, created_at::date d from analytics.events)
  select f.d0 as cohort, count(*) as users,
         round(100.0 * count(*) filter (where exists (select 1 from a where a.user_id = f.user_id and a.d = f.d0 + 1))  / count(*), 1) as d1_pct,
         round(100.0 * count(*) filter (where exists (select 1 from a where a.user_id = f.user_id and a.d between f.d0 + 7 and f.d0 + 13)) / count(*), 1) as d7_pct,
         round(100.0 * count(*) filter (where exists (select 1 from a where a.user_id = f.user_id and a.d between f.d0 + 30 and f.d0 + 44)) / count(*), 1) as d30_pct
  from f group by 1 order by 1 desc;

-- Lejek nowego użytkownika (ostatnie 30 dni): gdzie odpadają
create or replace view analytics.funnel_new_user as
  with u as (
    select user_id,
      bool_or(name = 'app_open')            as opened,
      bool_or(name = 'onboarding_complete') as onboarded,
      bool_or(name = 'location_result' and props->>'result' = 'granted') as located,
      bool_or(name = 'report_start')        as started_report,
      bool_or(name = 'report_submit')       as reported,
      bool_or(name = 'account_verified')    as account,
      bool_or(name = 'push_subscribed')     as push
    from analytics.events where created_at > now() - interval '30 days'
    group by user_id
    having min(created_at) > now() - interval '30 days')
  select count(*) filter (where opened) as "1_opened", count(*) filter (where onboarded) as "2_onboarded",
         count(*) filter (where located) as "3_location_ok", count(*) filter (where started_report) as "4_report_started",
         count(*) filter (where reported) as "5_reported", count(*) filter (where account) as "6_account", count(*) filter (where push) as "7_push"
  from u;

-- Lejek zgłoszenia: ilu zaczyna, wybiera gatunek, wysyła (ostatnie 30 dni)
create or replace view analytics.funnel_report as
  select count(*) filter (where name = 'report_start')   as started,
         count(*) filter (where name = 'report_species') as species_chosen,
         count(*) filter (where name = 'report_submit')  as submitted,
         count(*) filter (where name = 'report_fail')    as failed
  from analytics.events where created_at > now() - interval '30 days';

-- Użytkownicy (do segmentów reklamowych i analizy): ostatni stan z app_open
create or replace view analytics.users as
  select distinct on (user_id) user_id,
    min(created_at) over (partition by user_id) as first_seen,
    max(created_at) over (partition by user_id) as last_seen,
    platform, lang, tz,
    (props->>'level')::int as level, (props->>'xp')::int as xp, (props->>'sightings')::int as sightings,
    (props->>'account')::boolean as has_account, (props->>'push')::boolean as push_on,
    (props->>'lat')::numeric as lat, (props->>'lng')::numeric as lng
  from analytics.events where name = 'app_open'
  order by user_id, created_at desc;

-- Najczęstsze zdarzenia (7 dni)
create or replace view analytics.top_events as
  select name, count(*) as events, count(distinct user_id) as users
  from analytics.events where created_at > now() - interval '7 days'
  group by name order by events desc;

-- ---------------------------------------------------------------------
-- 5) POWIADOMIENIA PUSH
-- ---------------------------------------------------------------------
create schema if not exists push;
revoke all on schema push from anon, authenticated;

create table if not exists push.subscriptions (
  id           bigint generated always as identity primary key,
  user_id      uuid not null,
  kind         text not null check (kind in ('webpush', 'fcm')),
  endpoint     text not null unique,     -- adres Web Push albo token FCM
  p256dh       text,
  auth         text,
  lang         text not null default 'pl',
  tz           text not null default 'Europe/Warsaw',
  lat          double precision,         -- zaokrąglone do ~10 km, tylko do „co nowego w okolicy”
  lng          double precision,
  prefs        jsonb not null default '{"streak":true,"nearby":true,"confirm":true,"weekly":true}'::jsonb,
  created_at   timestamptz not null default now(),
  last_seen_at timestamptz not null default now(),   -- ostatnie otwarcie aplikacji
  disabled_at  timestamptz,
  fail_count   int not null default 0
);
alter table push.subscriptions enable row level security;
create index if not exists push_subs_user_idx on push.subscriptions (user_id);

create table if not exists push.log (
  id       bigint generated always as identity primary key,
  sub_id   bigint references push.subscriptions(id) on delete cascade,
  user_id  uuid,
  kind     text,
  sent_at  timestamptz not null default now(),
  ok       boolean,
  error    text
);
alter table push.log enable row level security;
create index if not exists push_log_user_idx on push.log (user_id, sent_at desc);

-- Zapis/odświeżenie subskrypcji (wołane przy każdym otwarciu aplikacji, jeśli push jest włączony)
create or replace function dk_push_subscribe(
  p_kind text, p_endpoint text, p_p256dh text default null, p_auth text default null,
  p_lang text default 'pl', p_tz text default 'Europe/Warsaw',
  p_lat double precision default null, p_lng double precision default null,
  p_prefs jsonb default null
) returns void
language plpgsql security definer set search_path = public, extensions
as $$
declare v_tz text;
begin
  if auth.uid() is null then raise exception 'Brak sesji'; end if;
  if p_kind not in ('webpush', 'fcm') then raise exception 'Nieznany typ'; end if;
  if p_endpoint is null or length(p_endpoint) > 1000
     or (p_kind = 'webpush' and p_endpoint !~ '^https://') then raise exception 'Nieprawidłowa subskrypcja'; end if;
  select name into v_tz from pg_timezone_names where name = p_tz;
  insert into push.subscriptions as s (user_id, kind, endpoint, p256dh, auth, lang, tz, lat, lng, prefs)
  values (auth.uid(), p_kind, p_endpoint, left(p_p256dh, 200), left(p_auth, 100),
          case when p_lang in ('pl', 'en') then p_lang else 'en' end, coalesce(v_tz, 'UTC'),
          round(p_lat::numeric, 1), round(p_lng::numeric, 1),
          coalesce(p_prefs, '{"streak":true,"nearby":true,"confirm":true,"weekly":true}'::jsonb))
  on conflict (endpoint) do update set
    user_id = excluded.user_id, p256dh = excluded.p256dh, auth = excluded.auth,
    lang = excluded.lang, tz = excluded.tz,
    lat = coalesce(excluded.lat, s.lat), lng = coalesce(excluded.lng, s.lng),
    prefs = coalesce(p_prefs, s.prefs),
    last_seen_at = now(), disabled_at = null, fail_count = 0;
end;
$$;

create or replace function dk_push_unsubscribe(p_endpoint text) returns void
language sql security definer set search_path = public, extensions
as $$ update push.subscriptions set disabled_at = now() where endpoint = p_endpoint and user_id = auth.uid(); $$;

-- Komu i co wysłać teraz. Zasady:
--  • tylko 10:00–19:59 czasu lokalnego, max 1 powiadomienie na 20 h na osobę;
--  • kolejność: potwierdzenie obserwacji → seria dni → powrót po przerwie (3/7/14 dni) → nowe wyzwania (poniedziałek).
create or replace function dk_push_due()
returns table (sub_id bigint, user_id uuid, kind text, channel text, endpoint text, p256dh text, auth text, lang text, n int)
language sql stable security definer set search_path = public, extensions
as $$
  with s as (
    select ps.*, (now() at time zone ps.tz) as lt
    from push.subscriptions ps
    where ps.disabled_at is null
  ), e as (
    select s.* from s
    where extract(hour from s.lt) between 10 and 19
      and not exists (select 1 from push.log l where l.user_id = s.user_id and l.ok and l.sent_at > now() - interval '20 hours')
  ), c as (   -- nowe potwierdzenia cudzych osób dla moich obserwacji
    select e.id, count(*)::int n from e
    join sightings si on si.created_by = e.user_id
    join confirmations co on co.sighting_id = si.id
    where (e.prefs->>'confirm')::boolean is not false
      and co.created_at > greatest(e.last_seen_at,
            coalesce((select max(l.sent_at) from push.log l where l.user_id = e.user_id and l.kind = 'confirm' and l.ok), '-infinity'))
    group by e.id
  ), d as (   -- dni (lokalnie) z obserwacjami w ostatnich 60 dniach
    select e.id, (si.seen_at at time zone e.tz)::date as day
    from e join sightings si on si.created_by = e.user_id
    where si.seen_at > now() - interval '61 days'
    group by 1, 2
  ), st as (  -- seria: wczoraj była obserwacja, dziś jeszcze nie, jest po 17:00
    select e.id, (select count(*)::int from (
              select day, row_number() over (order by day desc) rn from d where d.id = e.id and d.day < e.lt::date) x
            where x.day = e.lt::date - x.rn::int) as n
    from e
    where (e.prefs->>'streak')::boolean is not false
      and extract(hour from e.lt) >= 17
      and exists (select 1 from d where d.id = e.id and d.day = e.lt::date - 1)
      and not exists (select 1 from d where d.id = e.id and d.day = e.lt::date)
  ), ia as (  -- powrót po przerwie: 1. po 3 dniach, 2. po 7, 3. po 14 — potem cisza do następnego otwarcia
    select e.id, cnt,
      (select count(*)::int from sightings si
        where e.lat is not null and (e.prefs->>'nearby')::boolean is not false
          and si.seen_at > now() - interval '7 days' and si.created_by is distinct from e.user_id
          and st_dwithin(si.location, st_setsrid(st_makepoint(e.lng, e.lat), 4326)::geography, 15000)) as n
    from e, lateral (select count(*)::int cnt from push.log l
                     where l.user_id = e.user_id and l.kind = 'inactive' and l.ok and l.sent_at > e.last_seen_at) k
    where now() - e.last_seen_at >= case k.cnt when 0 then interval '3 days' when 1 then interval '7 days' when 2 then interval '14 days' end
      and not exists (select 1 from push.log l where l.user_id = e.user_id and l.kind = 'inactive' and l.sent_at > now() - interval '3 days')
  ), wk as (  -- poniedziałek rano: nowe wyzwania (aktywni w ostatnich 30 dniach)
    select e.id from e
    where (e.prefs->>'weekly')::boolean is not false
      and extract(isodow from e.lt) = 1 and extract(hour from e.lt) between 10 and 12
      and e.last_seen_at > now() - interval '30 days'
      and not exists (select 1 from push.log l where l.user_id = e.user_id and l.kind = 'weekly' and l.sent_at > now() - interval '6 days')
  )
  select e.id, e.user_id,
         case when c.id is not null then 'confirm' when st.id is not null then 'streak'
              when ia.id is not null then 'inactive' else 'weekly' end,
         e.kind, e.endpoint, e.p256dh, e.auth, e.lang,
         coalesce(c.n, st.n, ia.n, 0)
  from e
  left join c  on c.id  = e.id
  left join st on st.id = e.id
  left join ia on ia.id = e.id
  left join wk on wk.id = e.id
  where c.id is not null or st.id is not null or ia.id is not null or wk.id is not null;
$$;

-- Wynik wysyłki: [{"sub_id":1,"kind":"streak","ok":true}, {"sub_id":2,"kind":"weekly","ok":false,"gone":true,"error":"410"}]
create or replace function dk_push_mark(p_results jsonb) returns void
language plpgsql security definer set search_path = public, extensions
as $$
begin
  insert into push.log (sub_id, user_id, kind, ok, error)
  select (r->>'sub_id')::bigint, s.user_id, r->>'kind', coalesce((r->>'ok')::boolean, false), left(r->>'error', 300)
  from jsonb_array_elements(p_results) r join push.subscriptions s on s.id = (r->>'sub_id')::bigint;

  update push.subscriptions s set
    fail_count  = case when coalesce((r->>'ok')::boolean, false) then 0 else s.fail_count + 1 end,
    disabled_at = case when coalesce((r->>'gone')::boolean, false) or (not coalesce((r->>'ok')::boolean, false) and s.fail_count >= 4)
                       then now() else s.disabled_at end
  from jsonb_array_elements(p_results) r
  where s.id = (r->>'sub_id')::bigint;
end;
$$;

-- Statystyki przechowujemy do 24 miesięcy (polityka prywatności). Jeśli w projekcie jest pg_cron
-- (Database → Extensions → pg_cron), czyszczenie ustawi się samo raz w tygodniu.
create or replace function analytics.cleanup() returns void language sql as $$
  delete from analytics.events where created_at < now() - interval '24 months';
  delete from push.log where sent_at < now() - interval '12 months';
$$;
do $$
begin
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    perform cron.schedule('tropami-analytics-cleanup', '17 3 * * 0', 'select analytics.cleanup()');
  end if;
exception when others then null;
end $$;

-- ---------------------------------------------------------------------
-- 6) UPRAWNIENIA (Supabase domyślnie daje wszystkim prawo wywołania funkcji — zawężamy)
-- ---------------------------------------------------------------------
revoke execute on function dk_get_profile()                                    from public, anon;
revoke execute on function dk_save_profile(text, text, text, boolean, boolean) from public, anon;
revoke execute on function dk_merge_start()                                    from public, anon;
revoke execute on function dk_merge_finish(uuid)                               from public, anon;
revoke execute on function dk_delete_me()                                      from public, anon;
revoke execute on function dk_track(jsonb)                                     from public, anon;
revoke execute on function dk_push_subscribe(text, text, text, text, text, text, double precision, double precision, jsonb) from public, anon;
revoke execute on function dk_push_unsubscribe(text)                           from public, anon;
revoke execute on function dk_push_due()                                       from public, anon, authenticated;
revoke execute on function dk_push_mark(jsonb)                                 from public, anon, authenticated;

grant execute on function dk_is_anon()                                         to authenticated;
grant execute on function dk_get_profile()                                     to authenticated;
grant execute on function dk_save_profile(text, text, text, boolean, boolean)  to authenticated;
grant execute on function dk_merge_start()                                     to authenticated;
grant execute on function dk_merge_finish(uuid)                                to authenticated;
grant execute on function dk_delete_me()                                       to authenticated;
grant execute on function dk_track(jsonb)                                      to authenticated;
grant execute on function dk_push_subscribe(text, text, text, text, text, text, double precision, double precision, jsonb) to authenticated;
grant execute on function dk_push_unsubscribe(text)                            to authenticated;
grant execute on function dk_leaderboard_v2(timestamptz, double precision, double precision, double precision) to anon, authenticated;
grant usage on schema push to service_role;
grant execute on function dk_push_due()                                        to service_role;
grant execute on function dk_push_mark(jsonb)                                  to service_role;

-- Sprawdzenie: powinny pojawić się 3 wiersze (avatars, analytics, push)
select 'avatars' as part, exists (select 1 from storage.buckets where id = 'avatars') as ok
union all select 'analytics', to_regclass('analytics.events') is not null
union all select 'push', to_regclass('push.subscriptions') is not null;
