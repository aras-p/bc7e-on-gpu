#include "bc7e.hlsl"

[numthreads(GROUP_SIZE, 1, 1)]
void bc7e_compress_blocks_mode6(uint3 id : SV_DispatchThreadID)
{
    if (id.x >= g_widthInBlocks || id.y >= g_heightInBlocks)
        return;

    color_quad_i pixels[16];
    float lo_a, hi_a;
    load_pixel_block(pixels, lo_a, hi_a, id, g_width);
    const bool has_alpha = (lo_a < 255);
    if (has_alpha && !(g_params.m_alpha_use_modes4567 & 0xFF0000))
        return;
    if (!has_alpha && !(g_params.m_opaq_use_modes456 & 0xFF0000))
        return;

    uint block_index = id.y * g_widthInBlocks + id.x;
    uint prev_error = s_BufTemp[block_index].m_error;
    bc7_optimization_results res = (bc7_optimization_results)0;
    res.m_error = prev_error;

    handle_block_mode6(res, pixels, has_alpha);
    if (res.m_error < prev_error)
        s_BufTemp[block_index] = res;
}
