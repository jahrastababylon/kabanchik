-- =====================================================================
-- Tropami — SQL v10 (po v8 i v9). Uruchom raz: Supabase → SQL Editor → Run. Nic nie usuwa.
--  1) Częste gatunki miejskie: Wiewiórka 🐿️ i Jeż 🦔
--  2) Obserwacje z otwartych danych (GBIF/iNaturalist, licencje CC0/CC BY) — z prawdziwą datą,
--     miejscem i autorem; oznaczone jako import, poza rankingiem i raportami
--  3) XP: premia za rzadkość gatunku, każdy nowy gatunek (także ptak) się liczy
--  4) Codzienne wejście do aplikacji: +3 XP i seria dni (nie trzeba codziennie spotykać zwierząt)
-- =====================================================================
set search_path = public, extensions;

-- 1) Nowe gatunki -------------------------------------------------------
insert into species (name_pl, icon, danger_level)
select v.n, v.i, 0 from (values ('Wiewiórka','🐿️'), ('Jeż','🦔')) v(n, i)
where not exists (select 1 from species s where s.name_pl = v.n);

-- 2) Import otwartych danych ---------------------------------------------
alter table sightings add column if not exists source     text;   -- null = zgłoszenie w Tropami
alter table sightings add column if not exists source_id  text;
alter table sightings add column if not exists source_url text;
alter table sightings add column if not exists observer   text;
alter table sightings add column if not exists license    text;
create unique index if not exists sightings_source_id_uidx on sightings (source_id) where source_id is not null;

-- [{"source":"gbif","source_id":"gbif:123","source_url":"…","observer":"…","license":"CC BY 4.0",
--   "species":"Ptak","taxon":"Sroka","taxon_sci":"Pica pica","lat":50.06,"lng":19.94,"seen_at":"2026-10-20T08:00:00Z"}]
create or replace function dk_import_sightings(p jsonb) returns int
language plpgsql security definer set search_path = public, extensions
as $$
declare v_n int;
begin
  insert into sightings (species_id, location, seen_at, created_at, source, source_id, source_url, observer, license, taxon, taxon_sci, has_photo)
  select sp.id, st_setsrid(st_makepoint((e->>'lng')::float8, (e->>'lat')::float8), 4326)::geography,
         (e->>'seen_at')::timestamptz, now(),
         left(e->>'source', 20), left(e->>'source_id', 80), left(e->>'source_url', 300), left(e->>'observer', 80), left(e->>'license', 40),
         nullif(left(e->>'taxon', 80), ''), nullif(left(e->>'taxon_sci', 120), ''), false
  from jsonb_array_elements(p) e
  join species sp on sp.name_pl = e->>'species'
  where (e->>'lat')::float8 between -85 and 85 and (e->>'lng')::float8 between -180 and 180
    and (e->>'seen_at')::timestamptz < now() + interval '1 day'
  on conflict (source_id) where source_id is not null do nothing;
  get diagnostics v_n = row_count;
  return v_n;
end;
$$;

-- Obszar mapy z informacją o źródle
create or replace function dk_sightings_in_bbox_v4(
  p_w double precision, p_s double precision, p_e double precision, p_n double precision, p_limit int default 3000)
returns table (
  id uuid, species_id uuid, taxon text, taxon_sci text, taxon_inat integer, lat double precision, lng double precision,
  behavior text, has_photo boolean, seen_at timestamptz, confirmed_count int, nickname text, confirmed_by_me boolean, is_mine boolean,
  source text, source_url text, license text
)
language sql stable security definer set search_path = public, extensions
as $$
  select s.id, s.species_id, s.taxon, s.taxon_sci, s.taxon_inat,
         st_y(s.location::geometry), st_x(s.location::geometry),
         s.behavior, (s.photo_url is not null), s.seen_at,
         (select count(*)::int from confirmations c where c.sighting_id = s.id),
         case when s.source is not null then s.observer
              else coalesce(p.nickname, 'Tropiciel #' || left(s.created_by::text, 4)) end,
         exists (select 1 from confirmations c where c.sighting_id = s.id and c.user_id = auth.uid()),
         coalesce(s.created_by = auth.uid(), false),
         s.source, s.source_url, s.license
  from sightings s
  left join profiles p on p.id = s.created_by
  where s.location::geometry && (
    case when p_w <= p_e then st_makeenvelope(p_w, p_s, p_e, p_n, 4326)
      else st_collect(st_makeenvelope(p_w, p_s, 180, p_n, 4326), st_makeenvelope(-180, p_s, p_e, p_n, 4326)) end)
  order by s.seen_at desc
  limit least(greatest(p_limit, 1), 5000);
$$;

-- 3) Rzadkość gatunku: premia XP (ta sama tabela jest w aplikacji: RARITY w app/index.html)
create or replace function dk_rarity(p_species text, p_sci text) returns int
language sql immutable as $$
  select case p_species
    when 'Wilk' then 30 when 'Borsuk' then 15 when 'Sarna' then 10 when 'Dzik' then 5
    when 'Lis' then 5 when 'Jeż' then 5 when 'Wiewiórka' then 0
    else case
      when split_part(coalesce(p_sci, ''), ' ', 1) in ('Canis','Lynx','Alces','Lutra','Ursus','Bubo','Haliaeetus','Aquila','Grus','Felis') then 30
      when split_part(coalesce(p_sci, ''), ' ', 1) in ('Strix','Asio','Athene','Tyto','Accipiter','Falco','Buteo','Milvus','Circus','Pernis',
           'Alcedo','Upupa','Merops','Ciconia','Oriolus','Martes','Castor','Mustela','Cervus','Dama','Vipera','Nyctalus','Myotis',
           'Pipistrellus','Eptesicus','Plecotus','Glis','Muscardinus') then 15
      when split_part(coalesce(p_sci, ''), ' ', 1) in ('Dendrocopos','Dryobates','Picus','Dryocopus','Ardea','Egretta','Phalacrocorax','Sitta',
           'Pyrrhula','Carduelis','Cygnus','Aegithalos','Certhia','Regulus','Erithacus','Lepus','Erinaceus','Natrix','Lacerta',
           'Zootoca','Bufo','Rana','Pelophylax','Triturus','Lissotriton','Podiceps','Mergus','Aythya') then 5
      else 0 end
  end;
$$;

-- 4) Codzienne wejście ---------------------------------------------------
create table if not exists daily_checkins (
  user_id uuid not null,
  day     date not null,
  created_at timestamptz not null default now(),
  primary key (user_id, day)
);
alter table daily_checkins enable row level security;
revoke all on daily_checkins from anon, authenticated;

-- p_day = data lokalna urządzenia (różnica do 1 dnia od UTC dozwolona)
create or replace function dk_checkin(p_day date) returns boolean
language plpgsql security definer set search_path = public, extensions
as $$
declare v int;
begin
  if auth.uid() is null or p_day is null or abs(p_day - (now() at time zone 'utc')::date) > 1 then return false; end if;
  insert into profiles (id) values (auth.uid()) on conflict (id) do nothing;
  insert into daily_checkins (user_id, day) values (auth.uid(), p_day) on conflict do nothing;
  get diagnostics v = row_count;
  return v > 0;
end;
$$;

create or replace function dk_my_checkins() returns setof date
language sql stable security definer set search_path = public, extensions
as $$ select day from daily_checkins where user_id = auth.uid() and day > current_date - 400 order by day desc; $$;

-- Ranking: obserwacje 10 · zdjęcie 10 · każdy nowy gatunek 20 · premia za rzadkość · potwierdzenia 5/5 · dzień w aplikacji 3
-- Importowane obserwacje (created_by = null) nie biorą udziału.
create or replace function dk_leaderboard_v3(
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
    select created_by uid, count(*) n, count(*) filter (where photo_url is not null) ph,
           count(distinct (species_id::text || '|' || lower(coalesce(taxon_sci, taxon, '')))) tx,
           count(distinct species_id) sp, sum(dk_rarity(name_pl, taxon_sci)) rr
    from scope where p_since is null or seen_at >= p_since group by created_by
  ), cg as (
    select c.user_id uid, count(*) n from confirmations c join scope si on si.id = c.sighting_id
    where p_since is null or c.created_at >= p_since group by c.user_id
  ), cr as (
    select si.created_by uid, count(*) n from confirmations c join scope si on si.id = c.sighting_id
    where p_since is null or c.created_at >= p_since group by si.created_by
  ), u as (select uid from s union select uid from cg union select uid from cr),
  ck as (
    select d.user_id uid, count(*) n from daily_checkins d join u on u.uid = d.user_id
    where p_since is null or d.day >= p_since::date group by d.user_id
  )
  select coalesce(p.nickname, 'Tropiciel #' || left(u.uid::text, 4)), p.avatar_url,
         (coalesce(s.n,0)*10 + coalesce(s.ph,0)*10 + coalesce(s.tx,0)*20 + coalesce(s.rr,0)
          + coalesce(cg.n,0)*5 + coalesce(cr.n,0)*5 + coalesce(ck.n,0)*3)::int as xp,
         coalesce(s.n,0)::int, coalesce(s.sp,0)::int, u.uid = auth.uid()
  from u left join s using (uid) left join cg using (uid) left join cr using (uid) left join ck using (uid)
  left join profiles p on p.id = u.uid
  where u.uid is not null
  order by xp desc limit 50;
$$;

-- Przeniesienie postępów i usunięcie konta — teraz także z dniami w aplikacji
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
  delete from push.subscriptions where user_id = v;
  delete from analytics.events where user_id = v;
  delete from profile_private where id = v;
  delete from profiles where id = v;
  begin delete from storage.objects where bucket_id = 'avatars' and (storage.foldername(name))[1] = v::text; exception when others then null; end;
  begin delete from auth.users where id = v; exception when others then null; end;
end;
$$;

-- Push „seria”: liczą się dni w aplikacji, nie tylko dni z obserwacją
create or replace function dk_push_due()
returns table (sub_id bigint, user_id uuid, kind text, channel text, endpoint text, p256dh text, auth text, lang text, n int)
language sql stable security definer set search_path = public, extensions
as $$
  with s as (
    select ps.*, (now() at time zone ps.tz) as lt from push.subscriptions ps where ps.disabled_at is null
  ), e as (
    select s.* from s
    where extract(hour from s.lt) between 10 and 19
      and not exists (select 1 from push.log l where l.user_id = s.user_id and l.ok and l.sent_at > now() - interval '20 hours')
  ), c as (
    select e.id, count(*)::int n from e
    join sightings si on si.created_by = e.user_id
    join confirmations co on co.sighting_id = si.id
    where (e.prefs->>'confirm')::boolean is not false
      and co.created_at > greatest(e.last_seen_at,
            coalesce((select max(l.sent_at) from push.log l where l.user_id = e.user_id and l.kind = 'confirm' and l.ok), '-infinity'))
    group by e.id
  ), d as (
    select e.id, dc.day from e join daily_checkins dc on dc.user_id = e.user_id where dc.day > current_date - 62
  ), st as (
    select e.id, (select count(*)::int from (
              select day, row_number() over (order by day desc) rn from d where d.id = e.id and d.day < e.lt::date) x
            where x.day = e.lt::date - x.rn::int) as n
    from e
    where (e.prefs->>'streak')::boolean is not false
      and extract(hour from e.lt) >= 17
      and exists (select 1 from d where d.id = e.id and d.day = e.lt::date - 1)
      and not exists (select 1 from d where d.id = e.id and d.day = e.lt::date)
  ), ia as (
    select e.id, cnt,
      (select count(*)::int from sightings si
        where e.lat is not null and (e.prefs->>'nearby')::boolean is not false
          and si.seen_at > now() - interval '7 days' and si.created_by is distinct from e.user_id
          and st_dwithin(si.location, st_setsrid(st_makepoint(e.lng, e.lat), 4326)::geography, 15000)) as n
    from e, lateral (select count(*)::int cnt from push.log l
                     where l.user_id = e.user_id and l.kind = 'inactive' and l.ok and l.sent_at > e.last_seen_at) k
    where now() - e.last_seen_at >= case k.cnt when 0 then interval '3 days' when 1 then interval '7 days' when 2 then interval '14 days' end
      and not exists (select 1 from push.log l where l.user_id = e.user_id and l.kind = 'inactive' and l.sent_at > now() - interval '3 days')
  ), wk as (
    select e.id from e
    where (e.prefs->>'weekly')::boolean is not false
      and extract(isodow from e.lt) = 1 and extract(hour from e.lt) between 10 and 12
      and e.last_seen_at > now() - interval '30 days'
      and not exists (select 1 from push.log l where l.user_id = e.user_id and l.kind = 'weekly' and l.sent_at > now() - interval '6 days')
  )
  select e.id, e.user_id,
         case when c.id is not null then 'confirm' when st.id is not null then 'streak' when ia.id is not null then 'inactive' else 'weekly' end,
         e.kind, e.endpoint, e.p256dh, e.auth, e.lang, coalesce(c.n, st.n, ia.n, 0)
  from e left join c on c.id = e.id left join st on st.id = e.id left join ia on ia.id = e.id left join wk on wk.id = e.id
  where c.id is not null or st.id is not null or ia.id is not null or wk.id is not null;
$$;

-- Uprawnienia
revoke execute on function dk_import_sightings(jsonb) from public, anon, authenticated;
revoke execute on function dk_checkin(date)            from public, anon;
revoke execute on function dk_my_checkins()            from public, anon;
revoke execute on function dk_push_due()               from public, anon, authenticated;
grant execute on function dk_import_sightings(jsonb) to service_role;
grant execute on function dk_push_due()              to service_role;
grant execute on function dk_checkin(date)           to authenticated;
grant execute on function dk_my_checkins()           to authenticated;
grant execute on function dk_rarity(text, text)      to anon, authenticated;
grant execute on function dk_sightings_in_bbox_v4(double precision, double precision, double precision, double precision, int) to anon, authenticated;
grant execute on function dk_leaderboard_v3(timestamptz, double precision, double precision, double precision) to anon, authenticated;

-- Sprawdzenie
select name_pl, icon from species order by name_pl;
