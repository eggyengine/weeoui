struct VertexInput {
    [[vk::location(0)]] float2 position : POSITION;
    [[vk::location(1)]] float4 color : COLOR0;
    [[vk::location(2)]] float2 uv : TEXCOORD0;
    [[vk::location(3)]] float mode : TEXCOORD1;
};
struct VertexOutput {
    float4 position : SV_Position;
    [[vk::location(0)]] float4 color : COLOR0;
    [[vk::location(1)]] float2 uv : TEXCOORD0;
    [[vk::location(2)]] nointerpolation float mode : TEXCOORD1;
};

[[vk::binding(0, 0)]] Texture2D<float> fontAtlas : register(t0, space0);
[[vk::binding(1, 0)]] SamplerState fontSampler : register(s1, space0);
[[vk::binding(2, 0)]] Texture2D<float4> colorAtlas : register(t2, space0);

[shader("vertex")]
VertexOutput vertexMain(VertexInput input) {
    VertexOutput output;
    output.position = float4(input.position, 0.0, 1.0);
    output.color = input.color;
    output.uv = input.uv;
    output.mode = input.mode;
    return output;
}

// Coverage of a distance-field sample against `edge`, one screen pixel wide at any scale.
float edgeCoverage(float sample, float edge, float width) {
    return saturate((sample - edge) / width + 0.5);
}

[shader("pixel")]
float4 fragmentMain(VertexOutput input) : SV_Target0 {
    // Sample and differentiate outside branches: derivatives need uniform control flow.
    float sample = fontAtlas.Sample(fontSampler, input.uv).r;
    float4 color = colorAtlas.Sample(fontSampler, input.uv);
    float width = max(fwidth(sample), 1e-5);
    if (input.mode < -0.5) return float4(color.rgb, color.a * input.color.a);
    float coverage = sample;
    if (input.mode > 0.5) {
        // The field falls 0.5 per radius, so a ring f radii thick ends at 0.5 + 0.5 f.
        float inner = input.mode > 1.0 ? edgeCoverage(sample, 0.5 + 0.5 * (input.mode - 1.0), width) : 0.0;
        coverage = edgeCoverage(sample, 0.5, width) - inner;
    }
    return float4(input.color.rgb, input.color.a * coverage);
}
