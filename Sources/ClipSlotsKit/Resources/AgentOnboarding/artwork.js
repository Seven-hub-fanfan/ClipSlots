(() => {
  "use strict";
  let raf = 0, inFrame = false, last = 0, elapsed = 0, playing = false, reduced = false, mode = "";
  const query = window.AgentLineConstants.motionQuery;
  function wake() {
    if (!raf && !inFrame && !document.hidden) raf = requestAnimationFrame(frame);
  }
  const fields = [...document.querySelectorAll(".brand-card")].map(card =>
    new window.AgentLineField(card, wake, () => !reduced));
  function frame(now) {
    raf = 0; inFrame = true;
    const dt = Math.min(last ? (now - last) / 1000 : 1 / 60, .05);
    last = now;
    if (playing && !reduced && !query.matches) elapsed += dt;
    let settling = false;
    for (const field of fields) if (field.visible) {
      field.update(dt); field.draw(elapsed);
      settling ||= field.maxDisplacement > .01;
    }
    inFrame = false;
    if ((playing && !reduced && !query.matches) || settling) wake();
  }
  document.querySelectorAll("#picker button").forEach(card => card.addEventListener("click", () => {
    window.webkit?.messageHandlers.selectProvider.postMessage(card.dataset.brand);
  }));
  window.setNativeState = state => {
    if (typeof state.light === "boolean") document.documentElement.dataset.theme = state.light ? "light" : "dark";
    if (typeof state.reduced === "boolean") reduced = state.reduced;
    if (typeof state.playing === "boolean") playing = state.playing;
    if (state.mode && state.mode !== mode) {
      mode = state.mode;
      document.getElementById("picker").hidden = mode !== "picker";
      document.getElementById("heroes").hidden = mode === "picker";
      document.querySelectorAll(".hero-field").forEach(card => { card.hidden = card.dataset.brand !== mode; });
      fields.forEach(field => { field.releasePointer(); field.resize(); });
    }
    fields.forEach(field => { field.refreshColors(); if (reduced) field.releasePointer(); field.draw(elapsed); });
    last = 0; wake();
  };
  window.lineDiagnostics = () => ({ mode, playing, reduced, fields: fields.map(field => field.diagnostics()) });
  document.addEventListener("visibilitychange", () => { last = 0; if (!document.hidden) wake(); });
  query.addEventListener("change", wake);
})();
