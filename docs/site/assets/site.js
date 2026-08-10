/* hekouwang-terminal-kit site — lang / progress / reveal
   Self-contained: no CDN.
   Lang truth order: ?lang= → localStorage → navigator.
   A sync boot snippet in <head> (see pages) applies lang-zh before paint;
   this file syncs URL, buttons, and rewrites same-site links so nav keeps lang. */
(function () {
  var KEY = 'hkw-lang';

  function readQuery() {
    try {
      var q = new URLSearchParams(location.search).get('lang');
      return q === 'zh' || q === 'en' ? q : null;
    } catch (e) {
      return null;
    }
  }

  function readStored() {
    try {
      var s = localStorage.getItem(KEY);
      return s === 'zh' || s === 'en' ? s : null;
    } catch (e) {
      return null;
    }
  }

  function detect() {
    var q = readQuery();
    if (q) return q;
    var s = readStored();
    if (s) return s;
    return /^zh/i.test(navigator.language || '') ? 'zh' : 'en';
  }

  function patchLinks(lang) {
    document.querySelectorAll('a[href]').forEach(function (a) {
      var raw = a.getAttribute('href');
      if (!raw || raw.charAt(0) === '#' || /^(https?:|mailto:|javascript:)/i.test(raw)) return;
      if (raw.slice(0, 2) === '//') return;
      try {
        var u = new URL(raw, location.href);
        if (u.origin !== location.origin) return;
        var path = raw.split('#')[0].split('?')[0];
        var hash = u.hash || '';
        a.setAttribute('href', path + '?lang=' + lang + hash);
      } catch (e) {}
    });
  }

  function syncUrl(lang) {
    try {
      var u = new URL(location.href);
      if (u.searchParams.get('lang') === lang) return;
      u.searchParams.set('lang', lang);
      history.replaceState(null, '', u.pathname + u.search + u.hash);
    } catch (e) {}
  }

  function set(lang, remember) {
    var zh = lang === 'zh';
    document.documentElement.classList.toggle('lang-zh', zh);
    document.documentElement.lang = zh ? 'zh-CN' : 'en';
    var btnEn = document.getElementById('btn-en');
    var btnZh = document.getElementById('btn-zh');
    if (btnEn) btnEn.setAttribute('aria-pressed', String(!zh));
    if (btnZh) btnZh.setAttribute('aria-pressed', String(zh));
    if (remember) {
      try { localStorage.setItem(KEY, lang); } catch (e) {}
      syncUrl(lang);
    }
    patchLinks(lang);
  }

  var lang = detect();
  // Re-apply in case head boot missed (or file opened oddly)
  set(lang, false);
  // Persist query into storage; keep URL shareable
  try {
    if (readQuery()) localStorage.setItem(KEY, lang);
  } catch (e) {}
  syncUrl(lang);
  patchLinks(lang);

  var btnEn = document.getElementById('btn-en');
  var btnZh = document.getElementById('btn-zh');
  if (btnEn) btnEn.addEventListener('click', function () { set('en', true); });
  if (btnZh) btnZh.addEventListener('click', function () { set('zh', true); });
})();

(function () {
  var bar = document.getElementById('prog');
  if (!bar) return;
  function tick() {
    var h = document.documentElement.scrollHeight - window.innerHeight;
    bar.style.width = (h > 0 ? (window.scrollY / h) * 100 : 0) + '%';
  }
  window.addEventListener('scroll', tick, { passive: true });
  window.addEventListener('resize', tick);
  tick();
})();

(function () {
  var els = document.querySelectorAll('.pre');
  if (!els.length) return;
  if (!('IntersectionObserver' in window)) {
    els.forEach(function (e) { e.classList.add('in'); });
    return;
  }
  var io = new IntersectionObserver(function (entries) {
    entries.forEach(function (en) {
      if (en.isIntersecting) {
        en.target.classList.add('in');
        io.unobserve(en.target);
      }
    });
  }, { rootMargin: '0px 0px -12% 0px' });
  els.forEach(function (e) { io.observe(e); });
  setTimeout(function () {
    els.forEach(function (e) { e.classList.add('in'); });
  }, 1800);
})();

/* FiloMail-style closer-look tabs */
(function () {
  var tabs = document.querySelectorAll('.look-tab');
  var panels = document.querySelectorAll('.look-panel');
  if (!tabs.length || !panels.length) return;
  function activate(tab, moveFocus) {
    var id = tab.getAttribute('data-tab');
    tabs.forEach(function (t) {
      var selected = t === tab;
      t.classList.toggle('active', selected);
      t.setAttribute('aria-selected', String(selected));
      t.setAttribute('tabindex', selected ? '0' : '-1');
    });
    panels.forEach(function (p) {
      var selected = p.getAttribute('data-panel') === id;
      p.classList.toggle('active', selected);
      p.hidden = !selected;
    });
    if (moveFocus) tab.focus();
  }
  tabs.forEach(function (tab) {
    tab.addEventListener('click', function () {
      activate(tab, false);
    });
    tab.addEventListener('keydown', function (event) {
      var keys = ['ArrowLeft', 'ArrowRight', 'Home', 'End'];
      if (keys.indexOf(event.key) === -1) return;
      event.preventDefault();
      var current = Array.prototype.indexOf.call(tabs, tab);
      var next = event.key === 'Home' ? 0 : event.key === 'End' ? tabs.length - 1 :
        (current + (event.key === 'ArrowRight' ? 1 : -1) + tabs.length) % tabs.length;
      activate(tabs[next], true);
    });
  });
})();
