// GT7 Race Engineer — minimal app-shell service worker.
// Caches the static shell so the dashboard opens instantly when launched from
// the home screen. Live data still comes over the WebSocket (never cached).
const CACHE = "raceeng-v1";
const SHELL = [
  "/",
  "/static/icon-192.png",
  "/static/icon-512.png",
  "/manifest.webmanifest"
];

self.addEventListener("install", (e) => {
  e.waitUntil(caches.open(CACHE).then((c) => c.addAll(SHELL)).then(() => self.skipWaiting()));
});

self.addEventListener("activate", (e) => {
  e.waitUntil(
    caches.keys().then((keys) =>
      Promise.all(keys.filter((k) => k !== CACHE).map((k) => caches.delete(k)))
    ).then(() => self.clients.claim())
  );
});

self.addEventListener("fetch", (e) => {
  const url = new URL(e.request.url);
  // never intercept the websocket or API calls — always go to network
  if (url.pathname.startsWith("/ws") || url.pathname.startsWith("/session") ||
      url.pathname.startsWith("/analyze") || url.pathname.startsWith("/laps") ||
      url.pathname.startsWith("/tracks") || url.pathname.startsWith("/schemas") ||
      url.pathname.startsWith("/baseline")) {
    return; // default network handling
  }
  // app shell: cache-first, fall back to network
  e.respondWith(
    caches.match(e.request).then((hit) => hit || fetch(e.request).then((res) => {
      const copy = res.clone();
      caches.open(CACHE).then((c) => c.put(e.request, copy)).catch(() => {});
      return res;
    }).catch(() => caches.match("/")))
  );
});
