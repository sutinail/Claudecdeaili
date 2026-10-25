// 只缓存页面外壳，接口一律走网络
const CACHE = "lumi-shell-v20";
const SHELL = ["/", "/style.css?v=19", "/app.js?v=19", "/manifest.webmanifest", "/icon-192.png", "/apple-touch-icon.png", "/bg/ange.jpg", "/fonts/pinyon-script-latin-400-normal.woff2", "/fonts/cormorant-garamond-latin-300-italic.woff2", "/fonts/cormorant-garamond-latin-400-normal.woff2"];

self.addEventListener("install", (e) => {
  e.waitUntil(caches.open(CACHE).then((c) => c.addAll(SHELL)).then(() => self.skipWaiting()));
});

self.addEventListener("activate", (e) => {
  e.waitUntil(caches.keys().then((keys) => Promise.all(keys.filter((k) => k !== CACHE).map((k) => caches.delete(k)))).then(() => self.clients.claim()));
});

self.addEventListener("fetch", (e) => {
  const url = new URL(e.request.url);
  if (e.request.method !== "GET" || url.origin !== location.origin || url.pathname.startsWith("/api/")) return;
  e.respondWith(
    fetch(e.request)
      .then((r) => {
        if (r.ok) { const copy = r.clone(); caches.open(CACHE).then((c) => c.put(e.request, copy)); }
        return r;
      })
      .catch(() => caches.match(e.request).then((r) => r || caches.match("/")))
  );
});
