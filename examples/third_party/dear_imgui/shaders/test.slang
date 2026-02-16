
import "../../../shared.slang";

struct Vertex
{
    float4 pos;
    float4 color;
}

struct VertexData
{
    Vertex* verts;
}

struct VertexOutput
{
    float4 pos : SV_Position;
    float4 color : TEXCOORD0;
}

[shader("vertex")]
VertexOutput vertexMain(uint vert_id : SV_VertexID, GraphicsPipelineData<VertexData> data)
{
    VertexOutput vert_out;
    vert_out.pos = float4(data.vert.verts[vert_id].pos.xyz, 1.0);
    vert_out.color = data.vert.verts[vert_id].color;
    return vert_out;
}

[shader("fragment")]
float4 fragmentMain(float4 color : TEXCOORD0) : SV_Target
{
    return color;
}
