#include "bc7e.hlsl"

[numthreads(GROUP_SIZE, 1, 1)]
void bc7e_encode_blocks(uint3 id : SV_DispatchThreadID)
{
    if (id.x >= g_widthInBlocks || id.y >= g_heightInBlocks)
        return;

    uint block_index = id.y * g_widthInBlocks + id.x;
    bc7_optimization_results res = s_BufTemp[block_index];
    s_BufOutput[block_index] = encode_bc7_block(res);
}
