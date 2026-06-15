// GT7 Race Engineer — app-shell service worker.
//
// HTML/navigation is NETWORK-FIRST so a freshly deployed dashboard always
// lands (the previous version cached the page cache-first under a fixed name,
// which froze the UI across updates). Only genuinely static assets are cached;
// the WebSocket and every API route always go straight to the network.
//
// Bumping CACHE invalidates the old cache on activate.
const CACHE = "raceeng-v3";
const ASSETS = [
  "/static/icon-192.png",
  "/static/icon-512.png",
  "/manifest.webmanifest"
];

self.addEventListener("install", (e) => {
  e.waitUntil(
    caches.open(CACHE).then((c) => c.addAll(ASSETS)).then(() => self.skipWaiting())
  );
});

self.addEventListener("activate", (e) => {
  e.waitUntil(
    caches.keys()
      .then((keys) => Promise.all(keys.filter((k) => k !== CACHE).map((k) => caches.delete(k))))
      .then(() => self.clients.claim())
  );
});

self.addEventListener("fetch", (e) => {
  const req = e.request;
  if (req.method !== "GET") return;
  const url = new URL(req.url);
  if (url.origin !== self.location.origin) return;

  // The dashboard HTML: network-first, fall back to cache only when offline.
  const isNav = req.mode === "navigate" ||
                (req.headers.get("accept") || "").includes("text/html");
  if (isNav) {
    e.respondWith(
      fetch(req)
        .then((res) => {
          const copy = res.clone();
          caches.open(CACHE).then((c) => c.put("/", copy)).catch(() => {});
          return res;
        })
        .catch(() => caches.match("/").then((hit) => hit || caches.match(req)))
    );
    return;
  }

  // Static assets only: cache-first with a background refresh.
  if (url.pathname.startsWith("/static/") || url.pathname === "/manifest.webmanifest") {
    e.respondWith(
      caches.match(req).then((hit) =>
        hit || fetch(req).then((res) => {
          const copy = res.clone();
          caches.open(CACHE).then((c) => c.put(req, copy)).catch(() => {});
          return res;
        })
      )
    );
    return;
  }

  // Everything else (/ws, /catalog, /schemas, /session, /sessions, /lap_trace,
  // /reference, /tracks, /references, /config, /discover, /ask, /tts, …): network.
});