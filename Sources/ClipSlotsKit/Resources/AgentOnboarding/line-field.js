(() => {
  "use strict";
  // Same silhouette sampler, four stroke widths, downward flow and spring
  // constants as the approved four-brand preview. Only the fixed CSS scale
  // changes to fit each card; resizing changes the viewport, never this scale.
  const WORLD_W = 320, WORLD_H = 440, LOGO_SIZE = 208;
  const STEP_X = 6, STEP_Y = 5, WIDTHS = [.32, 1.05, 2.55, 4.35];
  const clamp = (v, min, max) => Math.max(min, Math.min(max, v));
  const motionQuery = matchMedia("(prefers-reduced-motion: reduce)");
  // Immutable silhouettes are shared by picker and detail cards. Pointer
  // displacement and velocity remain private to each mounted field.
  const masks = new Map();
  const noise = (x, y) => .50 + .24 * Math.sin(y * .076 + Math.sin(x * .091) * 2.1)
    + .16 * Math.sin(y * .171 + x * .093) + .10 * Math.sin(y * .043 - x * .23);

  class LineField {
    constructor(card, wake, onInteraction) {
      this.card = card; this.brand = card.dataset.brand;
      this.scale = Number(card.dataset.scale); this.wake = wake;
      this.canvas = card.querySelector("canvas"); this.ctx = this.canvas.getContext("2d");
      this.cursor = card.querySelector(".demo-pointer");
      this.path = new Path2D(window.LINE_LOGOS[this.brand].path);
      this.fillRule = window.LINE_LOGOS[this.brand].fillRule || "nonzero";
      this.width = 0; this.height = 0; this.frames = 0; this.time = 0;
      this.pointer = { x: 0, y: 0, active: false, source: "none" };
      this.maxDisplacement = 0; this.makeMask(); this.makeIcon(); this.resize();
      this.observer = new ResizeObserver(() => { this.resize(); wake(); });
      this.observer.observe(card);
      card.addEventListener("pointermove", event => {
        if (onInteraction() === false) return;
        this.setPointer(event.clientX, event.clientY, "user");
      });
      card.addEventListener("pointerleave", () => this.releasePointer());
      card.addEventListener("pointercancel", () => this.releasePointer());
      card.addEventListener("pointerup", event => {
        if (event.pointerType !== "mouse") this.releasePointer();
      });
      card.addEventListener("focus", () => {
        this.pointer = { x: this.width / 2 + 15, y: this.height / 2,
          active: true, source: "keyboard" }; wake();
      });
      card.addEventListener("blur", () => this.releasePointer());
    }

    get visible() { return this.card.getClientRects().length > 0; }
    makeIcon() {
      const host = this.card.querySelector(".brand-icon");
      if (!host) return;
      const ns = "http://www.w3.org/2000/svg";
      const svg = document.createElementNS(ns, "svg");
      svg.setAttribute("viewBox", window.LINE_LOGOS[this.brand].viewBox);
      svg.setAttribute("fill-rule", this.fillRule);
      const path = document.createElementNS(ns, "path");
      path.setAttribute("d", window.LINE_LOGOS[this.brand].path);
      svg.appendChild(path); host.appendChild(svg);
    }
    makeMask() {
      const cached = masks.get(this.brand);
      if (cached) { this.alpha = cached.alpha; this.boxes = cached.boxes; return; }
      const mask = document.createElement("canvas"); mask.width = WORLD_W; mask.height = WORLD_H;
      const ctx = mask.getContext("2d", { willReadFrequently: true });
      ctx.translate((WORLD_W - LOGO_SIZE) / 2, 109); ctx.scale(LOGO_SIZE / 24, LOGO_SIZE / 24);
      ctx.fill(this.path, this.fillRule);
      this.alpha = ctx.getImageData(0, 0, WORLD_W, WORLD_H).data;
      const regions = [], boxW = 36, boxH = 30;
      for (let y = 114; y < 306; y += 15) {
        for (let x = 58; x < 242; x += 18) {
          let score = 0;
          for (let by = y; by < y + boxH; by += 3)
            for (let bx = x; bx < x + boxW; bx += 3) score += this.sample(bx, by);
          regions.push({ x, y, w: boxW, h: boxH, score });
        }
      }
      regions.sort((a, b) => b.score - a.score); this.boxes = [];
      for (const region of regions) {
        if (this.boxes.every(box => Math.hypot(region.x - box.x, region.y - box.y) > 68)) {
          this.boxes.push(region); if (this.boxes.length === 3) break;
        }
      }
      this.boxes.sort((a, b) => a.y - b.y);
      masks.set(this.brand, { alpha: this.alpha, boxes: this.boxes });
    }
    sample(x, y) {
      const ix = Math.round(x), iy = Math.round(y);
      if (ix < 0 || ix >= WORLD_W || iy < 0 || iy >= WORLD_H) return 0;
      return this.alpha[(iy * WORLD_W + ix) * 4 + 3] / 255;
    }
    refreshColors() {
      const css = getComputedStyle(this.card), root = getComputedStyle(document.documentElement);
      this.color = css.getPropertyValue("--line").trim();
      this.thinOpacity = Number(css.getPropertyValue("--thin-opacity"));
      this.boxColor = root.getPropertyValue("--box").trim();
      this.boxText = root.getPropertyValue("--box-text").trim();
    }
    resize() {
      const rect = this.canvas.getBoundingClientRect();
      if (!rect.width || !rect.height) return;
      const dpr = Math.min(devicePixelRatio || 1, 2.5);
      const width = rect.width / this.scale, height = rect.height / this.scale;
      if (width === this.width && height === this.height && dpr === this.dpr) return;
      const previous = this.displacement ? {
        x: this.offsetX, y: this.offsetY, columns: this.columns, rows: this.rows,
        displacement: this.displacement, velocity: this.velocity
      } : null;
      this.width = width; this.height = height; this.dpr = dpr;
      this.canvas.width = Math.round(rect.width * dpr);
      this.canvas.height = Math.round(rect.height * dpr);
      this.offsetX = (width - WORLD_W) / 2; this.offsetY = (height - WORLD_H) / 2;
      this.columns = Math.ceil(width / STEP_X) + 1; this.rows = Math.ceil(height / STEP_Y) + 1;
      this.displacement = new Float32Array(this.columns * this.rows);
      this.velocity = new Float32Array(this.columns * this.rows);
      if (previous) {
        for (let col = 0; col < this.columns; col++) {
          const worldX = col * STEP_X + this.offsetX % STEP_X - this.offsetX;
          const oldCol = Math.round((worldX + previous.x - previous.x % STEP_X) / STEP_X);
          if (oldCol < 0 || oldCol >= previous.columns) continue;
          for (let row = 0; row < this.rows; row++) {
            const oldRow = Math.round((row * STEP_Y - this.offsetY + previous.y) / STEP_Y);
            if (oldRow < 0 || oldRow >= previous.rows) continue;
            const index = col * this.rows + row, oldIndex = oldCol * previous.rows + oldRow;
            this.displacement[index] = previous.displacement[oldIndex];
            this.velocity[index] = previous.velocity[oldIndex];
          }
        }
      }
      this.refreshColors();
      // Clearing the backing store on ResizeObserver must be followed by a
      // synchronous redraw, so continuous width changes never show a blank frame.
      this.draw(this.time);
    }
    releasePointer() {
      this.pointer.active = false; this.pointer.source = "none";
      this.cursor.style.display = "none"; this.wake();
    }
    setPointer(x, y, source) {
      const rect = this.canvas.getBoundingClientRect();
      this.pointer = { x: (x - rect.left) / this.scale,
        y: (y - rect.top) / this.scale, active: true, source };
      this.wake();
    }
    demoPointer(x, y, active) {
      this.pointer = { x: this.width / 2 + x, y: this.height / 2 + y,
        active, source: active ? "demo" : "none" };
      this.cursor.style.display = active && this.visible ? "block" : "none";
      this.cursor.style.left = `${this.pointer.x * this.scale}px`;
      this.cursor.style.top = `${this.pointer.y * this.scale}px`;
    }
    update(dt) {
      if (!this.pointer.active && this.maxDisplacement === 0) return;
      const p = this.pointer, radius = 85, timeStep = clamp(dt * 60, .1, 2);
      const damping = Math.pow(.79, timeStep), radiusSquared = radius * radius;
      let max = 0;
      for (let col = 0; col < this.columns; col++) {
        const x = col * STEP_X + this.offsetX % STEP_X;
        for (let row = 0; row < this.rows; row++) {
          const index = col * this.rows + row, dx = x - p.x, dy = row * STEP_Y - p.y;
          const distanceSquared = dx * dx + dy * dy; let target = 0;
          if (p.active && distanceSquared < radiusSquared) {
            const dist = Math.sqrt(distanceSquared), falloff = 1 - dist / radius;
            target = (dx / Math.max(dist, 12)) * falloff * falloff * 69;
          }
          this.velocity[index] += (target - this.displacement[index]) * .078 * timeStep;
          this.velocity[index] *= damping;
          this.displacement[index] += this.velocity[index] * timeStep;
          if (Math.abs(this.displacement[index]) < .004 && Math.abs(this.velocity[index]) < .004)
            this.displacement[index] = this.velocity[index] = 0;
          max = Math.max(max, Math.abs(this.displacement[index]));
        }
      }
      this.maxDisplacement = max;
    }
    draw(time) {
      if (!this.visible) return;
      this.time = time;
      const ctx = this.ctx, factor = this.dpr * this.scale;
      ctx.setTransform(factor, 0, 0, factor, 0, 0);
      ctx.clearRect(0, 0, this.width, this.height);
      const paths = WIDTHS.map(() => new Path2D()), phase = motionQuery.matches ? 0 : time * 10;
      for (let col = 0; col < this.columns; col++) {
        const x = col * STEP_X + this.offsetX % STEP_X, worldX = x - this.offsetX;
        for (let row = 0; row < this.rows - 1; row++) {
          const y = row * STEP_Y, index = col * this.rows + row, worldY = y - this.offsetY;
          const n = noise(worldX, worldY - phase);
          const subtleDrift = Math.sin(worldY * .018 - time * .25 + col * .16) * .38;
          const brightness = this.sample(worldX + subtleDrift, worldY) * (.47 + .53 * n);
          let band = brightness > .76 ? 3 : brightness > .34 ? 2 : brightness > .10 ? 1 : 0;
          if (!band && n > .915 && this.sample(worldX + 9 * Math.sin(col), worldY + 12) > .5) band = 1;
          paths[band].moveTo(x + this.displacement[index], y);
          paths[band].lineTo(x + this.displacement[index + 1], y + STEP_Y + .1);
        }
      }
      ctx.strokeStyle = this.color; ctx.lineCap = "butt";
      paths.forEach((path, band) => {
        ctx.globalAlpha = band === 0 ? this.thinOpacity : band === 1 ? .68 : 1;
        ctx.lineWidth = WIDTHS[band]; ctx.stroke(path);
      });
      this.drawBoxes(ctx, time); ctx.globalAlpha = 1; this.frames++;
    }
    fieldOffset(x, y) {
      const col = clamp(Math.round((x - this.offsetX % STEP_X) / STEP_X), 0, this.columns - 1);
      const row = clamp(Math.round(y / STEP_Y), 0, this.rows - 1);
      return this.displacement[col * this.rows + row];
    }
    drawBoxes(ctx, time) {
      ctx.globalAlpha = this.pointer.active ? 1 : .64;
      ctx.strokeStyle = this.boxColor; ctx.fillStyle = this.boxColor; ctx.lineWidth = .8;
      ctx.font = "6px DMMono, monospace"; ctx.textBaseline = "middle";
      this.boxes.forEach((box, i) => {
        const baseX = box.x + this.offsetX, y = box.y + this.offsetY;
        const x = baseX + this.fieldOffset(baseX + box.w / 2, y + box.h / 2) * .6;
        const w = box.w, h = box.h;
        ctx.strokeRect(x, y, w, h); ctx.lineWidth = 1.25;
        ctx.beginPath();
        ctx.moveTo(x, y + 5); ctx.lineTo(x, y); ctx.lineTo(x + 5, y);
        ctx.moveTo(x + w - 5, y + h); ctx.lineTo(x + w, y + h); ctx.lineTo(x + w, y + h - 5);
        ctx.stroke(); ctx.lineWidth = .8;
        const confidence = (.88 + i * .015 + Math.sin(time * .2 + i) * .008).toFixed(2);
        const label = `OBJ_${i + 1} ${confidence}`, labelWidth = ctx.measureText(label).width + 6;
        ctx.fillRect(x, y - 9, labelWidth, 8); ctx.fillStyle = this.boxText;
        ctx.fillText(label, x + 3, y - 5); ctx.fillStyle = this.boxColor;
        const connectorY = Math.min(y + h + 17 + i * 5, this.height - 55);
        ctx.beginPath(); ctx.moveTo(x + w, y + h); ctx.lineTo(x + w + 11, y + h);
        ctx.lineTo(x + w + 11, connectorY); ctx.lineTo(x + w + 23, connectorY); ctx.stroke();
        ctx.fillText(`${Math.round(box.x)},${Math.round(box.y)}`, x + w + 25, connectorY);
      });
    }
    diagnostics() {
      return { brand: this.brand, kind: this.card.classList.contains("hero-field") ? "hero" : "picker",
        visible: this.visible, viewportCSS: [this.width * this.scale, this.height * this.scale],
        canvasPixels: [this.canvas.width, this.canvas.height], scale: this.scale,
        logoSizeCSS: LOGO_SIZE * this.scale, opacity: getComputedStyle(this.canvas).opacity,
        pointer: { ...this.pointer }, displacementCSS: Number((this.maxDisplacement * this.scale).toFixed(3)),
        frames: this.frames, boxes: this.boxes.length };
    }
  }
  window.AgentLineField = LineField;
  window.AgentLineConstants = { world: [WORLD_W, WORLD_H], strokeWidths: WIDTHS, motionQuery };
})();
