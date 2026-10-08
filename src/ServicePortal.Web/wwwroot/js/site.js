// Progressive enhancement only: every form works without JavaScript.
(function () {
  "use strict";

  // "Go back" links (no inline script because of the Content-Security-Policy).
  document.querySelectorAll(".js-back").forEach(function (a) {
    a.addEventListener("click", function (e) {
      if (history.length > 1) { e.preventDefault(); history.back(); }
    });
  });

  // Character counters for textareas.
  document.querySelectorAll("[data-counter]").forEach(function (box) {
    var counter = document.getElementById(box.getAttribute("data-counter"));
    var update = function () { counter.textContent = box.value.length; };
    box.addEventListener("input", update);
    update();
  });

  // Show the service standard for the chosen category.
  var category = document.getElementById("category");
  var slaHint = document.getElementById("sla-hint");
  if (category && slaHint) {
    var showSla = function () {
      var option = category.options[category.selectedIndex];
      var days = option && option.getAttribute("data-sla");
      slaHint.textContent = days ? "Service standard: " + days + " business day" + (days === "1" ? "" : "s") + "." : "";
    };
    category.addEventListener("change", showSla);
    showSla();
  }

  // Optional location capture.
  var geoButton = document.getElementById("use-location");
  if (geoButton) {
    var geoStatus = document.getElementById("geo-status");
    if (!("geolocation" in navigator)) { geoButton.hidden = true; }
    geoButton.addEventListener("click", function () {
      geoStatus.textContent = "Getting your location…";
      navigator.geolocation.getCurrentPosition(function (pos) {
        document.getElementById("lat").value = pos.coords.latitude.toFixed(6);
        document.getElementById("lng").value = pos.coords.longitude.toFixed(6);
        geoStatus.textContent = "Location attached (" + pos.coords.latitude.toFixed(4) + ", " + pos.coords.longitude.toFixed(4) + ").";
      }, function () {
        geoStatus.textContent = "Location unavailable – please describe the location instead.";
      }, { timeout: 10000 });
    });
  }

  // Workflow form: show crew / resolution fields only for the statuses that need them.
  var transition = document.getElementById("transition-form");
  if (transition) {
    var toStatus = transition.querySelector("select[name=ToStatus]");
    var sync = function () {
      transition.querySelectorAll("[data-show-for]").forEach(function (el) {
        var show = el.getAttribute("data-show-for") === toStatus.value;
        el.classList.toggle("visible", show);
        el.querySelectorAll("select, textarea").forEach(function (input) { input.required = show; });
      });
    };
    toStatus.addEventListener("change", sync);
    sync();
  }

  // Permit fee estimate (the server recalculates on submit).
  var permitForm = document.getElementById("permit-form");
  if (permitForm) {
    var type = document.getElementById("permit-type");
    var value = document.getElementById("project-value");
    var amount = document.getElementById("fee-amount");
    var breakdown = document.getElementById("fee-breakdown");
    var money = new Intl.NumberFormat("en-CA", { style: "currency", currency: "CAD" });
    var timer;
    var quote = function () {
      if (!type.value || value.value === "") { amount.textContent = "–"; breakdown.textContent = ""; return; }
      var url = permitForm.getAttribute("data-fee-url") + "?type=" + encodeURIComponent(type.value) + "&value=" + encodeURIComponent(value.value);
      fetch(url, { headers: { "Accept": "application/json" } })
        .then(function (r) { return r.ok ? r.json() : Promise.reject(); })
        .then(function (q) {
          amount.textContent = money.format(q.fee);
          var text = money.format(q.baseFee) + " base";
          if (q.ratePerThousand > 0) text += " + " + money.format(q.ratePerThousand) + " per $1,000";
          text += " (minimum " + money.format(q.minFee) + (q.maxFee ? ", maximum " + money.format(q.maxFee) : "") + ")";
          breakdown.textContent = text;
        })
        .catch(function () { amount.textContent = "–"; breakdown.textContent = "Fee could not be calculated."; });
    };
    var debounced = function () { clearTimeout(timer); timer = setTimeout(quote, 300); };
    type.addEventListener("change", quote);
    value.addEventListener("input", debounced);
    quote();
  }

  // Reveal unmasked resident contact details (audited server-side).
  var reveal = document.getElementById("reveal-form");
  if (reveal) {
    reveal.addEventListener("submit", function (e) {
      e.preventDefault();
      var status = document.getElementById("reveal-status");
      var token = reveal.querySelector("input[name=__RequestVerificationToken]").value;
      fetch(reveal.getAttribute("data-url"), {
        method: "POST",
        headers: { "Content-Type": "application/json", "RequestVerificationToken": token },
        body: JSON.stringify({ residentId: Number(reveal.getAttribute("data-resident")), purpose: document.getElementById("purpose").value })
      })
        .then(function (r) { return r.json().then(function (body) { return { ok: r.ok, body: body }; }); })
        .then(function (res) {
          if (!res.ok) { status.textContent = res.body.error || "Not allowed."; return; }
          var block = document.getElementById("contact-block");
          block.querySelector("[data-field=email]").textContent = res.body.email || "–";
          block.querySelector("[data-field=phone]").textContent = res.body.phone || "–";
          block.querySelector("[data-field=address]").textContent = res.body.streetAddress || "–";
          block.classList.add("revealed");
          status.textContent = "Shown and recorded in the privacy audit log.";
          reveal.querySelector("button").disabled = true;
        })
        .catch(function () { status.textContent = "Could not load contact details."; });
    });
  }
})();
