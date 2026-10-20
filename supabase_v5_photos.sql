-- =====================================================================
-- Dzikie Korytarze — SQL v5: zdjęcia w Supabase Storage
-- Uruchom raz w Supabase → SQL Editor → New query → Run (po v4).
-- Nic nie usuwa. Bezpieczne do powtórzenia.
-- =====================================================================

-- 1) Publiczny magazyn „photos”: każdy może oglądać, limit 1 MB, tylko JPEG
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('photos', 'photos', true, 1048576, array['image/jpeg'])
on conflict (id) do update
  set public = excluded.public,
      file_size_limit = excluded.file_size_limit,
      allowed_mime_types = excluded.allowed_mime_types;

-- 2) Wgrywać można tylko do własnego folderu: photos/<id użytkownika>/...
--    (dotyczy też anonimowych użytkowników — mają rolę authenticated)
do $$
begin
  if not exists (
    select 1 from pg_policies
    where schemaname = 'storage' and tablename = 'objects' and policyname = 'dk photos: upload to own folder'
  ) then
    create policy "dk photos: upload to own folder"
      on storage.objects for insert to authenticated
      with check (bucket_id = 'photos' and (storage.foldername(name))[1] = auth.uid()::text);
  end if;
end $$;

-- 3) Sprawdzenie: powinien pojawić się jeden wiersz „photos | true”
select id, public, file_size_limit from storage.buckets where id = 'photos';
