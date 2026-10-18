// Google Apps Script für dein Gmail-Konto: findet Rechnungen in Gmail und schickt
// PDF-/Bild-Anhänge an die Belege-App (Supabase-Funktion beleg-eingang).
//
// Automatisch erkannt werden neue Mails mit PDF-Anhang und einem der SUCHWOERTER
// (kein Gmail-Filter nötig). Alles andere kann man von Hand mit dem Label "Belege"
// markieren. Übertragene Mails bekommen das Label "Belege-erledigt".
// Einrichtung: EINGANG-EINRICHTEN.md
//
// Zugangsdaten stehen NICHT hier, sondern unter Projekteinstellungen → Skripteigenschaften:
//   FUNKTION_URL   = https://<projekt>.supabase.co/functions/v1/beleg-eingang
//   EINGANG_TOKEN  = derselbe geheime Wert wie das Supabase-Secret EINGANG_TOKEN
//   SUPABASE_KEY   = Publishable key des Projekts (sb_publishable_…, Project Settings → API Keys);
//                    das Supabase-Gateway verlangt ihn, solange die JWT-Prüfung der Funktion an ist

const LABEL_NEU = 'Belege';
const LABEL_ERLEDIGT = 'Belege-erledigt';
const SUCHWOERTER = ['Rechnung', 'Invoice', 'Faktura', 'Gutschrift', 'Beleg'];
const ERLAUBT = ['application/pdf', 'image/jpeg', 'image/png', 'image/webp', 'image/heic'];
const MIN_BILD_BYTES = 30 * 1024; // kleinere Bilder sind fast immer Logos oder Signaturen
const MAX_BYTES = 10 * 1024 * 1024;

// Einmal von Hand ausführen: legt die Labels an, merkt sich das Startdatum (ältere Mails
// werden nicht automatisch geholt) und startet den 15-Minuten-Zeitplan.
function einrichten() {
  einstellungen_();
  label_(LABEL_NEU);
  label_(LABEL_ERLEDIGT);
  const p = PropertiesService.getScriptProperties();
  if (!p.getProperty('START')) {
    p.setProperty('START', Utilities.formatDate(new Date(), 'Europe/Vienna', 'yyyy/MM/dd'));
  }
  ScriptApp.getProjectTriggers()
    .filter((t) => t.getHandlerFunction() === 'belegeAbholen')
    .forEach((t) => ScriptApp.deleteTrigger(t));
  ScriptApp.newTrigger('belegeAbholen').timeBased().everyMinutes(15).create();
  belegeAbholen();
}

function belegeAbholen() {
  const { url, token, apikey } = einstellungen_();
  const neu = label_(LABEL_NEU);
  const erledigt = label_(LABEL_ERLEDIGT);
  const start = PropertiesService.getScriptProperties().getProperty('START');

  // Von Hand markierte Mails + automatisch gefundene Rechnungen seit dem Einrichten
  const suche = 'has:attachment filename:pdf (' + SUCHWOERTER.join(' OR ') + ')'
    + ' -label:' + LABEL_ERLEDIGT.toLowerCase() + (start ? ' after:' + start : '');
  const threads = neu.getThreads(0, 20).concat(GmailApp.search(suche, 0, 20));
  const gesehen = {};

  threads.forEach((thread) => {
    if (gesehen[thread.getId()]) return;
    gesehen[thread.getId()] = true;
    let allesOk = true;
    thread.getMessages().forEach((msg) => {
      const dateien = msg.getAttachments({ includeInlineImages: false })
        .map((a) => ({ a, mime: String(a.getContentType()).split(';')[0].trim().toLowerCase() }))
        .filter(({ a, mime }) =>
          ERLAUBT.indexOf(mime) >= 0 &&
          a.getSize() <= MAX_BYTES &&
          !(mime.indexOf('image/') === 0 && a.getSize() < MIN_BILD_BYTES))
        .map(({ a, mime }) => ({ name: a.getName(), mime, base64: Utilities.base64Encode(a.getBytes()) }));
      if (!dateien.length) return;

      const headers = { 'x-eingang-token': token };
      if (apikey) headers['apikey'] = apikey;
      const antwort = UrlFetchApp.fetch(url, {
        method: 'post',
        contentType: 'application/json',
        headers,
        payload: JSON.stringify({ message_id: msg.getId(), absender: msg.getFrom(), betreff: msg.getSubject(), dateien }),
        muteHttpExceptions: true,
      });
      if (antwort.getResponseCode() !== 200) {
        allesOk = false;
        console.error('Übertragung fehlgeschlagen (' + antwort.getResponseCode() + '): ' + msg.getSubject() + ' – ' + antwort.getContentText());
      }
    });
    // Nur bei Erfolg umlabeln — sonst wird es beim nächsten Lauf erneut versucht
    // (doppelte Anhänge erkennt die Funktion selbst und überspringt sie)
    if (allesOk) {
      thread.removeLabel(neu);
      thread.addLabel(erledigt);
    }
  });
}

function einstellungen_() {
  const p = PropertiesService.getScriptProperties();
  const url = p.getProperty('FUNKTION_URL');
  const token = p.getProperty('EINGANG_TOKEN');
  const apikey = p.getProperty('SUPABASE_KEY');
  if (!url || !token) {
    throw new Error('Bitte zuerst FUNKTION_URL und EINGANG_TOKEN unter Projekteinstellungen → Skripteigenschaften eintragen.');
  }
  return { url, token, apikey };
}

function label_(name) {
  return GmailApp.getUserLabelByName(name) || GmailApp.createLabel(name);
}
