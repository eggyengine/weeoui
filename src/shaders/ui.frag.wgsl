@binding(0) @group(0) var fontAtlas_0 : texture_2d<f32>;

@binding(1) @group(0) var fontSampler_0 : sampler;

@binding(2) @group(0) var colorAtlas_0 : texture_2d<f32>;

fn edgeCoverage_0( sample_0 : f32,  edge_0 : f32,  width_0 : f32) -> f32
{
    return saturate((sample_0 - edge_0) / width_0 + 0.5f);
}

struct pixelOutput_0
{
    @location(0) output_0 : vec4<f32>,
};

struct pixelInput_0
{
    @location(0) color_0 : vec4<f32>,
    @location(2) uv_0 : vec2<f32>,
    @interpolate(flat) @location(1) mode_0 : f32,
};

@fragment
fn fragmentMain( _S1 : pixelInput_0, @builtin(position) position_0 : vec4<f32>) -> pixelOutput_0
{
    var _S2 : f32 = (textureSample((fontAtlas_0), (fontSampler_0), (_S1.uv_0)).x);
    var color_1 : vec4<f32> = (textureSample((colorAtlas_0), (fontSampler_0), (_S1.uv_0)));
    var atlasWidth_0 : u32;
    var atlasHeight_0 : u32;
    {var dim = textureDimensions((fontAtlas_0));((atlasWidth_0)) = dim.x;((atlasHeight_0)) = dim.y;};
    var texelsPerPixel_0 : vec2<f32> = (fwidth((_S1.uv_0 * vec2<f32>(f32(atlasWidth_0), f32(atlasHeight_0)))));
    var _S3 : f32 = max(0.00390625f * (texelsPerPixel_0.x + texelsPerPixel_0.y), 0.00000999999974738f);
    if((_S1.mode_0) < -0.5f)
    {
        var _S4 : pixelOutput_0 = pixelOutput_0( vec4<f32>(color_1.xyz, color_1.w * _S1.color_0.w) );
        return _S4;
    }
    var coverage_0 : f32;
    if((_S1.mode_0) > 0.5f)
    {
        if((_S1.mode_0) > 1.0f)
        {
            coverage_0 = edgeCoverage_0(_S2, 0.5f + 0.5f * (_S1.mode_0 - 1.0f), _S3);
        }
        else
        {
            coverage_0 = 0.0f;
        }
        coverage_0 = edgeCoverage_0(_S2, 0.5f, _S3) - coverage_0;
    }
    else
    {
        coverage_0 = _S2;
    }
    var _S5 : pixelOutput_0 = pixelOutput_0( vec4<f32>(_S1.color_0.xyz, _S1.color_0.w * coverage_0) );
    return _S5;
}

