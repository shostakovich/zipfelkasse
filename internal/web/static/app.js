// teilen – kleine Verbesserungen für alle Seiten. Alles funktioniert auch
// ohne JavaScript; dieses Skript macht es nur bequemer.
(function () {
  "use strict";
  document.documentElement.classList.add("js");

  document.addEventListener("DOMContentLoaded", function () {
    // Filter-Auswahl schickt das Formular sofort ab.
    document.querySelectorAll("select[data-autosubmit]").forEach(function (el) {
      el.addEventListener("change", function () {
        if (el.form) el.form.requestSubmit ? el.form.requestSubmit() : el.form.submit();
      });
    });
  });

  // Rückfrage vor gefährlichen Aktionen: <button data-confirm="Wirklich?">.
  document.addEventListener("click", function (ev) {
    var el = ev.target.closest && ev.target.closest("[data-confirm]");
    if (el && !window.confirm(el.getAttribute("data-confirm"))) {
      ev.preventDefault();
    }
  });

  // Service Worker nur für die Installierbarkeit (kein Offline-Cache).
  if ("serviceWorker" in navigator && window.isSecureContext) {
    window.addEventListener("load", function () {
      navigator.serviceWorker.register("/sw.js").catch(function () {});
    });
  }
})();
