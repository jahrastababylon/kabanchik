-- =====================================================================
-- Dzikie Korytarze — SQL v4 (cały świat + gamifikacja)
-- Uruchom raz w Supabase → SQL Editor → New query → Run.
-- Zastępuje v3 (nie trzeba uruchamiać v3). Bezpieczne do powtórzenia.
-- Nie usuwa żadnych danych z v2.
-- =====================================================================

create extension if not exists postgis;
set search_path = public, extensions;  -- PostGIS w Supabase bywa w schemacie extensions

-- 1) Brakujące kolumny i indeksy ---------------------------------------
alter table sightings     add column if not exists behavior   text;
alter table sightings     add column if not exists photo_url  text;
alter table sightings     add column if not exists has_photo  boolean default false;
alter table sightings     add column if not exists created_at timestamptz default now();
alter table profiles      add column if not exists nickname   text;
alter table confirmations add column if not exists created_at timestamptz default now();

create index if not exists sightings_location_idx   on sightings using gist (location);
create index if not exists sightings_location_geom_idx on sightings using gist ((location::geometry));  -- do prostokąta mapy
create index if not exists sightings_seen_at_idx    on sightings (seen_at desc);
create index if not exists sightings_created_by_idx on sightings (created_by);
create index if not exists confirmations_user_idx   on confirmations (user_id);
create index if not exists confirmations_sight_idx  on confirmations (sighting_id);

-- Stare funkcje z v3 (jeśli były) — zmieniamy ich sygnatury
drop function if exists dk_list_sightings(int);
drop function if exists dk_leaderboard(timestamptz);

-- 2) Obserwacje w widocznym obszarze mapy ------------------------------
create or replace function dk_sightings_in_bbox(
  p_w double precision, p_s double precision,
  p_e double precision, p_n double precision,
  p_limit int default 3000
)
returns table (
  id uuid, species_id uuid, lat double precision, lng double precision,
  behavior text, has_photo boolean, seen_at timestamptz,
  confirmed_count int, nickname text, confirmed_by_me boolean, is_mine boolean
)
language sql stable security definer
set search_path = public, extensions
as $$
  select s.id, s.species_id,
         st_y(s.location::geometry), st_x(s.location::geometry),
         s.behavior, (s.photo_url is not null), s.seen_at,
         (select count(*)::int from confirmations c where c.sighting_id = s.id),
         coalesce(p.nickname, 'Tropiciel #' || left(s.created_by::text, 4)),
         exists (select 1 from confirmations c where c.sighting_id = s.id and c.user_id = auth.uid()),
         coalesce(s.created_by = auth.uid(), false)
  from sightings s
  left join profiles p on p.id = s.created_by
  where s.location::geometry && (
    case when p_w <= p_e
      then st_makeenvelope(p_w, p_s, p_e, p_n, 4326)
      -- obszar przechodzi przez linię zmiany daty (Pacyfik)
      else st_collect(st_makeenvelope(p_w, p_s, 180, p_n, 4326), st_makeenvelope(-180, p_s, p_e, p_n, 4326))
    end)
  order by s.seen_at desc
  limit least(greatest(p_limit, 1), 5000);
$$;

-- 3) Wszystkie moje obserwacje (do XP, odznak, kwadratów) --------------
create or replace function dk_my_sightings()
returns table (
  id uuid, species_id uuid, lat double precision, lng double precision,
  behavior text, has_photo boolean, seen_at timestamptz,
  confirmed_count int, nickname text, confirmed_by_me boolean, is_mine boolean
)
language sql stable security definer
set search_path = public, extensions
as $$
  select s.id, s.species_id,
         st_y(s.location::geometry), st_x(s.location::geometry),
         s.behavior, (s.photo_url is not null), s.seen_at,
         (select count(*)::int from confirmations c where c.sighting_id = s.id),
         coalesce(p.nickname, 'Ty'), false, true
  from sightings s
  left join profiles p on p.id = s.created_by
  where auth.uid() is not null and s.created_by = auth.uid()
  order by s.seen_at desc;
$$;

-- 4) Moje potwierdzenia (do XP i wyzwań) -------------------------------
create or replace function dk_my_confirmations()
returns table (created_at timestamptz)
language sql stable security definer
set search_path = public, extensions
as $$
  select c.created_at from confirmations c
  where auth.uid() is not null and c.user_id = auth.uid();
$$;

-- 5) Dodanie obserwacji (cały świat) z limitem antyspamowym ------------
create or replace function dk_add_sighting(
  p_species  uuid,
  p_lat      double precision,
  p_lng      double precision,
  p_behavior text default null,
  p_photo    text default null,
  p_seen_at  timestamptz default now()
) returns uuid
language plpgsql security definer
set search_path = public, extensions
as $$
declare v_id uuid;
begin
  if auth.uid() is null then raise exception 'Zaloguj się, aby dodać obserwację'; end if;
  if not exists (select 1 from species where id = p_species) then raise exception 'Nieznany gatunek'; end if;
  if p_lat is null or p_lng is null or p_lat not between -85 and 85 or p_lng not between -180 and 180 then
    raise exception 'Nieprawidłowa lokalizacja';
  end if;
  if p_seen_at > now() + interval '5 minutes' or p_seen_at < now() - interval '8 days' then
    raise exception 'Nieprawidłowa data obserwacji';
  end if;
  if p_photo is not null and length(p_photo) > 600000 then raise exception 'Zdjęcie jest za duże'; end if;
  if (select count(*) from sightings where created_by = auth.uid() and created_at > now() - interval '1 hour') >= 20 then
    raise exception 'Limit 20 obserwacji na godzinę. Spróbuj później.';
  end if;

  insert into profiles (id) values (auth.uid()) on conflict (id) do nothing;

  insert into sightings (species_id, location, behavior, photo_url, has_photo, seen_at, created_by, created_at)
  values (p_species,
          st_setsrid(st_makepoint(p_lng, p_lat), 4326)::geography,
          nullif(left(p_behavior, 300), ''),
          p_photo, p_photo is not null, p_seen_at, auth.uid(), now())
  returning id into v_id;
  return v_id;
end;
$$;

-- 6) Potwierdzenie cudzej obserwacji -----------------------------------
create or replace function dk_confirm(p_sighting uuid)
returns void
language plpgsql security definer
set search_path = public, extensions
as $$
begin
  if auth.uid() is null then raise exception 'Zaloguj się, aby potwierdzić'; end if;
  if exists (select 1 from sightings where id = p_sighting and created_by = auth.uid()) then
    raise exception 'Nie możesz potwierdzić własnej obserwacji';
  end if;
  insert into profiles (id) values (auth.uid()) on conflict (id) do nothing;
  insert into confirmations (sighting_id, user_id, created_at)
  values (p_sighting, auth.uid(), now())
  on conflict (sighting_id, user_id) do nothing;
end;
$$;

-- 7) Pseudonim -----------------------------------------------------------
create or replace function dk_set_nickname(p_nickname text)
returns void
language plpgsql security definer
set search_path = public, extensions
as $$
declare v text := btrim(p_nickname);
begin
  if auth.uid() is null then raise exception 'Brak sesji'; end if;
  if length(v) < 2 or length(v) > 24 then raise exception 'Pseudonim musi mieć 2–24 znaki'; end if;
  insert into profiles (id, nickname) values (auth.uid(), v)
  on conflict (id) do update set nickname = excluded.nickname;
end;
$$;

-- 8) Ranking: okolica (promień od punktu) albo cały świat --------------
--    XP: obserwacja +10, zdjęcie +10, każdy gatunek +25,
--        potwierdzenie dane +5, potwierdzenie otrzymane +5
create or replace function dk_leaderboard(
  p_since    timestamptz      default null,
  p_lat      double precision default null,
  p_lng      double precision default null,
  p_radius_m double precision default null
)
returns table (nickname text, xp int, sightings int, species int, is_me boolean)
language sql stable security definer
set search_path = public, extensions
as $$
  with scope as (
    select * from sightings
    where p_lat is null or p_lng is null
       or st_dwithin(location, st_setsrid(st_makepoint(p_lng, p_lat), 4326)::geography, coalesce(p_radius_m, 25000))
  ), s as (
    select created_by uid, count(*) n,
           count(*) filter (where photo_url is not null) ph,
           count(distinct species_id) sp
    from scope
    where created_by is not null and (p_since is null or seen_at >= p_since)
    group by created_by
  ), cg as (
    select c.user_id uid, count(*) n
    from confirmations c join scope si on si.id = c.sighting_id
    where p_since is null or c.created_at >= p_since group by c.user_id
  ), cr as (
    select si.created_by uid, count(*) n
    from confirmations c join scope si on si.id = c.sighting_id
    where p_since is null or c.created_at >= p_since group by si.created_by
  ), u as (
    select uid from s union select uid from cg union select uid from cr
  )
  select coalesce(p.nickname, 'Tropiciel #' || left(u.uid::text, 4)),
         (coalesce(s.n,0)*10 + coalesce(s.ph,0)*10 + coalesce(s.sp,0)*25
          + coalesce(cg.n,0)*5 + coalesce(cr.n,0)*5)::int as xp,
         coalesce(s.n,0)::int, coalesce(s.sp,0)::int,
         u.uid = auth.uid()
  from u
  left join s  using (uid)
  left join cg using (uid)
  left join cr using (uid)
  left join profiles p on p.id = u.uid
  where u.uid is not null
  order by xp desc
  limit 50;
$$;

-- 9) Uprawnienia --------------------------------------------------------
grant execute on function dk_sightings_in_bbox(double precision, double precision, double precision, double precision, int) to anon, authenticated;
grant execute on function dk_leaderboard(timestamptz, double precision, double precision, double precision)                to anon, authenticated;
grant execute on function dk_my_sightings()                                                                                 to authenticated;
grant execute on function dk_my_confirmations()                                                                             to authenticated;
grant execute on function dk_add_sighting(uuid, double precision, double precision, text, text, timestamptz)                to authenticated;
grant execute on function dk_confirm(uuid)                                                                                  to authenticated;
grant execute on function dk_set_nickname(text)                                                                             to authenticated;
grant select on species, sightings, profiles, confirmations to anon, authenticated;
