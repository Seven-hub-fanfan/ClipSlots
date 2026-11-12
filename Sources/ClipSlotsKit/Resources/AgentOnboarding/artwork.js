(() => {
  "use strict";
  let raf = 0, inFrame = false, last = 0, elapsed = 0, playing = false, reduced = false, mode = "";
  let generation = 0, announced = -1, paintPending = false, ambient = false, slowFrames = 0, lastCost = 0;
  const query = window.AgentLineConstants.motionQuery;
  const fields = new Map();
  let active = [];
  const cards = [...document.querySelectorAll(".brand-card")];
  const motionAllowed = () => !reduced && !query.matches;
  const interacting = () => active.some(field => field.pointer.active || field.maxDisplacement > .01);
  function wake() {
    if (announced !== generation) announcePaint();
    if (!raf && !inFrame && !document.hidden && motionAllowed() &&
        ((playing && ambient) || interacting())) raf = requestAnimationFrame(frame);
  }
  function showMode() {
    document.getElementById("picker").hidden = mode !== "picker";
    document.getElementById("heroes").hidden = mode === "picker";
    document.querySelectorAll(".hero-field").forEach(card => { card.hidden = card.dataset.brand !== mode; });
    active = cards.filter(card => mode === "picker" ? card.closest("#picker") : card.dataset.brand === mode && card.classList.contains("hero-field"))
      .map(card => {
        if (!fields.has(card)) fields.set(card, new window.AgentLineField(card, wake, motionAllowed));
        return fields.get(card);
      });
    active.forEach(field => { field.resize(); field.refreshColors(); });
    ambient = mode !== "picker";
  }
  function announcePaint() {
    if (paintPending) return;
    paintPending = true;
    const revision = generation, selectedMode = mode;
    // load/didFinish do not imply the canvas has painted. Two animation-frame
    // boundaries let WebKit commit the real visible cards before native handoff.
    requestAnimationFrame(() => requestAnimationFrame(() => {
      paintPending = false;
      if (revision !== generation) { announcePaint(); return; }
      if (announced === revision || !active.length ||
          active.some(field => !field.width || !field.height || !field.frames)) return;
      announced = revision;
      window.webkit?.messageHandlers.artworkReady?.postMessage({ mode: selectedMode, revision });
    }));
  }
  function frame(now) {
    raf = 0; inFrame = true;
    const started = performance.now();
    const dt = Math.min(last ? (now - last) / 1000 : 1 / 60, .05);
    last = now;
    if (motionAllowed()) elapsed += dt;
    let settling = false;
    for (const field of active) if (field.visible && ((playing && ambient) || field.pointer.active || field.maxDisplacement > .01)) {
      field.update(dt); field.draw(elapsed);
      settling ||= field.pointer.active || field.maxDisplacement > .01;
    }
    lastCost = performance.now() - started;
    slowFrames = lastCost > 12 ? slowFrames + 1 : Math.max(0, slowFrames - 1);
    // Preserve immediate pointer interaction but stop decorative idle flow when
    // sustained CPU cost threatens the 16.7 ms frame budget.
    if (slowFrames >= 4) ambient = false;
    inFrame = false;
    if ((playing && ambient) || settling) wake();
  }
  document.querySelectorAll("#picker button").forEach(card => card.addEventListener("click", () => {
    window.webkit?.messageHandlers.selectProvider?.postMessage(card.dataset.brand);
  }));
  window.setNativeState = state => {
    const appearanceChanged = (typeof state.light === "boolean" &&
      document.documentElement.dataset.theme !== (state.light ? "light" : "dark")) ||
      (typeof state.reduced === "boolean" && reduced !== state.reduced);
    if (typeof state.light === "boolean") document.documentElement.dataset.theme = state.light ? "light" : "dark";
    if (typeof state.reduced === "boolean") reduced = state.reduced;
    if (typeof state.playing === "boolean") playing = state.playing;
    const changed = state.mode && state.mode !== mode;
    const themeChanged = typeof state.light === "boolean";
    if (changed) {
      fields.forEach(field => field.releasePointer());
      mode = state.mode;
      generation++;
      elapsed = 0;
      showMode();
    }
    if (typeof state.revision === "number") generation = state.revision;
    active.forEach(field => {
      const wasDisplaced = field.pointer.active || field.maxDisplacement > .01;
      if (themeChanged) field.refreshColors();
      if (document.hidden || !motionAllowed()) {
        field.releasePointer();
        field.displacement?.fill(0); field.velocity?.fill(0); field.maxDisplacement = 0;
      }
      if (appearanceChanged || (!changed && wasDisplaced)) field.draw(elapsed);
    });
    last = 0;
    if (!playing || !motionAllowed()) { cancelAnimationFrame(raf); raf = 0; }
    if (changed || announced !== generation) announcePaint();
    wake();
  };
  // Coordinates come from AppKit's actual window events. This does not create
  // DOM events or depend on WebKit's pointer tracking during the native handoff.
  window.setNativePointer = (x, y, present) => {
    if (!Number.isFinite(x) || !Number.isFinite(y)) return;
    active.forEach(field => {
      const rect = field.card.getBoundingClientRect();
      const inside = present && motionAllowed() && !document.hidden &&
        x >= rect.left && x < rect.right && y >= rect.top && y < rect.bottom;
      if (inside) field.setPointer(x, y, "native");
      else if (field.pointer.active) field.releasePointer();
    });
    wake();
  };
  window.lineDiagnostics = () => ({ mode, playing, reduced, ambient, lastCost, slowFrames,
    fields: [...fields.values()].map(field => field.diagnostics()) });
  document.addEventListener("visibilitychange", () => {
    last = 0;
    if (document.hidden) { cancelAnimationFrame(raf); raf = 0; }
    else wake();
  });
  query.addEventListener("change", () => window.setNativeState({ reduced }));
  window.setNativeState(window.__nativeArtworkState || { mode: "picker", playing: false });
})();
