struct VertexOutput_0
{
    @builtin(position) position_0 : vec4<f32>,
    @location(0) color_0 : vec4<f32>,
    @location(2) uv_0 : vec2<f32>,
    @interpolate(flat) @location(1) mode_0 : f32,
};

struct vertexInput_0
{
    @location(0) position_1 : vec2<f32>,
    @location(1) color_1 : vec4<f32>,
    @location(2) uv_1 : vec2<f32>,
    @location(3) mode_1 : f32,
};

@vertex
fn vertexMain( _S1 : vertexInput_0) -> VertexOutput_0
{
    var output_0 : VertexOutput_0;
    output_0.position_0 = vec4<f32>(_S1.position_1, 0.0f, 1.0f);
    output_0.color_0 = _S1.color_1;
    output_0.uv_0 = _S1.uv_1;
    output_0.mode_0 = _S1.mode_1;
    return output_0;
}

