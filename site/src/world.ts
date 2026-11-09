// The laptop. One model for the whole page: it closes in the first scene, heats up in the heat section,
// and opens again at dawn. Everything it does is a Pose, and the page decides the pose from scroll.

import {
  ACESFilmicToneMapping,
  AdditiveBlending,
  AmbientLight,
  CanvasTexture,
  Color,
  DirectionalLight,
  ExtrudeGeometry,
  Group,
  Mesh,
  MeshBasicMaterial,
  MeshStandardMaterial,
  PerspectiveCamera,
  PlaneGeometry,
  PMREMGenerator,
  PointLight,
  Scene,
  Shape,
  SphereGeometry,
  Sprite,
  SpriteMaterial,
  SRGBColorSpace,
  WebGLRenderer,
} from "three";
import { RoomEnvironment } from "three/examples/jsm/environments/RoomEnvironment.js";

export type Pose = {
  /** Degrees the lid is open. 0 is shut. */
  lid: number;
  /** Camera angle around the laptop, in degrees. 0 faces the screen, -90 is the side view the logo is drawn from. */
  az: number;
  /** Camera height, in degrees above the desk. */
  el: number;
  /** How much of the viewport's width the laptop's width takes. */
  size: number;
  /** Where the laptop sits, as a fraction of the viewport from its centre. */
  x: number;
  y: number;
  /** 1 is a daylit studio, 0 is night. */
  light: number;
  /** How lit the ember is. */
  ember: number;
  alpha: number;
};

const WIDTH = 3.1;
const DEPTH = 2.15;
const BASE = 0.11;
const LID = 0.05;
const FOV = 26;
/** The gap between lid and base. Light escapes from it once the lid is down. */
const SEAM = 0.009;

const EMBER = new Color("#ff8a3d");
const DEEP = new Color("#d9421a");
const BODY = new Color("#141312");

const rad = (degrees: number) => (degrees * Math.PI) / 180;
const mix = (a: number, b: number, t: number) => a + (b - a) * t;
const clamp = (value: number, low = 0, high = 1) => Math.min(Math.max(value, low), high);
const smooth = (t: number) => t * t * (3 - 2 * t);

/** A slab with a laptop's corners: generous seen from above, tight along the edges. */
function slab(width: number, depth: number, height: number) {
  const bevel = 0.012;
  const radius = 0.14;
  const w = width / 2 - bevel;
  const d = depth / 2 - bevel;
  const shape = new Shape();
  shape.moveTo(-w + radius, -d);
  shape.lineTo(w - radius, -d);
  shape.absarc(w - radius, -d + radius, radius, -Math.PI / 2, 0, false);
  shape.lineTo(w, d - radius);
  shape.absarc(w - radius, d - radius, radius, 0, Math.PI / 2, false);
  shape.lineTo(-w + radius, d);
  shape.absarc(-w + radius, d - radius, radius, Math.PI / 2, Math.PI, false);
  shape.lineTo(-w, -d + radius);
  shape.absarc(-w + radius, -d + radius, radius, Math.PI, Math.PI * 1.5, false);
  const geometry = new ExtrudeGeometry(shape, {
    depth: height - 2 * bevel,
    bevelEnabled: true,
    bevelThickness: bevel,
    bevelSize: bevel,
    bevelSegments: 3,
    curveSegments: 10,
  });
  geometry.rotateX(-Math.PI / 2);
  geometry.translate(0, bevel, 0);
  return geometry;
}

function canvasOf(width: number, height: number) {
  const canvas = document.createElement("canvas");
  canvas.width = width;
  canvas.height = height;
  return canvas;
}

function keyboardTexture() {
  const canvas = canvasOf(1024, 694);
  const g = canvas.getContext("2d")!;
  g.fillStyle = "#0b0a0a";
  g.beginPath();
  g.roundRect(70, 44, 884, 352, 14);
  g.fill();
  const rows = 6;
  const columns = 14;
  const gap = 7;
  const keyWidth = (884 - 24 - gap * (columns - 1)) / columns;
  for (let row = 0; row < rows; row++) {
    const keyHeight = row === 0 ? 34 : 50;
    const y = 56 + (row === 0 ? 0 : 34 + gap + (row - 1) * (50 + gap));
    for (let column = 0; column < columns; column++) {
      // The bottom row is mostly one long key.
      if (row === rows - 1 && column > 3 && column < 9) continue;
      const x = 82 + column * (keyWidth + gap);
      g.fillStyle = "#1a1918";
      g.beginPath();
      g.roundRect(x, y, keyWidth, keyHeight, 6);
      g.fill();
    }
    if (row === rows - 1) {
      g.fillStyle = "#1a1918";
      g.beginPath();
      g.roundRect(82 + 4 * (keyWidth + gap), y, 5 * keyWidth + 4 * gap, keyHeight, 6);
      g.fill();
    }
  }
  g.strokeStyle = "rgb(255 255 255 / 9%)";
  g.lineWidth = 2;
  g.beginPath();
  g.roundRect(332, 440, 360, 224, 16);
  g.stroke();
  const texture = new CanvasTexture(canvas);
  texture.colorSpace = SRGBColorSpace;
  texture.anisotropy = 8;
  return texture;
}

function markTexture() {
  const canvas = canvasOf(512, 512);
  const g = canvas.getContext("2d")!;
  g.scale(512 / 24, 512 / 24);
  g.strokeStyle = "rgb(255 255 255 / 16%)";
  g.fillStyle = "rgb(255 255 255 / 16%)";
  g.lineWidth = 2;
  g.lineCap = "round";
  g.lineJoin = "round";
  g.stroke(new Path2D("M20.5 16.3H4.87A1 1 0 0 1 4.3 14.48L14 7.7"));
  g.beginPath();
  g.arc(15.8, 11.9, 2.25, 0, Math.PI * 2);
  g.fill();
  const texture = new CanvasTexture(canvas);
  texture.colorSpace = SRGBColorSpace;
  texture.anisotropy = 8;
  return texture;
}

function glowTexture(inner: string, outer: string) {
  const canvas = canvasOf(256, 256);
  const g = canvas.getContext("2d")!;
  const gradient = g.createRadialGradient(128, 128, 0, 128, 128, 128);
  gradient.addColorStop(0, inner);
  gradient.addColorStop(0.22, outer);
  gradient.addColorStop(1, "rgb(0 0 0 / 0%)");
  g.fillStyle = gradient;
  g.fillRect(0, 0, 256, 256);
  const texture = new CanvasTexture(canvas);
  texture.colorSpace = SRGBColorSpace;
  return texture;
}

function shadowTexture() {
  const canvas = canvasOf(256, 256);
  const g = canvas.getContext("2d")!;
  const gradient = g.createRadialGradient(128, 128, 20, 128, 128, 128);
  gradient.addColorStop(0, "rgb(20 14 8 / 100%)");
  gradient.addColorStop(0.55, "rgb(20 14 8 / 42%)");
  gradient.addColorStop(1, "rgb(20 14 8 / 0%)");
  g.fillStyle = gradient;
  g.fillRect(0, 0, 256, 256);
  return new CanvasTexture(canvas);
}

export type World = {
  /** Draws one frame. `seconds` only drives the ember's flicker. */
  render(pose: Pose, seconds: number): void;
  resize(): void;
  /** 0 is cool, 1 is as hot as the demo goes. */
  setHeat(heat: number): void;
  /** Whether this page's own session is on. The ember goes out when it isn't. */
  setAwake(isAwake: boolean): void;
  /** Call after the screen's canvas has been redrawn. */
  screenChanged(): void;
  /** A still of one pose, for the images people see when motion or WebGL is off. */
  capture(pose: Pose, width: number, height: number): string;
};

export function createWorld(canvas: HTMLCanvasElement, screen: HTMLCanvasElement, flickers: boolean): World | null {
  let renderer: WebGLRenderer;
  try {
    renderer = new WebGLRenderer({ canvas, alpha: true, antialias: true, powerPreference: "high-performance" });
  } catch {
    return null;
  }
  renderer.setClearColor(0x000000, 0);
  renderer.toneMapping = ACESFilmicToneMapping;
  renderer.outputColorSpace = SRGBColorSpace;

  const scene = new Scene();
  const pmrem = new PMREMGenerator(renderer);
  scene.environment = pmrem.fromScene(new RoomEnvironment(), 0.04).texture;
  pmrem.dispose();

  const camera = new PerspectiveCamera(FOV, 1, 0.1, 100);

  const ambient = new AmbientLight(0xfff4e6, 0.5);
  const key = new DirectionalLight(0xfff1df, 2);
  key.position.set(-3.5, 6, 5);
  const rim = new DirectionalLight(0xffd9b0, 0.8);
  rim.position.set(3, 3.5, -6);
  scene.add(ambient, key, rim);

  const metal = new MeshStandardMaterial({ color: BODY, metalness: 0.4, roughness: 0.56, emissive: DEEP, emissiveIntensity: 0 });

  const laptop = new Group();
  scene.add(laptop);

  const base = new Mesh(slab(WIDTH, DEPTH, BASE), metal);
  laptop.add(base);

  const deck = new Mesh(
    new PlaneGeometry(WIDTH - 0.16, DEPTH - 0.16),
    new MeshStandardMaterial({ map: keyboardTexture(), transparent: true, metalness: 0, roughness: 0.85, envMapIntensity: 0.3 }),
  );
  deck.rotation.x = -Math.PI / 2;
  deck.position.y = BASE + 0.0015;
  laptop.add(deck);

  const hinge = new Group();
  hinge.position.set(0, BASE + SEAM, -DEPTH / 2);
  laptop.add(hinge);

  const lidGeometry = slab(WIDTH, DEPTH, LID);
  lidGeometry.translate(0, 0, DEPTH / 2);
  hinge.add(new Mesh(lidGeometry, metal));

  const bezel = new Mesh(
    new PlaneGeometry(WIDTH - 0.07, DEPTH - 0.07),
    new MeshStandardMaterial({ color: 0x050505, metalness: 0, roughness: 0.22 }),
  );
  bezel.rotation.x = Math.PI / 2;
  bezel.position.set(0, -0.001, DEPTH / 2);
  hinge.add(bezel);

  const screenTexture = new CanvasTexture(screen);
  screenTexture.colorSpace = SRGBColorSpace;
  screenTexture.anisotropy = renderer.capabilities.getMaxAnisotropy();
  const display = new Mesh(
    new PlaneGeometry(WIDTH - 0.2, DEPTH - 0.2),
    new MeshBasicMaterial({ map: screenTexture, toneMapped: false }),
  );
  display.rotation.x = Math.PI / 2;
  display.position.set(0, -0.002, DEPTH / 2);
  hinge.add(display);

  const badge = new Mesh(
    new PlaneGeometry(0.9, 0.9),
    new MeshBasicMaterial({ map: markTexture(), transparent: true, depthWrite: false }),
  );
  badge.rotation.x = -Math.PI / 2;
  badge.position.set(0, LID + 0.001, DEPTH / 2);
  hinge.add(badge);

  const shadow = new Mesh(
    new PlaneGeometry(WIDTH * 1.7, DEPTH * 1.9),
    new MeshBasicMaterial({ map: shadowTexture(), transparent: true, depthWrite: false, toneMapped: false }),
  );
  shadow.rotation.x = -Math.PI / 2;
  shadow.position.y = -0.002;
  laptop.add(shadow);

  const seam = new Mesh(
    new PlaneGeometry(WIDTH - 0.05, DEPTH - 0.05),
    new MeshBasicMaterial({ color: EMBER, toneMapped: false, transparent: true, opacity: 0 }),
  );
  seam.rotation.x = -Math.PI / 2;
  seam.position.y = BASE + SEAM / 2;
  laptop.add(seam);
  const seamUnder = seam.clone();
  seamUnder.rotation.x = Math.PI / 2;
  laptop.add(seamUnder);

  // The ember: a coal inside the angle while the lid comes down, squeezed out to the front edge once it's shut.
  const ember = new Group();
  laptop.add(ember);
  const coal = new Mesh(new SphereGeometry(1, 32, 20), new MeshBasicMaterial({ color: EMBER, toneMapped: false }));
  const halo = new Sprite(
    new SpriteMaterial({
      map: glowTexture("rgb(255 138 61 / 60%)", "rgb(255 110 40 / 34%)"),
      blending: AdditiveBlending,
      depthWrite: false,
      toneMapped: false,
    }),
  );
  const emberLight = new PointLight(EMBER, 0, 7, 1.6);
  ember.add(coal, halo, emberLight);

  const fever = new Sprite(
    new SpriteMaterial({
      map: glowTexture("rgb(255 96 40 / 80%)", "rgb(217 66 26 / 40%)"),
      blending: AdditiveBlending,
      depthWrite: false,
      depthTest: false,
      toneMapped: false,
      opacity: 0,
    }),
  );
  fever.scale.set(WIDTH * 2.6, DEPTH * 2.2, 1);
  fever.position.set(0, 0.05, 0);
  fever.renderOrder = -1;
  laptop.add(fever);

  let heat = 0;
  let awake = 1;
  let awakeTarget = 1;
  let lastSeconds = 0;

  function apply(pose: Pose, seconds: number, width: number, height: number) {
    const lid = clamp(pose.lid, 0, 130);
    hinge.rotation.x = -rad(lid);

    // Lighting: a studio by day, almost nothing but the ember by night.
    const light = clamp(pose.light);
    ambient.intensity = mix(0.12, 0.7, light);
    key.intensity = mix(0.5, 2.2, light);
    // By day the warm light from behind would glare off the deck and turn it bronze.
    rim.intensity = mix(0.5, 0.1, light);
    scene.environmentIntensity = mix(0.12, 0.22, light);
    (shadow.material as MeshBasicMaterial).opacity = light * 0.3;

    // The screen dies as the lid comes down, the way a real one does.
    const screenOn = smooth(clamp((lid - 12) / 40));
    (display.material as MeshBasicMaterial).color.setScalar(screenOn);

    // The ember appears at 60 degrees, is the logo's size at 35, and is an LED on the front edge at 0.
    const t = clamp(1 - lid / 60);
    const along = t < 0.42 ? mix(0.62, 0.71, t / 0.42) : mix(0.71, 1.02, smooth((t - 0.42) / 0.58));
    const radius = t < 0.42 ? mix(0.02, 0.3, smooth(t / 0.42)) : mix(0.3, 0.052, smooth((t - 0.42) / 0.58));
    const z = along * DEPTH;
    const gap = Math.tan(rad(Math.min(lid, 60))) * Math.min(z, DEPTH);
    const y = BASE + mix(gap / 2, SEAM / 2, smooth(clamp((t - 0.72) / 0.28)));
    ember.position.set(0, y, -DEPTH / 2 + z);

    const flicker = flickers ? 1 + 0.05 * Math.sin(seconds * 7.3) * Math.sin(seconds * 2.9 + 1.7) : 1;
    const lit = clamp(pose.ember) * awake * (t > 0 ? 1 : 0) * smooth(clamp(t / 0.12));
    coal.scale.setScalar(Math.max(radius, 0.0001));
    coal.visible = lit > 0.01;
    const reach = mix(1.1, 2.6, 1 - light) * mix(1, 2.4, t);
    halo.scale.setScalar(radius * 5 + reach * lit * flicker);
    halo.material.opacity = lit * mix(0.5, 1, 1 - light) * flicker;
    emberLight.intensity = lit * mix(1.5, 9, 1 - light) * flicker;

    // Shut, a line of the same light shows all the way round the seam: still awake in there.
    const leak = lit * smooth(clamp((t - 0.9) / 0.1));
    (seam.material as MeshBasicMaterial).opacity = leak;
    seam.visible = seamUnder.visible = leak > 0.01;

    metal.emissiveIntensity = heat * heat * 0.3;
    fever.material.opacity = heat * 0.62 * (1 - light * 0.5);

    // Frame the laptop: look at the middle of whatever shape it currently is.
    const open = clamp(lid / 108);
    const targetY = mix(0.07, 0.98, open);
    const targetZ = mix(0, -0.3, open);
    const aspect = width / height;
    const halfWidth = Math.tan(rad(FOV / 2)) * aspect;
    const distance = WIDTH / (Math.max(pose.size, 0.05) * 2 * halfWidth);
    const az = rad(pose.az);
    const el = rad(pose.el);
    camera.aspect = aspect;
    camera.position.set(
      distance * Math.cos(el) * Math.sin(az),
      targetY + distance * Math.sin(el),
      targetZ + distance * Math.cos(el) * Math.cos(az),
    );
    camera.lookAt(0, targetY, targetZ);
    camera.setViewOffset(width, height, -pose.x * width, -pose.y * height, width, height);
    camera.updateProjectionMatrix();
  }

  let cssWidth = 1;
  let cssHeight = 1;

  function resize() {
    cssWidth = canvas.clientWidth || innerWidth;
    cssHeight = canvas.clientHeight || innerHeight;
    renderer.setPixelRatio(Math.min(devicePixelRatio || 1, 2));
    renderer.setSize(cssWidth, cssHeight, false);
  }
  resize();

  return {
    render(pose, seconds) {
      const elapsed = Math.min(seconds - lastSeconds, 0.1);
      lastSeconds = seconds;
      // The ember goes out and comes back over a moment, never in one frame.
      awake += (awakeTarget - awake) * Math.min(1, elapsed * 6);
      if (pose.alpha <= 0.001) return;
      apply(pose, seconds, cssWidth, cssHeight);
      renderer.render(scene, camera);
    },
    resize,
    setHeat(value) {
      heat = clamp(value);
    },
    setAwake(isAwake) {
      awakeTarget = isAwake ? 1 : 0;
    },
    screenChanged() {
      screenTexture.needsUpdate = true;
    },
    capture(pose, width, height) {
      renderer.setPixelRatio(1);
      renderer.setSize(width, height, false);
      const flicker = awake;
      awake = 1;
      apply(pose, 0, width, height);
      renderer.render(scene, camera);
      const url = canvas.toDataURL("image/png");
      awake = flicker;
      resize();
      return url;
    },
  };
}
