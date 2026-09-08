/* A dependency-free illustration: particles, orbital connections and scroll depth.
   This is decorative animation, never a representation of measured activations. */
(() => {
  "use strict";
  const $ = (selector) => document.querySelector(selector);
  const $$ = (selector) => [...document.querySelectorAll(selector)];
  const motionPreference = matchMedia("(prefers-reduced-motion: reduce)");
  const journey = $(".journey");
  const stage = $(".universe-stage");
  const world = $(".room-world");
  const photo = $(".room-photo");
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
  const stars = Array.from({ length: 150 }, () => ({
    x: random(),
    y: random(),
    radius: random() * 1.1 + 0.15,
    phase: random() * 6.28,
  }));
  const nodes = Array.from({ length: 76 }, (_, index) => ({
    angle: index * 2.39996,
    latitude: Math.acos(1 - (2 * (index + 0.5)) / 76),
    size: 0.7 + random() * 1.4,
    phase: random() * 6.28,
  }));
  const labels = ["QWEN", "LLAMA", "GEMMA", "MISTRAL", "DEEPSEEK", "PHI"];

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
      ? stage.clientWidth * 1.5
      : Math.max(stage.clientWidth, stage.clientHeight * 1.5);
    roomHeight = roomWidth / 1.5;
    world.style.width = `${roomWidth}px`;
    width = Math.round(roomWidth * 0.465);
    height = Math.round(roomHeight * 0.441);
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
    progress = reduced
      ? 0
      : clamp(-box.top / Math.max(1, box.height - stage.clientHeight));
    const p = sceneReady ? progress : 0;
    const pullback = smooth(0.08, 0.82, p);
    const startScale =
      Math.max(stage.clientWidth / width, stage.clientHeight / height) * 1.16;
    const scale = reduced ? 1 : Math.exp(Math.log(startScale) * (1 - pullback));
    const screenCenterX = (0.265 + 0.465 / 2 - 0.5) * roomWidth;
    const screenCenterY = (0.211 + 0.441 / 2 - 0.5) * roomHeight;
    const mobileOffset =
      stage.clientWidth <= 700 ? stage.clientHeight * 0.16 : 0;
    const offsetX = -screenCenterX * scale * (1 - pullback);
    const offsetY = reduced
      ? mobileOffset
      : -screenCenterY * scale * (1 - pullback) + mobileOffset * pullback;
    world.style.transform = `translate(calc(-50% + ${offsetX}px),calc(-50% + ${offsetY}px)) scale(${scale})`;
    const opacities = [
      reduced ? 1 : 1 - smooth(0.05, 0.32, p),
      reduced ? 0 : smooth(0.65, 0.85, p),
    ];
    copies.forEach((copy, index) => {
      copy.style.opacity = opacities[index];
      copy.style.visibility = opacities[index] < 0.01 ? "hidden" : "visible";
      copy.inert = opacities[index] < 0.1;
      if (index > 0)
        copy.setAttribute("aria-hidden", String(opacities[index] < 0.1));
      copy.style.transform =
        index === 0
          ? `translateY(${-p * 100}px) scale(${1 - pullback * 0.35})`
          : `translateY(${(1 - pullback) * 60}px)`;
    });
    $(".journey-progress b").style.width = `${progress * 100}%`;
    requestFrame();
  }
  window.addEventListener("scroll", updateScroll, { passive: true });
  window.addEventListener("resize", resize, { passive: true });
  stage.addEventListener(
    "pointermove",
    (event) => {
      if (reduced || event.pointerType === "touch") return;
      targetX = (event.clientX / width - 0.5) * 2;
      targetY = (event.clientY / height - 0.5) * 2;
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
    if (!reduced) time += Math.min((now - lastTime) / 1000 || 0, 0.05);
    lastTime = now;
    pointerX += ((reduced ? 0 : targetX) - pointerX) * 0.055;
    pointerY += ((reduced ? 0 : targetY) - pointerY) * 0.055;
    if (context) drawUniverse();
    if (!reduced) requestFrame();
  }
  function drawUniverse() {
    const ctx = context;
    ctx.clearRect(0, 0, width, height);
    const fade = 1;
    stars.forEach((star) => {
      const twinkle = 0.2 + (Math.sin(time * 0.6 + star.phase) + 1) * 0.22;
      ctx.fillStyle = `rgba(218,233,203,${twinkle * fade})`;
      ctx.beginPath();
      ctx.arc(
        (star.x * width + pointerX * star.radius * 6 + width) % width,
        (star.y * height - progress * (80 + star.radius * 80) + height) %
          height,
        star.radius,
        0,
        Math.PI * 2,
      );
      ctx.fill();
    });
    const centerX = width * 0.64 + pointerX * 12;
    const centerY = height * (0.54 + progress * 0.13) + pointerY * 10;
    const baseRadius = Math.min(width * 0.47, height * 0.6);
    const collapse = smooth(0.2, 0.62, progress);
    const radius =
      baseRadius * (1 - collapse * 0.58 + smooth(0.7, 1, progress) * 0.25);
    const rotation = time * 0.025 + progress * 2;
    // Inclined orbital paths give depth even when motion is paused.
    for (let ring = 0; ring < 3; ring++) {
      ctx.save();
      ctx.translate(centerX, centerY);
      ctx.rotate(-0.3 + ring * 0.38 + progress * 0.5);
      ctx.strokeStyle =
        ring === 1
          ? `rgba(182,156,231,${0.12 * fade})`
          : `rgba(186,225,142,${0.1 * fade})`;
      ctx.lineWidth = 0.65;
      ctx.beginPath();
      ctx.ellipse(
        0,
        0,
        radius * (1 + ring * 0.16),
        radius * (0.38 + ring * 0.08),
        0,
        0,
        Math.PI * 2,
      );
      ctx.stroke();
      const phase = time * (0.08 + ring * 0.025) + ring * 2;
      ctx.fillStyle = ring === 1 ? "#c8b3ff" : "#d0ff98";
      ctx.shadowColor = ctx.fillStyle;
      ctx.shadowBlur = 12;
      ctx.beginPath();
      ctx.arc(
        Math.cos(phase) * radius * (1 + ring * 0.16),
        Math.sin(phase) * radius * (0.38 + ring * 0.08),
        2,
        0,
        Math.PI * 2,
      );
      ctx.fill();
      ctx.restore();
    }
    const projected = nodes.map((node) => {
      const angle = node.angle + rotation;
      const x = Math.sin(node.latitude) * Math.cos(angle);
      const z = Math.sin(node.latitude) * Math.sin(angle);
      const y = Math.cos(node.latitude);
      const depth = 1 / (1.55 - z * 0.45);
      return {
        x: centerX + x * radius * depth * 1.45,
        y: centerY + y * radius * depth * 0.93,
        alpha: (0.15 + (z + 1) * 0.19) * fade,
        z,
        size: node.size * depth,
        phase: node.phase,
      };
    });
    const reach = radius * 0.43;
    projected.forEach((node, i) => {
      for (let j = i + 1; j < projected.length; j++) {
        const other = projected[j];
        const distance = Math.hypot(node.x - other.x, node.y - other.y);
        if (distance > reach || Math.abs(node.z - other.z) > 0.65) continue;
        const alpha = (1 - distance / reach) * 0.2 * fade;
        ctx.strokeStyle = `rgba(188,227,150,${alpha})`;
        ctx.lineWidth = 0.55;
        ctx.beginPath();
        ctx.moveTo(node.x, node.y);
        ctx.lineTo(other.x, other.y);
        ctx.stroke();
        if ((i + j) % 11 === 0) {
          const t = (time * 0.26 + node.phase) % 1;
          ctx.fillStyle = `rgba(209,255,161,${0.65 * fade})`;
          ctx.beginPath();
          ctx.arc(
            node.x + (other.x - node.x) * t,
            node.y + (other.y - node.y) * t,
            1.2,
            0,
            Math.PI * 2,
          );
          ctx.fill();
        }
      }
      ctx.fillStyle = `rgba(206,245,169,${node.alpha})`;
      ctx.beginPath();
      ctx.arc(node.x, node.y, node.size, 0, Math.PI * 2);
      ctx.fill();
      if (i % 13 === 0 && width > 550) {
        ctx.font = "9px ui-monospace, monospace";
        ctx.fillStyle = `rgba(167,190,144,${node.alpha * 0.9})`;
        ctx.fillText(
          labels[Math.floor(i / 13) % labels.length],
          node.x + 9,
          node.y - 7,
        );
      }
    });
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
  photo
    .decode()
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
