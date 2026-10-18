-- Salon-Cockpit (cockpit.html): Einstellungen und Monatswerte pro Person.
-- Enthält Löhne und Umsätze der Mitarbeiterinnen → nur für die Inhaberin.
-- Setzt 20261018120000_belege_nur_inhaberin.sql voraus (public.ist_inhaberin()).

-- Personen, Lohn, Prämienstufen, Kategorie-Zuordnung (ein JSON-Dokument)
create table if not exists public.cockpit_einstellungen (
  user_id uuid primary key default auth.uid() references auth.users(id) on delete cascade,
  daten jsonb not null default '{}'::jsonb,
  aktualisiert timestamptz not null default now()
);

-- Pro Monat: Umsatz (brutto aus meinKassa) und Abwesenheitstage je Person
create table if not exists public.cockpit_monat (
  user_id uuid not null default auth.uid() references auth.users(id) on delete cascade,
  monat text not null check (monat ~ '^\d{4}-\d{2}$'),
  daten jsonb not null default '{}'::jsonb,
  aktualisiert timestamptz not null default now(),
  primary key (user_id, monat)
);

alter table public.cockpit_einstellungen enable row level security;
alter table public.cockpit_monat enable row level security;

drop policy if exists "cockpit_einstellungen: eigene Zeile" on public.cockpit_einstellungen;
create policy "cockpit_einstellungen: eigene Zeile" on public.cockpit_einstellungen
  for all to authenticated
  using (user_id = auth.uid())
  with check (user_id = auth.uid());

drop policy if exists "cockpit_einstellungen: nur Inhaberin" on public.cockpit_einstellungen;
create policy "cockpit_einstellungen: nur Inhaberin" on public.cockpit_einstellungen
  as restrictive for all to public
  using (public.ist_inhaberin())
  with check (public.ist_inhaberin());

drop policy if exists "cockpit_monat: eigene Zeilen" on public.cockpit_monat;
create policy "cockpit_monat: eigene Zeilen" on public.cockpit_monat
  for all to authenticated
  using (user_id = auth.uid())
  with check (user_id = auth.uid());

drop policy if exists "cockpit_monat: nur Inhaberin" on public.cockpit_monat;
create policy "cockpit_monat: nur Inhaberin" on public.cockpit_monat
  as restrictive for all to public
  using (public.ist_inhaberin())
  with check (public.ist_inhaberin());
