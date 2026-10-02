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

  // Service worker only for installability (no offline cache).
  if ("serviceWorker" in navigator && window.isSecureContext) {
    window.addEventListener("load", function () {
      navigator.serviceWorker.register("/sw.js").catch(function () {});
    });
  }
})();
