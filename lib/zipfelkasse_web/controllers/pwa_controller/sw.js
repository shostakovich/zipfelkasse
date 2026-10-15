// Installability only: nothing is cached, so balances are never stale.

self.addEventListener("install", () => self.skipWaiting())

self.addEventListener("activate", (event) => event.waitUntil(self.clients.claim()))

const STYLE =
  "body{font-family:system-ui,sans-serif;margin:0;min-height:100vh;display:flex;" +
  "align-items:center;justify-content:center;padding:1rem;text-align:center;" +
  "color:#0d1928;background:#fff}a{color:inherit}" +
  "@media(prefers-color-scheme:dark){body{color:#e9ebef;background:#202328}}"

const OFFLINE =
  '<!doctype html><html lang="de"><head><meta charset="utf-8">' +
  '<meta name="viewport" content="width=device-width, initial-scale=1">' +
  `<title>Offline</title><style>${STYLE}</style></head><body><main>` +
  "<h1>Keine Verbindung</h1><p>Der Server ist gerade nicht erreichbar.</p>" +
  '<p><a href="">Erneut versuchen</a></p></main></body></html>'

let policy

// The notice keeps a strict policy: its one inline style is allowed by its hash.
async function offlinePolicy() {
  if (!policy) {
    const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(STYLE))
    const hash = btoa(String.fromCharCode(...new Uint8Array(digest)))
    policy = `default-src 'none'; style-src 'sha256-${hash}'; base-uri 'none'; form-action 'none'`
  }
  return policy
}

self.addEventListener("fetch", (event) => {
  if (event.request.mode !== "navigate") return

  event.respondWith(
    fetch(event.request).catch(
      async () =>
        new Response(OFFLINE, {
          status: 503,
          headers: {
            "Content-Type": "text/html; charset=utf-8",
            "Content-Security-Policy": await offlinePolicy(),
          },
        }),
    ),
  )
})
