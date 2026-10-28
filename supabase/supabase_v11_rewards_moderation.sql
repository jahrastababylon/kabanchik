-- =====================================================================
-- Tropami v11 — nowe nagrody, zaproszenia, ślady, podstawy moderacji zdjęć
-- Uruchom PO v10 (supabase_v10_open_data_xp.sql). Można uruchamiać wielokrotnie.
--
-- Punkty (XP), tak samo w aplikacji i w rankingu:
--   obserwacja albo ślady 10 · zdjęcie 10 (dzik i wilk: 10 także bez zdjęcia — nie podchodź!)
--   potwierdzenie dane 5 / otrzymane 5 · dzień w aplikacji 3 · co 7 dni serii +15
--   zagadka dnia 5 (dobra odpowiedź) / 2 (próba) · udostępnienie 5 (raz dziennie)
--   znajomy z Twojego zaproszenia, który zgłosił pierwszą obserwację: +30 · start z zaproszenia: +10
--   Nie ma już punktów za nowy gatunek ani za rzadkość.
-- =====================================================================

-- 0) Testowe obserwacje sprzed startu (konta Tropiciel #889a i #c7a8). Zdjęcia ze Storage są już usunięte.
delete from confirmations where sighting_id in (
  '292741e2-a436-4019-a244-ffec74d39e10','8ec13897-46ea-4b89-88a7-d4b1bee089f4','ee65f0bb-4843-4b00-ba4f-e15089c3d8ca',
  '48043070-1594-418a-80d4-582bd18c6435','f4c925d8-ab2c-4b4a-adc6-f3f0d73348c7','925a962b-652c-45fa-b299-4c9d2d73e8d8');
delete from sightings where id in (
  '292741e2-a436-4019-a244-ffec74d39e10','8ec13897-46ea-4b89-88a7-d4b1bee089f4','ee65f0bb-4843-4b00-ba4f-e15089c3d8ca',
  '48043070-1594-418a-80d4-582bd18c6435','f4c925d8-ab2c-4b4a-adc6-f3f0d73348c7','925a962b-652c-45fa-b299-4c9d2d73e8d8');

-- 1) Ślady zamiast zwierzęcia (tropy, ryjowisko, nora, gniazdo) + status zdjęcia -----------------
alter table sightings add column if not exists evidence     text not null default 'seen';
alter table sightings add column if not exists photo_status text not null default 'visible';
do $$ begin
  alter table sightings add constraint sightings_evidence_chk check (evidence in ('seen','traces'));
exception when duplicate_object then null; end $$;
do $$ begin
  alter table sightings add constraint sightings_photo_status_chk check (photo_status in ('visible','pending','hidden'));
exception when duplicate_object then null; end $$;

-- 2) Moderacja zdjęć — na razie wyłączona, ale gotowa do włączenia ---------------------------------
--   Włączenie wstępnej moderacji (nowe zdjęcia czekają na akceptację):
--     update app_settings set value = 'true' where key = 'photo_premoderation';
--   Akceptacja / ukrycie: w Table Editor → sightings → kolumna photo_status = visible / hidden
--   Kolejka do sprawdzenia: select * from moderation_queue;
create table if not exists app_settings (
  key text primary key, value jsonb not null, updated_at timestamptz not null default now());
alter table app_settings enable row level security;
revoke all on app_settings from anon, authenticated;
insert into app_settings (key, value) values ('photo_premoderation', 'false') on conflict (key) do nothing;
insert into app_settings (key, value) values ('photo_report_hide_at', '3')    on conflict (key) do nothing;

create table if not exists photo_reports (
  sighting_id uuid not null references sightings(id) on delete cascade,
  user_id     uuid not null,
  reason      text,
  created_at  timestamptz not null default now(),
  primary key (sighting_id, user_id)
);
alter table photo_reports enable row level security;
revoke all on photo_reports from anon, authenticated;

create or replace function dk_photo_status_default() returns trigger
language plpgsql security definer set search_path = public, extensions
as $$
begin
  if new.photo_url is not null and new.created_by is not null
     and (tg_op = 'INSERT' or new.photo_url is distinct from old.photo_url)
     and coalesce((select (value #>> '{}')::boolean from app_settings where key = 'photo_premoderation'), false)
  then new.photo_status := 'pending'; end if;
  return new;
end;
$$;
drop trigger if exists trg_photo_status on sightings;
create trigger trg_photo_status before insert or update of photo_url on sightings
  for each row execute function dk_photo_status_default();

-- Zgłoszenie zdjęcia przez użytkownika; po N zgłoszeniach zdjęcie znika do czasu sprawdzenia
create or replace function dk_report_photo(p_sighting uuid, p_reason text) returns int
language plpgsql security definer set search_path = public, extensions
as $$
declare v_n int; v_lim int;
begin
  if auth.uid() is null then return 0; end if;
  if exists (select 1 from sightings where id = p_sighting and created_by = auth.uid()) then return 0; end if;
  insert into photo_reports (sighting_id, user_id, reason) values (p_sighting, auth.uid(), left(p_reason, 40))
    on conflict do nothing;
  select count(*) into v_n from photo_reports where sighting_id = p_sighting;
  v_lim := coalesce((select (value #>> '{}')::int from app_settings where key = 'photo_report_hide_at'), 3);
  if v_n >= v_lim then update sightings set photo_status = 'hidden' where id = p_sighting and photo_status = 'visible'; end if;
  return v_n;
end;
$$;

-- Zdjęcie do karty: tylko zaakceptowane (albo własne)
create or replace function dk_sighting_photo(p_id uuid) returns text
language sql stable security definer set search_path = public, extensions
as $$
  select photo_url from sightings
  where id = p_id and (photo_status = 'visible' or created_by = auth.uid());
$$;

create or replace view moderation_queue as
  select s.id, s.created_at, s.photo_status, s.photo_url, sp.name_pl, s.taxon, p.nickname,
         (select count(*) from photo_reports r where r.sighting_id = s.id) as reports,
         (select string_agg(distinct r.reason, ', ') from photo_reports r where r.sighting_id = s.id) as reasons
  from sightings s join species sp on sp.id = s.species_id left join profiles p on p.id = s.created_by
  where s.photo_url is not null
    and (s.photo_status <> 'visible' or exists (select 1 from photo_reports r where r.sighting_id = s.id))
  order by reports desc, s.created_at desc;
revoke all on moderation_queue from anon, authenticated;

-- 3) Dodawanie i odczyt obserwacji z rodzajem (zwierzę / ślady) ------------------------------------
create or replace function dk_add_sighting_v4(
  p_species uuid, p_lat double precision, p_lng double precision, p_behavior text, p_photo text,
  p_seen_at timestamptz, p_taxon text, p_taxon_sci text, p_taxon_inat integer, p_evidence text
) returns uuid
language plpgsql security definer set search_path = public, extensions
as $$
declare v_id uuid;
begin
  v_id := dk_add_sighting_v3(p_species, p_lat, p_lng, p_behavior, p_photo, p_seen_at, p_taxon, p_taxon_sci, p_taxon_inat);
  update sightings set evidence = case when p_evidence = 'traces' then 'traces' else 'seen' end
   where id = v_id and created_by = auth.uid();
  return v_id;
end;
$$;

create or replace function dk_my_sightings_v4()
returns table (
  id uuid, species_id uuid, taxon text, taxon_sci text, taxon_inat integer, lat double precision, lng double precision,
  behavior text, has_photo boolean, seen_at timestamptz, confirmed_count int, nickname text, confirmed_by_me boolean,
  is_mine boolean, evidence text, photo_status text
)
language sql stable security definer set search_path = public, extensions
as $$
  select s.id, s.species_id, s.taxon, s.taxon_sci, s.taxon_inat,
         st_y(s.location::geometry), st_x(s.location::geometry),
         s.behavior, (s.photo_url is not null), s.seen_at,
         (select count(*)::int from confirmations c where c.sighting_id = s.id),
         coalesce(p.nickname, 'Ty'), false, true, s.evidence, s.photo_status
  from sightings s left join profiles p on p.id = s.created_by
  where auth.uid() is not null and s.created_by = auth.uid()
  order by s.seen_at desc;
$$;

create or replace function dk_sightings_in_bbox_v5(
  p_w double precision, p_s double precision, p_e double precision, p_n double precision, p_limit int default 3000)
returns table (
  id uuid, species_id uuid, taxon text, taxon_sci text, taxon_inat integer, lat double precision, lng double precision,
  behavior text, has_photo boolean, seen_at timestamptz, confirmed_count int, nickname text, confirmed_by_me boolean, is_mine boolean,
  source text, source_url text, license text, evidence text
)
language sql stable security definer set search_path = public, extensions
as $$
  select s.id, s.species_id, s.taxon, s.taxon_sci, s.taxon_inat,
         st_y(s.location::geometry), st_x(s.location::geometry),
         s.behavior,
         (s.photo_url is not null and (s.photo_status = 'visible' or s.created_by = auth.uid())),
         s.seen_at,
         (select count(*)::int from confirmations c where c.sighting_id = s.id),
         case when s.source is not null then s.observer
              else coalesce(p.nickname, 'Tropiciel #' || left(s.created_by::text, 4)) end,
         exists (select 1 from confirmations c where c.sighting_id = s.id and c.user_id = auth.uid()),
         coalesce(s.created_by = auth.uid(), false),
         s.source, s.source_url, s.license, s.evidence
  from sightings s
  left join profiles p on p.id = s.created_by
  where s.location::geometry && (
    case when p_w <= p_e then st_makeenvelope(p_w, p_s, p_e, p_n, 4326)
      else st_collect(st_makeenvelope(p_w, p_s, 180, p_n, 4326), st_makeenvelope(-180, p_s, p_e, p_n, 4326)) end)
  order by s.seen_at desc
  limit least(greatest(p_limit, 1), 5000);
$$;

-- 4) Premie: seria 7 dni, zagadka dnia, udostępnienie ----------------------------------------------
create table if not exists xp_bonus (
  user_id uuid not null,
  kind    text not null,           -- streak7 | quiz | share
  day     date not null,
  xp      int  not null,
  created_at timestamptz not null default now(),
  primary key (user_id, kind, day)
);
alter table xp_bonus enable row level security;
revoke all on xp_bonus from anon, authenticated;

-- Wejście do aplikacji (+3) — i co 7. dzień serii premia +15
create or replace function dk_checkin(p_day date) returns boolean
language plpgsql security definer set search_path = public, extensions
as $$
declare v int; v_streak int;
begin
  if auth.uid() is null or p_day is null or abs(p_day - (now() at time zone 'utc')::date) > 1 then return false; end if;
  insert into profiles (id) values (auth.uid()) on conflict (id) do nothing;
  insert into daily_checkins (user_id, day) values (auth.uid(), p_day) on conflict do nothing;
  get diagnostics v = row_count;
  if v > 0 then
    select count(*) into v_streak from (
      select day, row_number() over (order by day desc) rn
      from daily_checkins where user_id = auth.uid() and day <= p_day and day > p_day - 400) x
    where x.day = p_day - (x.rn::int - 1);
    if v_streak > 0 and v_streak % 7 = 0 then
      insert into xp_bonus (user_id, kind, day, xp) values (auth.uid(), 'streak7', p_day, 15) on conflict do nothing;
    end if;
  end if;
  return v > 0;
end;
$$;

-- p_kind: quiz (p_ok = dobra odpowiedź) | share. Raz dziennie każdego rodzaju.
create or replace function dk_bonus_claim(p_kind text, p_day date, p_ok boolean default null) returns int
language plpgsql security definer set search_path = public, extensions
as $$
declare v_xp int; v int;
begin
  if auth.uid() is null or p_day is null or abs(p_day - (now() at time zone 'utc')::date) > 1 then return 0; end if;
  v_xp := case p_kind when 'quiz' then case when p_ok then 5 else 2 end when 'share' then 5 else 0 end;
  if v_xp = 0 then return 0; end if;
  insert into profiles (id) values (auth.uid()) on conflict (id) do nothing;
  insert into xp_bonus (user_id, kind, day, xp) values (auth.uid(), p_kind, p_day, v_xp) on conflict do nothing;
  get diagnostics v = row_count;
  return case when v > 0 then v_xp else 0 end;
end;
$$;

-- 5) Zaproszenia ------------------------------------------------------------------------------------
create table if not exists ref_codes (
  user_id uuid primary key,
  code    text not null unique,
  created_at timestamptz not null default now()
);
create table if not exists referrals (
  referee  uuid primary key,          -- kto przyszedł z linku
  referrer uuid not null,             -- kto zaprosił
  code     text,
  created_at timestamptz not null default now()
);
alter table ref_codes enable row level security;
alter table referrals enable row level security;
revoke all on ref_codes from anon, authenticated;
revoke all on referrals from anon, authenticated;

create or replace function dk_my_ref_code() returns text
language plpgsql security definer set search_path = public, extensions
as $$
declare v text; a text := 'abcdefghjkmnpqrstuvwxyz23456789'; i int;
begin
  if auth.uid() is null then return null; end if;
  select code into v from ref_codes where user_id = auth.uid();
  if v is not null then return v; end if;
  loop
    v := '';
    for i in 1..6 loop v := v || substr(a, 1 + floor(random() * length(a))::int, 1); end loop;
    begin
      insert into ref_codes (user_id, code) values (auth.uid(), v);
      return v;
    exception when unique_violation then
      select code into v from ref_codes where user_id = auth.uid();
      if v is not null then return v; end if;
    end;
  end loop;
end;
$$;

-- Zgłasza, że ten użytkownik przyszedł z zaproszenia. Tylko nowe konto (bez obserwacji), raz.
create or replace function dk_referral_claim(p_code text) returns boolean
language plpgsql security definer set search_path = public, extensions
as $$
declare v_ref uuid; v int;
begin
  if auth.uid() is null or p_code is null then return false; end if;
  select user_id into v_ref from ref_codes where code = lower(btrim(p_code));
  if v_ref is null or v_ref = auth.uid() then return false; end if;
  if exists (select 1 from sightings where created_by = auth.uid()) then return false; end if;
  if exists (select 1 from referrals where referee = v_ref and referrer = auth.uid()) then return false; end if; -- bez „zapraszania się nawzajem”
  insert into profiles (id) values (auth.uid()) on conflict (id) do nothing;
  insert into referrals (referee, referrer, code) values (auth.uid(), v_ref, lower(btrim(p_code))) on conflict do nothing;
  get diagnostics v = row_count;
  return v > 0;
end;
$$;

-- Wszystko, czego aplikacja potrzebuje do policzenia premii
create or replace function dk_my_rewards() returns jsonb
language sql stable security definer set search_path = public, extensions
as $$
  select jsonb_build_object(
    'bonus', coalesce((select jsonb_agg(jsonb_build_object('kind', kind, 'day', day, 'xp', xp) order by day desc)
                       from xp_bonus where user_id = auth.uid() and day > current_date - 400), '[]'::jsonb),
    'invited_total', (select count(*) from referrals where referrer = auth.uid()),
    'invited_ok', (select count(*) from referrals r where r.referrer = auth.uid()
                     and exists (select 1 from sightings s where s.created_by = r.referee)),
    'referred', exists (select 1 from referrals where referee = auth.uid()),
    'ref_code', (select code from ref_codes where user_id = auth.uid()),
    'shares', (select count(*) from xp_bonus where user_id = auth.uid() and kind = 'share'),
    'quiz_ok', (select count(*) from xp_bonus where user_id = auth.uid() and kind = 'quiz' and xp = 5)
  );
$$;

-- 6) Ranking według nowych zasad ------------------------------------------------------------------
create or replace function dk_leaderboard_v4(
  p_since timestamptz default null, p_lat double precision default null, p_lng double precision default null, p_radius_m double precision default null)
returns table (nickname text, avatar_url text, xp int, sightings int, species int, is_me boolean)
language sql stable security definer set search_path = public, extensions
as $$
  with scope as (
    select si.*, sp.name_pl from sightings si join species sp on sp.id = si.species_id
    where si.created_by is not null
      and (p_lat is null or p_lng is null
           or st_dwithin(si.location, st_setsrid(st_makepoint(p_lng, p_lat), 4326)::geography, coalesce(p_radius_m, 25000)))
  ), s as (
    select created_by uid, count(*) n,
           count(*) filter (where photo_url is not null or name_pl in ('Dzik','Wilk')) ph,
           count(distinct species_id) sp
    from scope where p_since is null or seen_at >= p_since group by created_by
  ), cg as (
    select c.user_id uid, count(*) n from confirmations c join scope si on si.id = c.sighting_id
    where p_since is null or c.created_at >= p_since group by c.user_id
  ), cr as (
    select si.created_by uid, count(*) n from confirmations c join scope si on si.id = c.sighting_id
    where p_since is null or c.created_at >= p_since group by si.created_by
  ), bo0 as (
    select b.user_id uid, sum(b.xp) n from xp_bonus b
    where p_since is null or b.day >= p_since::date group by b.user_id
  ), inv0 as (
    select r.referrer uid, count(*) n from referrals r
    where (p_since is null or r.created_at >= p_since)
      and exists (select 1 from sightings x where x.created_by = r.referee) group by r.referrer
  ),
  -- w rankingu „okolica” liczą się osoby z obserwacjami w okolicy; w „świecie” także ci, którzy zbierają premie
  u as (select uid from s union select uid from cg union select uid from cr
        union select uid from bo0 where p_lat is null or p_lng is null
        union select uid from inv0 where p_lat is null or p_lng is null),
  ck as (
    select d.user_id uid, count(*) n from daily_checkins d join u on u.uid = d.user_id
    where p_since is null or d.day >= p_since::date group by d.user_id
  ), bo as (select bo0.* from bo0 join u using (uid)
  ), inv as (select inv0.* from inv0 join u using (uid)
  ), wel as (
    select r.referee uid, 1 n from referrals r join u on u.uid = r.referee
    where p_since is null or r.created_at >= p_since
  )
  select coalesce(p.nickname, 'Tropiciel #' || left(u.uid::text, 4)), p.avatar_url,
         (coalesce(s.n,0)*10 + coalesce(s.ph,0)*10 + coalesce(cg.n,0)*5 + coalesce(cr.n,0)*5 + coalesce(ck.n,0)*3
          + coalesce(bo.n,0) + coalesce(inv.n,0)*30 + coalesce(wel.n,0)*10)::int as xp,
         coalesce(s.n,0)::int, coalesce(s.sp,0)::int, u.uid = auth.uid()
  from u left join s using (uid) left join cg using (uid) left join cr using (uid) left join ck using (uid)
         left join bo using (uid) left join inv using (uid) left join wel using (uid)
  left join profiles p on p.id = u.uid
  where u.uid is not null
  order by xp desc limit 50;
$$;

-- 7) Przeniesienie postępów i usunięcie konta — z premiami i zaproszeniami ------------------------
create or replace function dk_merge_finish(p_ticket uuid) returns int
language plpgsql security definer set search_path = public, extensions
as $$
declare v_new uuid := auth.uid(); v_old uuid; v_n int := 0;
begin
  if v_new is null or dk_is_anon() then raise exception 'Najpierw zaloguj się e-mailem'; end if;
  select anon_id into v_old from account_merge_tickets
   where ticket = p_ticket and used_at is null and created_at > now() - interval '2 hours' for update;
  if v_old is null or v_old = v_new then return 0; end if;
  delete from confirmations c where c.user_id = v_old and (
    exists (select 1 from confirmations c2 where c2.sighting_id = c.sighting_id and c2.user_id = v_new)
    or exists (select 1 from sightings s where s.id = c.sighting_id and s.created_by = v_new));
  delete from confirmations c where c.user_id = v_new
    and exists (select 1 from sightings s where s.id = c.sighting_id and s.created_by = v_old);
  update confirmations set user_id = v_new where user_id = v_old;
  update sightings set created_by = v_new where created_by = v_old;
  get diagnostics v_n = row_count;
  insert into daily_checkins (user_id, day) select v_new, day from daily_checkins where user_id = v_old on conflict do nothing;
  delete from daily_checkins where user_id = v_old;
  insert into xp_bonus (user_id, kind, day, xp, created_at) select v_new, kind, day, xp, created_at from xp_bonus where user_id = v_old on conflict do nothing;
  delete from xp_bonus where user_id = v_old;
  -- zaproszenia: kod zostaje ten z konta (jeśli był), inaczej przechodzi z urządzenia
  if not exists (select 1 from ref_codes where user_id = v_new) then update ref_codes set user_id = v_new where user_id = v_old;
  else
    update referrals set code = (select code from ref_codes where user_id = v_new) where referrer = v_old;
    delete from ref_codes where user_id = v_old;
  end if;
  update referrals set referrer = v_new where referrer = v_old and referee <> v_new;
  delete from referrals where referrer = v_old;
  if not exists (select 1 from referrals where referee = v_new) then
    update referrals set referee = v_new where referee = v_old and referrer <> v_new;
  end if;
  delete from referrals where referee = v_old;
  update photo_reports r set user_id = v_new where user_id = v_old
    and not exists (select 1 from photo_reports r2 where r2.sighting_id = r.sighting_id and r2.user_id = v_new);
  delete from photo_reports where user_id = v_old;
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
  begin delete from auth.users where id = v_old and is_anonymous; exception when others then null; end;
  return v_n;
end;
$$;

create or replace function dk_delete_me() returns void
language plpgsql security definer set search_path = public, extensions
as $$
declare v uuid := auth.uid();
begin
  if v is null then raise exception 'Brak sesji'; end if;
  delete from confirmations where user_id = v;
  update sightings set created_by = null where created_by = v;
  delete from daily_checkins where user_id = v;
  delete from xp_bonus where user_id = v;
  delete from referrals where referee = v or referrer = v;
  delete from ref_codes where user_id = v;
  delete from photo_reports where user_id = v;
  delete from push.subscriptions where user_id = v;
  delete from analytics.events where user_id = v;
  delete from profile_private where id = v;
  delete from profiles where id = v;
  begin delete from storage.objects where bucket_id = 'avatars' and (storage.foldername(name))[1] = v::text; exception when others then null; end;
  begin delete from auth.users where id = v; exception when others then null; end;
end;
$$;

-- 8) Uprawnienia ------------------------------------------------------------------------------------
revoke execute on function dk_photo_status_default()                  from public, anon, authenticated;
revoke execute on function dk_report_photo(uuid, text)                from public, anon;
revoke execute on function dk_bonus_claim(text, date, boolean)        from public, anon;
revoke execute on function dk_my_ref_code()                           from public, anon;
revoke execute on function dk_referral_claim(text)                    from public, anon;
revoke execute on function dk_my_rewards()                            from public, anon;
revoke execute on function dk_my_sightings_v4()                       from public, anon;
revoke execute on function dk_add_sighting_v4(uuid, double precision, double precision, text, text, timestamptz, text, text, integer, text) from public, anon;
grant execute on function dk_report_photo(uuid, text)                 to authenticated;
grant execute on function dk_sighting_photo(uuid)                     to anon, authenticated;
grant execute on function dk_bonus_claim(text, date, boolean)         to authenticated;
grant execute on function dk_checkin(date)                            to authenticated;
grant execute on function dk_my_ref_code()                            to authenticated;
grant execute on function dk_referral_claim(text)                     to authenticated;
grant execute on function dk_my_rewards()                             to authenticated;
grant execute on function dk_my_sightings_v4()                        to authenticated;
grant execute on function dk_add_sighting_v4(uuid, double precision, double precision, text, text, timestamptz, text, text, integer, text) to authenticated;
grant execute on function dk_sightings_in_bbox_v5(double precision, double precision, double precision, double precision, int) to anon, authenticated;
grant execute on function dk_leaderboard_v4(timestamptz, double precision, double precision, double precision) to anon, authenticated;

-- Sprawdzenie
select 'v11' as wersja,
       (select count(*) from sightings where source is null) as obserwacje_z_aplikacji,
       (select count(*) from sightings where source is not null) as z_otwartych_danych,
       (select value from app_settings where key = 'photo_premoderation') as premoderacja;
