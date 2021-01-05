#include "bc7e.hlsl"

[numthreads(GROUP_SIZE, 1, 1)]
void bc7e_compress_blocks_mode4_opaq(uint3 id : SV_DispatchThreadID)
{
#if !defined(OPT_ULTRAFAST_ONLY)
    if (id.x >= g_widthInBlocks || id.y >= g_heightInBlocks)
        return;

    color_quad_i pixels[16];
    float lo_a, hi_a;
    load_pixel_block(pixels, lo_a, hi_a, id, g_width);
    const bool has_alpha = (lo_a < 255);
    if (has_alpha)
        return;
    if (glob_is_mode6_only() || glob_is_perceptual() || !(g_params.m_opaq_use_modes456 & 0xFF))
        return;

    uint block_index = id.y * g_widthInBlocks + id.x;
    uint prev_error = s_BufTemp[block_index].m_error;
    bc7_optimization_results res = (bc7_optimization_results)0;
    res.m_error = prev_error;

    handle_block_mode4(res, pixels, 255, 255, 4);
    if (res.m_error < prev_error)
        s_BufTemp[block_index] = res;
#endif // #if !defined(OPT_ULTRAFAST_ONLY)
}
