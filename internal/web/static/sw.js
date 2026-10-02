// Zipfelkasse – minimaler Service Worker. Er ist nur da, damit die App
// installierbar ist. Es wird bewusst nichts zwischengespeichert: Seiten
// kommen immer frisch vom Server, damit nie veraltete Salden zu sehen sind.
// Nur wenn der Server nicht erreichbar ist, erscheint ein Offline-Hinweis.

self.addEventListener("install", function () {
  self.skipWaiting();
});

self.addEventListener("activate", function (event) {
  event.waitUntil(self.clients.claim());
});

var OFFLINE_HTML =
  '<!doctype html><html lang="de"><head><meta charset="utf-8">' +
  '<meta name="viewport" content="width=device-width, initial-scale=1">' +
  "<title>Offline</title><style>body{font-family:system-ui,sans-serif;margin:0;" +
  "min-height:100vh;display:flex;align-items:center;justify-content:center;padding:1rem;" +
  "text-align:center;color:#18181b;background:#fff}@media(prefers-color-scheme:dark)" +
  "{body{color:#f2f2f2;background:#0c0a09}}a{color:inherit}</style></head><body><div>" +
  "<h1>Keine Verbindung</h1><p>Der Server ist gerade nicht erreichbar.</p>" +
  '<p><a href="">Erneut versuchen</a></p></div></body></html>';

self.addEventListener("fetch", function (event) {
  if (event.request.mode !== "navigate") return; // alles andere geht normal ans Netz
  event.respondWith(
    fetch(event.request).catch(function () {
      return new Response(OFFLINE_HTML, {
        status: 503,
        headers: { "Content-Type": "text/html; charset=utf-8" },
      });
    })
  );
});
