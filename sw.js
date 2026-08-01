// Service Worker для Dzikie Korytarze PWA
const CACHE = 'dzikie-korytarze-v1';
const ASSETS = ['./index.html', './manifest.json'];

// Установка — кешируем оболочку приложения
self.addEventListener('install', e => {
  e.waitUntil(caches.open(CACHE).then(c => c.addAll(ASSETS)));
  self.skipWaiting();
});

// Активация — чистим старые кеши
self.addEventListener('activate', e => {
  e.waitUntil(
    caches.keys().then(keys =>
      Promise.all(keys.filter(k => k !== CACHE).map(k => caches.delete(k)))
    )
  );
  self.clients.claim();
});

// Запросы: сеть в приоритете, кеш как запасной (для работы офлайн)
self.addEventListener('fetch', e => {
  // не трогаем запросы к API (Supabase, Google Maps, Nominatim) — только сеть
  const url = e.request.url;
  if (url.includes('supabase.co') || url.includes('googleapis.com') ||
      url.includes('nominatim') || url.includes('cdn.jsdelivr')) {
    return; // пусть идут напрямую в сеть
  }
  e.respondWith(
    fetch(e.request).catch(() => caches.match(e.request))
  );
});
