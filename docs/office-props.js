// Fixed desk props: modeled surfaces remain grounded throughout the camera move.
export function createOfficeProps(T) {
  const group = new T.Group();
  group.name = "office-props";
  const material = (color, roughness = 0.7, extra = {}) =>
    new T.MeshStandardMaterial({ color, roughness, ...extra });
  function add(parent, geometry, mat, name, position = [0, 0, 0]) {
    const object = new T.Mesh(geometry, mat);
    object.name = name;
    object.position.set(...position);
    object.castShadow = object.receiveShadow = true;
    parent.add(object);
    return object;
  }
  function tube(parent, points, radius, mat, name) {
    return add(
      parent,
      new T.TubeGeometry(new T.CatmullRomCurve3(points), 16, radius, 6, false),
      mat,
      name,
    );
  }
  // A rounded ceramic vessel with an actual open rim, soil and saucer.
  const plant = new T.Group();
  plant.name = "plant";
  plant.position.set(-2.6, -0.018, -0.4);
  group.add(plant);
  // Fine surface grain catches light without adding a photographic billboard.
  function grainTexture() {
    const canvas = document.createElement("canvas");
    canvas.width = canvas.height = 128;
    const ctx = canvas.getContext("2d");
    const pixels = ctx.createImageData(128, 128);
    let seed = 419;
    for (let i = 0; i < pixels.data.length; i += 4) {
      seed = (Math.imul(seed, 1664525) + 1013904223) >>> 0;
      const value = 110 + (seed % 36);
      pixels.data.set([value, value, value, 255], i);
    }
    ctx.putImageData(pixels, 0, 0);
    const texture = new T.CanvasTexture(canvas);
    texture.wrapS = texture.wrapT = T.RepeatWrapping;
    texture.repeat.set(5, 5);
    return texture;
  }
  const grain = grainTexture();
  const ceramic = material(0xd2c4ac, 0.87, {
    bumpMap: grain,
    bumpScale: 0.002,
  });
  const profile = [
    [0, 0.018],
    [0.18, 0.018],
    [0.206, 0.028],
    [0.218, 0.065],
    [0.257, 0.35],
    [0.258, 0.39],
    [0.248, 0.407],
    [0.23, 0.407],
    [0.225, 0.39],
    [0.222, 0.355],
  ];
  add(
    plant,
    new T.LatheGeometry(
      profile.map(([x, y]) => new T.Vector2(x, y)),
      64,
    ),
    ceramic,
    "ceramic-pot",
  );
  add(
    plant,
    new T.CylinderGeometry(0.235, 0.22, 0.024, 64),
    ceramic,
    "ceramic-saucer",
    [0, 0.012, 0],
  );
  add(
    plant,
    new T.CylinderGeometry(0.222, 0.222, 0.018, 48),
    material(0x30231a, 1),
    "potting-soil",
    [0, 0.357, 0],
  );
  const soilChip = material(0x786149, 1);
  for (let i = 0; i < 30; i++) {
    const angle = i * 2.39996,
      radius = 0.19 * Math.sqrt((i + 0.5) / 30);
    const stone = add(
      plant,
      new T.IcosahedronGeometry(0.009 + (i % 3) * 0.002, 0),
      soilChip,
      "soil-grain-" + i,
      [Math.cos(angle) * radius, 0.37, Math.sin(angle) * radius],
    );
    stone.scale.y = 0.45;
  }
  const stemMat = material(0x3a5931, 0.8);
  const veinMat = material(0x70864c, 0.74);
  // Curved, tapered leaf blades, folded gently along the central rib.
  const leafMats = [0x344c28, 0x466234, 0x526c38, 0x3f592e].map((color) =>
    material(color, 0.48, { side: T.DoubleSide }),
  );
  for (let i = 0; i < 13; i++) {
    const angle = i * 2.39996;
    const height = 0.56 + (i % 5) * 0.09;
    const root = new T.Vector3(
      Math.cos(angle) * 0.035,
      0.365,
      Math.sin(angle) * 0.035,
    );
    const base = new T.Vector3(
      Math.cos(angle) * 0.1,
      height,
      Math.sin(angle) * 0.1,
    );
    tube(
      plant,
      [root, new T.Vector3(base.x * 0.35, height * 0.8, base.z * 0.35), base],
      0.006,
      stemMat,
      "petiole-" + i,
    );
    const length = 0.28 + (i % 4) * 0.038,
      width = 0.1 + (i % 3) * 0.012;
    const direction = new T.Vector3(Math.cos(angle), 0, Math.sin(angle));
    const side = new T.Vector3(-Math.sin(angle), 0, Math.cos(angle));
    const center = (t) =>
      base
        .clone()
        .addScaledVector(direction, length * t)
        .add(
          new T.Vector3(0, 0.17 * Math.sin(t * Math.PI * 0.9) - 0.1 * t * t, 0),
        );
    const vertices = [],
      uvs = [],
      indices = [];
    const rows = 18,
      cols = 8;
    for (let row = 0; row <= rows; row++) {
      const t = row / rows;
      const half = width * Math.pow(Math.sin(Math.PI * t), 0.8);
      for (let col = 0; col <= cols; col++) {
        const s = (col / cols) * 2 - 1;
        const point = center(t).addScaledVector(side, s * half);
        point.y -= Math.abs(s) * half * 0.28;
        point.y += Math.sin(t * 20 + i) * 0.003 * s * s;
        vertices.push(point.x, point.y, point.z);
        uvs.push(col / cols, t);
        if (row < rows && col < cols) {
          const a = row * (cols + 1) + col,
            b = a + cols + 1;
          indices.push(a, b, a + 1, b, b + 1, a + 1);
        }
      }
    }
    const geometry = new T.BufferGeometry();
    geometry.setAttribute(
      "position",
      new T.Float32BufferAttribute(vertices, 3),
    );
    geometry.setAttribute("uv", new T.Float32BufferAttribute(uvs, 2));
    geometry.setIndex(indices);
    geometry.computeVertexNormals();
    add(plant, geometry, leafMats[i % 4], "leaf-blade-" + i);
    tube(
      plant,
      [center(0), center(0.3), center(0.65), center(0.97)],
      0.0018,
      veinMat,
      "leaf-midrib-" + i,
    );
    for (let j = 1; j <= 5; j++) {
      const t = j / 7;
      for (const sign of [-1, 1]) {
        const endT = t + 0.095;
        const end = center(endT).addScaledVector(
          side,
          sign * width * Math.pow(Math.sin(Math.PI * endT), 0.8) * 0.85,
        );
        end.y -= width * 0.2;
        tube(
          plant,
          [center(t), center(t + 0.05).lerp(end, 0.5), end],
          0.00065,
          veinMat,
          "leaf-vein-" + i + "-" + j + "-" + sign,
        );
      }
    }
  }
  // Clothbound notebook: rounded covers, ivory page block and elastic closure.
  const book = new T.Group();
  book.name = "notebook";
  book.position.set(2.75, -0.017, 0.7);
  book.rotation.y = -0.25;
  group.add(book);
  function roundedSlab(w, h, depth, r) {
    const shape = new T.Shape(),
      x = -w / 2,
      y = -h / 2;
    shape.moveTo(x + r, y);
    shape.lineTo(x + w - r, y);
    shape.quadraticCurveTo(x + w, y, x + w, y + r);
    shape.lineTo(x + w, y + h - r);
    shape.quadraticCurveTo(x + w, y + h, x + w - r, y + h);
    shape.lineTo(x + r, y + h);
    shape.quadraticCurveTo(x, y + h, x, y + h - r);
    shape.lineTo(x, y + r);
    shape.quadraticCurveTo(x, y, x + r, y);
    const geo = new T.ExtrudeGeometry(shape, {
      depth,
      bevelEnabled: true,
      bevelSegments: 2,
      steps: 1,
      bevelSize: 0.002,
      bevelThickness: 0.002,
      curveSegments: 8,
    });
    geo.rotateX(-Math.PI / 2);
    return geo;
  }
  const cloth = material(0x34423e, 0.96, { bumpMap: grain, bumpScale: 0.0015 });
  const paper = material(0xebe2ce, 0.95);
  add(
    book,
    roundedSlab(0.9, 1.15, 0.009, 0.04),
    cloth,
    "notebook-back-cover",
    [0, 0.004, 0],
  );
  add(
    book,
    roundedSlab(0.86, 1.1, 0.044, 0.025),
    paper,
    "notebook-pages",
    [0, 0.015, 0],
  );
  add(
    book,
    roundedSlab(0.9, 1.15, 0.012, 0.04),
    cloth,
    "notebook-front-cover",
    [0, 0.061, 0],
  );
  const pageLine = material(0xb9af99, 1);
  for (let i = 0; i < 9; i++) {
    add(
      book,
      new T.BoxGeometry(0.001, 0.0007, 1.035),
      pageLine,
      "page-edge-" + i,
      [0.431, 0.02 + i * 0.004, 0],
    );
    add(
      book,
      new T.BoxGeometry(0.77, 0.0007, 0.001),
      pageLine,
      "page-foot-" + i,
      [0.018, 0.02 + i * 0.004, 0.551],
    );
  }
  add(
    book,
    new T.BoxGeometry(0.027, 0.064, 1.075),
    cloth,
    "bound-spine",
    [-0.435, 0.037, 0],
  );
  const elastic = material(0x1b2420, 1);
  add(
    book,
    new T.BoxGeometry(0.025, 0.003, 1.13),
    elastic,
    "elastic-top",
    [0.31, 0.079, 0],
  );
  for (const z of [-0.564, 0.564])
    add(
      book,
      new T.BoxGeometry(0.025, 0.07, 0.005),
      elastic,
      "elastic-edge-" + z,
      [0.31, 0.043, z],
    );
  const ribbon = add(
    book,
    new T.PlaneGeometry(0.022, 0.16),
    material(0xa99766, 0.85, { side: T.DoubleSide }),
    "bookmark-ribbon",
    [-0.14, 0.02, 0.61],
  );
  ribbon.rotation.x = -Math.PI / 2;
  ribbon.rotation.z = 0.13;
  // A restrained foil line and small deboss on the cover, without fake text.
  add(
    book,
    new T.BoxGeometry(0.12, 0.001, 0.004),
    material(0x938362, 0.64, { metalness: 0.35 }),
    "cover-foil",
    [-0.22, 0.076, 0.39],
  );
  return group;
}
