import assert from "node:assert/strict";
import { cameraPose } from "./camera-path.mjs";
for (const aspect of [0.462, 1.5, 2.2]) {
  let last = cameraPose(0, aspect);
  for (let i = 0; i <= 2000; i++) {
    const p = i / 2000,
      s = cameraPose(p, aspect);
    assert.ok([...s.position, ...s.target, ...s.up].every(Number.isFinite));
    const delta = s.position.map((v, j) => v - s.target[j]);
    assert.ok(
      Math.abs(delta.reduce((a, v, j) => a + v * s.up[j], 0)) < 1e-8,
      "camera up must be orthogonal to view",
    );
    assert.ok(Math.abs(Math.hypot(...s.up) - 1) < 1e-10);
    if (p <= 0.7) {
      assert.equal(s.position[0], 0);
      assert.equal(s.position[2], -0.39);
      assert.ok(
        s.distance >= last.distance - 1e-10,
        "dolly must retreat monotonically",
      );
    }
    assert.ok(
      Math.hypot(...s.position.map((v, j) => v - last.position[j])) < 0.1,
      "continuous camera path",
    );
    assert.ok(s.keyboard >= 0 && s.keyboard <= 1);
    last = s;
  }
  assert.equal(cameraPose(0, aspect).keyboard, 0);
  assert.equal(cameraPose(1, aspect).keyboard, 1);
  assert.ok(cameraPose(1, aspect).position[2] > 5);
}
console.log(
  "Camera path: finite, continuous, monotonic vertical dolly, orthogonal up, desktop/mobile passed.",
);
