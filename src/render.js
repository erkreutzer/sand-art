// WebGL2 renderer: the sim's Uint32 grid is uploaded as-is as an RGBA8 texture
// and a single fragment shader turns cell types into sand, liquid and air.

const VS = `#version 300 es
in vec2 p;
void main() { gl_Position = vec4(p, 0.0, 1.0); }`;

const FS = `#version 300 es
precision highp float;
uniform sampler2D uGrid;
uniform sampler2D uPal;
uniform vec2 uSize;      // cells (w, h)
uniform float uScale;    // device pixels per cell
uniform float uGlint;
uniform vec3 uLiquidTop, uLiquidBot, uAir, uRim;
uniform float uLiquidAlpha;   // the liquid is see-through; sand and air are not
out vec4 outColor;

float hash(vec2 p) {
  vec3 q = fract(vec3(p.xyx) * 0.1031);
  q += dot(q, q.yzx + 33.33);
  return fract((q.x + q.y) * q.z);
}

int typeAt(ivec2 g) { return int(texelFetch(uGrid, g, 0).r * 255.0 + 0.5); }

void main() {
  vec2 fc = gl_FragCoord.xy;
  ivec2 cell = ivec2(floor(fc / uScale));
  cell.y = int(uSize.y) - 1 - cell.y;
  ivec2 g = cell + 1;
  vec4 c = texelFetch(uGrid, g, 0);
  int t = int(c.r * 255.0 + 0.5);
  vec2 uv = (vec2(cell) + 0.5) / uSize;
  float n = hash(floor(fc));
  vec3 col;

  if (t >= 3) {
    vec4 p = texelFetch(uPal, ivec2(t - 3, 0), 0);
    float s = c.g;
    col = p.rgb * (0.80 + 0.34 * s);
    col *= 0.94 + 0.10 * n;
    if (p.a < 0.5) {
      // Glitter flake: twinkles as the frame turns.
      float tw = pow(max(0.0, sin(s * 97.0 + uGlint * (1.0 + s * 3.0))), 24.0);
      col = mix(col, vec3(1.0, 0.98, 0.9), tw * 0.85);
    }
  } else if (t == 1) {
    // Air: silvery, with a soft meniscus only where a pocket has some depth,
    // so a one-cell film reads as a fine bright seam rather than a dark line.
    int up = typeAt(g - ivec2(0, 1)), dn = typeAt(g + ivec2(0, 1));
    int lf = typeAt(g - ivec2(1, 0)), rt = typeAt(g + ivec2(1, 0));
    int nAir = int(up == 1) + int(dn == 1) + int(lf == 1) + int(rt == 1);
    bool edge = (up == 0 || dn == 0 || lf == 0 || rt == 0);
    col = uAir * (0.97 + 0.05 * n);
    if (edge && nAir >= 2 && (up == 1 || dn == 1)) col = mix(col, uRim, 0.55);
  } else {
    // Clear liquid: a faint tint over whatever is behind the frame
    // (premultiplied alpha, as the page composites it).
    col = mix(uLiquidTop, uLiquidBot, uv.y) * (0.985 + 0.02 * n);
    outColor = vec4(col * uLiquidAlpha, uLiquidAlpha);
    return;
  }
  outColor = vec4(col, 1.0);
}`;

function compile(gl, type, src) {
  const s = gl.createShader(type);
  gl.shaderSource(s, src);
  gl.compileShader(s);
  if (!gl.getShaderParameter(s, gl.COMPILE_STATUS)) throw new Error(gl.getShaderInfoLog(s));
  return s;
}

// Live-tunable look. liquidTint scales each palette's own liquid opacity.
export const renderParams = { liquidTint: 1 };

const hex = (h) => [1, 3, 5].map((i) => parseInt(h.slice(i, i + 2), 16) / 255);

export class Renderer {
  constructor(canvas, sim, scale) {
    this.sim = sim;
    this.scale = scale;
    canvas.width = sim.w * scale;
    canvas.height = sim.h * scale;
    const gl = (this.gl = canvas.getContext('webgl2', {
      antialias: false, alpha: true, premultipliedAlpha: true, depth: false, stencil: false,
      preserveDrawingBuffer: false, powerPreference: 'high-performance',
    }));
    if (!gl) throw new Error('WebGL2 unavailable');

    const prog = gl.createProgram();
    gl.attachShader(prog, compile(gl, gl.VERTEX_SHADER, VS));
    gl.attachShader(prog, compile(gl, gl.FRAGMENT_SHADER, FS));
    gl.linkProgram(prog);
    if (!gl.getProgramParameter(prog, gl.LINK_STATUS)) throw new Error(gl.getProgramInfoLog(prog));
    gl.useProgram(prog);
    this.u = {};
    for (const n of ['uGrid', 'uPal', 'uSize', 'uScale', 'uGlint', 'uLiquidTop', 'uLiquidBot', 'uLiquidAlpha', 'uAir', 'uRim'])
      this.u[n] = gl.getUniformLocation(prog, n);

    const buf = gl.createBuffer();
    gl.bindBuffer(gl.ARRAY_BUFFER, buf);
    gl.bufferData(gl.ARRAY_BUFFER, new Float32Array([-1, -1, 3, -1, -1, 3]), gl.STATIC_DRAW);
    const loc = gl.getAttribLocation(prog, 'p');
    gl.enableVertexAttribArray(loc);
    gl.vertexAttribPointer(loc, 2, gl.FLOAT, false, 0, 0);

    const tex = (unit) => {
      const t = gl.createTexture();
      gl.activeTexture(gl.TEXTURE0 + unit);
      gl.bindTexture(gl.TEXTURE_2D, t);
      gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.NEAREST);
      gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.NEAREST);
      gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_S, gl.CLAMP_TO_EDGE);
      gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, gl.CLAMP_TO_EDGE);
      return t;
    };
    this.palTex = tex(1);
    gl.texImage2D(gl.TEXTURE_2D, 0, gl.RGBA8, 8, 1, 0, gl.RGBA, gl.UNSIGNED_BYTE, null);
    this.gridTex = tex(0);
    gl.texImage2D(gl.TEXTURE_2D, 0, gl.RGBA8, sim.W, sim.H, 0, gl.RGBA, gl.UNSIGNED_BYTE, sim.bytes);

    gl.uniform1i(this.u.uGrid, 0);
    gl.uniform1i(this.u.uPal, 1);
    gl.uniform2f(this.u.uSize, sim.w, sim.h);
    gl.uniform1f(this.u.uScale, scale);
    gl.viewport(0, 0, canvas.width, canvas.height);
  }

  setPalette(p) {
    const gl = this.gl;
    const data = new Uint8Array(32);
    p.sand.forEach((h, i) => data.set([...hex(h).map((v) => v * 255), 255], i * 4));
    data.set([...hex(p.glitter).map((v) => v * 255), 0], 6 * 4);
    gl.activeTexture(gl.TEXTURE1);
    gl.texSubImage2D(gl.TEXTURE_2D, 0, 0, 0, 8, 1, gl.RGBA, gl.UNSIGNED_BYTE, data);
    gl.activeTexture(gl.TEXTURE0);
    gl.uniform3fv(this.u.uLiquidTop, hex(p.liquid[0]));
    gl.uniform3fv(this.u.uLiquidBot, hex(p.liquid[1]));
    gl.uniform3fv(this.u.uAir, hex(p.air));
    gl.uniform3fv(this.u.uRim, hex(p.rim));
    this.palette = p;
    this.applyLiquid();
  }

  applyLiquid() {
    const a = Math.min(1, Math.max(0, (this.palette?.liquidAlpha ?? 1) * renderParams.liquidTint));
    this.gl.uniform1f(this.u.uLiquidAlpha, a);
  }

  upload(rows) {
    if (!rows) return;
    const { gl, sim } = this;
    const [a, b] = rows;
    gl.texSubImage2D(gl.TEXTURE_2D, 0, 0, a, sim.W, b - a + 1, gl.RGBA, gl.UNSIGNED_BYTE,
      sim.bytes, a * sim.W * 4);
  }

  draw(glint) {
    const gl = this.gl;
    gl.uniform1f(this.u.uGlint, glint);
    gl.drawArrays(gl.TRIANGLES, 0, 3);
  }
}
