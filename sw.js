// Service Worker dieser App: macht sie offline nutzbar.
// Die eigentliche Logik (Dateien merken, Supabase-Daten merken, Änderungen
// ohne Netz in einer Warteschlange sammeln und nachschicken, Konfliktregel
// „nichts überschreiben“) steckt zentral in ghd-offline-sw.js im Repo
// abwesenheiten-ghd und gilt für alle Great-Hair-Day-Apps gleich.
// Neue Seiten/Dateien dieser App hier bei `vorab` ergänzen.
self.GHD_OFFLINE = {
  app: 'belege',
  version: '2026-10-20a',
  start: './belege.html',
  vorab: [
    './',
    './belege.html',
    './cockpit.html',
    './index.html',
    './icon-512.png',
    './manifest.json',
    'https://mirjamwalenta-a11y.github.io/abwesenheiten-ghd/icon-512.png'
  ]
};
// „Teilen → Belege“ (Android, siehe share_target in manifest.json): die geteilten Dateien
// kurz im Cache ablegen und die App öffnen, die sie dann wie hochgeladene Dateien verarbeitet.
// Muss VOR importScripts registriert werden, damit dieser Handler den POST zuerst bekommt.
self.addEventListener('fetch', (event) => {
  const url = new URL(event.request.url);
  if (event.request.method !== 'POST' || !url.pathname.endsWith('/teilen')) return;
  event.respondWith((async () => {
    const form = await event.request.formData();
    const cache = await caches.open('belege-geteilt');
    let i = 0;
    for (const f of form.getAll('dateien')) {
      if (!(f instanceof File) || !f.size) continue;
      await cache.put(new URL('geteilt/' + Date.now() + '-' + (i++), self.registration.scope).href,
        new Response(f, { headers: { 'Content-Type': f.type || 'application/octet-stream', 'X-Dateiname': encodeURIComponent(f.name) } }));
    }
    return Response.redirect(new URL('belege.html?geteilt=1', self.registration.scope).href, 303);
  })());
});
importScripts('https://mirjamwalenta-a11y.github.io/abwesenheiten-ghd/ghd-offline-sw.js');
