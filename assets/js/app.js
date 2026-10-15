import "phoenix_html"
import { Socket } from "phoenix"
import { LiveSocket } from "phoenix_live_view"
import { hooks as colocatedHooks } from "phoenix-colocated/zipfelkasse"
import { hooks as setzkastenHooks } from "phoenix-colocated/setzkasten"

const csrfToken = document.querySelector("meta[name='csrf-token']").getAttribute("content")

const liveSocket = new LiveSocket("/live", Socket, {
  params: { _csrf_token: csrfToken },
  hooks: { ...colocatedHooks, ...setzkastenHooks },
})

liveSocket.connect()
window.liveSocket = liveSocket

const unlock = (form) => {
  delete form.dataset.submitting
  form.querySelectorAll("[data-submit-locked]").forEach((button) => {
    button.disabled = false
    button.removeAttribute("data-submit-locked")
  })
}

// Forms without LiveView post once; buttons lock after the submit: disabled ones send no value.
document.addEventListener("submit", (event) => {
  const form = event.target
  if (form.method !== "post" || form.hasAttribute("phx-submit")) return
  if (form.dataset.submitting) return event.preventDefault()

  form.dataset.submitting = "true"
  setTimeout(() => {
    if (event.defaultPrevented) return unlock(form)

    form.querySelectorAll("button[type=submit], button:not([type])").forEach((button) => {
      if (!button.disabled) {
        button.disabled = true
        button.setAttribute("data-submit-locked", "")
      }
    })
    setTimeout(() => unlock(form), 10000)
  })
})

// The back/forward cache brings a page back as it was left, still locked.
window.addEventListener("pageshow", (event) => {
  if (event.persisted) document.querySelectorAll("form[data-submitting]").forEach(unlock)
})

if ("serviceWorker" in navigator && window.isSecureContext) {
  window.addEventListener("load", () => navigator.serviceWorker.register("/sw.js").catch(() => {}))
}
