//---------------------------------------------------------------------
// Advanced Vehicle Sirens (AVS) - Pure Texture Replacement Shader
// Replaces the unlit material with the pure, untainted illuminated texture
// without vehicle diffuse color contamination or cyan/blue tinting.
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

float4 PixelShaderFunction(float2 TexCoord : TEXCOORD0) : COLOR0
{
    return tex2D(Sampler0, TexCoord);
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
