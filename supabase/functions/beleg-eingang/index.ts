// Nimmt Beleg-Anhänge vom Gmail-Skript (gmail-eingang/Code.gs) entgegen und legt sie in
// den Storage-Bucket "belege" + Tabelle beleg_eingang. Die Erkennung (OCR/KI) läuft
// bewusst NICHT hier, sondern erst in der App, wenn die Inhaberin den Eingang öffnet —
// so prüft sie jeden Beleg wie gewohnt, und von außen lassen sich keine KI-Kosten auslösen.
//
// Absicherung: geheimes Token im Header (Supabase-Secret EINGANG_TOKEN, nie im Code),
// nur PDF/Bilder, Größen- und Anzahlgrenzen. Ohne JWT-Prüfung deployen (das Skript hat
// keinen Supabase-Login) — das Token ersetzt sie. Siehe EINGANG-EINRICHTEN.md.
import { createClient } from 'npm:@supabase/supabase-js@2';

const ERLAUBT = ['application/pdf', 'image/jpeg', 'image/png', 'image/webp', 'image/heic'];
const MAX_BYTES = 10 * 1024 * 1024;
const MAX_DATEIEN = 10;

function json(daten: unknown, status = 200) {
  return new Response(JSON.stringify(daten), { status, headers: { 'Content-Type': 'application/json' } });
}

// Vergleich in konstanter Zeit, damit sich das Token nicht Zeichen für Zeichen erraten lässt
function gleich(a: string, b: string) {
  const x = new TextEncoder().encode(a), y = new TextEncoder().encode(b);
  let diff = x.length ^ y.length;
  for (let i = 0; i < Math.max(x.length, y.length); i++) diff |= (x[i] ?? 0) ^ (y[i] ?? 0);
  return diff === 0;
}

async function fingerabdruck(s: string) {
  if (!s) return 'leer';
  const h = new Uint8Array(await crypto.subtle.digest('SHA-256', new TextEncoder().encode(s)));
  return Array.from(h.slice(0, 2)).map((x) => x.toString(16).padStart(2, '0')).join('');
}

function base64ZuBytes(s: string) {
  const bin = atob(s);
  const bytes = new Uint8Array(bin.length);
  for (let i = 0; i < bin.length; i++) bytes[i] = bin.charCodeAt(i);
  return bytes;
}

// Echte Dateisignatur prüfen, nicht nur den angegebenen Typ
function signaturPasst(mime: string, b: Uint8Array) {
  if (mime === 'application/pdf') return b[0] === 0x25 && b[1] === 0x50 && b[2] === 0x44 && b[3] === 0x46; // %PDF
  if (mime === 'image/jpeg') return b[0] === 0xff && b[1] === 0xd8;
  if (mime === 'image/png') return b[0] === 0x89 && b[1] === 0x50 && b[2] === 0x4e && b[3] === 0x47;
  return true; // webp/heic: Container-Formate, Typ reicht hier
}

Deno.serve(async (req) => {
  if (req.method !== 'POST') return json({ error: 'Nur POST' }, 405);

  // trim(): beim Kopieren mitgerutschte Leerzeichen/Zeilenumbrüche sollen nicht zum 401 führen
  const token = (Deno.env.get('EINGANG_TOKEN') ?? '').trim();
  if (token.length < 32) return json({ error: 'Funktion nicht eingerichtet (EINGANG_TOKEN fehlt oder zu kurz)' }, 500);
  const erhalten = (req.headers.get('x-eingang-token') ?? '').trim();
  if (!gleich(erhalten, token)) {
    // Nur Länge + 4 Zeichen eines SHA-256-Fingerabdrucks — genug, um beim Einrichten zu sehen,
    // welche Seite abweicht, ohne etwas über das Token selbst preiszugeben
    return json({
      error: 'Nicht berechtigt',
      erhalten: erhalten.length + ' Zeichen, ' + await fingerabdruck(erhalten),
      erwartet: token.length + ' Zeichen, ' + await fingerabdruck(token),
    }, 401);
  }

  let body: any;
  try { body = await req.json(); } catch { return json({ error: 'Ungültiges JSON' }, 400); }
  const dateien = Array.isArray(body?.dateien) ? body.dateien : [];
  if (!dateien.length) return json({ ergebnis: [] });
  if (dateien.length > MAX_DATEIEN) return json({ error: 'Zu viele Dateien' }, 400);

  const sb = createClient(Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!, {
    auth: { persistSession: false },
  });

  // Besitzerin aus app_inhaberin — muss genau eine sein, sonst lieber nichts annehmen
  const { data: inh, error: inhFehler } = await sb.from('app_inhaberin').select('user_id');
  if (inhFehler || !inh || inh.length !== 1) return json({ error: 'Inhaberin nicht eindeutig eingetragen' }, 500);
  const uid = inh[0].user_id as string;

  const messageId = body.message_id ? String(body.message_id).slice(0, 300) : null;
  const absender = body.absender ? String(body.absender).slice(0, 300) : null;
  const betreff = body.betreff ? String(body.betreff).slice(0, 300) : null;
  const ergebnis: { name: string; status: string }[] = [];

  for (const d of dateien) {
    const name = String(d?.name || 'beleg').slice(0, 120);
    const mime = String(d?.mime || '').toLowerCase();
    if (!ERLAUBT.includes(mime)) { ergebnis.push({ name, status: 'übersprungen: Dateityp' }); continue; }

    let bytes: Uint8Array;
    try { bytes = base64ZuBytes(String(d.base64 || '')); } catch { ergebnis.push({ name, status: 'übersprungen: unlesbar' }); continue; }
    if (!bytes.length || bytes.length > MAX_BYTES) { ergebnis.push({ name, status: 'übersprungen: Größe' }); continue; }
    if (!signaturPasst(mime, bytes)) { ergebnis.push({ name, status: 'übersprungen: Inhalt passt nicht zum Typ' }); continue; }

    if (messageId) {
      const { data: schon } = await sb.from('beleg_eingang').select('id')
        .eq('user_id', uid).eq('message_id', messageId).eq('dateiname', name).maybeSingle();
      if (schon) { ergebnis.push({ name, status: 'schon vorhanden' }); continue; }
    }

    const pfad = `${uid}/eingang/${Date.now()}_${name.replace(/[^a-zA-Z0-9._-]/g, '_')}`;
    const up = await sb.storage.from('belege').upload(pfad, bytes, { contentType: mime });
    if (up.error) { ergebnis.push({ name, status: 'Fehler beim Speichern' }); continue; }

    const ins = await sb.from('beleg_eingang').insert({
      user_id: uid, quelle: 'gmail', message_id: messageId, absender, betreff, dateiname: name, mime, pfad,
    });
    if (ins.error) {
      await sb.storage.from('belege').remove([pfad]);
      ergebnis.push({ name, status: 'Fehler beim Eintragen' });
      continue;
    }
    ergebnis.push({ name, status: 'ok' });
  }

  // 200 auch bei übersprungenen Dateien: das Skript soll die Mail dann nicht ewig neu schicken
  const fehler = ergebnis.some((e) => e.status.startsWith('Fehler'));
  return json({ ergebnis }, fehler ? 502 : 200);
});
