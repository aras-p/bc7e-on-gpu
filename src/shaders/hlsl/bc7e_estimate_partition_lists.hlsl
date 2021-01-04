#include "bc7e.hlsl"

// First pass: figures out mode partition lists
// (writes them into the output texture buffer)
// - Up to 4 partitions for mode; partition indices encoded in 6 bits each, then list size
// - x: mode 7
// - y: mode 1|3
// - z: mode 0
// - w: mode 2
[numthreads(GROUP_SIZE, 1, 1)]
void bc7e_estimate_partition_lists(uint3 id : SV_DispatchThreadID)
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

    uint4 lists = 0;
#if !defined(OPT_OPAQUE_ONLY)
    if (has_alpha)
        lists = get_lists_alpha(pixels);
    else
#endif
    {
#ifdef OPT_ULTRAFAST_ONLY
        ;
#else
        if (glob_is_mode6_only())
            ;
        else
            lists = get_lists_opaque(pixels);
#endif
    }
    uint block_index = id.y * g_widthInBlocks + id.x;
    s_BufOutput[block_index] = lists;
    s_BufTemp[block_index].m_error = UINT_MAX;
}
