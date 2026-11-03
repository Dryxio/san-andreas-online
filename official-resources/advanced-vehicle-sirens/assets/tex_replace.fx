//---------------------------------------------------------------------
// Advanced Vehicle Sirens (AVS) - Texture Replacement Shader
// Replaces the dormant unlit lightbar texture with the authentic
// illuminated texture crafted by the vehicle modeler.
//---------------------------------------------------------------------

texture gTexture;

technique TexReplace
{
    pass P0
    {
        Texture[0] = gTexture;
    }
}
