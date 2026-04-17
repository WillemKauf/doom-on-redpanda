// Doom on Redpanda — browser client.
//
// Two jobs:
//   1. Ticker at 35 Hz flushes a queue of key down/up events as a
//      binary record to the bridge's /ws endpoint. The record matches
//      our transform's input format:
//          u32 tick_seq | u8 event_count | (u8 doom_key, u8 down)*
//   2. Incoming binary frames are decoded and drawn to the canvas.
//      Frame format:
//          u32 tick_seq | u8 palette_present | [768 palette] | [64000 pixels]

(() => {
const canvas = document.getElementById("canvas");
const ctx = canvas.getContext("2d");
ctx.imageSmoothingEnabled = false;
const imageData = ctx.createImageData(320, 200);
const status = document.getElementById("status");

// Scancodes doomgeneric uses (doomkeys.h). These are NOT the same as
// chocolate doom upstream — doomgeneric reassigned FIRE/USE/etc to
// 0xa0–0xa3 and the modifier keys include a 0x80 high bit.
const KEY = {
  RIGHTARROW: 0xae,
  LEFTARROW:  0xac,
  UPARROW:    0xad,
  DOWNARROW:  0xaf,
  STRAFE_L:   0xa0,
  STRAFE_R:   0xa1,
  USE:        0xa2,        // was 0x20, wrong for doomgeneric
  FIRE:       0xa3,        // was 0x9d (RCtrl) — doomgeneric uses 0xa3
  RALT:       0x80 + 0x38, // 0xb8 — default 'strafe' modifier
  RSHIFT:     0x80 + 0x36, // 0xb6 — default 'run' modifier
  ENTER:      13,
  ESCAPE:     27,
  TAB:        9,
  Y:          0x79,
  N:          0x6e,
};

// browser key → doom scancode
function mapKey(e) {
  switch (e.code) {
    case "ArrowUp":    return KEY.UPARROW;
    case "ArrowDown":  return KEY.DOWNARROW;
    case "ArrowLeft":  return KEY.LEFTARROW;
    case "ArrowRight": return KEY.RIGHTARROW;
    case "ControlLeft":
    case "ControlRight": return KEY.FIRE;
    case "Space":      return KEY.USE;
    case "AltLeft":
    case "AltRight":   return KEY.RALT;     // strafe modifier
    case "ShiftLeft":
    case "ShiftRight": return KEY.RSHIFT;   // run modifier
    case "Enter":      return KEY.ENTER;
    case "Escape":     return KEY.ESCAPE;
    case "Tab":        return KEY.TAB;
    case "KeyY":       return KEY.Y;
    case "KeyN":       return KEY.N;
    case "Digit1": case "Digit2": case "Digit3":
    case "Digit4": case "Digit5": case "Digit6":
    case "Digit7":
      return e.code.charCodeAt(5);  // '1'..'7' ascii
    default: return 0;
  }
}

// Key events queued this tick.
const pending = [];
// Track pressed state so we don't send keydown spam (browser auto-repeat).
const down = new Set();

window.addEventListener("keydown", e => {
  const k = mapKey(e);
  if (!k) return;
  e.preventDefault();
  if (down.has(k)) return;
  down.add(k);
  pending.push([k, 1]);
});
window.addEventListener("keyup", e => {
  const k = mapKey(e);
  if (!k) return;
  e.preventDefault();
  if (!down.has(k)) return;
  down.delete(k);
  pending.push([k, 0]);
});

let tickSeq = 1;
let ws = null;
let wsReady = false;

function connect() {
  const proto = location.protocol === "https:" ? "wss:" : "ws:";
  ws = new WebSocket(`${proto}//${location.host}/ws`);
  ws.binaryType = "arraybuffer";

  ws.addEventListener("open", () => {
    wsReady = true;
    status.textContent = "connected";
    sendTick();   // prime the frame-sync loop
  });
  ws.addEventListener("close", () => {
    wsReady = false;
    status.textContent = "disconnected — reconnecting in 1s";
    setTimeout(connect, 1000);
  });
  ws.addEventListener("error", e => {
    console.warn("ws error", e);
  });
  ws.addEventListener("message", ev => {
    drawFrame(new Uint8Array(ev.data));
    // Frame-sync ticker: push the next input record now that we've
    // observed one frame in response. Keeps exactly one in-flight,
    // so the pipeline never backlogs no matter how slow Redpanda
    // round-trips.
    sendTick();
  });
}
connect();

// ---- frame decoder ----

// 256-entry RGB palette, kept alive across frames (most frames don't ship one).
const palette = new Uint8Array(768);
let havePalette = false;
let framesRendered = 0;
let lastStatusUpdate = 0;

// Sliding-window FPS tracker: timestamps (ms) of the last N frames.
// `fps = frames_in_window / window_sec`. We keep 1 s of history.
const fpsWindow = [];
const FPS_WINDOW_MS = 1000;

function drawFrame(buf) {
  if (buf.byteLength < 5) return;
  const dv = new DataView(buf.buffer, buf.byteOffset, buf.byteLength);
  // skip tick_seq at [0..4)
  const palettePresent = buf[4];
  let offset = 5;
  if (palettePresent) {
    palette.set(buf.subarray(offset, offset + 768));
    havePalette = true;
    offset += 768;
  }
  if (!havePalette) {
    // Shouldn't happen — the first frame always carries the palette.
    return;
  }
  if (buf.byteLength - offset < 320 * 200) return;

  const pixels = buf.subarray(offset, offset + 320 * 200);
  const out = imageData.data;
  for (let i = 0, j = 0; i < 320 * 200; i++) {
    const idx = pixels[i] * 3;
    out[j++] = palette[idx];
    out[j++] = palette[idx + 1];
    out[j++] = palette[idx + 2];
    out[j++] = 255;
  }
  ctx.putImageData(imageData, 0, 0);

  framesRendered++;
  const now = performance.now();
  fpsWindow.push(now);
  while (fpsWindow.length && now - fpsWindow[0] > FPS_WINDOW_MS) {
    fpsWindow.shift();
  }

  if (now - lastStatusUpdate > 200) {
    // fps is how many frames landed in the last 1 s.
    const fps = fpsWindow.length;
    status.textContent =
      `connected — ${fps.toString().padStart(3)} fps  ·  ${framesRendered} total`;
    lastStatusUpdate = now;
  }
}

// ---- input ticker ----
//
// Pacing strategy:
//   - On each incoming frame, schedule the next sendTick. Scheduling
//     respects `minIntervalMs` so we don't outrun a user-chosen cap.
//   - Without a cap, the round-trip on a local cluster is ~1 ms, which
//     would drive the game at hundreds of Hz — playable gameplay needs
//     a cap near Doom's native 35 Hz tick rate.
//   - A heartbeat fires a tick if we've been idle for > heartbeatMs,
//     covering startup (no first frame yet) and stalls.
let lastSent = 0;
let pendingTimer = null;
let uncapped = false;
let minIntervalMs = 1000 / 35;   // target ~35 Hz by default

const rate = document.getElementById("rate");
const rateNum = document.getElementById("rate-num");
const uncappedBox = document.getElementById("uncapped");

function applyRate(hz) {
  rate.value = Math.min(rate.max, Math.max(rate.min, hz));
  rateNum.value = hz;
  minIntervalMs = 1000 / hz;
}
rate.addEventListener("input", () => applyRate(+rate.value));
rateNum.addEventListener("change", () => applyRate(+rateNum.value));
uncappedBox.addEventListener("change", () => {
  uncapped = uncappedBox.checked;
  rate.disabled = uncapped;
  rateNum.disabled = uncapped;
});

function sendTickNow() {
  if (!wsReady) return;
  const n = pending.length;
  const buf = new Uint8Array(5 + n * 2);
  buf[0] = tickSeq & 0xff;
  buf[1] = (tickSeq >> 8) & 0xff;
  buf[2] = (tickSeq >> 16) & 0xff;
  buf[3] = (tickSeq >> 24) & 0xff;
  buf[4] = n;
  for (let i = 0; i < n; i++) {
    buf[5 + i * 2]     = pending[i][0];
    buf[5 + i * 2 + 1] = pending[i][1];
  }
  pending.length = 0;
  tickSeq++;
  lastSent = performance.now();
  try { ws.send(buf); } catch (e) { /* will reconnect */ }
}

function sendTick() {
  if (!wsReady) return;
  if (pendingTimer !== null) return;   // one pending already
  if (uncapped) { sendTickNow(); return; }
  const now = performance.now();
  const wait = Math.max(0, lastSent + minIntervalMs - now);
  if (wait <= 0) { sendTickNow(); return; }
  pendingTimer = setTimeout(() => {
    pendingTimer = null;
    sendTickNow();
  }, wait);
}

// Heartbeat: covers startup + stalls. Keep it well under the slowest
// plausible target rate so it only kicks in when sendTick is idle.
setInterval(() => {
  if (wsReady && performance.now() - lastSent > 500) sendTick();
}, 200);

// Focus hint.
canvas.tabIndex = 0;
canvas.focus();
canvas.addEventListener("click", () => canvas.focus());

})();
