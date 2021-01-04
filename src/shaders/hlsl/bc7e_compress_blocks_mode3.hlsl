#include "bc7e.hlsl"

[numthreads(GROUP_SIZE, 1, 1)]
void bc7e_compress_blocks_mode3(uint3 id : SV_DispatchThreadID)
{
    if (id.x >= g_widthInBlocks || id.y >= g_heightInBlocks)
        return;

    color_cell_compressor_params params;
    color_cell_compressor_params_clear(params);
    params.m_weights = g_params.m_weights;

    color_quad_i pixels[16];
    float lo_a, hi_a;
    load_pixel_block(pixels, lo_a, hi_a, id, g_width);
    const bool has_alpha = (lo_a < 255);

    uint block_index = id.y * g_widthInBlocks + id.x;
    uint prev_error = s_BufTemp[block_index].m_error;
    bc7_optimization_results res = (bc7_optimization_results)0;
    res.m_error = prev_error;

#if !defined(OPT_OPAQUE_ONLY)
    if (has_alpha)
    {
        return;
    }
    else
#endif
    {
        if (!(g_params.m_opaq_use_modes0123 & 0xFF000000))
            return;
        uint4 lists = s_BufOutput[block_index];
        handle_opaque_block_mode3(res, pixels, params, lists);
    }
    if (res.m_error < prev_error)
        s_BufTemp[block_index] = res;
}