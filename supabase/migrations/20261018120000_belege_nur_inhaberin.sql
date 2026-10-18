-- Belege-App: Zugriff nur für die Inhaberin (Supabase-Projekt lpuxvvfrrcnbuzafscyk).
--
-- Vorher: Registrierung war offen (Einladungs-Code nur im Browser geprüft),
-- d. h. jede Person konnte sich über /auth/v1/signup ein Konto anlegen.
--
-- Prinzip: Eine Tabelle `app_inhaberin` hält die erlaubte(n) User-ID(s).
-- RESTRICTIVE-Policies werden mit allen bestehenden Policies UND-verknüpft,
-- greifen also unabhängig davon, welche Policies es auf den Tabellen schon gibt.
--
-- Nach dem Ausführen EINMALIG im SQL-Editor die eigene User-ID eintragen
-- (E-Mail nur dort eintippen, nie in Code/Repo):
--   insert into public.app_inhaberin (user_id)
--   select id from auth.users where email = '<deine E-Mail>';

create table if not exists public.app_inhaberin (
  user_id uuid primary key references auth.users(id) on delete cascade
);
-- RLS ohne Policy: über den API-Key weder lesbar noch schreibbar.
alter table public.app_inhaberin enable row level security;

create or replace function public.ist_inhaberin()
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (select 1 from public.app_inhaberin where user_id = auth.uid());
$$;
revoke all on function public.ist_inhaberin() from public;
grant execute on function public.ist_inhaberin() to authenticated;

-- Belege-Tabelle
alter table public.belege_neu enable row level security;

drop policy if exists "belege_neu: eigene Zeilen" on public.belege_neu;
create policy "belege_neu: eigene Zeilen" on public.belege_neu
  for all to authenticated
  using (user_id = auth.uid())
  with check (user_id = auth.uid());

drop policy if exists "belege_neu: nur Inhaberin" on public.belege_neu;
create policy "belege_neu: nur Inhaberin" on public.belege_neu
  as restrictive for all to public
  using (public.ist_inhaberin())
  with check (public.ist_inhaberin());

-- Storage-Bucket "belege" (die Beleg-Dateien selbst). Andere Buckets bleiben unberührt.
drop policy if exists "belege-bucket: nur Inhaberin" on storage.objects;
create policy "belege-bucket: nur Inhaberin" on storage.objects
  as restrictive for all to public
  using (bucket_id <> 'belege' or public.ist_inhaberin())
  with check (bucket_id <> 'belege' or public.ist_inhaberin());
