import Foundation

/// The embedded web remote page: a dark, phone-first GO surface served by
/// `WebRemoteServer` at `GET /`. Zero external resources (no CDN scripts,
/// no external stylesheets or fonts) — system font stack only, so the page
/// works on an isolated show network with no internet access.
///
/// Deliberately does NOT include a panic button: Esc-grade emergency stop
/// stays a physical keyboard action on the operator's Mac. STOP ALL (a
/// fade-out, double-tap-armed to guard against a stray touch) is the
/// remote's ceiling; `POST /panic` still exists server-side for
/// completeness, just not wired to anything on this page.
enum WebRemotePage {
    static let html = #"""
    <!doctype html>
    <html lang="en">
    <head>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1, maximum-scale=1">
    <title>StageWizard Remote</title>
    <style>
      :root {
        color-scheme: dark;
        --bg: #0b0c0f;
        --panel: #17181d;
        --inset: #1f2129;
        --text: #f5f6f8;
        --dim: #9aa0ab;
        --green: #24c766;
        --green-active: #1a9e51;
        --red: #ff3b30;
        --border: #2a2c34;
      }
      * {
        box-sizing: border-box;
        -webkit-tap-highlight-color: transparent;
        touch-action: manipulation;
      }
      html, body {
        margin: 0;
        height: 100%;
        background: var(--bg);
        color: var(--text);
        font-family: -apple-system, BlinkMacSystemFont, "SF Pro Text", system-ui, sans-serif;
        -webkit-user-select: none;
        user-select: none;
      }
      body {
        display: flex;
        flex-direction: column;
        min-height: 100vh;
        padding: max(env(safe-area-inset-top), 12px) 16px max(env(safe-area-inset-bottom), 16px);
      }
      header {
        display: flex;
        align-items: center;
        justify-content: space-between;
        padding: 6px 2px 12px;
      }
      .brand {
        font-size: 13px;
        font-weight: 700;
        letter-spacing: 0.16em;
        text-transform: uppercase;
        color: var(--dim);
      }
      .dot {
        width: 10px;
        height: 10px;
        border-radius: 50%;
        background: var(--red);
        box-shadow: 0 0 8px currentColor;
      }
      .dot.ok { background: var(--green); color: var(--green); }
      .dot.bad { background: var(--red); color: var(--red); }

      .standby {
        background: var(--panel);
        border: 1px solid var(--border);
        border-radius: 14px;
        padding: 16px;
        margin-bottom: 10px;
      }
      .standby .num {
        font-size: 14px;
        font-weight: 700;
        color: var(--dim);
        letter-spacing: 0.04em;
      }
      .standby .name {
        font-size: 26px;
        font-weight: 800;
        line-height: 1.25;
        margin-top: 2px;
        word-break: break-word;
      }
      .standby .notes {
        font-size: 14px;
        color: var(--dim);
        margin-top: 10px;
        white-space: pre-wrap;
      }

      .status-line {
        display: flex;
        align-items: center;
        justify-content: space-between;
        font-size: 13px;
        color: var(--dim);
        padding: 2px 4px 14px;
      }
      .status-line .panic {
        color: var(--red);
        font-weight: 800;
        letter-spacing: 0.08em;
      }

      .go-btn {
        flex: 1;
        min-height: 40vh;
        width: 100%;
        border: none;
        border-radius: 20px;
        background: var(--green);
        color: #06210f;
        font-size: 44px;
        font-weight: 900;
        letter-spacing: 0.06em;
        box-shadow: 0 6px 0 var(--green-active);
      }
      .go-btn:active {
        background: var(--green-active);
        box-shadow: 0 2px 0 var(--green-active);
        transform: translateY(4px);
      }
      .go-btn:disabled {
        opacity: 0.4;
        box-shadow: none;
        transform: none;
      }

      .row {
        display: flex;
        gap: 10px;
        margin-top: 10px;
      }
      .nav-btn {
        flex: 1;
        padding: 18px 0;
        border: 1px solid var(--border);
        border-radius: 14px;
        background: var(--panel);
        color: var(--text);
        font-size: 18px;
        font-weight: 700;
      }
      .nav-btn:active { background: var(--inset); }

      .stop-btn {
        margin-top: 10px;
        width: 100%;
        padding: 18px 0;
        border: 1px solid var(--red);
        border-radius: 14px;
        background: var(--inset);
        color: var(--red);
        font-size: 16px;
        font-weight: 800;
        letter-spacing: 0.05em;
      }
      .stop-btn.armed {
        background: var(--red);
        color: #2a0906;
        border-color: var(--red);
      }
      .stop-btn:active { transform: scale(0.98); }

      button { font-family: inherit; }
    </style>
    </head>
    <body>
      <header>
        <span class="brand">StageWizard</span>
        <span class="dot bad" id="dot"></span>
      </header>

      <div class="standby">
        <div class="num" id="num">—</div>
        <div class="name" id="name">—</div>
        <div class="notes" id="notes"></div>
      </div>

      <div class="status-line">
        <span id="running">idle</span>
        <span class="panic" id="panic" hidden>PANIC</span>
      </div>

      <button class="go-btn" id="go">GO</button>

      <div class="row">
        <button class="nav-btn" id="prev">◀ Prev</button>
        <button class="nav-btn" id="next">Next ▶</button>
      </div>

      <button class="stop-btn" id="stop">STOP ALL</button>

    <script>
    (function () {
      "use strict";

      var dot = document.getElementById("dot");
      var num = document.getElementById("num");
      var name = document.getElementById("name");
      var notes = document.getElementById("notes");
      var running = document.getElementById("running");
      var panic = document.getElementById("panic");
      var goBtn = document.getElementById("go");
      var prevBtn = document.getElementById("prev");
      var nextBtn = document.getElementById("next");
      var stopBtn = document.getElementById("stop");

      function post(path) {
        return fetch(path, { method: "POST" }).catch(function () {});
      }

      function debounce(btn, ms) {
        btn.disabled = true;
        setTimeout(function () { btn.disabled = false; }, ms || 350);
      }

      goBtn.addEventListener("click", function () {
        if (goBtn.disabled) { return; }
        if (navigator.vibrate) { navigator.vibrate(30); }
        debounce(goBtn, 350);
        post("/go");
      });

      prevBtn.addEventListener("click", function () {
        debounce(prevBtn, 300);
        post("/prev");
      });

      nextBtn.addEventListener("click", function () {
        debounce(nextBtn, 300);
        post("/next");
      });

      var stopArmed = false;
      var stopTimer = null;

      function disarmStop() {
        stopArmed = false;
        stopBtn.classList.remove("armed");
        stopBtn.textContent = "STOP ALL";
        if (stopTimer) { clearTimeout(stopTimer); stopTimer = null; }
      }

      stopBtn.addEventListener("click", function () {
        if (!stopArmed) {
          stopArmed = true;
          stopBtn.classList.add("armed");
          stopBtn.textContent = "TAP AGAIN TO STOP ALL";
          stopTimer = setTimeout(disarmStop, 1500);
          return;
        }
        disarmStop();
        debounce(stopBtn, 300);
        post("/stopall");
      });

      function fetchWithTimeout(path, ms) {
        if (typeof AbortSignal !== "undefined" && AbortSignal.timeout) {
          return fetch(path, { signal: AbortSignal.timeout(ms) });
        }
        var controller = new AbortController();
        var timer = setTimeout(function () { controller.abort(); }, ms);
        return fetch(path, { signal: controller.signal }).finally(function () { clearTimeout(timer); });
      }

      function poll() {
        fetchWithTimeout("/status", 900)
          .then(function (res) {
            if (!res.ok) { throw new Error("bad status"); }
            return res.json();
          })
          .then(function (data) {
            dot.classList.remove("bad");
            dot.classList.add("ok");
            num.textContent = data.standingByNumber || "—";
            name.textContent = data.standingByName || "—";
            notes.textContent = data.notes || "";
            running.textContent = data.runningCount > 0 ? (data.runningCount + " running") : "idle";
            panic.hidden = !data.panicking;
            goBtn.disabled = !data.standingByNumber || data.panicking;
          })
          .catch(function () {
            dot.classList.remove("ok");
            dot.classList.add("bad");
          });
      }

      poll();
      setInterval(poll, 1000);
    })();
    </script>
    </body>
    </html>
    """#
}
