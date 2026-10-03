// Zipfelkasse: small enhancements for all pages. Everything also works
// without JavaScript; this script just makes it more convenient.
(function () {
  "use strict";
  document.documentElement.classList.add("js");

  document.addEventListener("DOMContentLoaded", function () {
    // Bar widths are set here, so that the CSP needs no inline styles.
    document.querySelectorAll("[data-width]").forEach(function (el) {
      el.style.width = el.dataset.width + "%";
    });
    // Changing a filter select or an appearance radio submits the form right away.
    document.querySelectorAll("select[data-autosubmit], [data-autosubmit] input[type=radio]").forEach(function (el) {
      el.addEventListener("change", function () {
        if (el.form) el.form.requestSubmit ? el.form.requestSubmit() : el.form.submit();
      });
    });
  });

  // Paged lists: load the next page in place when its "more" link
  // (<a data-more>) comes into view or is clicked, instead of navigating and
  // jumping to the top. The list (<div data-more-list>) contains groups
  // (<div data-group="Label">) whose items are their other children. Items
  // already shown (same id) are skipped, so pages may repeat earlier items.
  // With data-sync-url the address is updated, so that reloading or going
  // back shows the same items.
  function loadMore(link) {
    if (link.getAttribute("aria-busy")) return;
    link.setAttribute("aria-busy", "true");
    link.textContent = "Lädt …";
    var list = link.closest("[data-more-list]");
    fetch(link.href, { credentials: "same-origin" })
      .then(function (res) {
        if (!res.ok) throw new Error(res.status);
        return res.text();
      })
      .then(function (html) {
        var next = new DOMParser().parseFromString(html, "text/html").querySelector("[data-more-list]");
        if (!next) throw new Error("no list");
        var oldMore = list.querySelector(".list-more");
        var hadFocus = document.activeElement === link;
        var first = null;
        next.querySelectorAll("[data-group]").forEach(function (group) {
          var items = Array.prototype.filter.call(group.children, function (el) {
            return !el.classList.contains("list-group-label") && !(el.id && document.getElementById(el.id));
          });
          if (!items.length) return;
          first = first || items[0];
          var groups = list.querySelectorAll("[data-group]");
          var last = groups[groups.length - 1];
          if (last && last.getAttribute("data-group") === group.getAttribute("data-group")) {
            items.forEach(function (el) { last.appendChild(el); });
          } else {
            Array.prototype.slice.call(group.children).forEach(function (el) {
              if (items.indexOf(el) < 0 && !el.classList.contains("list-group-label")) el.remove();
            });
            list.insertBefore(group, oldMore);
          }
        });
        var newMore = next.querySelector(".list-more");
        if (newMore) {
          oldMore.replaceWith(newMore);
          watchMore(newMore.querySelector("[data-more]"));
        } else {
          oldMore.remove();
        }
        if (list.hasAttribute("data-sync-url")) history.replaceState(history.state, "", link.href);
        // Keyboard users continue at the first new item.
        if (hadFocus && first) first.focus();
      })
      .catch(function () {
        window.location.href = link.href;
      });
  }

  var moreObserver = "IntersectionObserver" in window && new IntersectionObserver(function (entries) {
    entries.forEach(function (entry) {
      if (entry.isIntersecting) {
        moreObserver.unobserve(entry.target);
        loadMore(entry.target);
      }
    });
  }, { rootMargin: "0px 0px 400px 0px" });

  function watchMore(link) {
    if (link && moreObserver) moreObserver.observe(link);
  }

  document.addEventListener("DOMContentLoaded", function () {
    document.querySelectorAll("[data-more-list] [data-more]").forEach(watchMore);
  });

  document.addEventListener("click", function (ev) {
    var link = ev.target.closest && ev.target.closest("[data-more-list] [data-more]");
    if (link && !ev.metaKey && !ev.ctrlKey && !ev.shiftKey && ev.button === 0) {
      ev.preventDefault();
      loadMore(link);
    }
  });

  // Ask for confirmation before dangerous actions: <button data-confirm="Wirklich?">.
  document.addEventListener("click", function (ev) {
    var el = ev.target.closest && ev.target.closest("[data-confirm]");
    if (el && !window.confirm(el.getAttribute("data-confirm"))) {
      ev.preventDefault();
    }
  });

  // Submit lock: a POST form is sent only once, so that a double click or a
  // second Enter does not create an expense twice. The buttons are disabled
  // only after the submission has started: disabled buttons would drop the
  // clicked button's name/value (e.g. "Wer bist du?") and formaction. After
  // a validation error the server renders a fresh page anyway; if the
  // navigation is stopped, the lock is lifted after a while.
  var LOCK_MS = 10000;
  function unlock(form) {
    delete form.dataset.submitting;
    form.querySelectorAll("[data-submit-locked]").forEach(function (b) {
      b.disabled = false;
      b.removeAttribute("data-submit-locked");
    });
  }
  document.addEventListener("submit", function (ev) {
    var form = ev.target;
    if (ev.defaultPrevented || (form.getAttribute("method") || "").toLowerCase() !== "post") return;
    if (form.dataset.submitting) {
      ev.preventDefault();
      return;
    }
    form.dataset.submitting = "1";
    setTimeout(function () {
      if (ev.defaultPrevented) {
        // Cancelled by a later handler: nothing was sent.
        delete form.dataset.submitting;
        return;
      }
      form.querySelectorAll('button:not([type]), button[type="submit"], input[type="submit"]').forEach(function (b) {
        if (!b.disabled) {
          b.disabled = true;
          b.setAttribute("data-submit-locked", "");
        }
      });
      setTimeout(function () { unlock(form); }, LOCK_MS);
    }, 0);
  });
  // Back/forward cache: the page comes back as it was left, still locked.
  window.addEventListener("pageshow", function (ev) {
    if (ev.persisted) document.querySelectorAll("form[data-submitting]").forEach(unlock);
  });

  // Service worker only for installability (no offline cache).
  if ("serviceWorker" in navigator && window.isSecureContext) {
    window.addEventListener("load", function () {
      navigator.serviceWorker.register("/sw.js").catch(function () {});
    });
  }
})();
