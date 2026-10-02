// Zipfelkasse: expense form. Live preview of the split (exact to the cent like
// domain.Split: largest remainder method; on ties, precedence rotates with the
// expense ID from data-rotation), foreign currency with rate lookup via
// /api/kurs and conversion to euros.
// The form also works without this script; the server validates everything.
(function () {
  "use strict";

  var form = document.getElementById("expense-form");
  if (!form || form.querySelector("fieldset[disabled]")) return;
  // expense ID (the expected one for new expenses), see domain.Split.
  var rotation = Number(form.getAttribute("data-rotation")) || 0;

  var $ = function (id) { return document.getElementById(id); };
  var amountEl = $("betrag"), currencyEl = $("waehrung"), otherEl = $("waehrung_andere");
  var dateEl = $("datum"), rateEl = $("kurs"), rateSourceEl = $("kurs_quelle");
  var rateHint = $("kurs-hinweis"), rateReload = $("kurs-laden"), eurPreview = $("eur-vorschau");
  var modeEl = $("aufteilung"), reimbEl = $("rueckzahlung"), titleEl = $("titel");
  var rowsEl = $("split-rows"), sumEl = $("split-summe"), selectAll = $("alle-auswaehlen");
  var rows = Array.prototype.map.call(rowsEl.querySelectorAll(".split-row"), function (el) {
    return {
      id: Number(el.getAttribute("data-id")),
      check: el.querySelector('input[name="teil"]'),
      input: el.querySelector('input[name^="wert_"]'),
      share: el.querySelector("[data-share]"),
      unit: el.querySelector("[data-unit]"),
    };
  }).sort(function (a, b) { return a.id - b.id; });

  // --- Numbers -------------------------------------------------------------

  var DECIMALS0 = ["JPY", "KRW", "ISK", "HUF", "CLP", "VND", "XAF", "XOF", "PYG", "UGX", "IDR"];
  var DECIMALS3 = ["KWD", "BHD", "OMR", "JOD", "TND", "LYD", "IQD"];
  function decimals(cur) {
    if (DECIMALS0.indexOf(cur) >= 0) return 0;
    if (DECIMALS3.indexOf(cur) >= 0) return 3;
    return 2;
  }

  // splitNumber splits a number like domain.splitNumber into sign, integer
  // and fractional digits ({neg, int, frac}) or returns null.
  // dotThousands: a single dot before exactly three digits is a thousands
  // separator ("17.000" = 17000).
  function splitNumber(s, dotThousands) {
    if (!s) return null;
    var neg = false;
    if (s[0] === "-" || s[0] === "+") { neg = s[0] === "-"; s = s.slice(1); }
    if (!/^[0-9.,]+$/.test(s)) return null;
    var dots = s.split(".").length - 1, commas = s.split(",").length - 1;
    var intPart = s, frac = "", thousands = "";
    if (dots > 0 && commas > 0) {
      var d = Math.max(s.lastIndexOf("."), s.lastIndexOf(","));
      thousands = s[d] === "." ? "," : ".";
      intPart = s.slice(0, d); frac = s.slice(d + 1);
    } else if (dots + commas > 1) {
      thousands = commas > 0 ? "," : ".";
    } else if (dots + commas === 1) {
      var p = Math.max(s.lastIndexOf("."), s.lastIndexOf(","));
      if (s[p] === "." && s.length - p - 1 === 3 && dotThousands && p > 0) {
        thousands = ".";
      } else {
        intPart = s.slice(0, p); frac = s.slice(p + 1);
        if (!frac) return null;
      }
    }
    if (thousands) {
      var groups = intPart.split(thousands);
      if (!groups[0] || groups[0].length > 3 || groups.slice(1).some(function (g) { return g.length !== 3; })) return null;
      intPart = groups.join("");
    }
    if (/[.,]/.test(intPart + frac)) return null;
    return { neg: neg, int: intPart || "0", frac: frac };
  }

  // parseMinor reads "12,34", "12.34", "1.234,56" like domain.ParseMinor;
  // the result is a BigInt in the minor unit, or null.
  function parseMinor(s, dec) {
    var n = splitNumber(String(s || "").replace(/[\s €%]/g, ""), dec < 3);
    if (!n || n.frac.length > dec) return null;
    var v = BigInt(n.int + n.frac + "0".repeat(dec - n.frac.length));
    return n.neg ? -v : v;
  }

  // parseRate reads a rate like domain.ParseRate ("1,0857", "17.000" = 17000).
  function parseRate(s) {
    var n = splitNumber(String(s || "").replace(/\s/g, ""), true);
    if (!n || n.neg) return null;
    var v = Number(n.int + "." + n.frac + "0");
    return isFinite(v) && v > 0 ? v : null;
  }

  var eurFmt = new Intl.NumberFormat("de-DE", { style: "currency", currency: "EUR" });
  function formatCents(c) { return eurFmt.format(Number(c) / 100); }

  // formatInput: BigInt amount → input format "1234,56".
  function formatInput(v, dec) {
    var neg = v < 0n, s = (neg ? -v : v).toString();
    if (dec > 0) {
      s = s.padStart(dec + 1, "0");
      s = s.slice(0, -dec) + "," + s.slice(-dec);
    }
    return (neg ? "-" : "") + s;
  }
  function formatPercent(bp) {
    return bp % 100n === 0n ? (bp / 100n).toString() : formatInput(bp, 2);
  }

  // allocate distributes total proportionally to weights (largest remainder).
  // weights belong to people in ascending ID order. On ties, precedence among
  // the tied rotates by rot (like domain.Split with the expense ID); without
  // rot, the smaller index gets it (like web.allocate).
  function allocate(total, weights, rot) {
    var sum = weights.reduce(function (a, b) { return a + b; }, 0n);
    if (sum <= 0n) return null;
    var out = [], rems = [], allocated = 0n;
    weights.forEach(function (w, i) {
      out[i] = (total * w) / sum;
      rems[i] = (total * w) % sum;
      allocated += out[i];
    });
    var order = weights.map(function (_, i) { return i; });
    order.sort(function (a, b) { return rems[b] > rems[a] ? 1 : rems[b] < rems[a] ? -1 : a - b; });
    for (var i = 0; rot && i < order.length;) {
      var j = i + 1;
      while (j < order.length && rems[order[j]] === rems[order[i]]) j++;
      var n = j - i, r = ((rot % n) + n) % n, group = order.slice(i, j);
      Array.prototype.splice.apply(order, [i, n].concat(group.slice(r), group.slice(0, r)));
      i = j;
    }
    for (var k = 0; allocated < total; k++) {
      out[order[k % order.length]] += 1n;
      allocated += 1n;
    }
    return out;
  }

  // --- State ---------------------------------------------------------------

  function currency() {
    var c = currencyEl.value || otherEl.value;
    c = String(c || "").trim().toUpperCase();
    return c || "EUR";
  }
  function mode() { return reimbEl.checked ? "equal" : modeEl.value; }

  // eurTotal returns the total amount in euro cents (BigInt) or null.
  function eurTotal() {
    var cur = currency();
    if (cur === "EUR") return parseMinor(amountEl.value, 2);
    var orig = parseMinor(amountEl.value, decimals(cur)), rate = parseRate(rateEl.value);
    if (orig === null || rate === null) return null;
    var cents = Math.round(Number(orig) / Math.pow(10, decimals(cur)) / rate * 100);
    return BigInt(cents);
  }

  function unitLabel() {
    switch (mode()) {
      case "shares": return "Anteile";
      case "percent": return "%";
    }
    var cur = currency();
    return cur === "EUR" ? "€" : cur;
  }

  // --- Display -------------------------------------------------------------

  function setHidden(selector, hidden) {
    form.querySelectorAll(selector).forEach(function (el) { el.hidden = hidden; });
  }

  function updateVisibility() {
    var cur = currency(), foreign = cur !== "EUR";
    setHidden(".fx-only", !foreign);
    setHidden(".currency-other", currencyEl.value !== "");
    setHidden(".only-reimbursement", !reimbEl.checked);
    setHidden(".not-reimbursement", reimbEl.checked);
    rows.forEach(function (r) {
      r.input.parentNode.hidden = mode() === "equal";
      r.unit.textContent = unitLabel();
    });
    $("betrag-einheit").textContent = foreign ? cur : "€";
    $("kurs-einheit").textContent = foreign ? cur : "";
    if (selectAll) {
      var all = rows.every(function (r) { return r.check.checked; });
      selectAll.textContent = all ? "Keine auswählen" : "Alle auswählen";
    }
  }

  function updatePreview() {
    var cur = currency(), total = eurTotal(), m = mode();
    if (cur !== "EUR") eurPreview.textContent = total !== null && total > 0n ? formatCents(total) : "–";

    var active = rows.filter(function (r) { return r.check.checked; });
    rows.forEach(function (r) { r.share.textContent = ""; });
    sumEl.textContent = "";
    sumEl.classList.remove("bad");
    if (total === null || total <= 0n || active.length === 0) return;

    var weights = [], bad = false;
    var dec = m === "amount" ? decimals(cur) : 2;
    active.forEach(function (r) {
      var w;
      if (m === "equal") w = 1n;
      else if (m === "shares") w = r.input.value.trim() === "" ? 1n : (/^\d+$/.test(r.input.value.trim()) ? BigInt(r.input.value.trim()) : null);
      else w = r.input.value.trim() === "" ? 0n : parseMinor(r.input.value, dec);
      if (w === null || w < 0n) bad = true;
      weights.push(w || 0n);
    });
    if (bad) {
      sumEl.textContent = "Bitte nur gültige Zahlen eingeben.";
      sumEl.classList.add("bad");
      return;
    }
    var sum = weights.reduce(function (a, b) { return a + b; }, 0n);
    var shares = null;
    if (m === "percent") {
      if (sum !== 10000n) {
        var diff = 10000n - sum;
        sumEl.textContent = "Summe " + formatPercent(sum) + " % – " +
          (diff > 0n ? "es fehlen " + formatPercent(diff) : formatPercent(-diff) + " zu viel") + " %.";
        sumEl.classList.add("bad");
        return;
      }
      sumEl.textContent = "Summe 100 %.";
      shares = allocate(total, weights, rotation);
    } else if (m === "amount") {
      var target = cur === "EUR" ? total : parseMinor(amountEl.value, decimals(cur));
      var unit = cur === "EUR" ? " €" : " " + cur;
      if (sum !== target) {
        var rest = target - sum;
        sumEl.textContent = rest > 0n ? "Noch " + formatInput(rest, dec) + unit + " offen."
          : formatInput(-rest, dec) + unit + " zu viel.";
        sumEl.classList.add("bad");
        return;
      }
      sumEl.textContent = "Passt: " + formatInput(sum, dec) + unit + ".";
      shares = cur === "EUR" ? weights : allocate(total, weights);
    } else {
      shares = allocate(total, weights, rotation);
    }
    if (!shares) return;
    active.forEach(function (r, i) { r.share.textContent = formatCents(shares[i]); });
  }

  function update() {
    updateVisibility();
    updatePreview();
  }

  // Fill in sensible initial values when the split mode changes.
  function fillDefaults() {
    var m = mode(), active = rows.filter(function (r) { return r.check.checked; });
    rows.forEach(function (r) { if (!r.check.checked) r.input.value = ""; });
    if (active.length === 0) return;
    var vals;
    if (m === "shares") {
      vals = active.map(function () { return "1"; });
    } else if (m === "percent") {
      vals = allocate(10000n, active.map(function () { return 1n; })).map(formatPercent);
    } else if (m === "amount") {
      var cur = currency(), dec = decimals(cur);
      var total = cur === "EUR" ? parseMinor(amountEl.value, 2) : parseMinor(amountEl.value, dec);
      vals = total && total > 0n
        ? allocate(total, active.map(function () { return 1n; })).map(function (v) { return formatInput(v, dec); })
        : active.map(function () { return ""; });
    } else {
      vals = active.map(function () { return ""; });
    }
    active.forEach(function (r, i) { r.input.value = vals[i]; });
  }

  // --- Exchange rate -------------------------------------------------------

  var rateRequest = 0;
  function isoToDE(s) {
    var m = /^(\d{4})-(\d{2})-(\d{2})$/.exec(s || "");
    return m ? m[3] + "." + m[2] + "." + m[1] : s;
  }

  function loadRate(force) {
    var cur = currency();
    if (cur === "EUR" || !/^[A-Z]{3}$/.test(cur)) return;
    if (!force && rateSourceEl.value === "manuell" && rateEl.value.trim() !== "") return;
    var id = ++rateRequest;
    rateHint.textContent = "Kurs wird geladen …";
    var url = "/api/kurs?waehrung=" + encodeURIComponent(cur) + "&datum=" + encodeURIComponent(dateEl.value);
    fetch(url, { headers: { Accept: "application/json" }, credentials: "same-origin" })
      .then(function (res) {
        return res.json().catch(function () { return {}; }).then(function (data) { return { ok: res.ok, data: data }; });
      })
      .then(function (r) {
        if (id !== rateRequest) return;
        if (!r.ok || !(r.data.rate > 0)) {
          rateEl.value = "";
          rateSourceEl.value = "";
          rateHint.textContent = (r.data.error ? r.data.error + " " : "Kein Kurs verfügbar. ") + "Kurs bitte von Hand eintragen.";
        } else {
          rateEl.value = String(r.data.rate).replace(".", ",");
          rateSourceEl.value = r.data.source || "ezb";
          rateHint.textContent = (r.data.source === "manuell" ? "Hinterlegter manueller Kurs" : "EZB-Referenzkurs") +
            " vom " + isoToDE(r.data.date) + ". Für den echten Kartenkurs einfach überschreiben.";
        }
        rateReload.hidden = true;
        updatePreview();
      })
      .catch(function () {
        if (id !== rateRequest) return;
        rateHint.textContent = "Kurs konnte nicht geladen werden. Kurs bitte von Hand eintragen.";
      });
  }

  // --- Events ----------------------------------------------------------------

  currencyEl.addEventListener("change", function () {
    rateEl.value = "";
    rateSourceEl.value = "";
    update();
    if (currencyEl.value === "") otherEl.focus();
    loadRate(true);
  });
  otherEl.addEventListener("input", function () {
    update();
    if (/^[A-Za-z]{3}$/.test(otherEl.value.trim())) loadRate(true);
  });
  dateEl.addEventListener("change", function () { loadRate(false); });
  rateEl.addEventListener("input", function () {
    rateSourceEl.value = "manuell";
    rateHint.textContent = "Von Hand eingetragener Kurs.";
    rateReload.hidden = false;
    updatePreview();
  });
  rateReload.addEventListener("click", function () { loadRate(true); });
  amountEl.addEventListener("input", updatePreview);
  modeEl.addEventListener("change", function () { fillDefaults(); update(); });
  reimbEl.addEventListener("change", function () {
    if (reimbEl.checked) {
      if (titleEl.value.trim() === "") titleEl.value = "Rückzahlung";
      // Exactly one recipient: keep the first checked one who is not paying.
      var payer = Number($("bezahlt_von").value), kept = false;
      rows.forEach(function (r) {
        if (r.check.checked && !kept && r.id !== payer) { kept = true; return; }
        r.check.checked = false;
      });
    }
    update();
  });
  rows.forEach(function (r) {
    r.check.addEventListener("change", function () {
      if (reimbEl.checked && r.check.checked) {
        rows.forEach(function (o) { if (o !== r) o.check.checked = false; });
      }
      if (mode() !== "equal" && mode() !== "shares") fillDefaults();
      update();
    });
    r.input.addEventListener("input", updatePreview);
  });
  if (selectAll) {
    selectAll.hidden = false;
    selectAll.addEventListener("click", function () {
      var all = rows.every(function (r) { return r.check.checked; });
      rows.forEach(function (r) { r.check.checked = !all; });
      if (mode() !== "equal" && mode() !== "shares") fillDefaults();
      update();
    });
  }

  update();
  if (currency() !== "EUR" && rateEl.value.trim() === "") loadRate(true);
  if (rateSourceEl.value === "manuell") rateReload.hidden = false;
})();
