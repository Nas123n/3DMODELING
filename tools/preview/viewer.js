// Approximate Roblox renderer for scenes exported by build.luau. Good enough to judge layout,
// proportions and color; Roblox's own lighting and materials will look richer.
//   viewer.html?scene=zone-Meadow&view=iso|low|top|front   (drag to orbit when opened by hand)

import * as THREE from "three";
import { OrbitControls } from "three/addons/controls/OrbitControls.js";

const params = new URLSearchParams(location.search);
const sceneName = params.get("scene") ?? "zone-Meadow";
const view = params.get("view") ?? "iso";
document.getElementById("label").textContent = `${sceneName} · ${view}`;

const renderer = new THREE.WebGLRenderer({ antialias: true, preserveDrawingBuffer: true });
renderer.setPixelRatio(1);
renderer.setSize(innerWidth, innerHeight);
renderer.shadowMap.enabled = true;
renderer.shadowMap.type = THREE.PCFSoftShadowMap;
renderer.outputColorSpace = THREE.SRGBColorSpace;
document.body.appendChild(renderer.domElement);

const scene = new THREE.Scene();
scene.background = new THREE.Color(0xa9d8ff);

const data = await (await fetch(`./out/${sceneName}.json`)).json();
// Lune encodes an empty Luau table as {}, not [].
for (const key of ["parts", "lights", "fires", "texts"]) {
  if (!Array.isArray(data[key])) data[key] = [];
}
const [cx, cy, cz] = data.center;
const span = data.span;

// Sun and sky, roughly Roblox's default daytime lighting.
scene.add(new THREE.HemisphereLight(0xe8f4ff, 0x8a8170, 1.6));
const sun = new THREE.DirectionalLight(0xfff4e0, 2.4);
sun.position.set(cx - span * 0.6, cy + span * 1.1, cz - span * 0.35);
sun.target.position.set(cx, cy, cz);
sun.castShadow = true;
sun.shadow.mapSize.set(4096, 4096);
sun.shadow.bias = -0.0005;
sun.shadow.normalBias = 0.05;
Object.assign(sun.shadow.camera, { left: -span, right: span, top: span, bottom: -span, near: 1, far: span * 4 });
scene.add(sun, sun.target);

const geometries = {
  Block: new THREE.BoxGeometry(1, 1, 1),
  Ball: new THREE.SphereGeometry(0.5, 28, 18),
  Ellipsoid: new THREE.SphereGeometry(0.5, 28, 18),
  // Roblox cylinders run along X.
  Cylinder: new THREE.CylinderGeometry(0.5, 0.5, 1, 28).rotateZ(Math.PI / 2),
};

function materialFor(part) {
  const color = new THREE.Color().setRGB(...part.color, THREE.SRGBColorSpace);
  const opacity = 1 - part.transparency;
  const transparent = opacity < 1;
  switch (part.material) {
    case "Neon":
      return new THREE.MeshBasicMaterial({ color: color.clone().multiplyScalar(1.35), transparent, opacity });
    case "Glass":
      return new THREE.MeshStandardMaterial({ color, roughness: 0.05, metalness: 0.1, transparent: true, opacity: Math.min(opacity, 0.7) });
    case "Ice":
      return new THREE.MeshStandardMaterial({ color, roughness: 0.25, transparent: true, opacity: Math.min(opacity, 0.85) });
    case "Metal":
    case "Foil":
    case "DiamondPlate":
      return new THREE.MeshStandardMaterial({ color, roughness: 0.4, metalness: 0.55, transparent, opacity });
    case "SmoothPlastic":
      return new THREE.MeshStandardMaterial({ color, roughness: 0.55, transparent, opacity });
    default:
      return new THREE.MeshStandardMaterial({ color, roughness: 0.9, transparent, opacity });
  }
}

function matrixFor(cf, size, shape) {
  const [x, y, z, r00, r01, r02, r10, r11, r12, r20, r21, r22] = cf;
  const m = new THREE.Matrix4().set(r00, r01, r02, x, r10, r11, r12, y, r20, r21, r22, z, 0, 0, 0, 1);
  let [sx, sy, sz] = size;
  if (shape === "Ball") {
    sx = sy = sz = Math.min(sx, sy, sz);
  } else if (shape === "Cylinder") {
    sy = sz = Math.min(sy, sz);
  }
  return m.multiply(new THREE.Matrix4().makeScale(sx, sy, sz));
}

const meshes = [];
for (const part of data.parts) {
  const geometry = geometries[part.shape] ?? geometries.Block;
  const mesh = new THREE.Mesh(geometry, materialFor(part));
  mesh.matrixAutoUpdate = false;
  mesh.matrix.copy(matrixFor(part.cf, part.size, part.shape));
  mesh.castShadow = part.material !== "Neon" && part.transparency < 0.5;
  mesh.receiveShadow = true;
  scene.add(mesh);
  meshes.push(mesh);
}

for (const light of data.lights) {
  const point = new THREE.PointLight(new THREE.Color().setRGB(...light.color, THREE.SRGBColorSpace), light.brightness * 5, light.range, 1);
  point.position.set(...light.position);
  scene.add(point);
}

// Fire: stacked glowing cones standing in for Roblox's particle flame.
for (const fire of data.fires) {
  const outer = new THREE.Mesh(
    new THREE.ConeGeometry(fire.size * 0.22, fire.size * 0.8, 12),
    new THREE.MeshBasicMaterial({ color: new THREE.Color().setRGB(...fire.color, THREE.SRGBColorSpace), transparent: true, opacity: 0.85 }),
  );
  outer.position.set(fire.position[0], fire.position[1] + fire.size * 0.4, fire.position[2]);
  const inner = new THREE.Mesh(
    new THREE.ConeGeometry(fire.size * 0.12, fire.size * 0.5, 12),
    new THREE.MeshBasicMaterial({ color: new THREE.Color().setRGB(...fire.core, THREE.SRGBColorSpace) }),
  );
  inner.position.set(fire.position[0], fire.position[1] + fire.size * 0.3, fire.position[2]);
  scene.add(outer, inner);
}

// SurfaceGui text drawn onto the matching face of its part.
const FACES = {
  Front: { normal: [0, 0, -1], rotate: [0, Math.PI, 0], dims: [0, 1] },
  Back: { normal: [0, 0, 1], rotate: [0, 0, 0], dims: [0, 1] },
  Top: { normal: [0, 1, 0], rotate: [-Math.PI / 2, 0, 0], dims: [0, 2] },
};
for (const text of data.texts) {
  const part = data.parts[text.part - 1];
  const face = FACES[text.face];
  if (!part || !face) continue;
  const width = part.size[face.dims[0]];
  const height = part.size[face.dims[1]];
  const canvas = document.createElement("canvas");
  canvas.width = 1024;
  canvas.height = Math.max(64, Math.round((1024 * height) / width));
  const ctx = canvas.getContext("2d");
  let fontSize = canvas.height * 0.62;
  ctx.font = `bold ${fontSize}px sans-serif`;
  while (ctx.measureText(text.text).width > canvas.width * 0.9 && fontSize > 8) {
    fontSize -= 2;
    ctx.font = `bold ${fontSize}px sans-serif`;
  }
  ctx.textAlign = "center";
  ctx.textBaseline = "middle";
  ctx.lineWidth = fontSize * 0.12;
  ctx.strokeStyle = "#231e2d";
  ctx.strokeText(text.text, canvas.width / 2, canvas.height / 2);
  ctx.fillStyle = "#ffffff";
  ctx.fillText(text.text, canvas.width / 2, canvas.height / 2);
  const texture = new THREE.CanvasTexture(canvas);
  texture.colorSpace = THREE.SRGBColorSpace;
  const plane = new THREE.Mesh(new THREE.PlaneGeometry(width, height), new THREE.MeshBasicMaterial({ map: texture, transparent: true }));
  const depth = part.size[[0, 1, 2].find((i) => !face.dims.includes(i))];
  const local = new THREE.Matrix4()
    .makeTranslation(...face.normal.map((n) => n * (depth / 2 + 0.01)))
    .multiply(new THREE.Matrix4().makeRotationFromEuler(new THREE.Euler(...face.rotate)));
  const [x, y, z, r00, r01, r02, r10, r11, r12, r20, r21, r22] = part.cf;
  plane.matrixAutoUpdate = false;
  plane.matrix.copy(new THREE.Matrix4().set(r00, r01, r02, x, r10, r11, r12, y, r20, r21, r22, z, 0, 0, 0, 1).multiply(local));
  scene.add(plane);
}

const camera = new THREE.PerspectiveCamera(50, innerWidth / innerHeight, 0.5, span * 10);
const target = new THREE.Vector3(cx, cy + 2, cz);
const views = {
  iso: [-0.62, 0.72, -0.62],
  low: [-0.55, 0.22, -0.8],
  top: [0.001, 1.25, 0.001],
  front: [0, 0.28, -0.95],
};
const [dx, dy, dz] = views[view] ?? views.iso;
const distance = span * (view === "front" ? 0.95 : 1.05);
camera.position.set(cx + dx * distance, cy + dy * distance, cz + dz * distance);
camera.lookAt(target);

const controls = new OrbitControls(camera, renderer.domElement);
controls.target.copy(target);
controls.update();

function frame() {
  renderer.render(scene, camera);
  requestAnimationFrame(frame);
}
renderer.render(scene, camera);
window.__rendered = true;
requestAnimationFrame(frame);
addEventListener("resize", () => {
  camera.aspect = innerWidth / innerHeight;
  camera.updateProjectionMatrix();
  renderer.setSize(innerWidth, innerHeight);
});
