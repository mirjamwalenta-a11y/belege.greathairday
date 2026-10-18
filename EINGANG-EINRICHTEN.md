# Beleg-Eingang einrichten (Gmail + „Teilen“ am Android-Handy)

Ziel: Rechnungen, die per Mail kommen, landen ohne Herunterladen und Hochladen in der
Belege-App. Neue Rechnungen mit PDF-Anhang erkennt das Skript selbst; alles andere markierst du
mit dem Label **Belege**. Spätestens 15 Minuten später zeigt die App „📥 neue Belege im Eingang“.
Die Erkennung und das Prüf-Fenster laufen dann wie beim normalen Hochladen.

```
Rechnungs-Mails / Label „Belege“ → Google-Skript (alle 15 min) → Supabase-Funktion beleg-eingang
  → Eingang (nur für dich lesbar) → Belege-App: „Jetzt übernehmen“ → Erkennung + Prüfen
```

Voraussetzung: PR #10 ist gemergt und `app_inhaberin` enthält deine User-ID.

---

## 1. Supabase: Tabelle anlegen

SQL-Editor → Inhalt von `supabase/migrations/20261018140000_beleg_eingang.sql` einfügen → **Run**.

## 2. Supabase: geheimes Token erzeugen

Das Token ist das Passwort zwischen Gmail-Skript und Supabase. Es steht **nirgends im Code**.

1. Im Browser irgendeine Seite öffnen → F12 → Konsole → eintippen:
   `crypto.randomUUID()+crypto.randomUUID()` → Enter → den Wert (ohne Anführungszeichen) kopieren.
2. Supabase → **Edge Functions → Secrets** → *Add new secret*:
   Name `EINGANG_TOKEN`, Wert = das kopierte Token → Speichern.

## 3. Supabase: Funktion anlegen

1. **Edge Functions → Deploy a new function → Via Editor**.
2. Name: `beleg-eingang`.
3. Den gesamten Inhalt von `supabase/functions/beleg-eingang/index.ts` einfügen → **Deploy**.
4. In den Einstellungen der Funktion **„Enforce JWT verification“ / „Verify JWT“ ausschalten**
   (das Gmail-Skript hat keinen Supabase-Login; das Token aus Schritt 2 ersetzt diese Prüfung).
5. Die Adresse der Funktion notieren:
   `https://lpuxvvfrrcnbuzafscyk.supabase.co/functions/v1/beleg-eingang`

(Alternativ mit der Supabase-CLI: `supabase functions deploy beleg-eingang --no-verify-jwt`.)

## 4. Google: Skript in deinem Gmail-Konto

Mit dem Gmail-Konto angemeldet, in dem die Rechnungen ankommen:

1. <https://script.google.com> → **Neues Projekt** → Namen z. B. „Belege-Eingang“.
2. Den Inhalt von `gmail-eingang/Code.gs` in `Code.gs` einfügen → Speichern.
3. Links **⚙️ Projekteinstellungen** → ganz unten **Skripteigenschaften** → zwei Einträge:
   - `FUNKTION_URL` = die Adresse aus Schritt 3.5
   - `EINGANG_TOKEN` = dasselbe Token wie in Schritt 2
4. Zurück zum Editor → oben die Funktion **`einrichten`** auswählen → **Ausführen**.
5. Google fragt nach Berechtigungen (Gmail lesen/Labels ändern, externe Anfragen).
   Weil das Skript von dir selbst ist, warnt Google „App nicht überprüft“ →
   **Erweitert → Zu Belege-Eingang wechseln → Zulassen**. Das Skript läuft nur in deinem Konto.

Danach gibt es in Gmail die Labels **Belege** und **Belege-erledigt**, und das Skript läuft alle 15 Minuten.

## 5. Gmail: was automatisch geholt wird

Kein Gmail-Filter nötig: Das Skript sucht selbst alle Mails **ab dem Tag der Einrichtung**
mit PDF-Anhang und einem der Wörter *Rechnung, Invoice, Faktura, Gutschrift, Beleg*
(Liste `SUCHWOERTER` oben im Skript). Ältere Mails werden nicht automatisch geholt.

Alles andere — ältere Rechnungen, Fotos, Mails ohne diese Wörter — von Hand markieren:
Mail öffnen → ⋮ → **Label ändern** → **Belege**.

Falsch erkannte Mails sind kein Problem: In der App wird jeder Beleg vor dem Speichern
im Prüf-Fenster angezeigt und kann verworfen werden.

> Manche Anbieter schicken keine PDF, sondern nur einen Link zum Kundenportal. Solche
> Rechnungen weiter selbst herunterladen und über „Teilen → Belege“ oder Hochladen erfassen.

## 6. Android: „Teilen → Belege“

1. Die Belege-App in Chrome öffnen → ⋮ → **App installieren** (bzw. „Zum Startbildschirm hinzufügen“).
   Wenn sie schon installiert ist: einmal öffnen, damit die neue Version geladen wird —
   ggf. deinstallieren und neu installieren, falls „Belege“ im Teilen-Menü nicht auftaucht.
2. Ab dann in Gmail, Dateien, WhatsApp usw.: PDF oder Foto → **Teilen** → **Belege**.
   Die App öffnet sich und verarbeitet die Datei sofort (nach PIN, falls nötig — dann
   erscheint sie als „📥 im Eingang“).

---

## Wenn etwas nicht ankommt

- **script.google.com → Ausführungen**: zeigt jeden Lauf und Fehlermeldungen.
  `401` = Token in Skript und Supabase stimmt nicht überein.
  `500 Inhaberin nicht eindeutig` = `app_inhaberin` ist leer oder hat mehr als einen Eintrag.
- Mails mit Fehler bekommen nicht das Label **Belege-erledigt** und werden beim nächsten Lauf erneut versucht;
  doppelt übertragene Anhänge erkennt die Funktion selbst.
- Kleine Bilder (unter 30 KB) werden absichtlich übersprungen — das sind fast immer Logos
  oder E-Mail-Signaturen.
