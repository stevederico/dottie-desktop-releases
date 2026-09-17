//
//  MetalOrbShader.metal
//  Dottie
//
//  Premium glass orb: analytic ray-sphere shell with refracted volumetric
//  fbm nebula core, thin-film iridescence with chromatic dispersion,
//  studio-softbox reflections, layered fresnel rims, and ACES tonemapping.
//  All color is anchored to the single user hue (DESIGN.md: bright
//  translucent glass — soap bubble, not dark marble).
//

#include <metal_stdlib>
using namespace metal;

// MARK: - Uniforms

struct Uniforms {
    float time;
    float2 resolution;
    float agentState;    // 0=idle, 1=hover, 2=thinking, 3=listening, 4=speaking
    float audioLevel;    // 0.0 - 1.0
    float distortion;    // normal perturbation amount (0.0 - 1.0)
    float iridescence;   // iridescence intensity (0.0 - 1.0)
    float touchStrength; // audio/touch reactive deformation (0.0 - 1.0)
    float hue;           // color hue (0-360)
    float proactiveGlow; // transient notification glow (0.0 - 1.0, fades over time)
    float reduceMotion;  // 1.0 = accessibility reduce motion enabled
};

struct VertexOut {
    float4 position [[position]];
    float2 uv;
};

// MARK: - Noise

float hash(float3 p) {
    p = fract(p * 0.3183099 + 0.1);
    p *= 17.0;
    return fract(p.x * p.y * p.z * (p.x + p.y + p.z));
}

float noise3d(float3 p) {
    float3 i = floor(p);
    float3 f = fract(p);
    f = f * f * (3.0 - 2.0 * f);

    return mix(
        mix(mix(hash(i + float3(0,0,0)), hash(i + float3(1,0,0)), f.x),
            mix(hash(i + float3(0,1,0)), hash(i + float3(1,1,0)), f.x), f.y),
        mix(mix(hash(i + float3(0,0,1)), hash(i + float3(1,0,1)), f.x),
            mix(hash(i + float3(0,1,1)), hash(i + float3(1,1,1)), f.x), f.y),
        f.z
    );
}

float fbm(float3 p) {
    float v = 0.0;
    float a = 0.55;
    for (int i = 0; i < 3; i++) {
        v += a * noise3d(p);
        p = p * 2.13 + float3(7.7, 3.1, 9.4);
        a *= 0.5;
    }
    return v;
}

// MARK: - Helpers

float2 rot2(float2 v, float a) {
    float c = cos(a), s = sin(a);
    return float2(c * v.x - s * v.y, s * v.x + c * v.y);
}

float3 hsv2rgb(float h, float s, float v) {
    h = fmod(h + 360.0, 360.0);
    float c = v * s;
    float hp = h / 60.0;
    float x = c * (1.0 - abs(fmod(hp, 2.0) - 1.0));
    float3 rgb;
    if      (hp < 1.0) rgb = float3(c, x, 0);
    else if (hp < 2.0) rgb = float3(x, c, 0);
    else if (hp < 3.0) rgb = float3(0, c, x);
    else if (hp < 4.0) rgb = float3(0, x, c);
    else if (hp < 5.0) rgb = float3(x, 0, c);
    else               rgb = float3(c, 0, x);
    float m = v - c;
    return rgb + m;
}

/// Hue-anchored palette: sweeps ±35° around the user hue. Deep saturated
/// lows rising to hot, near-white HDR highs — luminous plasma, not fog.
float3 orbPalette(float t, float hue) {
    float h = hue + (t - 0.35) * 90.0; // biased toward the violet side — no green drift
    float s = mix(0.95, 0.4, t * t);
    float v = mix(0.12, 1.5, pow(t, 1.4));
    return hsv2rgb(h, s, v);
}

/// Narkowicz ACES filmic fit — lets HDR highlights roll off instead of clipping.
float3 acesTonemap(float3 x) {
    return clamp((x * (2.51 * x + 0.03)) / (x * (2.43 * x + 0.59) + 0.14), 0.0, 1.0);
}

// MARK: - Interior Volume (refracted fbm nebula)

/// Marches the refracted chord through the sphere accumulating a
/// domain-warped fbm nebula. `entry` is the surface hit point (sphere at
/// origin), `rd` the incoming ray. Returns HDR emission.
float3 marchInterior(float3 entry, float3 rd, float radius, float animTime,
                     float energy, float hue, float turbulence) {
    float3 n = entry / radius;
    float3 pd = refract(rd, n, 1.0 / 1.42);
    if (dot(pd, pd) < 1e-6) pd = rd;
    float chord = -2.0 * dot(entry, pd);

    const int STEPS = 20;
    float stepLen = chord / float(STEPS);
    float flow = animTime * 0.16;
    float spin = animTime * 0.06;

    float3 acc = float3(0.0);
    for (int i = 0; i < STEPS; i++) {
        float3 sp = entry + pd * (stepLen * (float(i) + 0.5));
        float3 q = sp / radius;
        // Helical twist: rotation increases along y for a fluid, alive core
        q.xz = rot2(q.xz, spin + q.y * 0.7);
        float warp = fbm(q * 1.4 + float3(0.0, flow, flow * 0.7));
        float den = fbm(q * 2.4 + (warp - 0.5) * turbulence
                        + float3(flow * 0.5, -flow * 0.3, 0.0));
        float core = smoothstep(1.05, 0.15, length(q));
        den = smoothstep(0.48, 0.92, den + core * 0.15) * core;
        den *= den; // sharpen: bright filaments against deep glass
        acc += orbPalette(den * 0.9 + warp * 0.3, hue) * den;
    }
    return acc * (4.5 / float(STEPS)) * (0.8 + energy * 1.4);
}

// MARK: - Normal Perturbation

float3 perturbNormal(float3 normal, float3 pos, float time, float amount) {
    if (amount < 0.001) return normal;

    float eps = 0.02;
    float3 timeOffset = float3(time * 0.4, time * 0.3, time * 0.25);
    float base = noise3d(pos * 1.5 + timeOffset);
    float dx = noise3d((pos + float3(eps, 0, 0)) * 1.5 + timeOffset) - base;
    float dy = noise3d((pos + float3(0, eps, 0)) * 1.5 + timeOffset) - base;
    float dz = noise3d((pos + float3(0, 0, eps)) * 1.5 + timeOffset) - base;

    float3 grad = float3(dx, dy, dz) / eps;
    return normalize(normal + grad * amount * 0.5);
}

// MARK: - Vertex Shader

vertex VertexOut metalOrbVertex(uint vertexID [[vertex_id]]) {
    float2 positions[3] = {
        float2(-1.0, -1.0),
        float2( 3.0, -1.0),
        float2(-1.0,  3.0)
    };

    VertexOut out;
    out.position = float4(positions[vertexID], 0.0, 1.0);
    out.uv = positions[vertexID] * 0.5 + 0.5;
    out.uv.y = 1.0 - out.uv.y;
    return out;
}

// MARK: - Fragment Shader

fragment float4 metalOrbFragment(VertexOut in [[stage_in]],
                                  constant Uniforms &uniforms [[buffer(0)]]) {
    float2 uv = in.uv;
    float2 res = uniforms.resolution;
    float time = uniforms.time;
    // Reduce motion: near-freeze all expressive animation, keep the still image
    float animTime = time * (1.0 - 0.92 * uniforms.reduceMotion);

    // Aspect-correct centered coordinates
    float aspect = res.x / res.y;
    float2 p = (uv * 2.0 - 1.0);
    p.x *= aspect;

    // Camera (p.y negated: the vertex-stage uv flip puts +y at the image
    // bottom; this keeps world-up = image-up so lights land where designed)
    float3 ro = float3(0.0, 0.0, 2.6);
    float3 rd = normalize(float3(p.x, -p.y, -1.5));

    // State-driven parameters
    float distortion = uniforms.distortion;
    float iriIntensity = uniforms.iridescence;
    float audioLevel = uniforms.audioLevel;
    float hue = uniforms.hue;
    float3 glowTint = hsv2rgb(hue, 0.6, 0.9);

    // Smooth state amounts (agentState is lerped host-side)
    float hoverAmount = smoothstep(0.5, 1.5, uniforms.agentState) * (1.0 - smoothstep(1.5, 2.5, uniforms.agentState));
    float thinkingAmount = smoothstep(1.5, 2.5, uniforms.agentState) * (1.0 - smoothstep(2.5, 3.5, uniforms.agentState));
    float listeningAmount = smoothstep(2.5, 3.5, uniforms.agentState) * (1.0 - smoothstep(3.5, 4.5, uniforms.agentState));
    float speakingAmount = smoothstep(3.5, 4.5, uniforms.agentState);
    float idleAmount = 1.0 - smoothstep(0.0, 0.8, uniforms.agentState);
    float thinkPulse = sin(animTime * 8.0) * 0.5 + 0.5;

    // Shared "energy" drives core brightness, sparkles, caustics
    float energy = hoverAmount * 0.35
                 + thinkingAmount * (0.3 + thinkPulse * 0.3)
                 + (listeningAmount + speakingAmount) * audioLevel * 0.9
                 + uniforms.proactiveGlow * 0.5;

    // Sphere radius — scaled down to leave room for glow within the view
    float radius = 0.55;

    // Idle breathing (~8s), disabled by reduce motion
    float breathDisable = uniforms.reduceMotion;
    float breathe = sin(time * 0.785) * 0.5 + 0.5 + sin(time * 0.23) * 0.05;
    radius += breathe * 0.012 * idleAmount * (1.0 - breathDisable);

    radius += hoverAmount * 0.04;                          // expand on hover
    radius += sin(animTime * 8.0) * 0.012 * thinkingAmount; // thinking pulse
    radius += audioLevel * 0.04 * speakingAmount;          // speaking pulse
    radius += audioLevel * uniforms.touchStrength * 0.14;  // listening expand

    // === ANALYTICAL SPHERE INTERSECTION ===
    float3 oc = ro;
    float a = dot(rd, rd);
    float b = 2.0 * dot(oc, rd);
    float c = dot(oc, oc) - radius * radius;
    float discriminant = b * b - 4.0 * a * c;

    // Smooth edge: pixel-width feather based on closest approach
    float pixelSize = 1.5 / res.y;
    float tClosest = -b / (2.0 * a);
    float3 closestPoint = ro + rd * max(tClosest, 0.0);
    float distToSurface = length(closestPoint) - radius;
    float edgeAlpha = 1.0 - smoothstep(-pixelSize, pixelSize, distToSurface);

    if (edgeAlpha < 0.001) {
        // === LAYERED OUTER GLOW (active states + proactive) ===
        float glowIntensity = hoverAmount;
        glowIntensity = max(glowIntensity, uniforms.proactiveGlow);
        glowIntensity = max(glowIntensity, (sin(animTime * 8.0) * 0.3 + 0.7) * thinkingAmount);
        glowIntensity = max(glowIntensity, audioLevel * listeningAmount);
        glowIntensity = max(glowIntensity, (audioLevel * 0.8 + 0.2) * speakingAmount);

        if (glowIntensity > 0.01) {
            // Projected silhouette radius: sphere at origin, camera z=2.6, focal 1.5
            float rScreen = 1.5 * radius / sqrt(6.76 - radius * radius);
            float d = max(length(p) - rScreen, 0.0);
            float halo  = exp(-d * 10.0);  // bright aura hugging the shell
            float bloom = exp(-d * 4.0);   // soft atmosphere falloff
            float g = (halo * 0.5 + bloom * 0.18) * glowIntensity;
            if (g > 0.003) {
                float3 glowColor = mix(hsv2rgb(hue, 0.7, 0.95), float3(1.0), halo * 0.4);
                return float4(glowColor, g);
            }
        }
        return float4(0.0);
    }

    // Hit point (project near-misses onto the surface for the AA fringe)
    float3 hitPos;
    if (discriminant < 0.0) {
        hitPos = normalize(closestPoint) * radius;
    } else {
        float sqrtDisc = sqrt(discriminant);
        float t = (-b - sqrtDisc) / (2.0 * a);
        if (t < 0.0) t = (-b + sqrtDisc) / (2.0 * a);
        hitPos = ro + rd * t;
    }
    float3 baseNormal = normalize(hitPos);
    float3 normal = perturbNormal(baseNormal, hitPos, animTime, distortion);

    // Audio-reactive surface shimmer
    if (audioLevel * uniforms.touchStrength > 0.01) {
        float audioNoise = noise3d(hitPos * 3.0 + float3(animTime * 2.0, 0.0, 0.0));
        normal = normalize(normal + normal * audioNoise * audioLevel * uniforms.touchStrength * 0.15);
    }

    float3 viewDir = normalize(ro - hitPos);
    float NdotV = max(dot(normal, viewDir), 0.0);

    // === LAYERED FRESNEL (wide halo / bright rim / razor edge) ===
    float f2  = pow(1.0 - NdotV, 2.0);
    float f5  = pow(1.0 - NdotV, 5.0);
    float f12 = pow(1.0 - NdotV, 12.0);

    // === HDR COLOR ASSEMBLY ===
    // Deep saturated glass shell with limb darkening — the core glows against it
    float3 color = hsv2rgb(hue, 0.65, 0.20) * (0.25 + NdotV * 0.75);

    // Refracted volumetric nebula core
    float turbulence = 0.9 + distortion * 3.0 + audioLevel * uniforms.touchStrength * 1.5;
    color += marchInterior(hitPos, rd, radius, animTime, energy, hue, turbulence);

    // Fake caustic — thin luminous crescent hugging the bottom rim
    float caustic = smoothstep(0.55, 0.98, -baseNormal.y) * f2;
    color += hsv2rgb(hue, 0.7, 1.2) * caustic * 0.35 * (0.5 + energy);

    // === THIN-FILM IRIDESCENCE with chromatic dispersion ===
    // Per-channel phase frequencies split white light into spectral fringes
    float filmPhase = (2.0 + fbm(baseNormal * 2.0 + animTime * 0.08) * 0.8) * NdotV * 6.2831;
    float3 film = 0.5 + 0.5 * cos(filmPhase * float3(1.0, 1.25, 1.5) + float3(0.0, 1.3, 2.1));
    color += film * f2 * iriIntensity * 0.8;
    color *= mix(float3(1.0), film, f5 * iriIntensity * 0.35);

    // === FRESNEL RIMS (hue-tinted, near-white at the razor edge) ===
    color += hsv2rgb(hue, 0.55, 0.85) * f2 * 0.40;
    color += hsv2rgb(hue, 0.25, 1.1) * f5 * 0.7;
    color += float3(1.2) * f12 * 1.1;

    // === STUDIO SOFTBOX REFLECTION (Apple product-shot key light) ===
    float3 R = reflect(-viewDir, normal);
    if (R.y > 0.05) {
        float2 lp = R.xz / R.y - float2(0.0, -0.2);
        float dRect = length(max(abs(lp) - float2(0.7, 0.28), 0.0)) - 0.2;
        float soft = smoothstep(0.35, -0.05, dRect);
        color += float3(1.02, 1.05, 1.12) * soft * (0.10 + 0.35 * f2);
    }
    // Sharp orbiting key catchlight (kept from v1 — the "alive" glint)
    float lightAngle = animTime * 0.15;
    float3 keyDir = normalize(float3(-0.8 + sin(lightAngle) * 0.3, 0.9 + cos(lightAngle) * 0.2, 0.6));
    float3 halfVec = normalize(keyDir + viewDir);
    color += float3(0.95, 0.95, 1.0) * pow(max(dot(normal, halfVec), 0.0), 260.0) * 0.9;

    // === SPARKLES (hash-grid twinkles on the shell) ===
    float3 g3 = baseNormal * 6.5;
    float3 cellId = floor(g3);
    float h1 = hash(cellId);
    float tw = pow(max(sin(animTime * (1.2 + h1 * 2.5) + h1 * 43.7), 0.0), 24.0);
    float spark = step(0.8, h1) * tw * smoothstep(0.14, 0.02, length(fract(g3) - 0.5));
    // Face-on cells project huge (normal varies slowly at the center) — a
    // "sparkle" there becomes a fat white blob. Keep glints in the rim zone.
    spark *= smoothstep(0.2, 0.55, 1.0 - NdotV);
    color += float3(1.3) * spark * (0.5 + energy * 0.6);

    // === STATE EFFECTS ===
    // HOVER: brighten + hue rim glow
    color += color * hoverAmount * 0.35;
    color += glowTint * f2 * hoverAmount * 0.5;

    // THINKING: rotating rim arcs ("computing") + pulse
    float az = atan2(baseNormal.y, baseNormal.x);
    float arcs = smoothstep(0.78, 0.98, sin(az * 3.0 + animTime * 5.0)) * pow(1.0 - NdotV, 1.2);
    color += glowTint * arcs * thinkingAmount * 3.5;
    color += color * thinkPulse * thinkingAmount * 0.25;

    // LISTENING: audio-reactive brightness
    color += color * audioLevel * listeningAmount * 0.5;
    color += glowTint * f2 * audioLevel * listeningAmount * 0.4;

    // SPEAKING: voice-driven concentric ripples
    float rippleSpeed = 4.0 + audioLevel * 8.0;
    float ripple = sin(length(baseNormal.xz) * 10.0 - animTime * rippleSpeed) * 0.5 + 0.5;
    color += glowTint * ripple * audioLevel * speakingAmount * 0.35 * (1.0 - NdotV);
    color += color * audioLevel * speakingAmount * 0.35;

    // IDLE BREATHING: subtle brightness oscillation
    color += color * breathe * 0.07 * idleAmount * (1.0 - breathDisable);

    // PROACTIVE GLOW: additive bloom (brightness, not motion — reduce-motion safe)
    color += glowTint * uniforms.proactiveGlow * 0.35;

    // === TONEMAP (HDR → display) ===
    color = acesTonemap(color);

    // Translucent bright glass: more solid at rim and where the core is dense
    float lum = dot(color, float3(0.299, 0.587, 0.114));
    float alpha = clamp(0.80 + f2 * 0.25 + lum * 0.15, 0.0, 1.0) * edgeAlpha;

    return float4(color, alpha);
}
