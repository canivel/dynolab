import { createOfficeProps } from "./office-props.js";
import { createNeuralField } from "./neural-field.js";
import * as THREE from "./vendor/three/three.module.js";
import { cameraPose, ease, clamp } from "./camera-path.mjs";
const $ = (s) => document.querySelector(s),
  $$ = (s) => [...document.querySelectorAll(s)];
const stage = $(".universe-stage"),
  journey = $(".journey"),
  canvas = $("#camera-scene");
const pref = matchMedia("(prefers-reduced-motion: reduce)");
let explicit = null;
try {
  explicit = localStorage.getItem("dyno-motion");
} catch {}
let reduced = explicit ? explicit === "paused" : pref.matches;
let renderer,
  scene,
  camera,
  keyboardMaterial,
  shellMaterial,
  neuralField,
  dieMaterial;
let frame = 0,
  progress = 0,
  targetProgress = 0,
  last = 0,
  time = 0,
  visible = true,
  ready = false;
const staticTransforms = [];
function requestFrame() {
  if (!frame && !document.hidden && visible)
    frame = requestAnimationFrame(draw);
}
function resize() {
  if (!renderer) return;
  const w = stage.clientWidth,
    h = stage.clientHeight;
  renderer.setSize(w, h, false);
  camera.aspect = w / h;
  camera.updateProjectionMatrix();
  scroll();
}
function scroll() {
  const r = journey.getBoundingClientRect();
  targetProgress = reduced
    ? 1
    : clamp(-r.top / Math.max(1, r.height - stage.clientHeight));
  requestFrame();
}
function applyMotion() {
  document.body.classList.toggle("reduced", reduced);
  $("#motion-toggle").textContent = reduced
    ? "Enable motion ▷"
    : "Pause motion Ⅱ";
  $("#motion-toggle").setAttribute("aria-pressed", String(reduced));
  if (reduced) progress = 1;
  scroll();
}
$("#motion-toggle").addEventListener("click", () => {
  reduced = !reduced;
  explicit = reduced ? "paused" : "enabled";
  try {
    localStorage.setItem("dyno-motion", explicit);
  } catch {}
  applyMotion();
});
pref.addEventListener("change", () => {
  if (!explicit) {
    reduced = pref.matches;
    applyMotion();
  }
});
window.addEventListener("scroll", scroll, { passive: true });
window.addEventListener("resize", resize, { passive: true });
new IntersectionObserver(([entry]) => {
  visible = entry.isIntersecting;
  if (visible) requestFrame();
  else {
    cancelAnimationFrame(frame);
    frame = 0;
  }
}).observe(journey);
document.addEventListener("visibilitychange", () => {
  if (document.hidden) {
    cancelAnimationFrame(frame);
    frame = 0;
  } else requestFrame();
});
function crop(texture, x, y, w, h) {
  const t = texture.clone();
  t.offset.set(x, 1 - y - h);
  t.repeat.set(w, h);
  t.needsUpdate = true;
  return t;
}
function mesh(geometry, material, name, position, rotation) {
  const m = new THREE.Mesh(geometry, material);
  m.name = name;
  if (position) m.position.set(...position);
  if (rotation) m.rotation.set(...rotation);
  m.castShadow = true;
  m.receiveShadow = true;
  scene.add(m);
  return m;
}
const basic = (map) => new THREE.MeshBasicMaterial({ map, toneMapped: false });
async function init() {
  renderer = new THREE.WebGLRenderer({
    canvas,
    antialias: true,
    alpha: false,
    powerPreference: "high-performance",
  });
  renderer.setPixelRatio(Math.min(devicePixelRatio, 2));
  renderer.outputColorSpace = THREE.SRGBColorSpace;
  renderer.shadowMap.enabled = true;
  renderer.shadowMap.type = THREE.PCFSoftShadowMap;
  scene = new THREE.Scene();
  scene.background = new THREE.Color("#171b16");
  camera = new THREE.PerspectiveCamera(45, 1, 0.02, 50);
  const loader = new THREE.TextureLoader();
  const [overhead, room, board, app] = await Promise.all(
    [
      "assets/office-overhead.jpg",
      "assets/office-background.jpg",
      "assets/silicon-board.jpg",
      "screenshots/window-run-dark.png",
    ].map((p) => loader.loadAsync(p)),
  );
  for (const t of [overhead, room, board, app]) {
    t.colorSpace = THREE.SRGBColorSpace;
    t.anisotropy = Math.min(8, renderer.capabilities.getMaxAnisotropy());
  }
  scene.add(new THREE.HemisphereLight(0xeaf6d4, 0x46372c, 2.1));
  const key = new THREE.DirectionalLight(0xffdfad, 1.5);
  key.position.set(-4, 7, 3);
  key.castShadow = true;
  key.shadow.mapSize.set(2048, 2048);
  key.shadow.camera.left = -6;
  key.shadow.camera.right = 6;
  key.shadow.camera.top = 6;
  key.shadow.camera.bottom = -6;
  key.shadow.bias = -0.0004;
  key.shadow.radius = 4;
  scene.add(key);
  const fill = new THREE.DirectionalLight(0xb9cfcd, 0.6);
  fill.position.set(3, 4, -1);
  scene.add(fill);
  const wood = crop(overhead, 0.015, 0.77, 0.22, 0.21);
  mesh(
    new THREE.BoxGeometry(12, 0.24, 8),
    new THREE.MeshStandardMaterial({
      map: wood,
      color: 0x967258,
      roughness: 0.7,
    }),
    "desk",
    [0, -0.14, 0],
  );
  // A real upright wall behind the desk: its transform never changes.
  const wall = mesh(
    new THREE.PlaneGeometry(15, 6),
    basic(crop(room, 0, 0, 1, 0.59)),
    "room-wall",
    [0, 3, -4],
  );
  wall.castShadow = false;
  const metal = new THREE.MeshStandardMaterial({
    color: 0x333539,
    roughness: 0.37,
    metalness: 0.7,
  });
  shellMaterial = metal.clone();
  shellMaterial.transparent = true;
  shellMaterial.depthWrite = false;
  const body = mesh(
    new THREE.BoxGeometry(3.4, 0.085, 2.27),
    shellMaterial,
    "mac-base",
    [0, 0.0525, 0],
  );
  keyboardMaterial = basic(crop(overhead, 0.272, 0.247, 0.456, 0.454));
  keyboardMaterial.transparent = true;
  keyboardMaterial.depthWrite = false;
  mesh(
    new THREE.PlaneGeometry(3.4, 2.27),
    keyboardMaterial,
    "keyboard",
    [0, 0.097, 0],
    [-Math.PI / 2, 0, 0],
  );
  // Silicon stays inside the physical base. This is an illustrative cutaway.
  const circuit = mesh(
    new THREE.PlaneGeometry(2.8, 1.6),
    basic(board),
    "circuit-board",
    [0, 0.063, -0.35],
    [-Math.PI / 2, 0, 0],
  );
  circuit.castShadow = false;
  dieMaterial = new THREE.MeshBasicMaterial({
    color: 0x050e0a,
    transparent: true,
    depthWrite: false,
  });
  mesh(
    new THREE.PlaneGeometry(0.65, 0.59),
    dieMaterial,
    "die-interior",
    [0, 0.065, -0.39],
    [-Math.PI / 2, 0, 0],
  );
  const lid = new THREE.Group();
  lid.name = "mac-display-hinge";
  lid.position.set(0, 0.1, -1.075);
  lid.rotation.x = -0.11;
  scene.add(lid);
  const panel = new THREE.Mesh(new THREE.BoxGeometry(3.38, 2.15, 0.055), metal);
  panel.name = "display-frame";
  panel.position.y = 1.075;
  panel.castShadow = true;
  lid.add(panel);
  const display = new THREE.Mesh(
    new THREE.PlaneGeometry(3.25, 2.015),
    basic(app),
  );
  display.name = "app-screen";
  display.position.set(0, 1.075, 0.03);
  lid.add(display);
  const notch = new THREE.Mesh(
    new THREE.BoxGeometry(0.27, 0.058, 0.009),
    new THREE.MeshBasicMaterial({ color: 0x060809 }),
  );
  notch.position.set(0, 2.1, 0.038);
  notch.name = "display-notch";
  lid.add(notch);
  scene.add(createOfficeProps(THREE));
  neuralField = createNeuralField(THREE);
  scene.add(neuralField.group);
  canvas.dataset.neurons = neuralField.nodeCount;
  canvas.dataset.synapses = neuralField.edgeCount;
  // Critical invariant: freeze all world transforms once construction is done.
  scene.traverse((o) => {
    if (o !== scene) {
      o.updateMatrix();
      o.matrixAutoUpdate = false;
      staticTransforms.push([o, o.matrix.elements.slice()]);
    }
  });
  ready = true;
  stage.classList.add("scene-ready");
  resize();
  applyMotion();
}
function draw(now) {
  frame = 0;
  const dt = Math.min((now - last) / 1000 || 1 / 60, 0.05);
  last = now;
  if (!ready) return;
  if (!reduced) time += dt;
  progress = reduced
    ? 1
    : progress + (targetProgress - progress) * (1 - Math.exp(-dt * 7));
  if (Math.abs(targetProgress - progress) < 0.00001) progress = targetProgress;
  const pose = cameraPose(progress, camera.aspect);
  camera.position.set(...pose.position);
  camera.up.set(...pose.up);
  camera.lookAt(...pose.target);
  keyboardMaterial.opacity = pose.keyboard;
  shellMaterial.opacity = pose.keyboard; // cutaway only
  dieMaterial.opacity = 0.96 * (1 - ease(0.18, 0.42, progress));
  neuralField.update(time, 1 - pose.keyboard);
  const opacity = [
    reduced ? 1 : 1 - ease(0.06, 0.2, progress),
    reduced ? 0 : ease(0.88, 0.98, progress),
  ];
  $$(".stage-copy").forEach((e, i) => {
    e.style.opacity = opacity[i];
    e.style.visibility = opacity[i] < 0.01 ? "hidden" : "visible";
    e.inert = opacity[i] < 0.1;
    if (i) e.setAttribute("aria-hidden", String(opacity[i] < 0.1));
    e.style.transform = "none";
  });
  $(".scene-label").textContent = [
    "01 / INSIDE THE GPU CORE",
    "02 / SILICON & BOARD",
    "03 / THROUGH THE KEYBOARD",
    "04 / ABOVE THE DESK",
    "05 / CAMERA AT THE FRONT",
  ][pose.chapter];
  $(".journey-progress b").style.width = `${progress * 100}%`;
  // Expose only review diagnostics in the DOM. A changed world transform is a failure.
  const unchanged = staticTransforms.every(([o, m]) =>
    o.matrix.elements.every((v, i) => v === m[i]),
  );
  canvas.dataset.worldTransforms = unchanged ? "fixed" : "CHANGED";
  canvas.dataset.cameraPosition = pose.position
    .map((n) => n.toFixed(3))
    .join(",");
  canvas.dataset.progress = progress.toFixed(4);
  renderer.render(scene, camera);
  if (!reduced && (progress < 0.68 || progress !== targetProgress))
    requestFrame();
}
init().catch((error) => {
  console.error("3D scene unavailable; using static fallback", error);
  canvas.style.display = "none";
  document.body.classList.add("reduced");
  $("#motion-toggle").hidden = true;
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
  button.addEventListener("click", () => selectShot(button.dataset.selectShot)),
);
