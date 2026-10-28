// Service worker: aplikacja otwiera się szybko i działa przy słabym zasięgu,
// a także odbiera powiadomienia push (przeglądarka, aplikacja z ekranu głównego, iPhone).
// Kafelki mapy i dane z bazy zawsze idą z sieci.
const CACHE = 'dk-shell-v14';
const SHELL = ['./', './index.html', './manifest-pl.webmanifest', './manifest-en.webmanifest', './icon-192.png', './icon-512.png'];
self.addEventListener('install', e => { e.waitUntil(caches.open(CACHE).then(c => c.addAll(SHELL))); self.skipWaiting(); });
self.addEventListener('activate', e => {
  e.waitUntil(caches.keys().then(keys => Promise.all(keys.filter(k => k !== CACHE).map(k => caches.delete(k)))));
  self.clients.claim();
});
self.addEventListener('fetch', e => {
  const url = new URL(e.request.url);
  if (e.request.method !== 'GET' || url.origin !== location.origin) return;
  e.respondWith(
    fetch(e.request)
      .then(r => { const copy = r.clone(); caches.open(CACHE).then(c => c.put(e.request, copy)); return r; })
      .catch(() => caches.match(e.request).then(r => r || caches.match('./index.html')))
  );
});

// ---------- powiadomienia push ----------
self.addEventListener('push', e => {
  let m = {};
  try { m = e.data ? e.data.json() : {}; } catch (err) { m = { title: 'Tropami', body: e.data ? e.data.text() : '' }; }
  e.waitUntil(self.registration.showNotification(m.title || 'Tropami', {
    body: m.body || '',
    icon: './icon-192.png',
    badge: './badge-96.png',
    tag: m.kind || 'tropami',
    renotify: false,
    data: { url: m.url || './', kind: m.kind || '' },
  }));
});
self.addEventListener('notificationclick', e => {
  e.notification.close();
  const target = new URL(e.notification.data?.url || './', self.registration.scope).href;
  e.waitUntil((async () => {
    const wins = await self.clients.matchAll({ type: 'window', includeUncontrolled: true });
    const open = wins.find(w => w.url.startsWith(self.registration.scope));
    if (open) { await open.focus(); return open.navigate(target).catch(() => {}); }
    return self.clients.openWindow(target);
  })());
});
