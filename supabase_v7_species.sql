-- =====================================================================
-- Dzikie Korytarze — SQL v7: ptaki + dokładne gatunki (nazwa łacińska, iNaturalist)
-- Uruchom raz w Supabase → SQL Editor → New query → Run (po v4).
-- Zawiera wszystko z v6 — jeśli v6 nie był uruchomiony, wystarczy ten plik.
-- Nic nie usuwa. Bezpieczne do powtórzenia.
-- =====================================================================

set search_path = public, extensions;


-- 1) Nowy gatunek „Ptak” i nowa ikona dla „Inne”
insert into species (name_pl, icon, danger_level)
select 'Ptak', '🐦', 0
where not exists (select 1 from species where name_pl = 'Ptak');

update species set icon = '🐾', danger_level = 0 where name_pl = 'Inne';

-- 2) Pole na konkretną nazwę: „sroka”, „jeż”…
alter table sightings add column if not exists taxon text;

-- 3) Dodawanie obserwacji z nazwą (dla „Ptak” i „Inne” nazwa jest obowiązkowa)
create or replace function dk_add_sighting_v2(
  p_species  uuid,
  p_lat      double precision,
  p_lng      double precision,
  p_behavior text,
  p_photo    text,
  p_seen_at  timestamptz,
  p_taxon    text
) returns uuid
language plpgsql security definer
set search_path = public, extensions
as $$
declare
  v_id uuid;
  v_sp text;
  v_taxon text := nullif(btrim(left(p_taxon, 60)), '');
begin
  if auth.uid() is null then raise exception 'Zaloguj się, aby dodać obserwację'; end if;
  select name_pl into v_sp from species where id = p_species;
  if v_sp is null then raise exception 'Nieznany gatunek'; end if;
  if v_sp in ('Ptak', 'Inne') and (v_taxon is null or length(v_taxon) < 2) then
    raise exception 'Podaj, jakie to było zwierzę';
  end if;
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

  insert into sightings (species_id, taxon, location, behavior, photo_url, has_photo, seen_at, created_by, created_at)
  values (p_species, v_taxon,
          st_setsrid(st_makepoint(p_lng, p_lat), 4326)::geography,
          nullif(left(p_behavior, 300), ''),
          p_photo, p_photo is not null, p_seen_at, auth.uid(), now())
  returning id into v_id;
  return v_id;
end;
$$;

-- 4) Odczyt z nazwą: obszar mapy
create or replace function dk_sightings_in_bbox_v2(
  p_w double precision, p_s double precision,
  p_e double precision, p_n double precision,
  p_limit int default 3000
)
returns table (
  id uuid, species_id uuid, taxon text, lat double precision, lng double precision,
  behavior text, has_photo boolean, seen_at timestamptz,
  confirmed_count int, nickname text, confirmed_by_me boolean, is_mine boolean
)
language sql stable security definer
set search_path = public, extensions
as $$
  select s.id, s.species_id, s.taxon,
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
      else st_collect(st_makeenvelope(p_w, p_s, 180, p_n, 4326), st_makeenvelope(-180, p_s, p_e, p_n, 4326))
    end)
  order by s.seen_at desc
  limit least(greatest(p_limit, 1), 5000);
$$;

-- 5) Odczyt z nazwą: moje obserwacje
create or replace function dk_my_sightings_v2()
returns table (
  id uuid, species_id uuid, taxon text, lat double precision, lng double precision,
  behavior text, has_photo boolean, seen_at timestamptz,
  confirmed_count int, nickname text, confirmed_by_me boolean, is_mine boolean
)
language sql stable security definer
set search_path = public, extensions
as $$
  select s.id, s.species_id, s.taxon,
         st_y(s.location::geometry), st_x(s.location::geometry),
         s.behavior, (s.photo_url is not null), s.seen_at,
         (select count(*)::int from confirmations c where c.sighting_id = s.id),
         coalesce(p.nickname, 'Ty'), false, true
  from sightings s
  left join profiles p on p.id = s.created_by
  where auth.uid() is not null and s.created_by = auth.uid()
  order by s.seen_at desc;
$$;

-- 6) Uprawnienia
grant execute on function dk_add_sighting_v2(uuid, double precision, double precision, text, text, timestamptz, text) to authenticated;
grant execute on function dk_sightings_in_bbox_v2(double precision, double precision, double precision, double precision, int) to anon, authenticated;
grant execute on function dk_my_sightings_v2() to authenticated;


-- =====================================================================
-- v7: nazwa łacińska i numer gatunku w iNaturalist (do raportów i eksportu danych)
-- =====================================================================
alter table sightings add column if not exists taxon_sci  text;
alter table sightings add column if not exists taxon_inat integer;
create index if not exists sightings_taxon_sci_idx on sightings (taxon_sci);

create or replace function dk_add_sighting_v3(
  p_species    uuid,
  p_lat        double precision,
  p_lng        double precision,
  p_behavior   text,
  p_photo      text,
  p_seen_at    timestamptz,
  p_taxon      text,
  p_taxon_sci  text,
  p_taxon_inat integer
) returns uuid
language plpgsql security definer
set search_path = public, extensions
as $$
declare v_id uuid;
begin
  v_id := dk_add_sighting_v2(p_species, p_lat, p_lng, p_behavior, p_photo, p_seen_at, p_taxon);
  update sightings
     set taxon_sci  = nullif(btrim(left(p_taxon_sci, 120)), ''),
         taxon_inat = case when p_taxon_inat > 0 then p_taxon_inat end
   where id = v_id and created_by = auth.uid();
  return v_id;
end;
$$;

create or replace function dk_sightings_in_bbox_v3(
  p_w double precision, p_s double precision,
  p_e double precision, p_n double precision,
  p_limit int default 3000
)
returns table (
  id uuid, species_id uuid, taxon text, taxon_sci text, taxon_inat integer, lat double precision, lng double precision,
  behavior text, has_photo boolean, seen_at timestamptz,
  confirmed_count int, nickname text, confirmed_by_me boolean, is_mine boolean
)
language sql stable security definer
set search_path = public, extensions
as $$
  select s.id, s.species_id, s.taxon, s.taxon_sci, s.taxon_inat,
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
      else st_collect(st_makeenvelope(p_w, p_s, 180, p_n, 4326), st_makeenvelope(-180, p_s, p_e, p_n, 4326))
    end)
  order by s.seen_at desc
  limit least(greatest(p_limit, 1), 5000);
$$;

create or replace function dk_my_sightings_v3()
returns table (
  id uuid, species_id uuid, taxon text, taxon_sci text, taxon_inat integer, lat double precision, lng double precision,
  behavior text, has_photo boolean, seen_at timestamptz,
  confirmed_count int, nickname text, confirmed_by_me boolean, is_mine boolean
)
language sql stable security definer
set search_path = public, extensions
as $$
  select s.id, s.species_id, s.taxon, s.taxon_sci, s.taxon_inat,
         st_y(s.location::geometry), st_x(s.location::geometry),
         s.behavior, (s.photo_url is not null), s.seen_at,
         (select count(*)::int from confirmations c where c.sighting_id = s.id),
         coalesce(p.nickname, 'Ty'), false, true
  from sightings s
  left join profiles p on p.id = s.created_by
  where auth.uid() is not null and s.created_by = auth.uid()
  order by s.seen_at desc;
$$;

grant execute on function dk_add_sighting_v3(uuid, double precision, double precision, text, text, timestamptz, text, text, integer) to authenticated;
grant execute on function dk_sightings_in_bbox_v3(double precision, double precision, double precision, double precision, int) to anon, authenticated;
grant execute on function dk_my_sightings_v3() to authenticated;

-- Sprawdzenie: powinny być widoczne „Ptak 🐦” i „Inne 🐾”
select name_pl, icon from species order by name_pl;
