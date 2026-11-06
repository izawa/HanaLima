// HanaLima site: language toggle, copy buttons, reveal-on-scroll, ambient background. No dependencies.
(function () {
  "use strict";
  var root = document.documentElement;

  function setLang(lang) {
    root.className = root.className.replace(/\blang-\w+\b/, "").trim() + " lang-" + lang;
    root.lang = lang;
    try { localStorage.setItem("hanalima-lang", lang); } catch (e) {}
  }
  document.querySelectorAll(".lang-toggle [data-lang]").forEach(function (button) {
    button.addEventListener("click", function () { setLang(button.dataset.lang); });
  });

  document.querySelectorAll("[data-copy]").forEach(function (button) {
    button.addEventListener("click", function () {
      var source = document.querySelector(button.dataset.copy);
      // Copy only the commands, not the comment lines.
      var text = source.innerText.split("\n").filter(function (line) {
        return line.trim() && !line.trim().startsWith("#");
      }).join("\n");
      var done = function () {
        button.textContent = "copied";
        setTimeout(function () { button.textContent = "copy"; }, 1500);
      };
      if (navigator.clipboard) navigator.clipboard.writeText(text).then(done, function () {});
    });
  });

  var items = document.querySelectorAll(".reveal");
  if (!("IntersectionObserver" in window)) {
    items.forEach(function (el) { el.classList.add("in"); });
    return;
  }
  var observer = new IntersectionObserver(function (entries) {
    entries.forEach(function (entry) {
      if (entry.isIntersecting) {
        entry.target.classList.add("in");
        observer.unobserve(entry.target);
      }
    });
  }, { rootMargin: "0px 0px -8% 0px" });
  items.forEach(function (el) { observer.observe(el); });

  // Ambient background: three slow waves in the brand colors and a few drifting sparks,
  // on a canvas behind the page. 30 fps, paused while the tab is hidden; a single
  // still frame when the user asked for reduced motion.
  (function ambient() {
    var host = document.createElement("div");
    host.id = "ambient";
    var canvas = document.createElement("canvas");
    host.appendChild(canvas);
    document.body.prepend(host);
    var g = canvas.getContext("2d");
    if (!g) return;

    var light = matchMedia("(prefers-color-scheme: light)");
    var reduce = matchMedia("(prefers-reduced-motion: reduce)");
    var W, H, dpr;
    function resize() {
      dpr = Math.min(window.devicePixelRatio || 1, 2);
      W = window.innerWidth; H = window.innerHeight;
      canvas.width = W * dpr; canvas.height = H * dpr;
      g.setTransform(dpr, 0, 0, dpr, 0, 0);
    }
    function rgba(c, a) { return "rgba(" + c[0] + "," + c[1] + "," + c[2] + "," + a + ")"; }
    var sparks = [];
    for (var i = 0; i < 60; i++) {
      sparks.push({ x: Math.random(), y: Math.random(), r: .6 + Math.random() * 1.6, s: .2 + Math.random() * .6, p: Math.random() * 6.28 });
    }
    function draw(t) {
      var L = light.matches;
      var hana = L ? [224, 51, 127] : [255, 95, 162];
      var lime = L ? [76, 154, 14] : [182, 243, 107];
      var sky = L ? [20, 121, 196] : [108, 198, 255];
      var waves = [
        { c: hana, a: L ? .11 : .16, y: .42, amp: .11, k: 1.1, sp: .11, w: 150 },
        { c: lime, a: L ? .14 : .18, y: .50, amp: .12, k: 1.6, sp: .08, w: 130, line: 2.4 },
        { c: sky, a: L ? .06 : .08, y: .56, amp: .13, k: .8, sp: .14, w: 170 }
      ];
      g.clearRect(0, 0, W, H);
      waves.forEach(function (wv, n) {
        g.beginPath();
        for (var x = 0; x <= W; x += 8) {
          var u = x / W;
          var y = H * (wv.y + wv.amp * Math.sin(u * 6.28 * wv.k + t * wv.sp + n) + .05 * Math.sin(u * 6.28 * 2.3 - t * wv.sp * 1.7));
          if (x === 0) g.moveTo(x, y); else g.lineTo(x, y);
        }
        var grad = g.createLinearGradient(0, 0, W, 0);
        grad.addColorStop(0, rgba(wv.c, 0));
        grad.addColorStop(.3, rgba(wv.c, wv.a));
        grad.addColorStop(.7, rgba(wv.c, wv.a));
        grad.addColorStop(1, rgba(wv.c, 0));
        g.strokeStyle = grad; g.lineWidth = wv.w; g.lineCap = "round";
        g.filter = "blur(" + (L ? 28 : 36) + "px)"; g.stroke(); g.filter = "none";
        g.lineWidth = wv.line || 1.2; g.strokeStyle = rgba(wv.c, Math.min(1, wv.a * 2.4)); g.stroke();
      });
      var sparkColor = L ? hana : [255, 230, 240];
      sparks.forEach(function (sp) {
        var x = ((sp.x + t * .006 * sp.s) % 1) * W;
        var y = (sp.y + .01 * Math.sin(t * .4 + sp.p)) * H;
        var a = (L ? .35 : .6) * (.5 + .5 * Math.sin(t * 1.3 + sp.p));
        g.fillStyle = rgba(sparkColor, a);
        g.beginPath(); g.arc(x, y, sp.r, 0, 6.28); g.fill();
      });
    }

    var FPS = 30, t0 = performance.now(), last = 0, running = false;
    function frame(now) {
      if (!running) return;
      if (now - last >= 1000 / FPS) { last = now; draw((now - t0) / 1000); }
      requestAnimationFrame(frame);
    }
    function update() {
      var shouldRun = !reduce.matches && !document.hidden;
      if (shouldRun && !running) { running = true; requestAnimationFrame(frame); }
      if (!shouldRun) { running = false; draw((performance.now() - t0) / 1000); }
    }
    resize();
    window.addEventListener("resize", function () { resize(); if (!running) draw((performance.now() - t0) / 1000); });
    document.addEventListener("visibilitychange", update);
    reduce.addEventListener("change", update);
    light.addEventListener("change", function () { if (!running) draw((performance.now() - t0) / 1000); });
    update();
  })();
})();
