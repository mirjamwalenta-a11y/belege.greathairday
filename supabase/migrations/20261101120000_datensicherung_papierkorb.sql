-- ════════════════════════════════════════════════════════════════════════
-- Datensicherung für ALLE Great-Hair-Day-Apps: Papierkorb + Notbremse
-- (Supabase-Projekt lpuxvvfrrcnbuzafscyk = BELEGE-APP, gilt für jede Tabelle in public)
-- Gleiche Datei wie index.greathairday/supabase/migrations/20261101120000_datensicherung_papierkorb.sql
-- (dort für das gemeinsame Projekt wrxlaltgtgkdomklgrlj). Hier im Belege-Projekt ausführen.
--
-- Anlass (2026-11-01): In der Schaltzentrale waren alle Vorlagen
-- (ghd_aufgaben_vorlagen) weg, vorher schon in anderen Apps. Gelöschte
-- Zeilen waren bisher unwiederbringlich. Ab jetzt:
--
--  1. PAPIERKORB: Jede Zeile, die in einer public-Tabelle gelöscht oder
--     geändert wird, landet vorher als Kopie in sicherung.verlauf
--     (180 Tage aufbewahrt). Wiederherstellen mit
--       SELECT * FROM sicherung.wiederherstellen('tabelle', '2026-10-30');
--
--  2. NOTBREMSE: Über die App (Rollen anon/authenticated) dürfen in einer
--     Anweisung höchstens 25 Zeilen auf einmal gelöscht werden, TRUNCATE
--     gar nicht. Mehr wird abgelehnt und nichts gelöscht. SECURITY-DEFINER-
--     Funktionen und der SQL-Editor sind davon nicht betroffen.
--
--  3. NEUE TABELLEN bekommen beides automatisch (Event-Trigger). Falls der
--     Event-Trigger nicht angelegt werden darf: nach neuen Tabellen
--       SELECT sicherung.aktivieren();
--     ausführen.
--
-- Sicherheit (CLAUDE.md): Schema sicherung ist nicht über die Data-API
-- erreichbar, RLS ist an, KEINE Grants für anon/authenticated. Lesen und
-- Wiederherstellen nur im Supabase-SQL-Editor.
--
-- Mehrfach ausführbar.
-- ════════════════════════════════════════════════════════════════════════

CREATE SCHEMA IF NOT EXISTS sicherung;
REVOKE ALL ON SCHEMA sicherung FROM public, anon, authenticated;

CREATE TABLE IF NOT EXISTS sicherung.verlauf (
  id      bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  zeit    timestamptz NOT NULL DEFAULT now(),
  tabelle text        NOT NULL,
  aktion  text        NOT NULL,          -- 'DELETE' oder 'UPDATE'
  alt     jsonb       NOT NULL,          -- die Zeile VOR der Änderung
  wer     text,                          -- auth-Benutzer-ID (sub aus dem JWT), falls vorhanden
  rolle   text                           -- Datenbank-Rolle (anon / authenticated / postgres …)
);
CREATE INDEX IF NOT EXISTS verlauf_tabelle_zeit_idx ON sicherung.verlauf (tabelle, zeit DESC);

ALTER TABLE sicherung.verlauf ENABLE ROW LEVEL SECURITY;
-- bewusst keine Policy und keine Grants: nur SQL-Editor / service_role
REVOKE ALL ON sicherung.verlauf FROM public, anon, authenticated;

-- ── 1. Papierkorb: alte Zeile merken ────────────────────────────────────
CREATE OR REPLACE FUNCTION sicherung.zeile_merken()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog
AS $$
DECLARE
  v_wer text;
BEGIN
  IF TG_OP = 'UPDATE' AND to_jsonb(OLD) = to_jsonb(NEW) THEN
    RETURN NULL;                          -- nichts geändert → nichts merken
  END IF;
  BEGIN
    v_wer := nullif(current_setting('request.jwt.claims', true), '')::jsonb ->> 'sub';
  EXCEPTION WHEN OTHERS THEN
    v_wer := NULL;
  END;
  BEGIN
    INSERT INTO sicherung.verlauf (tabelle, aktion, alt, wer, rolle)
    VALUES (TG_TABLE_NAME, TG_OP, to_jsonb(OLD), v_wer, current_setting('role', true));
    -- gelegentlich aufräumen, damit der Papierkorb nicht endlos wächst
    IF random() < 0.002 THEN
      DELETE FROM sicherung.verlauf WHERE zeit < now() - interval '180 days';
    END IF;
  EXCEPTION WHEN OTHERS THEN
    -- Die Sicherung darf die App nie blockieren
    RAISE WARNING 'sicherung.zeile_merken (%): %', TG_TABLE_NAME, SQLERRM;
  END;
  RETURN NULL;
END;
$$;

-- ── 2. Notbremse: Massenlöschung über die App verhindern ───────────────
-- Absichtlich NICHT SECURITY DEFINER: current_user ist die aufrufende Rolle.
CREATE OR REPLACE FUNCTION sicherung.massenloeschung_bremsen()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = pg_catalog
AS $$
DECLARE
  v_grenze int := coalesce(nullif(TG_ARGV[0], '')::int, 25);
  v_anzahl int;
BEGIN
  IF current_user IN ('anon', 'authenticated') THEN
    SELECT count(*) INTO v_anzahl FROM alte_zeilen;
    IF v_anzahl > v_grenze THEN
      RAISE EXCEPTION 'Sicherung: % Einträge in "%" auf einmal zu löschen ist über die App gesperrt (höchstens %). Es wurde nichts gelöscht.',
        v_anzahl, TG_TABLE_NAME, v_grenze
        USING ERRCODE = 'P0001';
    END IF;
  END IF;
  RETURN NULL;
END;
$$;

CREATE OR REPLACE FUNCTION sicherung.truncate_sperren()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = pg_catalog
AS $$
BEGIN
  IF current_user IN ('anon', 'authenticated') THEN
    RAISE EXCEPTION 'Sicherung: Tabelle "%" leeren (TRUNCATE) ist über die App gesperrt.', TG_TABLE_NAME
      USING ERRCODE = 'P0001';
  END IF;
  RETURN NULL;
END;
$$;

-- ── Einzelne Tabelle absichern ─────────────────────────────────────────
CREATE OR REPLACE FUNCTION sicherung.tabelle_absichern(p_tabelle regclass)
RETURNS void
LANGUAGE plpgsql
SET search_path = pg_catalog
AS $$
BEGIN
  EXECUTE format('CREATE OR REPLACE TRIGGER ghd_sicherung_papierkorb
                    AFTER UPDATE OR DELETE ON %s
                    FOR EACH ROW EXECUTE FUNCTION sicherung.zeile_merken()', p_tabelle);
  EXECUTE format('CREATE OR REPLACE TRIGGER ghd_sicherung_bremse
                    AFTER DELETE ON %s
                    REFERENCING OLD TABLE AS alte_zeilen
                    FOR EACH STATEMENT EXECUTE FUNCTION sicherung.massenloeschung_bremsen(''25'')', p_tabelle);
  EXECUTE format('CREATE OR REPLACE TRIGGER ghd_sicherung_truncate
                    BEFORE TRUNCATE ON %s
                    FOR EACH STATEMENT EXECUTE FUNCTION sicherung.truncate_sperren()', p_tabelle);
END;
$$;

-- ── Alle public-Tabellen absichern (nach neuen Tabellen erneut ausführen) ─
CREATE OR REPLACE FUNCTION sicherung.aktivieren()
RETURNS text
LANGUAGE plpgsql
SET search_path = pg_catalog
AS $$
DECLARE
  t record;
  v_ok int := 0;
  v_fehler text := '';
BEGIN
  FOR t IN
    SELECT c.oid::regclass AS tab
    FROM pg_class c
    JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE n.nspname = 'public'
      AND c.relkind = 'r'
      AND NOT c.relispartition
  LOOP
    BEGIN
      PERFORM sicherung.tabelle_absichern(t.tab);
      v_ok := v_ok + 1;
    EXCEPTION WHEN OTHERS THEN
      v_fehler := v_fehler || format(E'\n  %s: %s', t.tab, SQLERRM);
    END;
  END LOOP;
  RETURN format('%s Tabellen abgesichert.', v_ok)
      || CASE WHEN v_fehler <> '' THEN E'\nNicht abgesichert:' || v_fehler ELSE '' END;
END;
$$;

-- ── 3. Neue Tabellen automatisch absichern ──────────────────────────────
CREATE OR REPLACE FUNCTION sicherung.neue_tabelle()
RETURNS event_trigger
LANGUAGE plpgsql
SET search_path = pg_catalog
AS $$
DECLARE
  o record;
BEGIN
  FOR o IN
    SELECT objid FROM pg_event_trigger_ddl_commands()
    WHERE command_tag = 'CREATE TABLE' AND schema_name = 'public' AND object_type = 'table'
  LOOP
    BEGIN
      PERFORM sicherung.tabelle_absichern(o.objid::regclass);
    EXCEPTION WHEN OTHERS THEN
      RAISE WARNING 'sicherung.neue_tabelle (%): %', o.objid::regclass, SQLERRM;
    END;
  END LOOP;
END;
$$;

DO $$
BEGIN
  DROP EVENT TRIGGER IF EXISTS ghd_sicherung_neue_tabelle;
  CREATE EVENT TRIGGER ghd_sicherung_neue_tabelle
    ON ddl_command_end
    WHEN TAG IN ('CREATE TABLE')
    EXECUTE FUNCTION sicherung.neue_tabelle();
EXCEPTION WHEN insufficient_privilege THEN
  RAISE NOTICE 'Event-Trigger nicht erlaubt – nach neuen Tabellen bitte SELECT sicherung.aktivieren(); ausführen.';
END;
$$;

-- ── Wiederherstellen ────────────────────────────────────────────────────
-- Spielt gelöschte Zeilen einer Tabelle aus dem Papierkorb zurück.
-- Vorhandene Zeilen (gleicher Schlüssel) bleiben unangetastet.
--   SELECT * FROM sicherung.wiederherstellen('ghd_aufgaben_vorlagen', '2026-10-30');
CREATE OR REPLACE FUNCTION sicherung.wiederherstellen(
  p_tabelle text,
  p_seit    timestamptz,
  p_bis     timestamptz DEFAULT now()
)
RETURNS TABLE (wiederhergestellt int, schon_vorhanden int, fehler int)
LANGUAGE plpgsql
SET search_path = pg_catalog
AS $$
DECLARE
  r record;
  n int;
BEGIN
  wiederhergestellt := 0; schon_vorhanden := 0; fehler := 0;
  FOR r IN
    SELECT alt FROM sicherung.verlauf
    WHERE tabelle = p_tabelle AND aktion = 'DELETE' AND zeit BETWEEN p_seit AND p_bis
    ORDER BY zeit
  LOOP
    BEGIN
      EXECUTE format(
        'INSERT INTO public.%I OVERRIDING SYSTEM VALUE
           SELECT * FROM jsonb_populate_record(NULL::public.%I, $1)
         ON CONFLICT DO NOTHING', p_tabelle, p_tabelle)
      USING r.alt;
      GET DIAGNOSTICS n = ROW_COUNT;
      IF n > 0 THEN wiederhergestellt := wiederhergestellt + 1;
      ELSE schon_vorhanden := schon_vorhanden + 1; END IF;
    EXCEPTION WHEN OTHERS THEN
      fehler := fehler + 1;
      RAISE WARNING 'Zeile nicht wiederhergestellt: %', SQLERRM;
    END;
  END LOOP;
  RETURN NEXT;
END;
$$;

REVOKE ALL ON ALL FUNCTIONS IN SCHEMA sicherung FROM public, anon, authenticated;

SELECT sicherung.aktivieren();

-- ════════════════════════════════════════════════════════════════════════
-- Nützliche Abfragen (SQL-Editor):
--
-- Was wurde zuletzt gelöscht?
--   SELECT zeit, tabelle, rolle, wer, alt FROM sicherung.verlauf
--   WHERE aktion = 'DELETE' ORDER BY zeit DESC LIMIT 50;
--
-- Gelöschte Belege der letzten Tage zurückholen:
--   SELECT * FROM sicherung.wiederherstellen('belege_neu', now() - interval '3 days');
--
-- Eine Tabelle braucht wirklich Massenlöschungen über die App? Grenze anheben:
--   CREATE OR REPLACE TRIGGER ghd_sicherung_bremse AFTER DELETE ON public.<tabelle>
--     REFERENCING OLD TABLE AS alte_zeilen FOR EACH STATEMENT
--     EXECUTE FUNCTION sicherung.massenloeschung_bremsen('500');
-- ════════════════════════════════════════════════════════════════════════
