//---------------------------------------------------------------------
// Advanced Vehicle Sirens (AVS) - Dynamic Strobe Shader
// 
// Provides authentic individual bulb/reflector strobing in standard MTA:SA:
// - Decodes AVS standard material encoding: G == B with R < G
//   where (Diffuse.r / Diffuse.g * 255.0) specifies the exact dummy group ID (1..42)
//   (Ratio-normalized for complete daytime/nighttime lighting invariance)
// - Decodes IVF material encoding: G < 0.05 && B < 0.05 && R > 0.1
//   where (256.0 - round(Diffuse.r * 255.0)) specifies the dummy group ID
// - When the dummy is ON: blends in the illuminated texture (gTextureOn)
// - When the dummy is OFF: renders the dark unlit texture (gTextureOff)
// - Supports global pulsing for unencoded materials (gGlobalOn)
//---------------------------------------------------------------------

texture gTextureOff;
texture gTextureOn;

// Array of active strobe states for dummies 0..63 (1.0 = ON, 0.0 = OFF)
float gDummyStates[64];

// Global on/off state for unencoded materials (1.0 = ON, 0.0 = OFF)
float gGlobalOn = 1.0;

sampler SamplerOff = sampler_state
{
    Texture = (gTextureOff);
    MinFilter = Linear;
    MagFilter = Linear;
    MipFilter = Linear;
    AddressU = Wrap;
    AddressV = Wrap;
};

sampler SamplerOn = sampler_state
{
    Texture = (gTextureOn);
    MinFilter = Linear;
    MagFilter = Linear;
    MipFilter = Linear;
    AddressU = Wrap;
    AddressV = Wrap;
};

struct PS_INPUT
{
    float2 TexCoord : TEXCOORD0;
    float4 Diffuse  : COLOR0;
};

float4 PixelShader30(PS_INPUT input) : COLOR0
{
    float4 colOff = tex2D(SamplerOff, input.TexCoord);
    float4 colOn  = tex2D(SamplerOn,  input.TexCoord);

    float isOn = gGlobalOn;

    // 1. AVS Standard Material Encoding: G == B and R < G (lighting-invariant ratio)
    if (abs(input.Diffuse.g - input.Diffuse.b) < 0.06 && input.Diffuse.g > 0.04 && input.Diffuse.r < input.Diffuse.g * 0.75)
    {
        float normR = input.Diffuse.r / input.Diffuse.g;
        int id = (int)round(normR * 255.0);
        if (id > 0 && id < 64)
        {
            isOn = gDummyStates[id];
        }
    }
    // 2. IVF Material Encoding: G == 0, B == 0, R > 0.1 (dummyId = 256 - R)
    else if (input.Diffuse.g < 0.05 && input.Diffuse.b < 0.05 && input.Diffuse.r > 0.1)
    {
        int id = (int)(256.0 - round(input.Diffuse.r * 255.0));
        if (id > 0 && id < 64)
        {
            isOn = gDummyStates[id];
        }
    }

    return lerp(colOff, colOn, isOn);
}

float4 PixelShader20(PS_INPUT input) : COLOR0
{
    float4 colOff = tex2D(SamplerOff, input.TexCoord);
    float4 colOn  = tex2D(SamplerOn,  input.TexCoord);
    return lerp(colOff, colOn, gGlobalOn);
}

technique DynamicStrobe
{
    pass P0
    {
        AlphaBlendEnable = true;
        SrcBlend = SrcAlpha;
        DestBlend = InvSrcAlpha;
        PixelShader = compile ps_3_0 PixelShader30();
    }
}

technique DynamicStrobeFallback
{
    pass P0
    {
        AlphaBlendEnable = true;
        SrcBlend = SrcAlpha;
        DestBlend = InvSrcAlpha;
        PixelShader = compile ps_2_0 PixelShader20();
    }
}
