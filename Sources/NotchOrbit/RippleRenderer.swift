import MetalKit

/// One piece of a music effect: a glass ring, a soap bubble or an edge glow.
/// Positions, speeds and sizes are in global screen points (y up), so one
/// element can be handed to every screen and each draws its share of it.
struct RippleElement {
    enum Kind: Float { case ring = 0, bubble = 1, glow = 2 }
    var kind: Kind
    var origin: CGPoint
    var velocity = CGVector.zero   // points per second; bubbles drift
    var startTime: CFTimeInterval
    var duration: Float
    var color: SIMD3<Float>
    var strength: Float            // 0...1
    var size: CGFloat              // ring: radius where it has faded out; bubble: radius; glow: depth
    var width: Float = 1           // ring thickness multiplier
    var seed = Float.random(in: 0..<1)
    var edge: Float = 0            // glow: 0 bottom, 1 top, 2 left, 3 right
}

/// Draws one expanding shockwave. With a screenshot bound it refracts the
/// screen content through the wave; without one it draws only the light.
/// Music effects (up to `maxElements` pieces at once) play alongside it and
/// bend the live picture from `liveScreen` when there is one.
/// Output is premultiplied alpha, so everything outside the wave stays
/// transparent and the live screen shows through.
final class RippleRenderer: NSObject, MTKViewDelegate {
    static let pixelFormat: MTLPixelFormat = .bgra8Unorm

    let device: MTLDevice
    private let queue: MTLCommandQueue
    private let pipeline: MTLRenderPipelineState
    private let sampler: MTLSamplerState
    private let blank: MTLTexture

    var screenTexture: MTLTexture?
    var origin = SIMD2<Float>(0, 0)
    var maxRadius: Float = 1
    var scale: Float = 2
    var duration: Float = 1.8
    var onFinish: (() -> Void)?

    static let maxElements = 24
    private var elements: [RippleElement] = []
    /// The screen this renderer covers, for placing elements.
    var screenFrame = CGRect.zero
    /// Live picture of that screen for the effects to bend; nil draws them as light only.
    var liveScreen: LiveScreen?
    /// When the last bass beat landed; bubbles swell to it.
    var lastBeat: CFTimeInterval = 0

    private var startTime: CFTimeInterval = 0
    private(set) var isPlaying = false   // the main shockwave
    var isIdle: Bool { !isPlaying && elements.isEmpty }

    init?(device: MTLDevice) {
        guard let queue = device.makeCommandQueue() else { return nil }
        self.device = device
        self.queue = queue

        do {
            // Compiled at runtime so the build needs no Metal toolchain.
            let library = try device.makeLibrary(source: Self.shaderSource, options: nil)
            let desc = MTLRenderPipelineDescriptor()
            desc.vertexFunction = library.makeFunction(name: "rippleVertex")
            desc.fragmentFunction = library.makeFunction(name: "rippleFragment")
            desc.colorAttachments[0].pixelFormat = Self.pixelFormat
            pipeline = try device.makeRenderPipelineState(descriptor: desc)
        } catch {
            NSLog("NotchOrbit: shader setup failed: \(error)")
            return nil
        }

        let samplerDesc = MTLSamplerDescriptor()
        samplerDesc.minFilter = .linear
        samplerDesc.magFilter = .linear
        samplerDesc.sAddressMode = .clampToEdge
        samplerDesc.tAddressMode = .clampToEdge
        let blankDesc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: 1, height: 1, mipmapped: false)
        guard let sampler = device.makeSamplerState(descriptor: samplerDesc),
              let blank = device.makeTexture(descriptor: blankDesc) else { return nil }
        self.sampler = sampler
        self.blank = blank
        super.init()
    }

    func makeTexture(from image: CGImage) -> MTLTexture? {
        // Raw (non-sRGB) values in, raw values out: the layer is tagged with
        // the screenshot's colour space, so undistorted pixels match exactly.
        try? MTKTextureLoader(device: device).newTexture(cgImage: image, options: [
            .SRGB: false,
            .generateMipmaps: false,
        ])
    }

    private var frameCount = 0

    /// All screens share one start time so their pieces of the wave line up.
    func start(at time: CFTimeInterval) {
        frameCount = 0
        startTime = time
        isPlaying = true
    }

    func add(_ element: RippleElement) {
        if elements.count >= Self.maxElements - 4 {
            // Crowded: bring the oldest to its end early (a bubble pops)
            // rather than have it vanish.
            let now = CACurrentMediaTime()
            if let oldest = elements.indices.first(where: { Float(now - elements[$0].startTime) < elements[$0].duration - 0.15 }) {
                elements[oldest].duration = Float(now - elements[oldest].startTime) + 0.15
            }
        }
        guard elements.count < Self.maxElements else { return }
        elements.append(element)
    }

    func stop() {
        isPlaying = false
        screenTexture = nil
        elements.removeAll()
        liveScreen = nil
        frameCount = 0
    }

    // MARK: MTKViewDelegate

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        let now = CACurrentMediaTime()
        let elapsed = Float(now - startTime)
        if isPlaying && elapsed >= duration {
            isPlaying = false
            screenTexture = nil
        }
        elements.removeAll { Float(now - $0.startTime) >= $0.duration }
        if isIdle {
            onFinish?()
            return
        }
        frameCount += 1
        if frameCount == 1 || frameCount == 30 {
            debugLog("draw #\(frameCount) size=\(view.drawableSize) drawable=\(view.currentDrawable != nil) windowVisibleToUser=\(view.window?.occlusionState.contains(.visible) ?? false) screen=\(view.window?.screen?.localizedName ?? "none") alphaValue=\(view.window?.alphaValue ?? -1)")
        }
        guard let pass = view.currentRenderPassDescriptor,
              let drawable = view.currentDrawable,
              let commandBuffer = queue.makeCommandBuffer(),
              let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else { return }

        // Packed to match `Uniforms` in the shader: 16 floats, then 16 per element.
        let size = view.drawableSize
        let live = liveScreen?.texture
        var u: [Float] = [
            Float(size.width), Float(size.height), origin.x, origin.y,
            elapsed, duration, scale, screenTexture == nil ? 0 : 1,
            maxRadius, isPlaying ? 1 : 0, Float(elements.count), live == nil ? 0 : 1,
            Float(min(now - lastBeat, 100)), Float(now.truncatingRemainder(dividingBy: 1000)), 0, 0,
        ]
        let s = CGFloat(scale)
        for e in elements {
            u += [Float((e.origin.x - screenFrame.minX) * s), Float((screenFrame.maxY - e.origin.y) * s),
                  Float(now - e.startTime), e.duration,
                  e.color.x, e.color.y, e.color.z, e.strength,
                  Float(e.size * s), e.width, e.kind.rawValue, e.seed,
                  Float(e.velocity.dx * s), Float(-e.velocity.dy * s), e.edge, 0]
        }
        u += [Float](repeating: 0, count: (Self.maxElements - elements.count) * 16)

        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentBytes(u, length: u.count * MemoryLayout<Float>.stride, index: 0)
        encoder.setFragmentTexture(screenTexture ?? blank, index: 0)
        encoder.setFragmentTexture(live ?? blank, index: 1)
        encoder.setFragmentSamplerState(sampler, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }

    // MARK: Shader

    static let shaderSource = """
    #include <metal_stdlib>
    using namespace metal;

    struct Element {
        float4 place;   // origin.xy, age, duration
        float4 tint;    // rgb, strength
        float4 shape;   // size, width multiplier, kind, seed
        float4 motion;  // velocity.xy, edge
    };

    struct Uniforms {
        float2 resolution;
        float2 origin;
        float  time;
        float  duration;
        float  scale;
        float  hasTexture;
        float  maxRadius;
        float  mainActive;
        float  count;
        float  hasLive;
        float  beatAge;     // seconds since the last bass beat
        float  clock;
        float  unused0;
        float  unused1;
        Element elements[24];
    };

    struct VertexOut {
        float4 position [[position]];
        float2 uv;
    };

    vertex VertexOut rippleVertex(uint vid [[vertex_id]]) {
        float2 p = float2((vid << 1) & 2, vid & 2);
        VertexOut out;
        out.position = float4(p * 2.0 - 1.0, 0.0, 1.0);
        out.uv = float2(p.x, 1.0 - p.y);
        return out;
    }

    fragment float4 rippleFragment(VertexOut in [[stage_in]],
                                   constant Uniforms &u [[buffer(0)]],
                                   texture2d<float> screen [[texture(0)]],
                                   texture2d<float> live [[texture(1)]],
                                   sampler smp [[sampler(0)]]) {
        float2 px = in.uv * u.resolution;
        float2 d = px - u.origin;
        float dist = length(d);
        float2 dir = dist > 0.001 ? d / dist : float2(0.0);

        float prog = saturate(u.time / u.duration);

        // The front starts fast, slows a little, and runs past the far corner.
        float eased = 1.0 - pow(1.0 - prog, 1.7);
        float radius = eased * u.maxRadius * 1.2;

        // The ring broadens as it travels.
        float width = (55.0 + 150.0 * prog) * u.scale;
        float x = (dist - radius) / width;

        // Sharp leading edge, a few damped ripples trailing behind it.
        float env = exp(-x * x * (x > 0.0 ? 1.8 : 0.16));
        float fade = pow(1.0 - prog, 1.4) * smoothstep(0.0, 0.05, prog);
        float height = cos(x * 2.3) * env;
        float slope = sin(x * 2.3) * env;

        // Refract the screen along the wave's slope, splitting the channels
        // slightly for a glassy chromatic edge.
        // Scaled by the ring width so a tight young ring does not fold the image.
        float offset = slope * fade * 0.36 * width;
        float2 shift = dir * offset / u.resolution;
        float3 refracted = float3(
            screen.sample(smp, in.uv - shift * 1.16).r,
            screen.sample(smp, in.uv - shift).g,
            screen.sample(smp, in.uv - shift * 0.84).b);

        // Plasma light: a white-hot core on each crest inside a thick
        // electric-blue band, with fine filaments flickering along the ring.
        float angle = atan2(d.y, d.x);
        float filament = 0.78 + 0.22 * sin(angle * 46.0 + x * 3.0 - u.time * 13.0)
                                     * sin(angle * 19.0 - u.time * 7.0);
        float crest = pow(max(height, 0.0), 2.2);
        float sheen = exp(-x * x * 0.35);
        float3 core = float3(0.80, 0.95, 1.0);
        float3 halo = float3(0.22, 0.62, 1.0);
        float3 light = (core * 0.95 * crest + halo * 0.62 * sheen) * filament * fade;

        // Bloom at the source that dies away quickly.
        float bloomRadius = 300.0 * u.scale;
        float bloom = exp(-(dist * dist) / (bloomRadius * bloomRadius))
                    * exp(-u.time * 4.5) * smoothstep(0.0, 0.06, u.time);
        light += float3(0.62, 0.86, 1.0) * bloom * 0.9;

        float alpha;
        float3 rgb;
        if (u.mainActive < 0.5) {
            alpha = 0.0;
            rgb = float3(0.0);
        } else if (u.hasTexture > 0.5) {
            // Opaque only where the wave actually bends the picture.
            alpha = saturate(env * fade * 8.0);
            rgb = refracted * alpha + light;
        } else {
            // No screenshot: fake depth by shading the troughs.
            alpha = saturate((max(-height, 0.0) * 0.6 + sheen * 0.12) * fade);
            rgb = light;
        }
        // ---- Music effects ----
        // Everything that bends the picture adds to one displacement, so the
        // live screen is sampled once however many pieces overlap.
        float2 bend = float2(0.0);      // pixels
        float cover = 0.0;              // where the bent picture replaces the real one
        float3 glassLight = float3(0.0);
        float3 plainLight = float3(0.0);  // used instead when there is no picture to bend
        float shade = 0.0;
        float3 film = float3(0.0);      // soap film, premultiplied, laid over the picture
        float filmAlpha = 0.0;
        float3 glow = float3(0.0);      // highlights, added last
        float glowAlpha = 0.0;

        for (int i = 0; i < int(u.count); i++) {
            Element e = u.elements[i];
            float age = e.place.z;
            float life = saturate(age / e.place.w);
            float3 tint = e.tint.rgb;
            float kind = e.shape.z;
            float seed = e.shape.w;

            if (kind < 0.5) {
                // Glass ring: a travelling swell with a few ripples behind it.
                float2 rd = px - e.place.xy;
                float rdist = length(rd);
                float radius = (1.0 - pow(1.0 - life, 2.0)) * e.shape.x;
                float width = (34.0 + 90.0 * life) * u.scale * e.shape.y;
                float x = (rdist - radius) / width;
                if (abs(x) > 6.0) continue;
                float2 rdir = rdist > 0.001 ? rd / rdist : float2(0.0);
                float renv = exp(-x * x * (x > 0.0 ? 1.8 : 0.3));
                float rfade = pow(1.0 - life, 1.5) * smoothstep(0.0, 0.04, life) * e.tint.a;
                float h = cos(x * 2.3) * renv;
                float sl = sin(x * 2.3) * renv;
                float rsheen = exp(-x * x * 0.35);

                bend += rdir * sl * rfade * 0.5 * width;
                cover = max(cover, saturate(renv * rfade * 7.0));
                // A thin bright line where the swell catches the light, and
                // a breath of colour in the glass itself.
                glassLight += (float3(1.0) * 0.5 * pow(max(h, 0.0), 6.0) + tint * 0.2 * rsheen) * rfade;

                float rangle = atan2(rd.y, rd.x);
                float rfilament = 0.8 + 0.2 * sin(rangle * 38.0 + x * 3.0 - age * 11.0);
                plainLight += (mix(tint, float3(1.0), 0.55) * 0.9 * pow(max(h, 0.0), 2.2) + tint * 0.6 * rsheen) * rfilament * rfade;
                shade += (max(-h, 0.0) * 0.45 + rsheen * 0.1) * rfade;

            } else if (kind < 1.5) {
                // Soap bubble.
                float sway = sin(age * 1.6 + seed * 40.0) * 16.0 * u.scale;
                float2 c = e.place.xy + e.motion.xy * age + float2(sway, 0.0);
                float grow = 1.0 - exp(-age * 9.0) * cos(age * 13.0);         // springs open
                float pop = saturate((age - (e.place.w - 0.14)) / 0.14);      // last moments
                float swell = 1.0 + 0.07 * exp(-u.beatAge * 7.0);             // breathes with the bass
                float R = max(e.shape.x * grow * swell * (1.0 + 0.3 * pop), 1.0);
                float2 q = (px - c) / R;
                if (dot(q, q) > 1.25) continue;
                float theta = atan2(q.y, q.x);
                q /= 1.0 + 0.022 * sin(3.0 * theta + age * 4.0 + seed * 10.0)
                         + 0.012 * sin(5.0 * theta - age * 6.0);              // never quite round
                float r = length(q);
                float aa = saturate((1.0 - r) * R / 1.5);
                float alive = 1.0 - pop;
                float nz = sqrt(max(1.0 - r * r, 0.0));
                float fresnel = pow(1.0 - nz, 2.0);

                // The shell bends light only near its edge.
                bend += q * r * r * r * R * 0.2 * aa * alive;
                cover = max(cover, aa * saturate(r * r * r * 3.0) * alive);

                // Thin-film colour: the film is thicker low down, swirls slowly,
                // and shows its colours most at grazing angles.
                float thickness = 0.5 + 0.35 * q.y + 0.6 * fresnel
                    + 0.25 * sin(q.x * 3.0 + age * 1.3 + seed * 20.0) * sin(q.y * 4.0 - age * 0.9 + seed * 7.0);
                float3 irid = 0.5 + 0.5 * cos(6.2832 * (thickness * 1.6 + float3(0.0, 0.33, 0.67)));
                irid = mix(irid, tint, 0.2);
                float rim = smoothstep(0.86, 0.985, r);
                float a = aa * alive * saturate(0.05 + 0.5 * fresnel + 0.22 * rim) * e.tint.a;
                float3 colour = mix(irid, float3(1.0), 0.3 * rim);
                film = film * (1.0 - a) + colour * a;
                filmAlpha = filmAlpha + (1.0 - filmAlpha) * a;

                // Reflections: a soft window top-left, its echo bottom-right,
                // and a bright arc along the upper rim.
                float2 d1 = q - float2(-0.40, -0.46);
                float2 d2 = q - float2(0.36, 0.48);
                float window = exp(-(d1.x * d1.x * 1.6 + d1.y * d1.y) / 0.016);
                float echo = exp(-dot(d2, d2) / 0.008);
                float arc = smoothstep(0.78, 0.9, r) * smoothstep(0.985, 0.9, r)
                          * saturate((dot(q / max(r, 0.001), float2(-0.7071, -0.7071)) - 0.55) * 2.6);
                float shine = (0.85 * window + 0.3 * echo + 0.45 * arc) * aa * alive;
                // The pop: a quick bright ring where the skin was.
                float burst = exp(-pow((r - 1.0) * 7.0, 2.0)) * pop * (1.0 - pop) * 2.4;
                glow += float3(1.0) * (shine + burst) * e.tint.a;
                glowAlpha += (shine + burst) * 0.5;

            } else {
                // Edge glow: colour welling up from one side of the screen.
                float edge = e.motion.z;
                float dist = edge < 0.5 ? u.resolution.y - px.y : edge < 1.5 ? px.y
                           : edge < 2.5 ? px.x : u.resolution.x - px.x;
                float along = edge < 1.5 ? px.x : px.y;
                float wave = 0.72 + 0.28 * sin(along * 0.006 / u.scale + u.clock * 1.4 + seed * 30.0)
                                         * sin(along * 0.0023 / u.scale - u.clock * 0.9 + seed * 11.0);
                float g = exp(-dist / max(e.shape.x * wave, 1.0))
                        * smoothstep(0.0, 0.06, life) * pow(1.0 - life, 2.0) * e.tint.a;
                glow += tint * g * 0.95;
                glowAlpha += g * 0.35;
            }
        }

        float3 effect;
        float effectAlpha;
        if (u.hasLive > 0.5) {
            float2 uvShift = bend / u.resolution;
            float3 bent = float3(
                live.sample(smp, in.uv - uvShift * 1.14).r,
                live.sample(smp, in.uv - uvShift).g,
                live.sample(smp, in.uv - uvShift * 0.86).b);
            effect = bent * cover + glassLight;
            effectAlpha = cover;
        } else {
            effect = plainLight;
            effectAlpha = saturate(shade);
        }
        effect = effect * (1.0 - filmAlpha) + film;
        effectAlpha = effectAlpha + (1.0 - effectAlpha) * filmAlpha;
        effect += glow;
        effectAlpha = saturate(effectAlpha + glowAlpha);

        rgb = rgb * (1.0 - effectAlpha) + effect;
        alpha = alpha + (1.0 - alpha) * effectAlpha;
        return float4(saturate(rgb), saturate(alpha));
    }
    """
}
