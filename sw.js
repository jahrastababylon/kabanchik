// Stary service worker z czasów, gdy aplikacja była w katalogu głównym.
// Teraz aplikacja jest w /app/ — ten plik czyści stare dane i wyrejestrowuje się.
self.addEventListener('install', () => self.skipWaiting());
self.addEventListener('activate', e => {
  e.waitUntil((async () => {
    for(const k of await caches.keys()) await caches.delete(k);
    await self.registration.unregister();
    for(const c of await self.clients.matchAll({ type:'window' })) c.navigate(c.url);
  })());
});
