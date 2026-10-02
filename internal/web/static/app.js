// Zipfelkasse: small enhancements for all pages. Everything also works
// without JavaScript; this script just makes it more convenient.
(function () {
  "use strict";
  document.documentElement.classList.add("js");

  document.addEventListener("DOMContentLoaded", function () {
    // Changing a filter select submits the form right away.
    document.querySelectorAll("select[data-autosubmit]").forEach(function (el) {
      el.addEventListener("change", function () {
        if (el.form) el.form.requestSubmit ? el.form.requestSubmit() : el.form.submit();
      });
    });
  });

  // Ask for confirmation before dangerous actions: <button data-confirm="Wirklich?">.
  document.addEventListener("click", function (ev) {
    var el = ev.target.closest && ev.target.closest("[data-confirm]");
    if (el && !window.confirm(el.getAttribute("data-confirm"))) {
      ev.preventDefault();
    }
  });

  // Service worker only for installability (no offline cache).
  if ("serviceWorker" in navigator && window.isSecureContext) {
    window.addEventListener("load", function () {
      navigator.serviceWorker.register("/sw.js").catch(function () {});
    });
  }
})();
