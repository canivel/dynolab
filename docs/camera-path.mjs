// World geometry never moves. This is the only motion path.
export const clamp = (v) => Math.min(1, Math.max(0, v));
export function ease(a, b, p) {
  const t = clamp((p - a) / (b - a));
  return t * t * t * (t * (t * 6 - 15) + 10);
}
export function cameraPose(p, aspect = 1.5) {
  const dolly = ease(0.035, 0.69, p),
    orbit = ease(0.7, 0.98, p);
  const fit = 1 + (Math.max(1, 0.74 / aspect) - 1) * ease(0.45, 0.72, p);
  const distance =
    Math.exp(Math.log(0.31) + (Math.log(6.4) - Math.log(0.31)) * dolly) * fit;
  const angle = (orbit * Math.PI * 70) / 180;
  const target = [
    0,
    0.105 + orbit * (aspect < 0.8 ? 1.5 : 0.8),
    -0.39 + orbit * 0.3,
  ];
  return {
    position: [
      0,
      target[1] + Math.cos(angle) * distance,
      target[2] + Math.sin(angle) * distance,
    ],
    target,
    up: [0, Math.sin(angle), -Math.cos(angle)],
    angle,
    distance,
    keyboard: ease(0.44, 0.66, p),
    chapter: p < 0.2 ? 0 : p < 0.42 ? 1 : p < 0.65 ? 2 : p < 0.78 ? 3 : 4,
  };
}
