// HanaLima site: language toggle, copy buttons, reveal-on-scroll. No dependencies.
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
})();
