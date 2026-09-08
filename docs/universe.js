/* A dependency-free illustration: particles, orbital connections and scroll depth.
   This is decorative animation, never a representation of measured activations. */
(() => {
  "use strict";
  const $ = (selector) => document.querySelector(selector);
  const $$ = (selector) => [...document.querySelectorAll(selector)];
  const motionPreference = matchMedia("(prefers-reduced-motion: reduce)");
  const journey = $(".journey");
  const stage = $(".universe-stage");
  const world = $(".orbit-world");
  const photo = $(".desk-photo");
  const backdrop = $(".office-background");
  const cutaway = $(".base-cutaway");
  const appImage = $(".screen-app");
  const depthLabel = $(".scene-label");
  const board = new Image();
  board.src = "assets/silicon-board.jpg";
  let sceneProgress = 0;
  // Normalized anchors measured against the supplied photographic plate.
  // Everything is nested: neural field → die → board UNDER keyboard → overhead desk → front.
  const die = { x: 586 / 1536, y: 296 / 1024, w: 360 / 1536, h: 380 / 1024 };
  const dieCenter = { x: die.x + die.w / 2, y: die.y + die.h / 2 };
  let sceneReady = false;
  let roomWidth = 1,
    roomHeight = 1;
  const canvas = $("#universe");
  const context = canvas.getContext("2d");
  const copies = $$(".stage-copy");
  const toggle = $("#motion-toggle");
  let explicitMotion = null;
  try {
    explicitMotion = localStorage.getItem("dyno-motion");
  } catch {
    /* Storage is optional. */
  }
  let reduced = explicitMotion
    ? explicitMotion === "paused"
    : motionPreference.matches;
  let width = 1,
    height = 1,
    progress = 0,
    targetProgress = 0,
    frame = 0,
    lastTime = 0,
    time = 0;
  let pointerX = 0,
    pointerY = 0,
    targetX = 0,
    targetY = 0;
  let visible = true;
  const clamp = (n, low = 0, high = 1) => Math.min(high, Math.max(low, n));
  const smooth = (a, b, x) => {
    const t = clamp((x - a) / (b - a));
    return t * t * (3 - 2 * t);
  };
  let seed = 31415;
  const random = () => {
    seed = (seed * 1664525 + 1013904223) >>> 0;
    return seed / 4294967296;
  };
  const neurons = Array.from({ length: 96 }, (_, i) => ({
    layer: Math.floor(i / 12),
    row: i % 12,
    z: random() * 2 - 1,
    phase: random(),
  }));
  const synapses = [];
  neurons.forEach((neuron, i) => {
    if (neuron.layer === 7) return;
    for (let offset = -2; offset <= 2; offset++) {
      const row = neuron.row + offset;
      if (row >= 0 && row < 12)
        synapses.push([i, (neuron.layer + 1) * 12 + row]);
    }
  });

  function applyMotion() {
    document.body.classList.toggle("reduced", reduced);
    toggle.textContent = reduced ? "Enable motion ▷" : "Pause motion Ⅱ";
    toggle.setAttribute("aria-pressed", String(reduced));
    if (frame) cancelAnimationFrame(frame);
    frame = 0;
    updateScroll();
    requestFrame();
  }
  toggle.addEventListener("click", () => {
    reduced = !reduced;
    explicitMotion = reduced ? "paused" : "enabled";
    try {
      localStorage.setItem("dyno-motion", explicitMotion);
    } catch {
      /* No persistence required. */
    }
    applyMotion();
  });
  motionPreference.addEventListener("change", () => {
    if (!explicitMotion) {
      reduced = motionPreference.matches;
      applyMotion();
    }
  });
  function resize() {
    const mobile = stage.clientWidth <= 700;
    roomWidth = mobile
      ? stage.clientWidth * 1.65
      : Math.max(stage.clientWidth * 1.35, stage.clientHeight * 1.5);
    roomHeight = roomWidth / 1.5;
    world.style.width = `${roomWidth}px`;
    width = Math.round(roomWidth * 0.386);
    height = Math.round(roomHeight * 0.24);
    // Render enough pixels for the initial close-up, bounded for mobile GPUs.
    const ratio = Math.min(
      5,
      Math.max(devicePixelRatio || 1, (stage.clientHeight / height) * 1.5),
    );
    canvas.width = Math.round(width * ratio);
    canvas.height = Math.round(height * ratio);
    if (context) context.setTransform(ratio, 0, 0, ratio, 0, 0);
    updateScroll();
    requestFrame();
  }
  function updateScroll() {
    const box = journey.getBoundingClientRect();
    targetProgress = reduced
      ? 0
      : clamp(-box.top / Math.max(1, box.height - stage.clientHeight));
    if (reduced) progress = 0;
    requestFrame();
  }
  function updateCamera() {
    const p = sceneReady ? progress : 0;
    sceneProgress = p;
    // Retreat vertically from the silicon under the keys, then orbit around
    // the keyboard hinge. The screen is a separate upright plane, never a
    // container for hardware imagery. Both are transformed in the same space.
    const pullback = reduced ? 1 : smooth(0.39, 0.76, p);
    const orbit = reduced ? 1 : smooth(0.76, 0.98, p);
    const startScale =
      Math.max(stage.clientWidth / width, stage.clientHeight / height) * 1.16;
    const zoom = reduced ? 1 : Math.exp(Math.log(startScale) * (1 - pullback));
    // Complete the vertical dolly before lowering the camera. Keeping the
    // room's scale fixed during the orbit avoids the impression of a moving desk.
    const finalScale = stage.clientWidth <= 700 ? 0.968 : 0.6864;
    const scale = zoom * (1 + (finalScale - 1) * pullback);
    const baseCenterX = (0.306 + 0.386 / 2 - 0.5) * roomWidth;
    const baseCenterY = (0.282 + 0.24 / 2 - 0.5) * roomHeight;
    const offsetX = reduced ? 0 : -baseCenterX * scale * (1 - pullback);
    const finalY =
      stage.clientHeight * (stage.clientWidth <= 700 ? 0.18 : 0.22);
    const offsetY = -baseCenterY * scale * (1 - pullback) + finalY * orbit;
    world.style.transform = `translate(calc(-50% + ${offsetX}px),calc(-50% + ${offsetY}px)) rotateX(${orbit * 67}deg) scale3d(${scale},${scale},${scale})`;
    cutaway.style.opacity = reduced ? 0 : 1 - smooth(0.49, 0.73, p);
    const opacities = [
      reduced ? 1 : 1 - smooth(0.06, 0.2, p),
      reduced ? 0 : smooth(0.94, 0.995, p),
    ];
    copies.forEach((copy, index) => {
      copy.style.opacity = opacities[index];
      copy.style.visibility = opacities[index] < 0.01 ? "hidden" : "visible";
      copy.inert = opacities[index] < 0.1;
      if (index > 0)
        copy.setAttribute("aria-hidden", String(opacities[index] < 0.1));
      copy.style.transform = reduced
        ? "none"
        : index === 0
          ? `translateY(${-p * 100}px) scale(${1 - pullback * 0.35})`
          : `translateY(${(1 - pullback) * 60}px)`;
    });
    const labels = [
      "01 / NEURAL ACTIVATIONS",
      "02 / SILICON UNDER THE KEYS",
      "03 / THROUGH THE KEYBOARD",
      "04 / ABOVE YOUR DESK",
      "05 / YOUR MAC",
    ];
    const depth = p < 0.19 ? 0 : p < 0.45 ? 1 : p < 0.62 ? 2 : p < 0.84 ? 3 : 4;
    depthLabel.textContent = reduced ? "APPLE SILICON × MLX" : labels[depth];
    $(".journey-progress b").style.width = `${progress * 100}%`;
  }
  window.addEventListener("scroll", updateScroll, { passive: true });
  window.addEventListener("resize", resize, { passive: true });
  stage.addEventListener(
    "pointermove",
    (event) => {
      if (reduced || event.pointerType === "touch") return;
      targetX = (event.clientX / stage.clientWidth - 0.5) * 2;
      targetY = (event.clientY / stage.clientHeight - 0.5) * 2;
      requestFrame();
    },
    { passive: true },
  );
  stage.addEventListener("pointerleave", () => {
    targetX = 0;
    targetY = 0;
  });
  function requestFrame() {
    if (!frame && !document.hidden && visible)
      frame = requestAnimationFrame(draw);
  }
  function draw(now) {
    frame = 0;
    const dt = Math.min((now - lastTime) / 1000 || 1 / 60, 0.05);
    if (!reduced) time += dt;
    progress += (targetProgress - progress) * (1 - Math.exp(-dt * 8));
    if (Math.abs(targetProgress - progress) < 0.00001)
      progress = targetProgress;
    updateCamera();
    lastTime = now;
    pointerX += ((reduced ? 0 : targetX) - pointerX) * 0.055;
    pointerY += ((reduced ? 0 : targetY) - pointerY) * 0.055;
    if (context) drawUniverse();
    if (!reduced && (sceneProgress < 0.74 || progress !== targetProgress))
      requestFrame();
  }
  function drawUniverse() {
    const ctx = context;
    const p = sceneProgress;
    ctx.clearRect(0, 0, width, height);
    ctx.fillStyle = "#070e0c";
    ctx.fillRect(0, 0, width, height);
    if (reduced || p > 0.74) return;
    const boardWidth = Math.max(width, height * 1.5) * 1.08;
    const boardHeight = boardWidth / 1.5;
    const startZoom =
      Math.max(width / (boardWidth * die.w), height / (boardHeight * die.h)) *
      1.15;
    const zoom = Math.exp(Math.log(startZoom) * (1 - smooth(0.06, 0.42, p)));
    ctx.save();
    ctx.translate(width / 2, height / 2);
    ctx.scale(zoom, zoom);
    ctx.translate(-boardWidth * dieCenter.x, -boardHeight * dieCenter.y);
    if (sceneReady) ctx.drawImage(board, 0, 0, boardWidth, boardHeight);
    const x = boardWidth * die.x,
      y = boardHeight * die.y;
    const w = boardWidth * die.w,
      h = boardHeight * die.h;
    ctx.save();
    ctx.beginPath();
    ctx.rect(x, y, w, h);
    ctx.clip();
    const silicon = smooth(0.15, 0.4, p);
    ctx.fillStyle = `rgba(5,14,11,${1 - silicon * 0.28})`;
    ctx.fillRect(x, y, w, h);
    // The architectural grid resolves from darkness as the camera clears the die.
    ctx.lineWidth = 0.22;
    ctx.strokeStyle = `rgba(155,190,132,${0.04 + silicon * 0.16})`;
    for (let i = 0; i <= 24; i++) {
      ctx.beginPath();
      ctx.moveTo(x + (w * i) / 24, y);
      ctx.lineTo(x + (w * i) / 24, y + h);
      ctx.stroke();
      ctx.beginPath();
      ctx.moveTo(x, y + (h * i) / 24);
      ctx.lineTo(x + w, y + (h * i) / 24);
      ctx.stroke();
    }
    // A layered neural field, with animated signal packets and firing neurons.
    // This is a conceptual illustration, not live measured model activity.
    const projected = neurons.map((n) => {
      const depth = 1 / (1.7 - n.z * 0.3);
      return {
        x:
          x +
          w * (0.5 + (n.layer / 7 - 0.5) * 1.38 * depth) +
          pointerX * w * 0.018 * n.z,
        y:
          y +
          h * (0.5 + (n.row / 11 - 0.5) * 1.55 * depth) +
          Math.sin(time * 0.22 + n.phase * 6.28) * h * 0.016 +
          pointerY * h * 0.018 * n.z,
        z: n.z,
        phase: n.phase,
        layer: n.layer,
      };
    });
    for (let i = 0; i < synapses.length; i++) {
      const [ai, bi] = synapses[i],
        a = projected[ai],
        b = projected[bi];
      ctx.strokeStyle = `rgba(165,218,158,${0.1 + (a.z + 1) * 0.065})`;
      ctx.lineWidth = w * 0.0014;
      ctx.beginPath();
      ctx.moveTo(a.x, a.y);
      ctx.lineTo(b.x, b.y);
      ctx.stroke();
      if (i % 5 !== 0) continue;
      const t = (time * 0.65 - a.layer * 0.15 + a.phase + 10) % 1;
      const tail = Math.max(0, t - 0.16);
      ctx.strokeStyle = i % 3 === 0 ? "#c5b1ff" : "#cfff9c";
      ctx.lineWidth = w * 0.0028;
      ctx.beginPath();
      ctx.moveTo(a.x + (b.x - a.x) * tail, a.y + (b.y - a.y) * tail);
      ctx.lineTo(a.x + (b.x - a.x) * t, a.y + (b.y - a.y) * t);
      ctx.stroke();
    }
    for (const n of projected) {
      const firing = Math.pow(
        Math.max(0, Math.sin(time * 3.4 - n.layer * 0.8 + n.phase * 6.28)),
        10,
      );
      const radius = w * (0.0025 + firing * 0.0035);
      if (firing > 0.25) {
        const glow = ctx.createRadialGradient(
          n.x,
          n.y,
          0,
          n.x,
          n.y,
          radius * 5,
        );
        glow.addColorStop(0, `rgba(190,255,137,${firing * 0.5})`);
        glow.addColorStop(1, "rgba(190,255,137,0)");
        ctx.fillStyle = glow;
        ctx.fillRect(
          n.x - radius * 5,
          n.y - radius * 5,
          radius * 10,
          radius * 10,
        );
      }
      ctx.fillStyle = `rgba(210,255,184,${0.45 + firing * 0.55})`;
      ctx.beginPath();
      ctx.arc(n.x, n.y, radius, 0, Math.PI * 2);
      ctx.fill();
    }
    ctx.restore();
    // Signals continue from the silicon out along component-level traces.
    const traceAlpha = smooth(0.2, 0.42, p) * 0.65;
    if (traceAlpha > 0) {
      ctx.save();
      ctx.globalAlpha = traceAlpha;
      ctx.strokeStyle = "#c7f88d";
      ctx.lineWidth = boardWidth * 0.00065;
      for (let side = 0; side < 4; side++)
        for (let i = 0; i < 5; i++) {
          const f = (i + 1) / 6;
          const cx = x + w * f,
            cy = y + h * f;
          const path =
            side === 0
              ? [
                  [x, cy],
                  [x - w * 0.35, cy],
                  [x - w * 0.6, cy - h * 0.16],
                  [x - w * 1.5, cy - h * 0.16],
                ]
              : side === 1
                ? [
                    [x + w, cy],
                    [x + w * 1.35, cy],
                    [x + w * 1.6, cy + h * 0.16],
                    [x + w * 2.5, cy + h * 0.16],
                  ]
                : side === 2
                  ? [
                      [cx, y],
                      [cx, y - h * 0.32],
                      [cx - w * 0.16, y - h * 0.55],
                      [cx - w * 0.16, y - h * 1.1],
                    ]
                  : [
                      [cx, y + h],
                      [cx, y + h * 1.32],
                      [cx + w * 0.16, y + h * 1.55],
                      [cx + w * 0.16, y + h * 2.1],
                    ];
          ctx.beginPath();
          path.forEach((v, j) => (j ? ctx.lineTo(...v) : ctx.moveTo(...v)));
          ctx.stroke();
          const t = ((time * 0.38 + i * 0.17 + side * 0.11) % 1) * 3,
            segment = Math.floor(t),
            fraction = t - segment;
          const a = path[segment],
            b = path[segment + 1];
          ctx.fillStyle = "#e4ffb6";
          ctx.beginPath();
          ctx.arc(
            a[0] + (b[0] - a[0]) * fraction,
            a[1] + (b[1] - a[1]) * fraction,
            boardWidth * 0.002,
            0,
            Math.PI * 2,
          );
          ctx.fill();
        }
      ctx.restore();
    }
    ctx.restore();
  }
  // Never keep rendering a hidden tab or an offscreen universe.
  new IntersectionObserver((entries) => {
    visible = entries[0].isIntersecting;
    if (visible) requestFrame();
    else if (frame) {
      cancelAnimationFrame(frame);
      frame = 0;
    }
  }).observe(journey);
  document.addEventListener("visibilitychange", () => {
    if (document.hidden && frame) {
      cancelAnimationFrame(frame);
      frame = 0;
    } else requestFrame();
  });
  const revealObserver = new IntersectionObserver(
    (entries) => {
      entries.forEach((entry) => {
        if (entry.isIntersecting) {
          entry.target.classList.add("visible");
          revealObserver.unobserve(entry.target);
        }
      });
    },
    { threshold: 0.08 },
  );
  $$(".reveal").forEach((element) => revealObserver.observe(element));
  document.documentElement.classList.add("js");
  function selectShot(name) {
    $$("[data-shot-image]").forEach((image) =>
      image.classList.toggle("active", image.dataset.shotImage === name),
    );
    $$("[data-select-shot]").forEach((button) =>
      button.setAttribute(
        "aria-pressed",
        String(button.dataset.selectShot === name),
      ),
    );
    $(".shot-stack").scrollTop = 0;
  }
  const storyObserver = new IntersectionObserver(
    (entries) => {
      if (matchMedia("(max-width: 700px)").matches) return;
      entries
        .filter((entry) => entry.isIntersecting)
        .forEach((entry) => selectShot(entry.target.dataset.shot));
    },
    { rootMargin: "-20% 0px -40% 0px", threshold: 0 },
  );
  $$(".story-step").forEach((step) => storyObserver.observe(step));
  $$("[data-select-shot]").forEach((button) =>
    button.addEventListener("click", () =>
      selectShot(button.dataset.selectShot),
    ),
  );
  Promise.all([
    photo.decode(),
    backdrop.decode(),
    board.decode(),
    appImage.decode(),
  ])
    .then(() => {
      sceneReady = true;
      resize();
    })
    .catch(() => {
      // Keep the complete universe opening if the photographic asset cannot load.
      journey.style.height = "100svh";
      world.style.opacity = "1";
    });
  resize();
  applyMotion();
})();
