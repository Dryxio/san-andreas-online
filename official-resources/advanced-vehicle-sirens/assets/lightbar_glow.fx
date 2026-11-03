//---------------------------------------------------------------------
// Advanced Vehicle Sirens (AVS) - Lightbar Lens Emissive Glow Shader
//
// Automatically illuminates vehicle lightbar lenses and beacon covers
// when sirens are activated, eliminating the dull flat-plastic look
// without affecting the surrounding vehicle body paint or glass.
//---------------------------------------------------------------------

technique LightbarEmissive
{
    pass P0
    {
        Lighting = false;
        AlphaBlendEnable = true;
        SrcBlend = SrcAlpha;
        DestBlend = InvSrcAlpha;
        ColorOp[0] = Modulate2X;
        ColorArg1[0] = Texture;
        ColorArg2[0] = Current;
    }
}
