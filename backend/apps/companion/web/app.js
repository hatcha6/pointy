/* Companion camera — the phone half of the till/phone pair.
 *
 * Four rules shape this file:
 *
 * 1. It must work on plain HTTP. `getUserMedia` needs a secure context, which a
 *    shop LAN address is not, so capture goes through a file input and the OS
 *    camera instead. That path has no such requirement and needs nothing
 *    installed, configured or trusted on the phone.
 * 2. Decoding is CHEAPEST-FIRST and stops at the first hit. The first version
 *    of this file decoded at 1000, then 1600, then 640 pixels, trying both
 *    polarities at every size, and ran all three even after a hit: 782 ms on a
 *    desktop, several seconds on a phone. Measured, a 480-pixel pass reads the
 *    same code in 49 ms. Order and early exit were worth about 16x.
 * 3. What the browser cannot read, the server can. jsQR is a clean-image
 *    decoder and reads no 1-D barcodes at all, so on an iPhone (no
 *    `BarcodeDetector`) every EAN-13 failed outright. A miss now uploads one
 *    downscaled frame to zxing-cpp, which reads real photographs.
 * 4. It polls; it does not hold a connection. Mobile Safari kills sockets the
 *    moment the screen locks, and a phone that silently stopped receiving would
 *    be worse than one that visibly reconnects.
 */
(function () {
  "use strict";

  var TOKEN_KEY = "pointy.companion.token.v1";
  var API = "/api/companion";
  var CONTEXT_POLL_MS = 3000;

  // Photos sent as photos keep their detail; frames sent only to be DECODED are
  // smaller, because zxing reads them fine and the upload is on the critical
  // path of a scan.
  var PHOTO_MAX_EDGE = 1600;
  var PHOTO_QUALITY = 0.82;
  var DECODE_UPLOAD_EDGE = 1400;
  var DECODE_UPLOAD_QUALITY = 0.75;

  // One cheap pass, then the server.
  //
  // Measured on a real iPhone, jsQR read neither a photographed EAN-13 (it
  // cannot: QR only) nor a photographed receipt QR — zxing-cpp on the server
  // read both. Every in-page pass after the first is therefore latency an iOS
  // user pays before the request that actually resolves their scan. The one
  // 480-pixel pass stays because it costs ~50 ms and does win outright on a
  // clean code — a QR on a screen, a crisp printed label — with no round trip.
  var DECODE_EDGES = [480];
  var NATIVE_EDGE = 800;

  var el = {};
  ["shop-name","till-name","live","live-label","screen-pair","screen-camera",
   "code-input","pair-submit","pair-error","ask","ask-prompt","paused","modes",
   "mode-scan","mode-photo","stage","stage-title","stage-hint","viewfinder",
   "result","result-icon","result-label","result-value","shutter","shutter-hint",
   "leave","camera","flash"].forEach(function (id) {
    el[id.replace(/-(.)/g, function (_, c) { return c.toUpperCase(); })] =
      document.getElementById(id);
  });

  var ICON_OK = "M9 16.2 4.8 12l-1.4 1.4L9 19 21 7l-1.4-1.4L9 16.2Z";
  var ICON_FAIL = "M12 2a10 10 0 1 0 0 20 10 10 0 0 0 0-20Zm1 15h-2v-2h2v2Zm0-4h-2V7h2v6Z";

  var state = {
    token: null,
    mode: "scan",
    busy: false,
    modeLocked: false,
    captureRequestId: null,
    pollTimer: null,
    audio: null
  };

  // ---------------------------------------------------------------- transport

  function api(path, options) {
    options = options || {};
    var headers = options.headers || {};
    if (state.token) headers.Authorization = "Companion " + state.token;
    return fetch(API + path, {
      method: options.method || "GET",
      headers: headers,
      body: options.body,
      cache: "no-store",
      credentials: "omit"
    }).then(function (response) {
      if (response.status === 401) {
        forgetToken();
        throw new Error("unpaired");
      }
      if (!response.ok) {
        return response.json().catch(function () { return {}; }).then(function (body) {
          throw new Error(firstDetail(body) || "تعذّر الاتصال بالصندوق");
        });
      }
      return response.status === 204 ? null : response.json();
    });
  }

  function firstDetail(body) {
    if (!body || typeof body !== "object") return "";
    if (typeof body.detail === "string") return body.detail;
    for (var key in body) {
      if (!Object.prototype.hasOwnProperty.call(body, key)) continue;
      var value = body[key];
      if (typeof value === "string") return value;
      if (Array.isArray(value) && typeof value[0] === "string") return value[0];
    }
    return "";
  }

  // ------------------------------------------------------------------ pairing

  function storeToken(token) {
    state.token = token;
    try { localStorage.setItem(TOKEN_KEY, token); } catch (error) { /* private mode */ }
  }

  function loadToken() {
    try { return localStorage.getItem(TOKEN_KEY); } catch (error) { return null; }
  }

  function forgetToken() {
    state.token = null;
    try { localStorage.removeItem(TOKEN_KEY); } catch (error) { /* ignore */ }
    showPairScreen();
  }

  function pair(code) {
    return api("/pair/", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ code: code, label: deviceLabel() })
    }).then(function (data) {
      storeToken(data.token);
      applyContext(data.context);
      showCameraScreen();
    });
  }

  function deviceLabel() {
    var agent = navigator.userAgent || "";
    if (/iPhone/i.test(agent)) return "iPhone";
    if (/iPad/i.test(agent)) return "iPad";
    if (/Android/i.test(agent)) return "Android";
    return "هاتف";
  }

  // ------------------------------------------------------------------ context

  function refreshContext() {
    if (!state.token) return Promise.resolve();
    return api("/context/").then(applyContext).catch(function () {
      /* A missed poll is not worth showing; the next one is 3 seconds away. */
    });
  }

  function applyContext(context) {
    if (!context) return;
    if (context.shop_name) el.shopName.textContent = context.shop_name;
    el.tillName.textContent = context.device_label || "كاميرا مساعدة";
    el.paused.hidden = !context.is_paused;
    el.live.hidden = false;
    el.live.classList.toggle("paused", !!context.is_paused);
    el.liveLabel.textContent = context.is_paused ? "موقوف" : "متصل";

    var ask = context.capture_request;
    state.captureRequestId = ask ? ask.id : null;
    el.ask.hidden = !ask;
    if (ask) {
      el.askPrompt.textContent = ask.prompt || "التقط صورة وأرسلها";
      // A named request overrides the mode: the till has already said what it
      // wants, so the operator should not have to also pick "photo".
      setMode("photo", true);
    } else {
      state.modeLocked = false;
    }
  }

  function startPolling() {
    stopPolling();
    state.pollTimer = setInterval(function () {
      if (document.visibilityState === "visible") refreshContext();
    }, CONTEXT_POLL_MS);
  }

  function stopPolling() {
    if (state.pollTimer) clearInterval(state.pollTimer);
    state.pollTimer = null;
  }

  // --------------------------------------------------------------------- mode

  function setMode(mode, locking) {
    if (state.modeLocked && !locking) return;
    if (locking) state.modeLocked = true;
    state.mode = mode;
    el.modes.setAttribute("data-mode", mode);
    el.modeScan.setAttribute("aria-pressed", String(mode === "scan"));
    el.modePhoto.setAttribute("aria-pressed", String(mode === "photo"));
    if (mode === "scan") {
      el.stageTitle.textContent = "وجّه الكاميرا نحو الرمز";
      el.stageHint.textContent = "اضغط الزر، صوّر الرمز، وسيصل إلى الصندوق فورًا";
      el.shutterHint.textContent = "اضغط للالتقاط";
    } else {
      el.stageTitle.textContent = "التقط صورة";
      el.stageHint.textContent = "ستصل الصورة إلى الصندوق مباشرة";
      el.shutterHint.textContent = "اضغط للتصوير";
    }
  }

  // ------------------------------------------------------------------ capture

  el.shutter.addEventListener("click", function () {
    if (state.busy) return;
    primeAudio();
    el.camera.value = "";
    el.camera.click();
  });

  el.camera.addEventListener("change", function () {
    var file = el.camera.files && el.camera.files[0];
    if (!file) return;
    if (state.mode === "scan") handleScan(file);
    else handlePhoto(file);
  });

  function handleScan(file) {
    setBusy(true, "جارٍ القراءة…");
    var started = Date.now();
    loadBitmap(file)
      .then(function (bitmap) {
        return decodeLocally(bitmap).then(function (local) {
          if (local) return local;
          // Nothing the browser could read. Hand the frame to the server, which
          // reads 1-D barcodes and copes with a real photograph.
          return decodeOnServer(bitmap);
        });
      })
      .then(function (result) {
        if (!result) {
          showResult("failed", "لم نتعرف على رمز", "قرّب الكاميرا من الرمز وحاول مرة أخرى");
          return null;
        }
        signalHit();
        if (result.viaServer) {
          // The server already recorded it as a scan when it decoded it.
          showResult("ok", result.value, label(result, started));
          return null;
        }
        return api("/scans/", {
          method: "POST",
          headers: { "Content-Type": "application/json" },
          body: JSON.stringify({ value: result.value, symbology: result.symbology })
        }).then(function (response) {
          if (response && response.paused) {
            showResult("failed", result.value, "الهاتف موقوف — لم يُرسل الرمز");
          } else {
            showResult("ok", result.value, label(result, started));
          }
        });
      })
      .catch(reportError)
      .then(function () { setBusy(false); });
  }

  function label(result, started) {
    var ms = Date.now() - started;
    var how = result.viaServer ? "الخادم" : "الهاتف";
    return "وصل إلى الصندوق · " + how + " · " + ms + " م.ث";
  }

  function handlePhoto(file) {
    setBusy(true, "جارٍ الإرسال…");
    loadBitmap(file)
      .then(function (bitmap) { return toJpegBlob(bitmap, PHOTO_MAX_EDGE, PHOTO_QUALITY); })
      .then(function (blob) {
        var form = new FormData();
        form.append("file", blob, "companion-" + Date.now() + ".jpg");
        if (state.captureRequestId) form.append("capture_request", String(state.captureRequestId));
        return api("/captures/", { method: "POST", body: form });
      })
      .then(function () {
        signalHit();
        showResult("ok", "وصلت الصورة إلى الصندوق", "");
        state.captureRequestId = null;
        state.modeLocked = false;
        return refreshContext();
      })
      .catch(reportError)
      .then(function () { setBusy(false); });
  }

  function reportError(error) {
    if (error && error.message === "unpaired") return;
    showResult("failed", (error && error.message) || "تعذّر الإرسال", "");
  }

  // ----------------------------------------------------------------- decoding

  function loadBitmap(file) {
    if (typeof createImageBitmap === "function") {
      // `from-image` applies the EXIF rotation an iPhone writes instead of
      // rotating the pixels, so a portrait photo is not decoded sideways.
      return createImageBitmap(file, { imageOrientation: "from-image" })
        .catch(function () { return createImageBitmap(file); })
        .catch(function () { return loadViaElement(file); });
    }
    return loadViaElement(file);
  }

  function loadViaElement(file) {
    return new Promise(function (resolve, reject) {
      var url = URL.createObjectURL(file);
      var image = new Image();
      image.onload = function () { URL.revokeObjectURL(url); resolve(image); };
      image.onerror = function () { URL.revokeObjectURL(url); reject(new Error("تعذّر فتح الصورة")); };
      image.src = url;
    });
  }

  function drawToCanvas(bitmap, maxEdge) {
    var width = bitmap.width || bitmap.naturalWidth;
    var height = bitmap.height || bitmap.naturalHeight;
    var scale = Math.min(1, maxEdge / Math.max(width, height));
    var canvas = document.createElement("canvas");
    canvas.width = Math.max(1, Math.round(width * scale));
    canvas.height = Math.max(1, Math.round(height * scale));
    canvas.getContext("2d", { willReadFrequently: true })
      .drawImage(bitmap, 0, 0, canvas.width, canvas.height);
    return canvas;
  }

  function decodeLocally(bitmap) {
    // Native first where it exists (Android Chrome): it reads EAN and Code 128
    // as well as QR, in native code, so it is both broader and faster than jsQR.
    return decodeNative(bitmap).then(function (native) {
      if (native) return native;
      if (typeof window.jsQR !== "function") return null;
      for (var index = 0; index < DECODE_EDGES.length; index++) {
        var canvas = drawToCanvas(bitmap, DECODE_EDGES[index]);
        var pixels = canvas
          .getContext("2d", { willReadFrequently: true })
          .getImageData(0, 0, canvas.width, canvas.height);
        // `dontInvert` halves the work. A light-on-dark code is rare enough
        // that the server fallback is the right place to catch it.
        var found = window.jsQR(pixels.data, pixels.width, pixels.height, {
          inversionAttempts: "dontInvert"
        });
        if (found && found.data) return { value: found.data, symbology: "qr" };
      }
      return null;
    });
  }

  function decodeNative(bitmap) {
    if (typeof window.BarcodeDetector !== "function") return Promise.resolve(null);
    var detector;
    try { detector = new window.BarcodeDetector(); }
    catch (error) { return Promise.resolve(null); }
    return detector
      .detect(drawToCanvas(bitmap, NATIVE_EDGE))
      .then(function (codes) {
        if (!codes || !codes.length) return null;
        return { value: codes[0].rawValue, symbology: codes[0].format || "" };
      })
      .catch(function () { return null; });
  }

  function decodeOnServer(bitmap) {
    return toJpegBlob(bitmap, DECODE_UPLOAD_EDGE, DECODE_UPLOAD_QUALITY)
      .then(function (blob) {
        var form = new FormData();
        form.append("file", blob, "frame.jpg");
        return api("/decode/", { method: "POST", body: form });
      })
      .then(function (response) {
        if (!response || !response.found) return null;
        return {
          value: response.value,
          symbology: response.symbology || "",
          viaServer: true
        };
      })
      .catch(function (error) {
        if (error && error.message === "unpaired") throw error;
        return null;
      });
  }

  function toJpegBlob(bitmap, maxEdge, quality) {
    var canvas = drawToCanvas(bitmap, maxEdge);
    return new Promise(function (resolve, reject) {
      if (canvas.toBlob) {
        canvas.toBlob(function (blob) {
          blob ? resolve(blob) : reject(new Error("تعذّر تجهيز الصورة"));
        }, "image/jpeg", quality);
        return;
      }
      // Safari before 14 has no toBlob; the data URL path is slower but works.
      try {
        var url = canvas.toDataURL("image/jpeg", quality);
        var binary = atob(url.split(",")[1]);
        var bytes = new Uint8Array(binary.length);
        for (var i = 0; i < binary.length; i++) bytes[i] = binary.charCodeAt(i);
        resolve(new Blob([bytes], { type: "image/jpeg" }));
      } catch (error) {
        reject(new Error("تعذّر تجهيز الصورة"));
      }
    });
  }

  // ----------------------------------------------------------------- feedback

  function primeAudio() {
    // An AudioContext may only be created or resumed inside a user gesture, and
    // the decode that wants to beep happens well after the tap that started it.
    try {
      if (!state.audio) {
        var Ctor = window.AudioContext || window.webkitAudioContext;
        if (Ctor) state.audio = new Ctor();
      }
      if (state.audio && state.audio.state === "suspended") state.audio.resume();
    } catch (error) { state.audio = null; }
  }

  function signalHit() {
    beep();
    if (navigator.vibrate) navigator.vibrate(35);
    el.flash.classList.remove("on");
    // Force a reflow so the animation restarts on a rapid second scan.
    void el.flash.offsetWidth;
    el.flash.classList.add("on");
  }

  function beep() {
    if (!state.audio) return;
    try {
      var oscillator = state.audio.createOscillator();
      var gain = state.audio.createGain();
      oscillator.type = "square";
      oscillator.frequency.value = 1720;
      gain.gain.value = 0.06;
      oscillator.connect(gain).connect(state.audio.destination);
      oscillator.start();
      oscillator.stop(state.audio.currentTime + 0.09);
    } catch (error) { /* Feedback is a nicety; never let it break a scan. */ }
  }

  function setBusy(busy, message) {
    state.busy = busy;
    el.shutter.disabled = busy;
    el.stage.classList.toggle("working", busy);
    if (busy) {
      el.result.hidden = true;
      el.stageTitle.textContent = message || "…";
      el.stageHint.textContent = "";
    } else {
      setMode(state.mode, state.modeLocked);
    }
  }

  function showResult(kind, value, note) {
    el.result.hidden = false;
    el.result.className = "result " + kind;
    el.resultIcon.innerHTML = '<path d="' + (kind === "ok" ? ICON_OK : ICON_FAIL) + '"/>';
    el.resultLabel.textContent = note || (kind === "ok" ? "تم" : "");
    el.resultValue.textContent = value;
    // Arabic text should read RTL; a URL or a barcode must not be reordered.
    el.resultValue.classList.toggle("rtl", /[؀-ۿ]/.test(value));
  }

  // -------------------------------------------------------------------- screens

  function showPairScreen() {
    stopPolling();
    el.screenPair.hidden = false;
    el.screenCamera.hidden = true;
    el.leave.hidden = true;
    el.live.hidden = true;
    el.codeInput.focus();
  }

  function showCameraScreen() {
    el.screenPair.hidden = true;
    el.screenCamera.hidden = false;
    el.leave.hidden = false;
    setMode(state.mode, state.modeLocked);
    startPolling();
  }

  el.modeScan.addEventListener("click", function () {
    state.modeLocked = false;
    setMode("scan");
  });
  el.modePhoto.addEventListener("click", function () {
    state.modeLocked = false;
    setMode("photo");
  });

  el.pairSubmit.addEventListener("click", function () {
    var code = (el.codeInput.value || "").trim();
    if (!code) return;
    el.pairError.hidden = true;
    el.pairSubmit.disabled = true;
    pair(code)
      .catch(function (error) {
        el.pairError.hidden = false;
        el.pairError.textContent = (error && error.message) || "رمز غير صالح";
      })
      .then(function () { el.pairSubmit.disabled = false; });
  });

  el.codeInput.addEventListener("keydown", function (event) {
    if (event.key === "Enter") el.pairSubmit.click();
  });

  el.leave.addEventListener("click", function () {
    api("/leave/", { method: "POST" }).catch(function () {}).then(forgetToken);
  });

  document.addEventListener("visibilitychange", function () {
    if (document.visibilityState === "visible") refreshContext();
  });

  // ----------------------------------------------------------------------- boot

  (function boot() {
    var hashCode = (location.hash || "").replace(/^#/, "").trim();
    if (hashCode) {
      // Strip it immediately: a live credential should not survive in the
      // address bar, the back stack, or a screenshot of the phone.
      history.replaceState(null, "", location.pathname + location.search);
    }

    state.token = loadToken();

    if (hashCode) {
      pair(hashCode).catch(function (error) {
        if (state.token) {
          // The QR was stale but this phone was already paired — carry on.
          refreshContext().then(showCameraScreen);
          return;
        }
        showPairScreen();
        el.pairError.hidden = false;
        el.pairError.textContent = (error && error.message) || "رمز غير صالح";
      });
      return;
    }

    if (state.token) {
      refreshContext().then(function () { if (state.token) showCameraScreen(); });
      return;
    }

    showPairScreen();
  })();
})();
