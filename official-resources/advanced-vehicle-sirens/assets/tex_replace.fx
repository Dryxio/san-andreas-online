//---------------------------------------------------------------------
// Advanced Vehicle Sirens (AVS) - Texture Replacement Shader
// Replaces the dormant unlit lightbar texture with the authentic
// illuminated texture crafted by the vehicle modeler.
//---------------------------------------------------------------------

texture gTexture;

sampler Sampler0 = sampler_state
{
    Texture = (gTexture);
    MinFilter = Linear;
    MagFilter = Linear;
    MipFilter = Linear;
    AddressU = Wrap;
    AddressV = Wrap;
};

struct PSInput
{
    float4 Position : POSITION;
    float4 Diffuse : COLOR0;
    float2 TexCoord : TEXCOORD0;
};

float4 PixelShaderFunction(PSInput input) : COLOR0
{
    float4 texColor = tex2D(Sampler0, input.TexCoord);
    return texColor * input.Diffuse;
}

technique TexReplace
{
    pass P0
    {
        AlphaBlendEnable = true;
        SrcBlend = SrcAlpha;
        DestBlend = InvSrcAlpha;
        PixelShader = compile ps_2_0 PixelShaderFunction();
    }
}
