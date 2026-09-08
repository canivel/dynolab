// A conceptual neural activation field. Positions stay fixed; light propagates
// along branching axons and arrives at each soma on the same wave schedule.
export function createNeuralField(T) {
  const group = new T.Group();
  group.name = "neural-field";
  let seed = 84721;
  const random = () => {
    seed = (seed * 1664525 + 1013904223) >>> 0;
    return seed / 4294967296;
  };
  const nodes = [];
  for (let column = 0; column < 9; column++)
    for (let row = 0; row < 8; row++) {
      const x = (column / 8 - 0.5) * 0.6 + (random() - 0.5) * 0.044;
      const z = -0.39 + (row / 7 - 0.5) * 0.55 + (random() - 0.5) * 0.045;
      nodes.push({
        p: new T.Vector3(x, 0.077 + random() * 0.025, z),
        phase: (x + 0.34) * 3.7,
        size: 0.75 + random() * 0.5,
      });
    }
  const uniforms = { time: { value: 0 }, alpha: { value: 1 } };
  const positions = [],
    phases = [],
    sizes = [];
  for (const n of nodes) {
    positions.push(...n.p);
    phases.push(n.phase);
    sizes.push(n.size);
  }
  const geometry = new T.BufferGeometry();
  geometry.setAttribute("position", new T.Float32BufferAttribute(positions, 3));
  geometry.setAttribute("phase", new T.Float32BufferAttribute(phases, 1));
  geometry.setAttribute("size", new T.Float32BufferAttribute(sizes, 1));
  const somaMaterial = new T.ShaderMaterial({
    uniforms,
    transparent: true,
    depthWrite: false,
    blending: T.AdditiveBlending,
    vertexShader: `attribute float phase; attribute float size; uniform float time; varying float firing; varying float afterglow;
      void main(){float age=mod(time-phase+8.,4.);firing=exp(-age*10.);afterglow=exp(-age*2.8);
      vec4 p=modelViewMatrix*vec4(position,1.);gl_Position=projectionMatrix*p;
      gl_PointSize=clamp(size*(12.+firing*15.+afterglow*8.)/-p.z,3.,115.);}`,
    fragmentShader: `uniform float alpha; varying float firing; varying float afterglow;
      void main(){vec2 p=gl_PointCoord-.5;float r=length(p)*2.;
      float core=exp(-r*r*140.);float body=exp(-r*r*29.);float halo=exp(-r*r*5.)*pow(max(0.,1.-r),2.);
      float intensity=core*(.7+firing*1.8)+body*(.22+afterglow*.6)+halo*(.06+firing*.8);
      vec3 color=mix(vec3(.23,.61,.48),vec3(.87,1.,.62),min(1.,firing+core));
      gl_FragColor=vec4(color,intensity*alpha);}`,
  });
  const somas = new T.Points(geometry, somaMaterial);
  somas.name = "firing-neuron-somas";
  group.add(somas);
  const vertices = [],
    normals = [],
    uvs = [],
    starts = [],
    durations = [],
    hues = [],
    indices = [];
  function tube(curve, radius, start, duration, hue, segments = 14) {
    const g = new T.TubeGeometry(curve, segments, radius, 4, false),
      base = vertices.length / 3;
    vertices.push(...g.attributes.position.array);
    normals.push(...g.attributes.normal.array);
    uvs.push(...g.attributes.uv.array);
    for (let i = 0; i < g.attributes.position.count; i++) {
      starts.push(start);
      durations.push(duration);
      hues.push(hue);
    }
    for (const i of g.index.array) indices.push(i + base);
    g.dispose();
  }
  // Irregular nearby connections replace the previous straight lattice.
  let edges = 0;
  for (const a of nodes) {
    const targets = nodes
      .filter((b) => b.p.x > a.p.x + 0.014 && b.p.distanceTo(a.p) < 0.145)
      .sort((b, c) => a.p.distanceTo(b.p) - a.p.distanceTo(c.p))
      .slice(0, 3);
    for (const b of targets) {
      const delta = b.p.clone().sub(a.p),
        bend = (random() - 0.5) * 0.035;
      const c1 = a.p.clone().addScaledVector(delta, 0.32);
      c1.z += bend;
      c1.y += 0.004;
      const c2 = a.p.clone().addScaledVector(delta, 0.72);
      c2.z -= bend * 0.6;
      tube(
        new T.CubicBezierCurve3(a.p, c1, c2, b.p),
        0.00038,
        a.phase,
        b.phase - a.phase,
        random(),
      );
      edges++;
    }
    // Fine dendritic branches radiate from the soma, with forked tips.
    for (let j = 0; j < 5; j++) {
      const angle = (j * Math.PI * 2) / 5 + random() * 0.8,
        length = 0.009 + random() * 0.018;
      const end = a.p
        .clone()
        .add(
          new T.Vector3(
            Math.cos(angle) * length,
            (random() - 0.5) * 0.007,
            Math.sin(angle) * length,
          ),
        );
      const mid = a.p.clone().lerp(end, 0.57);
      mid.z += (random() - 0.5) * 0.01;
      tube(
        new T.QuadraticBezierCurve3(a.p, mid, end),
        0.0002,
        a.phase,
        0.22,
        0.2,
        7,
      );
      for (const side of [-1, 1]) {
        const tip = end
          .clone()
          .add(
            new T.Vector3(
              Math.cos(angle + side * 0.65) * length * 0.38,
              0.002,
              Math.sin(angle + side * 0.65) * length * 0.38,
            ),
          );
        tube(new T.LineCurve3(end, tip), 0.00011, a.phase + 0.18, 0.14, 0.2, 2);
      }
    }
  }
  const axonGeometry = new T.BufferGeometry();
  for (const [name, array, size] of [
    ["position", vertices, 3],
    ["normal", normals, 3],
    ["uv", uvs, 2],
    ["start", starts, 1],
    ["duration", durations, 1],
    ["hue", hues, 1],
  ])
    axonGeometry.setAttribute(name, new T.Float32BufferAttribute(array, size));
  axonGeometry.setIndex(indices);
  const axonMaterial = new T.ShaderMaterial({
    uniforms,
    transparent: true,
    depthWrite: false,
    blending: T.AdditiveBlending,
    vertexShader: `attribute float start;attribute float duration;attribute float hue;varying float route;varying float launch;varying float travel;varying float tint;
      void main(){route=uv.x;launch=start;travel=duration;tint=hue;gl_Position=projectionMatrix*modelViewMatrix*vec4(position,1.);}`,
    fragmentShader: `uniform float time;uniform float alpha;varying float route;varying float launch;varying float travel;varying float tint;
      void main(){float age=mod(time-launch+8.,4.);float head=age/max(.04,travel);float gap=head-route;
      float pulse=exp(-pow(gap*28.,2.));float trail=exp(-max(0.,gap)*13.)*step(0.,gap)*step(head,1.25);
      float light=.09+pulse*.95+trail*.34;vec3 color=mix(vec3(.26,.65,.46),vec3(.71,.60,.98),step(.86,tint));
      color=mix(color,vec3(.88,1.,.67),pulse*.8);gl_FragColor=vec4(color,light*alpha);}`,
  });
  const axons = new T.Mesh(axonGeometry, axonMaterial);
  axons.name = "branching-axons-and-dendrites";
  group.add(axons);
  return {
    group,
    update(time, alpha) {
      uniforms.time.value = time;
      uniforms.alpha.value = alpha;
    },
    nodeCount: nodes.length,
    edgeCount: edges,
  };
}
