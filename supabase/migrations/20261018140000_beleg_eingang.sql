-- Beleg-Eingang: Rechnungen, die über Gmail (Label "Belege") hereinkommen und noch
-- nicht in der App übernommen wurden. Setzt 20261018120000_belege_nur_inhaberin.sql voraus.
--
-- Schreiben (insert) tut nur die Edge Function `beleg-eingang` mit dem Service-Role-Key;
-- deshalb gibt es bewusst KEINE insert-Policy. Die App darf lesen, als übernommen
-- markieren und löschen — und nur die Inhaberin.

create table if not exists public.beleg_eingang (
  id bigint generated always as identity primary key,
  user_id uuid not null references auth.users(id) on delete cascade,
  erhalten timestamptz not null default now(),
  quelle text not null default 'gmail',
  message_id text,
  absender text,
  betreff text,
  dateiname text not null,
  mime text not null,
  pfad text not null,
  status text not null default 'neu' check (status in ('neu','uebernommen','verworfen')),
  unique (user_id, message_id, dateiname)
);
create index if not exists beleg_eingang_offen on public.beleg_eingang (user_id) where status = 'neu';

alter table public.beleg_eingang enable row level security;

drop policy if exists "beleg_eingang: eigene lesen" on public.beleg_eingang;
create policy "beleg_eingang: eigene lesen" on public.beleg_eingang
  for select to authenticated using (user_id = auth.uid());

drop policy if exists "beleg_eingang: eigene ändern" on public.beleg_eingang;
create policy "beleg_eingang: eigene ändern" on public.beleg_eingang
  for update to authenticated using (user_id = auth.uid()) with check (user_id = auth.uid());

drop policy if exists "beleg_eingang: eigene löschen" on public.beleg_eingang;
create policy "beleg_eingang: eigene löschen" on public.beleg_eingang
  for delete to authenticated using (user_id = auth.uid());

drop policy if exists "beleg_eingang: nur Inhaberin" on public.beleg_eingang;
create policy "beleg_eingang: nur Inhaberin" on public.beleg_eingang
  as restrictive for all to public
  using (public.ist_inhaberin())
  with check (public.ist_inhaberin());
