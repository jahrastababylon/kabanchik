-- =====================================================================
-- Tropami — usunięcie danych testowych (uruchom po v10, przed promocją)
-- Usuwa WSZYSTKIE obserwacje zgłoszone w aplikacji (zostają tylko importowane z otwartych danych)
-- wraz z potwierdzeniami, a także testowe statystyki i dzienniki push.
-- Pseudonimy, konta i subskrypcje push zostają.
-- Zdjęcia usuń osobno: Supabase → Storage → photos → zaznacz wszystko → Delete
-- (oraz avatars, jeśli chcesz wyczyścić testowe zdjęcia profilowe).
-- =====================================================================

-- 1) Podgląd: co zostanie usunięte
select count(*) filter (where source is null)     as obserwacje_testowe,
       count(*) filter (where source is not null) as z_otwartych_danych
from sightings;

-- 2) Usuwanie
delete from confirmations where sighting_id in (select id from sightings where source is null);
delete from sightings where source is null;
truncate analytics.events;
truncate push.log;
delete from daily_checkins;

-- 3) Sprawdzenie
select count(*) as obserwacje_po from sightings where source is null;
