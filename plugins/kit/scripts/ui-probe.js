(function kitUiProbe(opts) {
  opts = opts || {};
  var doc = document;
  var root = doc.documentElement;
  var vw = root.clientWidth || window.innerWidth;
  var findings = [];
  var MAX_NODES = 6000;

  function add(rule, id, level, el, detail) {
    findings.push({ rule: rule, id: id, level: level, where: el ? describe(el) : "página", detail: detail || "" });
  }

  function describe(el) {
    var s = el.tagName.toLowerCase();
    if (el.id) return s + "#" + el.id;
    var cls = Array.prototype.slice.call(el.classList, 0, 2);
    if (cls.length) return s + "." + cls.join(".");
    var name = el.getAttribute("name");
    if (name) return s + "[name=" + name + "]";
    var type = el.getAttribute("type");
    if (type) s += "[type=" + type + "]";
    var p = el.parentElement;
    if (p && p !== doc.body && p !== root) {
      var ps = p.tagName.toLowerCase();
      if (p.id) ps += "#" + p.id;
      else if (p.classList.length) ps += "." + p.classList[0];
      return ps + " > " + s;
    }
    return s;
  }

  function snippet(el) {
    var h = el.outerHTML.replace(/\s+/g, " ");
    return h.length > 90 ? h.slice(0, 90) + "…" : h;
  }

  function visible(el) {
    if (!el.isConnected) return false;
    if (typeof el.checkVisibility === "function") {
      if (!el.checkVisibility({ checkOpacity: true, checkVisibilityCSS: true })) return false;
    } else {
      var cs = getComputedStyle(el);
      if (cs.display === "none" || cs.visibility !== "visible" || cs.opacity === "0") return false;
    }
    var r = el.getBoundingClientRect();
    if (r.width <= 1 || r.height <= 1) return false;
    if (r.right + window.scrollX <= 0 || r.bottom + window.scrollY <= 0) return false;
    return true;
  }

  function text(el) {
    return (el.textContent || "").replace(/\s+/g, " ").trim();
  }

  function all(selector) {
    return Array.prototype.slice.call(doc.querySelectorAll(selector), 0, MAX_NODES);
  }

  function clipsX(el) {
    var ox = getComputedStyle(el).overflowX;
    return ox === "hidden" || ox === "auto" || ox === "scroll" || ox === "clip";
  }

  function hidesX(value) {
    return value === "hidden" || value === "clip";
  }

  function checkOverflow() {
    var docW = Math.max(root.scrollWidth, doc.body ? doc.body.scrollWidth : 0);
    if (docW <= vw + 1) return;
    // O overflow do body vale para a tela quando o do html e visible. Com ele oculto a pagina nao rola
    // para o lado: o que passa da borda fica cortado, de proposito (menu fechado fora da tela) ou nao.
    var hx = getComputedStyle(root).overflowX;
    var bx = doc.body ? getComputedStyle(doc.body).overflowX : "visible";
    var cut = hidesX(hx !== "visible" ? hx : bx) || (hx !== "visible" && hidesX(bx) && root.scrollWidth <= vw + 1);
    var offenders = [];
    var nodes = all("body *");
    for (var i = 0; i < nodes.length; i++) {
      var el = nodes[i];
      var r = el.getBoundingClientRect();
      if (r.width <= 1 || r.height <= 1) continue;
      if (r.right + window.scrollX <= vw + 1) continue;
      if (!visible(el)) continue;
      var clipped = false;
      for (var p = el.parentElement; p && p !== doc.body && p !== root; p = p.parentElement) {
        if (clipsX(p)) {
          var pr = p.getBoundingClientRect();
          if (pr.right + window.scrollX <= vw + 1) { clipped = true; break; }
        }
      }
      if (!clipped) offenders.push(el);
    }
    var outer = offenders.filter(function (el) { return offenders.indexOf(el.parentElement) === -1; });
    if (cut) {
      outer = outer.filter(function (el) { return el.getBoundingClientRect().left + window.scrollX < vw - 1; });
      if (!outer.length) return;
    }
    var parts = outer.slice(0, 4).map(function (el) {
      return describe(el) + " (" + Math.round(el.getBoundingClientRect().width) + "px)";
    });
    if (cut) {
      add("corte-horizontal", "B2", "conferir", null,
        "html ou body com overflow-x oculto numa tela de " + vw + "px; começa dentro da tela e passa da borda: " + parts.join(", "));
      return;
    }
    add("rolagem-horizontal", "B2", "achado", null,
      "página com " + docW + "px numa tela de " + vw + "px" + (parts.length ? "; passa da borda: " + parts.join(", ") : ""));
  }

  var TARGETS = "a[href], button, input:not([type=hidden]), select, textarea, summary, [role=button], [role=link], " +
    "[role=checkbox], [role=radio], [role=switch], [role=tab], [role=menuitem], [onclick], [tabindex]:not([tabindex='-1'])";

  function disabled(el) {
    return !!el.closest(":disabled, [aria-disabled='true'], [inert]");
  }

  function inlineLink(el) {
    if (el.tagName !== "A" || getComputedStyle(el).display !== "inline") return false;
    var p = el.parentElement;
    if (!p) return false;
    for (var n = p.firstChild; n; n = n.nextSibling) {
      if (n.nodeType === 3 && n.nodeValue.trim().length > 1) return true;
    }
    return false;
  }

  function labelled(el) {
    if (el.labels && el.labels.length) return true;
    return !!el.closest("label");
  }

  function boxAround(r) {
    var cx = r.left + r.width / 2, cy = r.top + r.height / 2;
    return { left: cx - 12, top: cy - 12, right: cx + 12, bottom: cy + 12 };
  }

  function overlap(a, b) {
    return a.left < b.right && b.left < a.right && a.top < b.bottom && b.top < a.bottom;
  }

  function checkTargets() {
    var els = all(TARGETS).filter(function (el) { return visible(el) && !disabled(el); }).slice(0, 600);
    var rects = els.map(function (el) { return el.getBoundingClientRect(); });
    var small = rects.map(function (r) { return r.width < 23.5 || r.height < 23.5; });
    for (var i = 0; i < els.length; i++) {
      if (!small[i]) continue;
      var el = els[i];
      if (inlineLink(el)) continue;
      if ((el.type === "checkbox" || el.type === "radio") && labelled(el)) continue;
      var box = boxAround(rects[i]);
      var crowded = false;
      for (var j = 0; j < els.length && !crowded; j++) {
        if (j === i || els[j].contains(el) || el.contains(els[j])) continue;
        crowded = overlap(box, small[j] ? boxAround(rects[j]) : rects[j]);
      }
      if (crowded) {
        add("alvo-pequeno", "M2", "achado", el,
          Math.round(rects[i].width) + "×" + Math.round(rects[i].height) + "px, a menos de 24px de outro alvo");
      }
    }
  }

  function checkSmallText() {
    var nodes = all("body *");
    var seen = 0;
    for (var i = 0; i < nodes.length && seen < 8; i++) {
      var el = nodes[i];
      var own = "";
      for (var n = el.firstChild; n; n = n.nextSibling) if (n.nodeType === 3) own += n.nodeValue;
      if (own.trim().length < 2) continue;
      var size = parseFloat(getComputedStyle(el).fontSize);
      if (!(size < 12) || !visible(el)) continue;
      seen++;
      add("texto-pequeno", "M7", "conferir", el, "fonte de " + (Math.round(size * 10) / 10) + "px");
    }
  }

  function refText(ids) {
    return (ids || "").split(/\s+/).map(function (id) {
      var t = id && doc.getElementById(id);
      return t ? text(t) : "";
    }).join(" ").trim();
  }

  function accName(el) {
    var aria = (el.getAttribute("aria-label") || "").trim();
    if (aria) return aria;
    var by = refText(el.getAttribute("aria-labelledby"));
    if (by) return by;
    var tag = el.tagName;
    if (tag === "INPUT" || tag === "SELECT" || tag === "TEXTAREA") {
      if (el.labels && el.labels.length) {
        var lt = Array.prototype.map.call(el.labels, text).join(" ").trim();
        if (lt) return lt;
      }
      var wrap = el.closest("label");
      if (wrap && text(wrap)) return text(wrap);
      var type = (el.getAttribute("type") || "").toLowerCase();
      if (type === "submit" || type === "reset") return el.value || type;
      if (type === "button") return el.value || "";
      if (type === "image") return (el.getAttribute("alt") || "").trim();
      return (el.getAttribute("title") || "").trim();
    }
    var t = text(el);
    if (t) return t;
    var img = el.querySelector("img[alt]:not([alt='']), svg[aria-label], [aria-label]");
    if (img) return (img.getAttribute("alt") || img.getAttribute("aria-label") || "").trim();
    var svgTitle = el.querySelector("svg title");
    if (svgTitle && text(svgTitle)) return text(svgTitle);
    return (el.getAttribute("title") || "").trim();
  }

  function checkNames() {
    var els = all("button, a[href], input:not([type=hidden]), select, textarea, [role=button], [role=link], [role=checkbox], [role=switch], [role=tab], [role=menuitem]");
    for (var i = 0; i < els.length; i++) {
      var el = els[i];
      if (!visible(el) || el.getAttribute("aria-hidden") === "true") continue;
      if (accName(el)) continue;
      var field = el.tagName === "INPUT" || el.tagName === "SELECT" || el.tagName === "TEXTAREA";
      if (field && (el.getAttribute("placeholder") || "").trim()) {
        add("so-placeholder", "M8", "achado", el, "campo com placeholder e sem rótulo: " + snippet(el));
      } else {
        add("sem-nome", "B3", "achado", el, (field ? "campo sem rótulo: " : "controle sem nome acessível: ") + snippet(el));
      }
    }
    var div = all("div[onclick], span[onclick], li[onclick], td[onclick], img[onclick]");
    for (var k = 0; k < div.length; k++) {
      var d = div[k];
      if (!visible(d) || d.hasAttribute("tabindex") || d.getAttribute("role")) continue;
      add("sem-teclado", "B3", "achado", d, "clique em elemento sem papel nem tabindex: " + snippet(d));
    }
  }

  function checkImages() {
    var imgs = all("img:not([alt]), input[type=image]:not([alt]), [role=img]:not([aria-label]):not([aria-labelledby])");
    for (var i = 0; i < imgs.length; i++) {
      var el = imgs[i];
      if (!visible(el) || el.closest("[aria-hidden='true']")) continue;
      if (el.tagName === "svg" && el.querySelector("title")) continue;
      add("sem-alt", "M8", "achado", el, "imagem sem texto alternativo: " + snippet(el));
    }
  }

  var canvas = null;
  var colorCache = {};
  function rgba(color) {
    if (colorCache[color]) return colorCache[color];
    var m = /^rgba?\(\s*([\d.]+)[,\s]+([\d.]+)[,\s]+([\d.]+)(?:\s*[,/]\s*([\d.]+%?))?\s*\)$/.exec(color);
    var out;
    if (m) {
      var a = m[4] === undefined ? 1 : (m[4].slice(-1) === "%" ? parseFloat(m[4]) / 100 : parseFloat(m[4]));
      out = [parseFloat(m[1]), parseFloat(m[2]), parseFloat(m[3]), a];
    } else {
      if (!canvas) {
        canvas = doc.createElement("canvas");
        canvas.width = canvas.height = 1;
      }
      var ctx = canvas.getContext("2d", { willReadFrequently: true });
      ctx.clearRect(0, 0, 1, 1);
      ctx.fillStyle = "rgba(0,0,0,0)";
      ctx.fillStyle = color;
      ctx.fillRect(0, 0, 1, 1);
      var d = ctx.getImageData(0, 0, 1, 1).data;
      out = [d[0], d[1], d[2], d[3] / 255];
    }
    colorCache[color] = out;
    return out;
  }

  function blend(top, bottom) {
    var a = top[3];
    return [top[0] * a + bottom[0] * (1 - a), top[1] * a + bottom[1] * (1 - a), top[2] * a + bottom[2] * (1 - a), 1];
  }

  function luminance(c) {
    var v = [c[0], c[1], c[2]].map(function (x) {
      x /= 255;
      return x <= 0.03928 ? x / 12.92 : Math.pow((x + 0.055) / 1.055, 2.4);
    });
    return 0.2126 * v[0] + 0.7152 * v[1] + 0.0722 * v[2];
  }

  function hex(c) {
    return "#" + [c[0], c[1], c[2]].map(function (x) {
      var h = Math.round(x).toString(16);
      return h.length < 2 ? "0" + h : h;
    }).join("");
  }

  var canvasBase = null;
  function canvasColor() {
    if (canvasBase) return canvasBase;
    var d = doc.createElement("div");
    d.style.cssText = "position:absolute;width:0;height:0;background-color:Canvas";
    (doc.body || root).appendChild(d);
    var c = rgba(getComputedStyle(d).backgroundColor);
    d.remove();
    canvasBase = c[3] >= 1 ? c : [255, 255, 255, 1];
    return canvasBase;
  }

  function background(el) {
    var layers = [];
    var unsure = false;
    for (var n = el; n && n.nodeType === 1; n = n.parentElement) {
      var cs = getComputedStyle(n);
      if (cs.backgroundImage && cs.backgroundImage !== "none") return null;
      if (parseFloat(cs.opacity) < 1 || (cs.mixBlendMode && cs.mixBlendMode !== "normal")) return null;
      if (cs.position === "absolute" || cs.position === "fixed") unsure = true;
      var c = rgba(cs.backgroundColor);
      if (c[3] > 0) {
        layers.push(c);
        if (c[3] >= 1) break;
      }
    }
    var base = canvasColor();
    for (var i = layers.length - 1; i >= 0; i--) base = blend(layers[i], base);
    return { color: base, unsure: unsure };
  }

  // Imagem, video ou fundo com imagem que nao e ancestral do texto mas ocupa a mesma area (texto sobre foto
  // posicionada). A cor de fundo calculada pelos ancestrais nao vale ali.
  var media = null;
  function overMedia(el) {
    if (!media) {
      media = [];
      var nodes = all("body *");
      for (var i = 0; i < nodes.length && media.length < 300; i++) {
        var n = nodes[i];
        var tag = n.tagName.toLowerCase();
        var painted = tag === "img" || tag === "video" || tag === "canvas" || tag === "svg" || tag === "picture" ||
          tag === "iframe" || tag === "object" || tag === "embed";
        if (!painted) {
          var image = getComputedStyle(n).backgroundImage;
          painted = !!image && image !== "none";
        }
        if (painted && visible(n)) media.push({ el: n, rect: n.getBoundingClientRect() });
      }
    }
    var r = el.getBoundingClientRect();
    for (var k = 0; k < media.length; k++) {
      var m = media[k];
      if (m.el === el || m.el.contains(el) || el.contains(m.el)) continue;
      if (overlap(r, m.rect)) return true;
    }
    return false;
  }

  function checkContrast() {
    var nodes = all("body *");
    var seenPairs = {};
    var count = 0;
    for (var i = 0; i < nodes.length && count < 10; i++) {
      var el = nodes[i];
      var tag = el.tagName;
      if (tag === "SCRIPT" || tag === "STYLE" || tag === "NOSCRIPT" || tag === "OPTION") continue;
      var own = "";
      for (var n = el.firstChild; n; n = n.nextSibling) if (n.nodeType === 3) own += n.nodeValue;
      if (own.trim().length < 2) continue;
      if (!visible(el) || disabled(el)) continue;
      var cs = getComputedStyle(el);
      if (cs.textShadow && cs.textShadow !== "none") continue;
      if (cs.webkitTextFillColor && cs.webkitTextFillColor !== cs.color) continue;
      var bg = background(el);
      if (!bg) continue;
      var fg = rgba(cs.color);
      if (fg[3] <= 0) continue;
      var shown = blend(fg, bg.color);
      var l1 = luminance(shown), l2 = luminance(bg.color);
      var ratio = (Math.max(l1, l2) + 0.05) / (Math.min(l1, l2) + 0.05);
      var size = parseFloat(cs.fontSize);
      var weight = parseInt(cs.fontWeight, 10) || 400;
      var large = size >= 24 || (size >= 18.66 && weight >= 700);
      var need = large ? 3 : 4.5;
      if (ratio >= need) continue;
      var key = hex(shown) + hex(bg.color) + need;
      if (seenPairs[key]) continue;
      seenPairs[key] = 1;
      count++;
      var photo = overMedia(el);
      add("contraste", "M1", bg.unsure || photo ? "conferir" : "achado", el,
        (Math.round(ratio * 100) / 100) + ":1 (mínimo " + need + ":1), " + hex(shown) + " sobre " + hex(bg.color) +
        ', texto "' + own.trim().slice(0, 30) + '"' + (photo ? "; há imagem na área do texto, o fundo medido pode não ser o que aparece" : ""));
    }
  }

  function checkDocument() {
    if (!(root.getAttribute("lang") || "").trim()) add("sem-lang", "M8", "achado", null, "<html> sem o atributo lang");
    if (!(doc.title || "").trim()) add("sem-titulo", "M8", "achado", null, "<title> vazio ou ausente");
    var meta = doc.querySelector("meta[name=viewport]");
    if (!meta) {
      add("sem-viewport", "M8", "achado", null, "sem <meta name=viewport>: no celular a página abre com largura de desktop");
    } else {
      var c = (meta.getAttribute("content") || "").toLowerCase().replace(/\s+/g, "");
      var max = /maximum-scale=([\d.]+)/.exec(c);
      if (/user-scalable=(no|0)/.test(c) || (max && parseFloat(max[1]) < 2)) {
        add("zoom-bloqueado", "M8", "achado", null, "meta viewport impede o zoom: " + c);
      }
    }
    var heads = all("h1, h2, h3, h4, h5, h6").filter(visible);
    if (heads.length && !heads.some(function (h) { return h.tagName === "H1"; })) {
      add("titulos", "M8", "conferir", null, "página com títulos e sem h1");
    }
    var last = 0;
    for (var i = 0; i < heads.length; i++) {
      var level = parseInt(heads[i].tagName.slice(1), 10);
      if (last && level > last + 1) {
        add("titulos", "M8", "conferir", heads[i], "título pula de h" + last + " para h" + level);
        break;
      }
      last = level;
    }
  }

  function toPx(value, unit) {
    var v = parseFloat(value);
    if (unit === "em" || unit === "rem") v *= 16;
    return Math.round(v);
  }

  // Tema escuro ligado por classe ou atributo na raiz, lido dos seletores do CSS. Atributo de tema com valor
  // dark vale sempre. Classe vale quando esta no html, no :root ou no body, quando e ancestral de outro
  // seletor, ou quando a regra define variaveis ou color-scheme; ".dark" grudada em outra classe e variante
  // de componente e fica de fora.
  var darkToggles = {};
  var DARK_ATTR = /\[(data-theme|data-bs-theme|data-mode|data-color-mode|data-color-scheme|data-mui-color-scheme|data-mantine-color-scheme|data-joy-color-scheme)\s*[~|^$*]?=\s*["']?dark["']?\s*\]/g;
  var DARK_ROOT = /^(html|:root|body)?\.(dark|dark-mode|dark-theme|theme-dark)(?![\w\\-])(.*)$/;
  var DARK_IN = /:(?:where|is)\(\s*\.(dark|dark-mode|dark-theme|theme-dark)(?![\w\\-])/;

  function declaresTheme(style) {
    if (!style) return false;
    for (var i = 0; i < style.length && i < 80; i++) {
      if (style[i].indexOf("--") === 0 || style[i] === "color-scheme") return true;
    }
    return false;
  }

  function fromSelector(rule) {
    var parts = rule.selectorText.split(",");
    for (var i = 0; i < parts.length; i++) {
      var s = parts[i].trim();
      var m;
      DARK_ATTR.lastIndex = 0;
      while ((m = DARK_ATTR.exec(s))) darkToggles["attr:" + m[1]] = 1;
      m = DARK_ROOT.exec(s);
      if (m && (m[1] || m[2] !== "dark" || /^[\s>+~]/.test(m[3]) || (m[3] === "" && declaresTheme(rule.style)))) darkToggles["class:" + m[2]] = 1;
      m = DARK_IN.exec(s);
      if (m) darkToggles["class:" + m[1]] = 1;
    }
  }

  var darkAware = false;
  function collectBreakpoints() {
    var found = {};
    function fromText(t) {
      if (/prefers-color-scheme\s*:\s*dark/.test(t)) darkAware = true;
      var re = /(?:(?:min|max)-width\s*:\s*|width\s*[<>]=?\s*)([\d.]+)(px|em|rem)/g;
      var m;
      while ((m = re.exec(t))) found[toPx(m[1], m[2])] = 1;
      var rev = /([\d.]+)(px|em|rem)\s*[<>]=?\s*width/g;
      while ((m = rev.exec(t))) found[toPx(m[1], m[2])] = 1;
    }
    function walk(rules, depth) {
      if (!rules || depth > 6) return;
      for (var i = 0; i < rules.length; i++) {
        var r = rules[i];
        if (r.media && r.media.mediaText) fromText(r.media.mediaText);
        if (r.selectorText) fromSelector(r);
        if (r.styleSheet) { try { walk(r.styleSheet.cssRules, depth + 1); } catch (e) { /* folha de outra origem */ } }
        if (r.cssRules) walk(r.cssRules, depth + 1);
      }
    }
    for (var s = 0; s < doc.styleSheets.length; s++) {
      var sheet = doc.styleSheets[s];
      if (sheet.media && sheet.media.mediaText) fromText(sheet.media.mediaText);
      try { walk(sheet.cssRules, 0); } catch (e) { /* folha de outra origem */ }
    }
    return Object.keys(found).map(Number).filter(function (n) { return n >= 200 && n <= 4000; }).sort(function (a, b) { return a - b; });
  }

  var out = { width: vw, height: window.innerHeight, scrollWidth: root.scrollWidth, scrollHeight: root.scrollHeight };
  try {
    checkOverflow();
    checkTargets();
    if (opts.full) {
      checkSmallText();
      checkNames();
      checkImages();
      checkContrast();
      checkDocument();
      out.title = doc.title || "";
    }
    if (opts.breakpoints) {
      out.breakpoints = collectBreakpoints();
      out.dark = darkAware || /dark/.test(getComputedStyle(root).colorScheme || "");
      out.darkToggles = Object.keys(darkToggles);
    }
    if (opts.only) findings = findings.filter(function (f) { return opts.only.indexOf(f.rule) !== -1; });
  } catch (e) {
    out.error = String((e && e.stack) || e);
  }
  out.findings = findings;
  return out;
})
