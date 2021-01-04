
#define GROUP_SIZE 64

//#define precise

#define assert(x)
#define select(a, b, c) ((c) ? (b) : (a))
#define max3(a, b, c) (max((a), max((b), (c))))

//#define OPT_ULTRAFAST_ONLY // disables Mode 7; for opaque only uses Mode 6
#define OPT_FASTMODES_ONLY // disables m_uber_level being non-zero paths
//#define OPT_OPAQUE_ONLY // disables all transparency handling

#define BC7E_2SUBSET_CHECKERBOARD_PARTITION_INDEX (34)
#define BC7E_BLOCK_SIZE (16)
#define BC7E_MAX_PARTITIONS0 (16)
#define BC7E_MAX_PARTITIONS1 (64)
#define BC7E_MAX_PARTITIONS2 (64)
#define BC7E_MAX_PARTITIONS3 (64)
#define BC7E_MAX_PARTITIONS7 (64)
#define BC7E_MAX_UBER_LEVEL (4)

#ifndef UINT_MAX
#define UINT_MAX (0xFFFFFFFFU)
#endif

struct bc7e_compress_block_params // note: should match C++ code struct
{
    uint4 m_max_partitions_mode[2];

    uint4    m_weights;

    uint m_uber_level;
    uint m_refinement_passes;
    
    uint m_mode4_rotation_mask;
    uint m_mode4_index_mask;
    uint m_mode5_rotation_mask;
    uint m_uber1_mask;
    
    uint m_bools; // m_perceptual, m_pbit_search, m_mode6_only, m_unused0
    
    uint m_opaq_max_mode13_partitions_to_try;
    uint m_opaq_max_mode0_partitions_to_try;
    uint m_opaq_max_mode2_partitions_to_try;
    uint m_opaq_use_modes0123; // one byte per bool
    uint m_opaq_use_modes456; // one byte per bool

    uint m_alpha_max_mode7_partitions_to_try;
    uint m_alpha_mode67_error_weight_mul0, m_alpha_mode67_error_weight_mul1, m_alpha_mode67_error_weight_mul2, m_alpha_mode67_error_weight_mul3;
    uint m_alpha_use_modes4567; // one byte per bool
    uint m_alpha_use_mode45_rotation; // one byte per bool
};

cbuffer Globals : register(b0) // note: should match C++ code struct
{
    uint g_width, g_height;
    uint g_widthInBlocks, g_heightInBlocks;
    bc7e_compress_block_params g_params;
};

bool glob_is_perceptual() { return (g_params.m_bools & 0xFF) != 0; }
bool glob_is_pbit_search() { return (g_params.m_bools & 0xFF00) != 0; }
bool glob_is_mode6_only() { return (g_params.m_bools & 0xFF0000) != 0; }


static inline void swapu(inout uint a, inout uint b) { uint t = a; a = b; b = t; }
static inline void swapf(inout float a, inout float b) { float t = a; a = b; b = t; }

static inline precise float square(precise float s) { return s * s; }

typedef int4 color_quad_i;
typedef precise float4 color_quad_f;

static inline bool color_quad_i_equals(color_quad_i a, color_quad_i b)
{
    return all(a == b);
}

static inline bool color_quad_i_notequals(color_quad_i a, color_quad_i b)
{
    return !color_quad_i_equals(a, b);
}

typedef precise float4 vec4F;

static inline precise float dot4(precise float4 a, precise float4 b)
{
    return a.x * b.x + a.y * b.y + a.z * b.z + a.w * b.w;
}

static inline vec4F vec4F_normalize(vec4F v)
{
    precise float lensq = dot4(v, v);
    if (lensq != 0.0f)
    {
        precise float invlen = 1.0f / sqrt(lensq);
        return v * invlen;
    }
    return v;
}

static const int g_bc7_partition1[16] = { 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0 };

static const int g_bc7_partition2[64][16] =
{
    {0,0,1,1,0,0,1,1,0,0,1,1,0,0,1,1},        {0,0,0,1,0,0,0,1,0,0,0,1,0,0,0,1},        {0,1,1,1,0,1,1,1,0,1,1,1,0,1,1,1},        {0,0,0,1,0,0,1,1,0,0,1,1,0,1,1,1},        {0,0,0,0,0,0,0,1,0,0,0,1,0,0,1,1},        {0,0,1,1,0,1,1,1,0,1,1,1,1,1,1,1},        {0,0,0,1,0,0,1,1,0,1,1,1,1,1,1,1},        {0,0,0,0,0,0,0,1,0,0,1,1,0,1,1,1},
    {0,0,0,0,0,0,0,0,0,0,0,1,0,0,1,1},        {0,0,1,1,0,1,1,1,1,1,1,1,1,1,1,1},        {0,0,0,0,0,0,0,1,0,1,1,1,1,1,1,1},        {0,0,0,0,0,0,0,0,0,0,0,1,0,1,1,1},        {0,0,0,1,0,1,1,1,1,1,1,1,1,1,1,1},        {0,0,0,0,0,0,0,0,1,1,1,1,1,1,1,1},        {0,0,0,0,1,1,1,1,1,1,1,1,1,1,1,1},        {0,0,0,0,0,0,0,0,0,0,0,0,1,1,1,1},
    {0,0,0,0,1,0,0,0,1,1,1,0,1,1,1,1},        {0,1,1,1,0,0,0,1,0,0,0,0,0,0,0,0},        {0,0,0,0,0,0,0,0,1,0,0,0,1,1,1,0},        {0,1,1,1,0,0,1,1,0,0,0,1,0,0,0,0},        {0,0,1,1,0,0,0,1,0,0,0,0,0,0,0,0},        {0,0,0,0,1,0,0,0,1,1,0,0,1,1,1,0},        {0,0,0,0,0,0,0,0,1,0,0,0,1,1,0,0},        {0,1,1,1,0,0,1,1,0,0,1,1,0,0,0,1},
    {0,0,1,1,0,0,0,1,0,0,0,1,0,0,0,0},        {0,0,0,0,1,0,0,0,1,0,0,0,1,1,0,0},        {0,1,1,0,0,1,1,0,0,1,1,0,0,1,1,0},        {0,0,1,1,0,1,1,0,0,1,1,0,1,1,0,0},        {0,0,0,1,0,1,1,1,1,1,1,0,1,0,0,0},        {0,0,0,0,1,1,1,1,1,1,1,1,0,0,0,0},        {0,1,1,1,0,0,0,1,1,0,0,0,1,1,1,0},        {0,0,1,1,1,0,0,1,1,0,0,1,1,1,0,0},
    {0,1,0,1,0,1,0,1,0,1,0,1,0,1,0,1},        {0,0,0,0,1,1,1,1,0,0,0,0,1,1,1,1},        {0,1,0,1,1,0,1,0,0,1,0,1,1,0,1,0},        {0,0,1,1,0,0,1,1,1,1,0,0,1,1,0,0},        {0,0,1,1,1,1,0,0,0,0,1,1,1,1,0,0},        {0,1,0,1,0,1,0,1,1,0,1,0,1,0,1,0},        {0,1,1,0,1,0,0,1,0,1,1,0,1,0,0,1},        {0,1,0,1,1,0,1,0,1,0,1,0,0,1,0,1},
    {0,1,1,1,0,0,1,1,1,1,0,0,1,1,1,0},        {0,0,0,1,0,0,1,1,1,1,0,0,1,0,0,0},        {0,0,1,1,0,0,1,0,0,1,0,0,1,1,0,0},        {0,0,1,1,1,0,1,1,1,1,0,1,1,1,0,0},        {0,1,1,0,1,0,0,1,1,0,0,1,0,1,1,0},        {0,0,1,1,1,1,0,0,1,1,0,0,0,0,1,1},        {0,1,1,0,0,1,1,0,1,0,0,1,1,0,0,1},        {0,0,0,0,0,1,1,0,0,1,1,0,0,0,0,0},
    {0,1,0,0,1,1,1,0,0,1,0,0,0,0,0,0},        {0,0,1,0,0,1,1,1,0,0,1,0,0,0,0,0},        {0,0,0,0,0,0,1,0,0,1,1,1,0,0,1,0},        {0,0,0,0,0,1,0,0,1,1,1,0,0,1,0,0},        {0,1,1,0,1,1,0,0,1,0,0,1,0,0,1,1},        {0,0,1,1,0,1,1,0,1,1,0,0,1,0,0,1},        {0,1,1,0,0,0,1,1,1,0,0,1,1,1,0,0},        {0,0,1,1,1,0,0,1,1,1,0,0,0,1,1,0},
    {0,1,1,0,1,1,0,0,1,1,0,0,1,0,0,1},        {0,1,1,0,0,0,1,1,0,0,1,1,1,0,0,1},        {0,1,1,1,1,1,1,0,1,0,0,0,0,0,0,1},        {0,0,0,1,1,0,0,0,1,1,1,0,0,1,1,1},        {0,0,0,0,1,1,1,1,0,0,1,1,0,0,1,1},        {0,0,1,1,0,0,1,1,1,1,1,1,0,0,0,0},        {0,0,1,0,0,0,1,0,1,1,1,0,1,1,1,0},        {0,1,0,0,0,1,0,0,0,1,1,1,0,1,1,1}
};

static const int g_bc7_table_anchor_index_second_subset[64] =
{
    15,15,15,15,15,15,15,15,        15,15,15,15,15,15,15,15,        15, 2, 8, 2, 2, 8, 8,15,        2, 8, 2, 2, 8, 8, 2, 2,        15,15, 6, 8, 2, 8,15,15,        2, 8, 2, 2, 2,15,15, 6,        6, 2, 6, 8,15,15, 2, 2,        15,15,15,15,15, 2, 2,15
};

static const int g_bc7_partition3[64][16] =
{
    {0,0,1,1,0,0,1,1,0,2,2,1,2,2,2,2},        {0,0,0,1,0,0,1,1,2,2,1,1,2,2,2,1},        {0,0,0,0,2,0,0,1,2,2,1,1,2,2,1,1},        {0,2,2,2,0,0,2,2,0,0,1,1,0,1,1,1},        {0,0,0,0,0,0,0,0,1,1,2,2,1,1,2,2},        {0,0,1,1,0,0,1,1,0,0,2,2,0,0,2,2},        {0,0,2,2,0,0,2,2,1,1,1,1,1,1,1,1},        {0,0,1,1,0,0,1,1,2,2,1,1,2,2,1,1},
    {0,0,0,0,0,0,0,0,1,1,1,1,2,2,2,2},        {0,0,0,0,1,1,1,1,1,1,1,1,2,2,2,2},        {0,0,0,0,1,1,1,1,2,2,2,2,2,2,2,2},        {0,0,1,2,0,0,1,2,0,0,1,2,0,0,1,2},        {0,1,1,2,0,1,1,2,0,1,1,2,0,1,1,2},        {0,1,2,2,0,1,2,2,0,1,2,2,0,1,2,2},        {0,0,1,1,0,1,1,2,1,1,2,2,1,2,2,2},        {0,0,1,1,2,0,0,1,2,2,0,0,2,2,2,0},
    {0,0,0,1,0,0,1,1,0,1,1,2,1,1,2,2},        {0,1,1,1,0,0,1,1,2,0,0,1,2,2,0,0},        {0,0,0,0,1,1,2,2,1,1,2,2,1,1,2,2},        {0,0,2,2,0,0,2,2,0,0,2,2,1,1,1,1},        {0,1,1,1,0,1,1,1,0,2,2,2,0,2,2,2},        {0,0,0,1,0,0,0,1,2,2,2,1,2,2,2,1},        {0,0,0,0,0,0,1,1,0,1,2,2,0,1,2,2},        {0,0,0,0,1,1,0,0,2,2,1,0,2,2,1,0},
    {0,1,2,2,0,1,2,2,0,0,1,1,0,0,0,0},        {0,0,1,2,0,0,1,2,1,1,2,2,2,2,2,2},        {0,1,1,0,1,2,2,1,1,2,2,1,0,1,1,0},        {0,0,0,0,0,1,1,0,1,2,2,1,1,2,2,1},        {0,0,2,2,1,1,0,2,1,1,0,2,0,0,2,2},        {0,1,1,0,0,1,1,0,2,0,0,2,2,2,2,2},        {0,0,1,1,0,1,2,2,0,1,2,2,0,0,1,1},        {0,0,0,0,2,0,0,0,2,2,1,1,2,2,2,1},
    {0,0,0,0,0,0,0,2,1,1,2,2,1,2,2,2},        {0,2,2,2,0,0,2,2,0,0,1,2,0,0,1,1},        {0,0,1,1,0,0,1,2,0,0,2,2,0,2,2,2},        {0,1,2,0,0,1,2,0,0,1,2,0,0,1,2,0},        {0,0,0,0,1,1,1,1,2,2,2,2,0,0,0,0},        {0,1,2,0,1,2,0,1,2,0,1,2,0,1,2,0},        {0,1,2,0,2,0,1,2,1,2,0,1,0,1,2,0},        {0,0,1,1,2,2,0,0,1,1,2,2,0,0,1,1},
    {0,0,1,1,1,1,2,2,2,2,0,0,0,0,1,1},        {0,1,0,1,0,1,0,1,2,2,2,2,2,2,2,2},        {0,0,0,0,0,0,0,0,2,1,2,1,2,1,2,1},        {0,0,2,2,1,1,2,2,0,0,2,2,1,1,2,2},        {0,0,2,2,0,0,1,1,0,0,2,2,0,0,1,1},        {0,2,2,0,1,2,2,1,0,2,2,0,1,2,2,1},        {0,1,0,1,2,2,2,2,2,2,2,2,0,1,0,1},        {0,0,0,0,2,1,2,1,2,1,2,1,2,1,2,1},
    {0,1,0,1,0,1,0,1,0,1,0,1,2,2,2,2},        {0,2,2,2,0,1,1,1,0,2,2,2,0,1,1,1},        {0,0,0,2,1,1,1,2,0,0,0,2,1,1,1,2},        {0,0,0,0,2,1,1,2,2,1,1,2,2,1,1,2},        {0,2,2,2,0,1,1,1,0,1,1,1,0,2,2,2},        {0,0,0,2,1,1,1,2,1,1,1,2,0,0,0,2},        {0,1,1,0,0,1,1,0,0,1,1,0,2,2,2,2},        {0,0,0,0,0,0,0,0,2,1,1,2,2,1,1,2},
    {0,1,1,0,0,1,1,0,2,2,2,2,2,2,2,2},        {0,0,2,2,0,0,1,1,0,0,1,1,0,0,2,2},        {0,0,2,2,1,1,2,2,1,1,2,2,0,0,2,2},        {0,0,0,0,0,0,0,0,0,0,0,0,2,1,1,2},        {0,0,0,2,0,0,0,1,0,0,0,2,0,0,0,1},        {0,2,2,2,1,2,2,2,0,2,2,2,1,2,2,2},        {0,1,0,1,2,2,2,2,2,2,2,2,2,2,2,2},        {0,1,1,1,2,0,1,1,2,2,0,1,2,2,2,0},
};

static const int g_bc7_table_anchor_index_third_subset_1[64] =
{
    3, 3,15,15, 8, 3,15,15,        8, 8, 6, 6, 6, 5, 3, 3,        3, 3, 8,15, 3, 3, 6,10,        5, 8, 8, 6, 8, 5,15,15,        8,15, 3, 5, 6,10, 8,15,        15, 3,15, 5,15,15,15,15,        3,15, 5, 5, 5, 8, 5,10,        5,10, 8,13,15,12, 3, 3
};

static const int g_bc7_table_anchor_index_third_subset_2[64] =
{
    15, 8, 8, 3,15,15, 3, 8,        15,15,15,15,15,15,15, 8,        15, 8,15, 3,15, 8,15, 8,        3,15, 6,10,15,15,10, 8,        15, 3,15,10,10, 8, 9,10,        6,15, 8,15, 3, 6, 6, 8,        15, 3,15,15,15,15,15,15,        15,15,15,15, 3,15,15, 8
};

static const int g_bc7_num_subsets[8] = { 3, 2, 3, 2, 1, 1, 1, 2 };
static const int g_bc7_partition_bits[8] = { 4, 6, 6, 6, 0, 0, 0, 6 };
static const int g_bc7_color_index_bitcount[8] = { 3, 3, 2, 2, 2, 2, 4, 2 };
static int get_bc7_color_index_size(int mode, int index_selection_bit) { return g_bc7_color_index_bitcount[mode] + index_selection_bit; }
static const int g_bc7_alpha_index_bitcount[8] = { 0, 0, 0, 0, 3, 2, 4, 2 };
static int get_bc7_alpha_index_size(int mode, int index_selection_bit) { return g_bc7_alpha_index_bitcount[mode] - index_selection_bit; }
static const int g_bc7_mode_has_p_bits[8] = { 1, 1, 0, 1, 0, 0, 1, 1 };
static const int g_bc7_mode_has_shared_p_bits[8] = { 0, 1, 0, 0, 0, 0, 0, 0 };
static const int g_bc7_color_precision_table[8] = { 4, 6, 5, 7, 5, 7, 7, 5 };
static const int g_bc7_alpha_precision_table[8] = { 0, 0, 0, 0, 6, 8, 7, 5 };
static bool get_bc7_mode_has_seperate_alpha_selectors(int mode) { return (mode == 4) || (mode == 5); }

typedef uint endpoint_err; // 16bit error, 8bit lo, 8bit hi

uint endpoint_get_err(uint data)
{
    return data & 0xFFFF;
}
uint endpoint_get_lo(uint data)
{
    return (data >> 16) & 0xFF;
}
uint endpoint_get_hi(uint data)
{
    return data >> 24;
}

#define kBC7Weights2Index 0
#define kBC7Weights3Index 4
#define kBC7Weights4Index 12

/*
// Basically it's this layout, just spelled out manually into a buffer.
struct LookupTables // note: should match C++ code struct
{
    // optimal endpoint tables
    endpoint_err mode_1[256][2]; // [c][pbit]
    endpoint_err mode_7[256][2][2]; // [c][hp][lp]
    endpoint_err mode_6[256][2][2]; // [c][hp][lp]
    uint mode_4_3[256]; // [c]
    uint mode_4_2[256]; // [c]
    endpoint_err mode_0[256][2][2]; // [c][hp][lp]

    // weights (what was g_bc7_weights2, g_bc7_weights3, g_bc7_weights4 in ISPC)
    uint g_bc7_weights[4+8+16];
    // Precomputed weight constants used during least fit determination. For each entry in g_bc7_weights[]: w * w, (1.0f - w) * w, (1.0f - w) * (1.0f - w), w
    // (what was g_bc7_weights2x, g_bc7_weights3x, g_bc7_weights4x in ISPC)
    float4 g_bc7_weightsx[4+8+16];
};
*/
StructuredBuffer<uint> s_Tables : register(t4);
uint get_table_mode1(uint c, uint pbit) { return s_Tables[c * 2 + pbit]; }
uint get_table_mode7(uint c, uint hp, uint lp) { return s_Tables[512 + c * 4 + hp * 2 + lp]; }
uint get_table_mode6(uint c, uint hp, uint lp) { return s_Tables[1536 + c * 4 + hp * 2 + lp]; }
uint get_table_mode4_3(uint c) { return s_Tables[2560 + c]; }
uint get_table_mode4_2(uint c) { return s_Tables[2816 + c]; }
uint get_table_mode0(uint c, uint hp, uint lp) { return s_Tables[3072 + c * 4 + hp * 2 + lp]; }
uint get_table_bc7_weight(uint index) { return s_Tables[4096 + index]; }
float4 get_table_bc7_weightx(uint index) { index = 4124 + index * 4; uint4 r = uint4(s_Tables[index + 0], s_Tables[index + 1], s_Tables[index + 2], s_Tables[index + 3]); return asfloat(r); }

static const uint BC7E_MODE_1_OPTIMAL_INDEX = 2;
static const uint BC7E_MODE_7_OPTIMAL_INDEX = 1;
static const uint BC7E_MODE_6_OPTIMAL_INDEX = 5;
static const uint BC7E_MODE_4_OPTIMAL_INDEX3 = 2;
static const uint BC7E_MODE_4_OPTIMAL_INDEX2 = 1;
static const uint BC7E_MODE_0_OPTIMAL_INDEX = 2;


static void compute_least_squares_endpoints_rgba(uint N, int selectors[16], uint weights_index, out precise float4 pXl, out precise float4 pXh, color_quad_i colors[16])
{
    // Least squares using normal equations: http://www.cs.cornell.edu/~bindel/class/cs3220-s12/notes/lec10.pdf
    // I did this in matrix form first, expanded out all the ops, then optimized it a bit.
    precise float z00 = 0.0f, z01 = 0.0f, z10 = 0.0f, z11 = 0.0f;
    precise float4 q00 = 0.0f, q10 = 0.0f, t = 0.0f;
    for (uint i = 0; i < N; i++)
    {
        const uint sel = selectors[i];
        precise float4 wt = get_table_bc7_weightx(weights_index+sel);
        z00 += wt.r;
        z10 += wt.g;
        z11 += wt.b;
        precise float w = wt.a;
        q00 += w * float4(colors[i]); t += float4(colors[i]);
    }

    q10 = t - q00;

    z01 = z10;

    precise float det = z00 * z11 - z01 * z10;
    if (det != 0.0f)
        det = 1.0f / det;

    precise float iz00, iz01, iz10, iz11;
    iz00 = z11 * det;
    iz01 = -z01 * det;
    iz10 = -z10 * det;
    iz11 = z00 * det;

    pXl = iz00 * q00 + iz01 * q10; pXh = iz10 * q00 + iz11 * q10;
}

static void compute_least_squares_endpoints_rgb(uint N, int selectors[16], uint weights_index, inout precise float4 pXl, inout precise float4 pXh, color_quad_i colors[16])
{
    // Least squares using normal equations: http://www.cs.cornell.edu/~bindel/class/cs3220-s12/notes/lec10.pdf
    // I did this in matrix form first, expanded out all the ops, then optimized it a bit.
    precise float z00 = 0.0f, z01 = 0.0f, z10 = 0.0f, z11 = 0.0f;
    precise float3 q00 = 0.0f, q10 = 0.0f, t = 0.0f;
    for (uint i = 0; i < N; i++)
    {
        const uint sel = selectors[i];
        precise float4 wt = get_table_bc7_weightx(weights_index + sel);
        z00 += wt.r;
        z10 += wt.g;
        z11 += wt.b;
        precise float w = wt.a;
        q00 += w * float3(colors[i].rgb); t += float3(colors[i].rgb);
    }

    q10 = t - q00;

    z01 = z10;

    precise float det = z00 * z11 - z01 * z10;
    if (det != 0.0f)
        det = 1.0f / det;

    precise float iz00, iz01, iz10, iz11;
    iz00 = z11 * det;
    iz01 = -z01 * det;
    iz10 = -z10 * det;
    iz11 = z00 * det;

    pXl.rgb = iz00 * q00 + iz01 * q10; pXh.rgb = iz10 * q00 + iz11 * q10;
}

static void compute_least_squares_endpoints_a(uint N, int selectors[16], uint weights_index, out precise float pXl, out precise float pXh, color_quad_i colors[16])
{
    // Least squares using normal equations: http://www.cs.cornell.edu/~bindel/class/cs3220-s12/notes/lec10.pdf
    // I did this in matrix form first, expanded out all the ops, then optimized it a bit.
    precise float z00 = 0.0f, z01 = 0.0f, z10 = 0.0f, z11 = 0.0f;
    precise float q00_a = 0.0f, q10_a = 0.0f, t_a = 0.0f;
    for (uint i = 0; i < N; i++)
    {
        const uint sel = selectors[i];
        precise float4 wt = get_table_bc7_weightx(weights_index + sel);
        z00 += wt.r;
        z10 += wt.g;
        z11 += wt.b;
        precise float w = wt.a;
        q00_a += w * colors[i].a; t_a += colors[i].a;
    }

    q10_a = t_a - q00_a;

    z01 = z10;

    precise float det = z00 * z11 - z01 * z10;
    if (det != 0.0f)
        det = 1.0f / det;

    precise float iz00, iz01, iz10, iz11;
    iz00 = z11 * det;
    iz01 = -z01 * det;
    iz10 = -z10 * det;
    iz11 = z00 * det;

    pXl = iz00 * q00_a + iz01 * q10_a; pXh = iz10 * q00_a + iz11 * q10_a;
}

struct color_cell_compressor_params
{
    uint m_num_selector_weights;
    uint m_weights_index;
    uint m_comp_bits;
    uint4 m_weights;
    bool m_has_alpha;
    bool m_has_pbits;
    bool m_endpoints_share_pbit;
    bool m_perceptual;
};

static inline void color_cell_compressor_params_clear(out color_cell_compressor_params p)
{
    p = (color_cell_compressor_params)0;
    p.m_weights = 1;
}

int4 unpack_color(uint packed)
{
    int4 r;
    r.x = packed & 0xFF;
    r.y = (packed >> 8) & 0xFF;
    r.z = (packed >> 16) & 0xFF;
    r.w = packed >> 24;
    return r;
}

uint pack_color(int4 c)
{
    c = clamp(c, 0, 255);
    return c.x | (c.y << 8) | (c.z << 16) | (c.w << 24);
}

struct color_cell_compressor_results
{
    uint m_best_overall_err;
    color_quad_i m_low_endpoint;
    color_quad_i m_high_endpoint;
    uint m_pbits;
    int m_selectors[16];
};

static inline color_quad_i scale_color(color_quad_i c, color_cell_compressor_params params)
{
    color_quad_i results;

    const uint n = params.m_comp_bits + (params.m_has_pbits ? 1 : 0);
    assert((n >= 4) && (n <= 8));
    uint4 v = uint4(c) << (8 - n);
    v |= v >> n;
    results = int4(v);
    return results;
}

static const float pr_weight = (.5f / (1.0f - .2126f)) * (.5f / (1.0f - .2126f));
static const float pb_weight = (.5f / (1.0f - .0722f)) * (.5f / (1.0f - .0722f));

static inline uint compute_color_distance_rgb(color_quad_i e1, color_quad_i e2, bool perceptual, uint4 weights)
{
    if (perceptual)
    {
        precise const float l1 = e1.r * .2126f + e1.g * .7152f + e1.b * .0722f;
        const float cr1 = e1.r - l1;
        const float cb1 = e1.b - l1;

        precise const float l2 = e2.r * .2126f + e2.g * .7152f + e2.b * .0722f;
        const float cr2 = e2.r - l2;
        const float cb2 = e2.b - l2;

        float dl = l1 - l2;
        float dcr = cr1 - cr2;
        float dcb = cb1 - cb2;

        precise float res = (weights[0] * (dl * dl) + weights[1] * pr_weight * (dcr * dcr) + weights[2] * pb_weight * (dcb * dcb));
        return (uint)res;
    }
    else
    {
        float dr = (float)e1.r - (float)e2.r;
        float dg = (float)e1.g - (float)e2.g;
        float db = (float)e1.b - (float)e2.b;
        
        return (int)(weights[0] * dr * dr + weights[1] * dg * dg + weights[2] * db * db);
    }
}

static inline uint compute_color_distance_rgba(color_quad_i e1, color_quad_i e2, bool perceptual, uint4 weights)
{
    float da = (float)e1.a - (float)e2.a;
    precise float a_err = weights[3] * (da * da);

    if (perceptual)
    {
        precise const float l1 = e1.r * .2126f + e1.g * .7152f + e1.b * .0722f;
        const float cr1 = e1.r - l1;
        const float cb1 = e1.b - l1;

        precise const float l2 = e2.r * .2126f + e2.g * .7152f + e2.b * .0722f;
        const float cr2 = e2.r - l2;
        const float cb2 = e2.b - l2;

        float dl = l1 - l2;
        float dcr = cr1 - cr2;
        float dcb = cb1 - cb2;

        precise float res = (weights[0] * (dl * dl) + weights[1] * pr_weight * (dcr * dcr) + weights[2] * pb_weight * (dcb * dcb) + a_err);
        return (uint)res;
    }
    else
    {
        float dr = (float)e1.r - (float)e2.r;
        float dg = (float)e1.g - (float)e2.g;
        float db = (float)e1.b - (float)e2.b;

        return (int)(weights[0] * dr * dr + weights[1] * dg * dg + weights[2] * db * db + a_err);
    }
}

struct ModePackResult
{
    uint err;
    int bestSelector;
};

static ModePackResult pack_mode1_to_one_color(color_cell_compressor_params pParams, inout color_cell_compressor_results pResults, uint r, uint g, uint b,
    uint num_pixels, color_quad_i pPixels[16])
{
    ModePackResult res;

    uint best_err = UINT_MAX;
    uint best_p = 0;

    for (uint pp = 0; pp < 2; pp++)
    {
        uint err = endpoint_get_err(get_table_mode1(r,pp)) + endpoint_get_err(get_table_mode1(g,pp)) + endpoint_get_err(get_table_mode1(b,pp));
        if (err < best_err)
        {
            best_err = err;
            best_p = pp;
        }
    }

    endpoint_err pEr = get_table_mode1(r,best_p);
    endpoint_err pEg = get_table_mode1(g,best_p);
    endpoint_err pEb = get_table_mode1(b,best_p);

    pResults.m_low_endpoint = int4(endpoint_get_lo(pEr), endpoint_get_lo(pEg), endpoint_get_lo(pEb), 0);
    pResults.m_high_endpoint = int4(endpoint_get_hi(pEr), endpoint_get_hi(pEg), endpoint_get_hi(pEb), 0);
    pResults.m_pbits = best_p;

    res.bestSelector = BC7E_MODE_1_OPTIMAL_INDEX;

    color_quad_i p;
    {
        uint3 low = uint3(((pResults.m_low_endpoint.rgb << 1) | best_p) << 1);
        low |= (low >> 7);

        uint3 high = uint3(((pResults.m_high_endpoint.rgb << 1) | best_p) << 1);
        high |= (high >> 7);

        p.rgb = int3((low * (64 - get_table_bc7_weight(kBC7Weights3Index + BC7E_MODE_1_OPTIMAL_INDEX)) + high * get_table_bc7_weight(kBC7Weights3Index + BC7E_MODE_1_OPTIMAL_INDEX) + 32) >> 6);
    }
    p.a = 255;

    uint total_err = 0;
    for (uint i = 0; i < num_pixels; i++)
        total_err += compute_color_distance_rgb(p, pPixels[i], pParams.m_perceptual, pParams.m_weights);

    pResults.m_best_overall_err = total_err;

    res.err = total_err;
    return res;
}

static ModePackResult pack_mode24_to_one_color(color_cell_compressor_params pParams, inout color_cell_compressor_results pResults, uint r, uint g, uint b,
    uint num_pixels, color_quad_i pPixels[16])
{
    ModePackResult res;
    uint er, eg, eb;

    if (pParams.m_num_selector_weights == 8)
    {
        er = get_table_mode4_3(r);
        eg = get_table_mode4_3(g);
        eb = get_table_mode4_3(b);
    }
    else
    {
        er = get_table_mode4_2(r);
        eg = get_table_mode4_2(g);
        eb = get_table_mode4_2(b);
    }
    
    pResults.m_low_endpoint = int4(er & 0xFF, eg & 0xFF, eb & 0xFF, 0);
    pResults.m_high_endpoint = int4(er >> 8, eg >> 8, eb >> 8, 0);

    res.bestSelector = (pParams.m_num_selector_weights == 8) ? BC7E_MODE_4_OPTIMAL_INDEX3 : BC7E_MODE_4_OPTIMAL_INDEX2;

    color_quad_i p;
    {
        uint3 low = uint3(pResults.m_low_endpoint.rgb << 3);
        low |= (low >> 5);

        uint3 high = uint3(pResults.m_high_endpoint.rgb << 3);
        high |= (high >> 5);

        if (pParams.m_num_selector_weights == 8)
            p.rgb = int3((low * (64 - get_table_bc7_weight(kBC7Weights3Index + BC7E_MODE_4_OPTIMAL_INDEX3)) + high * get_table_bc7_weight(kBC7Weights3Index + BC7E_MODE_4_OPTIMAL_INDEX3) + 32) >> 6);
        else
            p.rgb = int3((low * (64 - get_table_bc7_weight(kBC7Weights2Index + BC7E_MODE_4_OPTIMAL_INDEX2)) + high * get_table_bc7_weight(kBC7Weights2Index + BC7E_MODE_4_OPTIMAL_INDEX2) + 32) >> 6);
    }
    p.a = 255;

    uint total_err = 0;
    for (uint i = 0; i < num_pixels; i++)
        total_err += compute_color_distance_rgb(p, pPixels[i], pParams.m_perceptual, pParams.m_weights);

    pResults.m_best_overall_err = total_err;

    res.err = total_err;
    return res;
}

static ModePackResult pack_mode0_to_one_color(color_cell_compressor_params pParams, inout color_cell_compressor_results pResults, uint r, uint g, uint b,
    uint num_pixels, color_quad_i pPixels[16])
{
    ModePackResult res;
    uint best_err = UINT_MAX;
    uint best_p = 0;

    for (uint pp = 0; pp < 4; pp++)
    {
        uint err = endpoint_get_err(get_table_mode0(r,pp >> 1,pp & 1)) + endpoint_get_err(get_table_mode0(g,pp >> 1,pp & 1)) + endpoint_get_err(get_table_mode0(b,pp >> 1,pp & 1));
        if (err < best_err)
        {
            best_err = err;
            best_p = pp;
        }
    }

   endpoint_err pEr = get_table_mode0(r,best_p >> 1,best_p & 1);
   endpoint_err pEg = get_table_mode0(g,best_p >> 1,best_p & 1);
   endpoint_err pEb = get_table_mode0(b,best_p >> 1,best_p & 1);

    pResults.m_low_endpoint = int4(endpoint_get_lo(pEr), endpoint_get_lo(pEg), endpoint_get_lo(pEb), 0);
    pResults.m_high_endpoint = int4(endpoint_get_hi(pEr), endpoint_get_hi(pEg), endpoint_get_hi(pEb), 0);

    pResults.m_pbits = best_p;

    res.bestSelector = BC7E_MODE_0_OPTIMAL_INDEX;

    color_quad_i p;
    {
        uint3 low = uint3(((pResults.m_low_endpoint.rgb << 1) | (best_p & 1)) << 3);
        low |= (low >> 5);

        uint3 high = uint3(((pResults.m_high_endpoint.rgb << 1) | (best_p >> 1)) << 3);
        high |= (high >> 5);

        p.rgb = int3((low * (64 - get_table_bc7_weight(kBC7Weights3Index + BC7E_MODE_0_OPTIMAL_INDEX)) + high * get_table_bc7_weight(kBC7Weights3Index + BC7E_MODE_0_OPTIMAL_INDEX) + 32) >> 6);
    }    
    p.a = 255;

    uint total_err = 0;
    for (uint i = 0; i < num_pixels; i++)
        total_err += compute_color_distance_rgb(p, pPixels[i], pParams.m_perceptual, pParams.m_weights);

    pResults.m_best_overall_err = total_err;

    res.err = total_err;
    return res;
}

static ModePackResult pack_mode6_to_one_color(color_cell_compressor_params pParams, inout color_cell_compressor_results pResults, uint r, uint g, uint b, uint a,
    uint num_pixels, color_quad_i pPixels[16])
{
    ModePackResult res;
    uint best_err = UINT_MAX;
    uint best_p = 0;

    for (uint pp = 0; pp < 4; pp++)
    {
        uint hi_p = pp >> 1;
        uint lo_p = pp & 1;
        uint err = endpoint_get_err(get_table_mode6(r,hi_p,lo_p)) + endpoint_get_err(get_table_mode6(g,hi_p,lo_p)) + endpoint_get_err(get_table_mode6(b,hi_p,lo_p)) + endpoint_get_err(get_table_mode6(a,hi_p,lo_p));
        if (err < best_err)
        {
            best_err = err;
            best_p = pp;
        }
    }

    uint best_hi_p = best_p >> 1;
    uint best_lo_p = best_p & 1;

    endpoint_err pEr = get_table_mode6(r,best_hi_p,best_lo_p);
    endpoint_err pEg = get_table_mode6(g,best_hi_p,best_lo_p);
    endpoint_err pEb = get_table_mode6(b,best_hi_p,best_lo_p);
    endpoint_err pEa = get_table_mode6(a,best_hi_p,best_lo_p);

    pResults.m_low_endpoint = int4(endpoint_get_lo(pEr), endpoint_get_lo(pEg), endpoint_get_lo(pEb), endpoint_get_lo(pEa));
    pResults.m_high_endpoint = int4(endpoint_get_hi(pEr), endpoint_get_hi(pEg), endpoint_get_hi(pEb), endpoint_get_hi(pEa));

    pResults.m_pbits = best_p;

    res.bestSelector = BC7E_MODE_6_OPTIMAL_INDEX;

    color_quad_i p;
    {
        uint4 low = uint4((pResults.m_low_endpoint << 1) | best_lo_p);
        uint4 high = uint4((pResults.m_high_endpoint << 1) | best_hi_p);
        
        p = int4((low * (64 - get_table_bc7_weight(kBC7Weights4Index + BC7E_MODE_6_OPTIMAL_INDEX)) + high * get_table_bc7_weight(kBC7Weights4Index + BC7E_MODE_6_OPTIMAL_INDEX) + 32) >> 6);
    }

    uint total_err = 0;
    for (uint i = 0; i < num_pixels; i++)
        total_err += compute_color_distance_rgba(p, pPixels[i], pParams.m_perceptual, pParams.m_weights);

    pResults.m_best_overall_err = total_err;

    res.err = total_err;
    return res;
}

static ModePackResult pack_mode7_to_one_color(color_cell_compressor_params pParams, inout color_cell_compressor_results pResults, uint r, uint g, uint b, uint a,
    uint num_pixels, color_quad_i pPixels[16])
{
    ModePackResult res;
    uint best_err = UINT_MAX;
    uint best_p = 0;

    for (uint pp = 0; pp < 4; pp++)
    {
        uint hi_p = pp >> 1;
        uint lo_p = pp & 1;
        uint err = endpoint_get_err(get_table_mode7(r, hi_p, lo_p)) + endpoint_get_err(get_table_mode7(g, hi_p, lo_p)) + endpoint_get_err(get_table_mode7(b, hi_p, lo_p)) + endpoint_get_err(get_table_mode7(a, hi_p, lo_p));
        if (err < best_err)
        {
            best_err = err;
            best_p = pp;
        }
    }

    uint best_hi_p = best_p >> 1;
    uint best_lo_p = best_p & 1;

    endpoint_err pEr = get_table_mode7(r, best_hi_p, best_lo_p);
    endpoint_err pEg = get_table_mode7(g, best_hi_p, best_lo_p);
    endpoint_err pEb = get_table_mode7(b, best_hi_p, best_lo_p);
    endpoint_err pEa = get_table_mode7(a, best_hi_p, best_lo_p);

    pResults.m_low_endpoint = int4(endpoint_get_lo(pEr), endpoint_get_lo(pEg), endpoint_get_lo(pEb), endpoint_get_lo(pEa));
    pResults.m_high_endpoint = int4(endpoint_get_hi(pEr), endpoint_get_hi(pEg), endpoint_get_hi(pEb), endpoint_get_hi(pEa));

    pResults.m_pbits = best_p;

    res.bestSelector = BC7E_MODE_7_OPTIMAL_INDEX;

    color_quad_i p;
    {
        uint4 low = uint4((pResults.m_low_endpoint << 1) | best_lo_p);
        uint4 high = uint4((pResults.m_high_endpoint << 1) | best_hi_p);
        
        p = int4((low * (64 - get_table_bc7_weight(kBC7Weights2Index + BC7E_MODE_7_OPTIMAL_INDEX)) + high * get_table_bc7_weight(kBC7Weights2Index + BC7E_MODE_7_OPTIMAL_INDEX) + 32) >> 6);
    }

    uint total_err = 0;
    for (uint i = 0; i < num_pixels; i++)
        total_err += compute_color_distance_rgba(p, pPixels[i], pParams.m_perceptual, pParams.m_weights);

    pResults.m_best_overall_err = total_err;

    res.err = total_err;
    return res;
}

static ModePackResult pack_mode_to_one_color(
    int mode,
    color_cell_compressor_params pParams,
    inout color_cell_compressor_results pResults,
    color_quad_i col,
    uint num_pixels,
    color_quad_i pPixels[16])
{
    if (mode == 0)
        return pack_mode0_to_one_color(pParams, pResults, col.r, col.g, col.b, num_pixels, pPixels);
    else if (mode == 1)
        return pack_mode1_to_one_color(pParams, pResults, col.r, col.g, col.b, num_pixels, pPixels);
    else if (mode == 6)
        return pack_mode6_to_one_color(pParams, pResults, col.r, col.g, col.b, col.a, num_pixels, pPixels);
    else if (mode == 7)
        return pack_mode7_to_one_color(pParams, pResults, col.r, col.g, col.b, col.a, num_pixels, pPixels);
    else
        return pack_mode24_to_one_color(pParams, pResults, col.r, col.g, col.b, num_pixels, pPixels);
}

static uint evaluate_solution(const color_quad_i pLow, const color_quad_i pHigh, const uint pbits[2],
    const color_cell_compressor_params pParams, inout color_cell_compressor_results pResults, uint num_pixels, const color_quad_i pPixels[16])
{
    color_quad_i quantMinColor = pLow;
    color_quad_i quantMaxColor = pHigh;

    if (pParams.m_has_pbits)
    {
        uint minPBit, maxPBit;

        if (pParams.m_endpoints_share_pbit)
            maxPBit = minPBit = pbits[0];
        else
        {
            minPBit = pbits[0];
            maxPBit = pbits[1];
        }

        quantMinColor = (pLow << 1) | minPBit;
        quantMaxColor = (pHigh << 1) | maxPBit;
    }

    color_quad_i actualMinColor = scale_color(quantMinColor, pParams);
    color_quad_i actualMaxColor = scale_color(quantMaxColor, pParams);

    const uint N = pParams.m_num_selector_weights;
    const uint nc = pParams.m_has_alpha ? 4 : 3;

    precise float total_errf = 0;

    precise float wr = pParams.m_weights[0];
    precise float wg = pParams.m_weights[1];
    precise float wb = pParams.m_weights[2];
    precise float wa = pParams.m_weights[3];

    precise color_quad_f weightedColors[16];
    weightedColors[0] = float4(actualMinColor);
    weightedColors[N-1] = float4(actualMaxColor);
        
    for (uint i = 1; i < (N - 1); i++)
        for (uint j = 0; j < nc; j++)
        {
            precise float wt = get_table_bc7_weight(pParams.m_weights_index + i);
            precise float w = (weightedColors[0][j] * (64.0f - wt) + weightedColors[N - 1][j] * wt + 32) * (1.0f / 64.0f);
            weightedColors[i][j] = floor(w);
        }

    int selectors[16];

    if (!pParams.m_perceptual)
    {
        if (!pParams.m_has_alpha)
        {
            if (N == 16)
            {
                float lr = actualMinColor[0];
                float lg = actualMinColor[1];
                float lb = actualMinColor[2];

                float dr = actualMaxColor[0] - lr;
                float dg = actualMaxColor[1] - lg;
                float db = actualMaxColor[2] - lb;
            
                const float f = N / (dr * dr + dg * dg + db * db);

                lr *= -dr;
                lg *= -dg;
                lb *= -db;

                for (uint i = 0; i < num_pixels; i++)
                {
                    const color_quad_i pC = pPixels[i];
                    float r = pC.r;
                    float g = pC.g;
                    float b = pC.b;

                    float best_sel = floor(((r * dr + lr) + (g * dg + lg) + (b * db + lb)) * f + .5f);
                    best_sel = clamp(best_sel, (float)1, (float)(N - 1));

                    float best_sel0 = best_sel - 1;

                    float dr0 = weightedColors[(int)best_sel0][0] - r;

                    float dg0 = weightedColors[(int)best_sel0][1] - g;

                    float db0 = weightedColors[(int)best_sel0][2] - b;

                    float err0 = wr * dr0 * dr0 + wg * dg0 * dg0 + wb * db0 * db0;

                    float dr1 = weightedColors[(int)best_sel][0] - r;

                    float dg1 = weightedColors[(int)best_sel][1] - g;

                    float db1 = weightedColors[(int)best_sel][2] - b;

                    float err1 = wr * dr1 * dr1 + wg * dg1 * dg1 + wb * db1 * db1;

                    float min_err = min(err0, err1);
                    total_errf += min_err;
                    selectors[i] = (int)select(best_sel0, best_sel, min_err == err0);
                }
            }
            else if (N == 8)
            {
                for (uint i = 0; i < num_pixels; i++)
                {
                    float pr = (float)pPixels[i][0];
                    float pg = (float)pPixels[i][1];
                    float pb = (float)pPixels[i][2];
                
                    float best_err;
                    int best_sel;

                    {
                        float dr0 = weightedColors[0][0] - pr;
                        float dg0 = weightedColors[0][1] - pg;
                        float db0 = weightedColors[0][2] - pb;
                        float err0 = wr * dr0 * dr0 + wg * dg0 * dg0 + wb * db0 * db0;

                        float dr1 = weightedColors[1][0] - pr;
                        float dg1 = weightedColors[1][1] - pg;
                        float db1 = weightedColors[1][2] - pb;
                        float err1 = wr * dr1 * dr1 + wg * dg1 * dg1 + wb * db1 * db1;

                        float dr2 = weightedColors[2][0] - pr;
                        float dg2 = weightedColors[2][1] - pg;
                        float db2 = weightedColors[2][2] - pb;
                        float err2 = wr * dr2 * dr2 + wg * dg2 * dg2 + wb * db2 * db2;

                        float dr3 = weightedColors[3][0] - pr;
                        float dg3 = weightedColors[3][1] - pg;
                        float db3 = weightedColors[3][2] - pb;
                        float err3 = wr * dr3 * dr3 + wg * dg3 * dg3 + wb * db3 * db3;

                        best_err = min(min(min(err0, err1), err2), err3);
                                    
                        best_sel = select(1, 0, best_err == err1);
                        best_sel = select(2, best_sel, best_err == err2);
                        best_sel = select(3, best_sel, best_err == err3);
                    }

                    {
                        float dr0 = weightedColors[4][0] - pr;
                        float dg0 = weightedColors[4][1] - pg;
                        float db0 = weightedColors[4][2] - pb;
                        float err0 = wr * dr0 * dr0 + wg * dg0 * dg0 + wb * db0 * db0;

                        float dr1 = weightedColors[5][0] - pr;
                        float dg1 = weightedColors[5][1] - pg;
                        float db1 = weightedColors[5][2] - pb;
                        float err1 = wr * dr1 * dr1 + wg * dg1 * dg1 + wb * db1 * db1;

                        float dr2 = weightedColors[6][0] - pr;
                        float dg2 = weightedColors[6][1] - pg;
                        float db2 = weightedColors[6][2] - pb;
                        float err2 = wr * dr2 * dr2 + wg * dg2 * dg2 + wb * db2 * db2;

                        float dr3 = weightedColors[7][0] - pr;
                        float dg3 = weightedColors[7][1] - pg;
                        float db3 = weightedColors[7][2] - pb;
                        float err3 = wr * dr3 * dr3 + wg * dg3 * dg3 + wb * db3 * db3;

                        best_err = min(best_err, min(min(min(err0, err1), err2), err3));

                        best_sel = select(4, best_sel, best_err == err0);
                        best_sel = select(5, best_sel, best_err == err1);
                        best_sel = select(6, best_sel, best_err == err2);
                        best_sel = select(7, best_sel, best_err == err3);
                    }
                
                    total_errf += best_err;

                    selectors[i] = best_sel;
                }
            }
            else // if (N == 4)
            {
                for (uint i = 0; i < num_pixels; i++)
                {
                    float pr = (float)pPixels[i][0];
                    float pg = (float)pPixels[i][1];
                    float pb = (float)pPixels[i][2];
                
                    float dr0 = weightedColors[0][0] - pr;
                    float dg0 = weightedColors[0][1] - pg;
                    float db0 = weightedColors[0][2] - pb;
                    float err0 = wr * dr0 * dr0 + wg * dg0 * dg0 + wb * db0 * db0;

                    float dr1 = weightedColors[1][0] - pr;
                    float dg1 = weightedColors[1][1] - pg;
                    float db1 = weightedColors[1][2] - pb;
                    float err1 = wr * dr1 * dr1 + wg * dg1 * dg1 + wb * db1 * db1;

                    float dr2 = weightedColors[2][0] - pr;
                    float dg2 = weightedColors[2][1] - pg;
                    float db2 = weightedColors[2][2] - pb;
                    float err2 = wr * dr2 * dr2 + wg * dg2 * dg2 + wb * db2 * db2;

                    float dr3 = weightedColors[3][0] - pr;
                    float dg3 = weightedColors[3][1] - pg;
                    float db3 = weightedColors[3][2] - pb;
                    float err3 = wr * dr3 * dr3 + wg * dg3 * dg3 + wb * db3 * db3;

                    float best_err = min(min(min(err0, err1), err2), err3);

                    int best_sel = select(1, 0, best_err == err1);
                    best_sel = select(2, best_sel, best_err == err2);
                    best_sel = select(3, best_sel, best_err == err3);
                                
                    total_errf += best_err;

                    selectors[i] = best_sel;
                }
            }
        }
        else
        {
            // alpha
            if (N == 16)
            {
                float lr = actualMinColor[0];
                float lg = actualMinColor[1];
                float lb = actualMinColor[2];
                float la = actualMinColor[3];

                float dr = actualMaxColor[0] - lr;
                float dg = actualMaxColor[1] - lg;
                float db = actualMaxColor[2] - lb;
                float da = actualMaxColor[3] - la;
            
                const float f = N / (dr * dr + dg * dg + db * db + da * da);

                lr *= -dr;
                lg *= -dg;
                lb *= -db;
                la *= -da;

                for (uint i = 0; i < num_pixels; i++)
                {
                    const color_quad_i pC = pPixels[i];
                    float r = pC.r;
                    float g = pC.g;
                    float b = pC.b;
                    float a = pC.a;

                    float best_sel = floor(((r * dr + lr) + (g * dg + lg) + (b * db + lb) + (a * da + la)) * f + .5f);
                    best_sel = clamp(best_sel, (float)1, (float)(N - 1));

                    float best_sel0 = best_sel - 1;

                    float dr0 = weightedColors[(int)best_sel0][0] - r;
                    float dg0 = weightedColors[(int)best_sel0][1] - g;
                    float db0 = weightedColors[(int)best_sel0][2] - b;
                    float da0 = weightedColors[(int)best_sel0][3] - a;
                    float err0 = (wr * dr0 * dr0) + (wg * dg0 * dg0) + (wb * db0 * db0) + (wa * da0 * da0);

                    float dr1 = weightedColors[(int)best_sel][0] - r;
                    float dg1 = weightedColors[(int)best_sel][1] - g;
                    float db1 = weightedColors[(int)best_sel][2] - b;
                    float da1 = weightedColors[(int)best_sel][3] - a;

                    float err1 = (wr * dr1 * dr1) + (wg * dg1 * dg1) + (wb * db1 * db1) + (wa * da1 * da1);

                    float min_err = min(err0, err1);
                    total_errf += min_err;
                    selectors[i] = (int)select(best_sel0, best_sel, min_err == err0);
                }
            }
            else if (N == 8)
            {
                for (uint i = 0; i < num_pixels; i++)
                {
                    float pr = (float)pPixels[i][0];
                    float pg = (float)pPixels[i][1];
                    float pb = (float)pPixels[i][2];
                    float pa = (float)pPixels[i][3];
                
                    float best_err;
                    int best_sel;

                    {
                        float dr0 = weightedColors[0][0] - pr;
                        float dg0 = weightedColors[0][1] - pg;
                        float db0 = weightedColors[0][2] - pb;
                        float da0 = weightedColors[0][3] - pa;
                        float err0 = wr * dr0 * dr0 + wg * dg0 * dg0 + wb * db0 * db0 + wa * da0 * da0;

                        float dr1 = weightedColors[1][0] - pr;
                        float dg1 = weightedColors[1][1] - pg;
                        float db1 = weightedColors[1][2] - pb;
                        float da1 = weightedColors[1][3] - pa;
                        float err1 = wr * dr1 * dr1 + wg * dg1 * dg1 + wb * db1 * db1 + wa * da1 * da1;

                        float dr2 = weightedColors[2][0] - pr;
                        float dg2 = weightedColors[2][1] - pg;
                        float db2 = weightedColors[2][2] - pb;
                        float da2 = weightedColors[2][3] - pa;
                        float err2 = wr * dr2 * dr2 + wg * dg2 * dg2 + wb * db2 * db2 + wa * da2 * da2;

                        float dr3 = weightedColors[3][0] - pr;
                        float dg3 = weightedColors[3][1] - pg;
                        float db3 = weightedColors[3][2] - pb;
                        float da3 = weightedColors[3][3] - pa;
                        float err3 = wr * dr3 * dr3 + wg * dg3 * dg3 + wb * db3 * db3 + wa * da3 * da3;

                        best_err = min(min(min(err0, err1), err2), err3);
                                    
                        best_sel = select(1, 0, best_err == err1);
                        best_sel = select(2, best_sel, best_err == err2);
                        best_sel = select(3, best_sel, best_err == err3);
                    }

                    {
                        float dr0 = weightedColors[4][0] - pr;
                        float dg0 = weightedColors[4][1] - pg;
                        float db0 = weightedColors[4][2] - pb;
                        float da0 = weightedColors[4][3] - pa;
                        float err0 = wr * dr0 * dr0 + wg * dg0 * dg0 + wb * db0 * db0 + wa * da0 * da0;

                        float dr1 = weightedColors[5][0] - pr;
                        float dg1 = weightedColors[5][1] - pg;
                        float db1 = weightedColors[5][2] - pb;
                        float da1 = weightedColors[5][3] - pa;
                        float err1 = wr * dr1 * dr1 + wg * dg1 * dg1 + wb * db1 * db1 + wa * da1 * da1;

                        float dr2 = weightedColors[6][0] - pr;
                        float dg2 = weightedColors[6][1] - pg;
                        float db2 = weightedColors[6][2] - pb;
                        float da2 = weightedColors[6][3] - pa;
                        float err2 = wr * dr2 * dr2 + wg * dg2 * dg2 + wb * db2 * db2 + wa * da2 * da2;

                        float dr3 = weightedColors[7][0] - pr;
                        float dg3 = weightedColors[7][1] - pg;
                        float db3 = weightedColors[7][2] - pb;
                        float da3 = weightedColors[7][3] - pa;
                        float err3 = wr * dr3 * dr3 + wg * dg3 * dg3 + wb * db3 * db3 + wa * da3 * da3;

                        best_err = min(best_err, min(min(min(err0, err1), err2), err3));

                        best_sel = select(4, best_sel, best_err == err0);
                        best_sel = select(5, best_sel, best_err == err1);
                        best_sel = select(6, best_sel, best_err == err2);
                        best_sel = select(7, best_sel, best_err == err3);
                    }
                
                    total_errf += best_err;

                    selectors[i] = best_sel;
                }
            }
            else // if (N == 4)
            {
                for (uint i = 0; i < num_pixels; i++)
                {
                    float pr = (float)pPixels[i][0];
                    float pg = (float)pPixels[i][1];
                    float pb = (float)pPixels[i][2];
                    float pa = (float)pPixels[i][3];
                
                    float dr0 = weightedColors[0][0] - pr;
                    float dg0 = weightedColors[0][1] - pg;
                    float db0 = weightedColors[0][2] - pb;
                    float da0 = weightedColors[0][3] - pa;
                    float err0 = wr * dr0 * dr0 + wg * dg0 * dg0 + wb * db0 * db0 + wa * da0 * da0;

                    float dr1 = weightedColors[1][0] - pr;
                    float dg1 = weightedColors[1][1] - pg;
                    float db1 = weightedColors[1][2] - pb;
                    float da1 = weightedColors[1][3] - pa;
                    float err1 = wr * dr1 * dr1 + wg * dg1 * dg1 + wb * db1 * db1 + wa * da1 * da1;

                    float dr2 = weightedColors[2][0] - pr;
                    float dg2 = weightedColors[2][1] - pg;
                    float db2 = weightedColors[2][2] - pb;
                    float da2 = weightedColors[2][3] - pa;
                    float err2 = wr * dr2 * dr2 + wg * dg2 * dg2 + wb * db2 * db2 + wa * da2 * da2;

                    float dr3 = weightedColors[3][0] - pr;
                    float dg3 = weightedColors[3][1] - pg;
                    float db3 = weightedColors[3][2] - pb;
                    float da3 = weightedColors[3][3] - pa;
                    float err3 = wr * dr3 * dr3 + wg * dg3 * dg3 + wb * db3 * db3 + wa * da3 * da3;

                    float best_err = min(min(min(err0, err1), err2), err3);

                    int best_sel = select(1, 0, best_err == err1);
                    best_sel = select(2, best_sel, best_err == err2);
                    best_sel = select(3, best_sel, best_err == err3);
                                
                    total_errf += best_err;

                    selectors[i] = best_sel;
                }
            }
        }
    }
    else
    {
        wg *= pr_weight;
        wb *= pb_weight;

        precise float weightedColorsY[16], weightedColorsCr[16], weightedColorsCb[16];
        
        for (uint i = 0; i < N; i++)
        {
            precise float r = weightedColors[i][0];
            precise float g = weightedColors[i][1];
            precise float b = weightedColors[i][2];

            precise float y = r * .2126f + g * .7152f + b * .0722f;
                                    
            weightedColorsY[i] = y;
            weightedColorsCr[i] = r - y;
            weightedColorsCb[i] = b - y;
        }

        if (pParams.m_has_alpha)
        {
            for (uint i = 0; i < num_pixels; i++)
            {
                precise float r = pPixels[i][0];
                precise float g = pPixels[i][1];
                precise float b = pPixels[i][2];
                precise float a = pPixels[i][3];

                precise float y = r * .2126f + g * .7152f + b * .0722f;
                precise float cr = r - y;
                precise float cb = b - y;

                precise float best_err = 1e+10f;
                int best_sel;
                                
                for (uint j = 0; j < N; j++)
                {
                    precise float dl = y - weightedColorsY[j];
                    precise float dcr = cr - weightedColorsCr[j];
                    precise float dcb = cb - weightedColorsCb[j];
                    precise float da = a - weightedColors[j][3];

                    precise float err = (wr * dl * dl) + (wg * dcr * dcr) + (wb * dcb * dcb) + (wa * da * da);
                    if (err < best_err)
                    {
                        best_err = err;
                        best_sel = j;
                    }
                }
                
                total_errf += best_err;

                selectors[i] = best_sel;
            }
        }
        else
        {
            for (uint i = 0; i < num_pixels; i++)
            {
                precise float r = pPixels[i][0];
                precise float g = pPixels[i][1];
                precise float b = pPixels[i][2];

                precise float y = r * .2126f + g * .7152f + b * .0722f;
                precise float cr = r - y;
                precise float cb = b - y;

                precise float best_err = 1e+10f;
                int best_sel;
                                
                for (uint j = 0; j < N; j++)
                {
                    precise float dl = y - weightedColorsY[j];
                    precise float dcr = cr - weightedColorsCr[j];
                    precise float dcb = cb - weightedColorsCb[j];

                    precise float err = (wr * dl * dl) + (wg * dcr * dcr) + (wb * dcb * dcb);
                    if (err < best_err)
                    {
                        best_err = err;
                        best_sel = j;
                    }
                }
                
                total_errf += best_err;

                selectors[i] = best_sel;
            }
        }
    }

    uint total_err = total_errf;

    if (total_err < pResults.m_best_overall_err)
    {
        pResults.m_best_overall_err = total_err;

        pResults.m_low_endpoint = pLow;
        pResults.m_high_endpoint = pHigh;

        pResults.m_pbits = pbits[0] | (pbits[1] << 1);

        for (uint i = 0; i < num_pixels; i++)
            pResults.m_selectors[i] = selectors[i];
    }
                
    return total_err;
}

static void fixDegenerateEndpoints(uint mode, inout color_quad_i pTrialMinColor, inout color_quad_i pTrialMaxColor, const vec4F pXl, const vec4F pXh, uint iscale)
{
    if ((mode == 1) || (mode == 4)) // also mode 2
    {
        // fix degenerate case where the input collapses to a single colorspace voxel, and we loose all freedom (test with grayscale ramps)
        for (uint i = 0; i < 3; i++)
        {
            if (pTrialMinColor[i] == pTrialMaxColor[i])
            {
                if (abs(pXl[i] - pXh[i]) > 0.0f)
                {
                    if (pTrialMinColor[i] > (iscale >> 1))
                    {
                        if (pTrialMinColor[i] > 0)
                            pTrialMinColor[i]--;
                        else
                            if (pTrialMaxColor[i] < iscale)
                                pTrialMaxColor[i]++;
                    }
                    else
                    {
                        if (pTrialMaxColor[i] < iscale)
                            pTrialMaxColor[i]++;
                        else if (pTrialMinColor[i] > 0)
                            pTrialMinColor[i]--;
                    }

                    if (mode == 4)
                    {
                        if (pTrialMinColor[i] > (iscale >> 1))
                        {
                            if (pTrialMaxColor[i] < iscale)
                                pTrialMaxColor[i]++;
                            else if (pTrialMinColor[i] > 0)
                                pTrialMinColor[i]--;
                        }
                        else
                        {
                            if (pTrialMinColor[i] > 0)
                                pTrialMinColor[i]--;
                            else if (pTrialMaxColor[i] < iscale)
                                pTrialMaxColor[i]++;
                        }
                    }
                }
            }
        }
    }
}

static uint find_optimal_solution(uint mode, const vec4F pXl, const vec4F pXh, const color_cell_compressor_params pParams, inout color_cell_compressor_results pResults,
    bool pbit_search, uint num_pixels, const color_quad_i pPixels[16])
{
    precise vec4F xl = saturate(pXl);
    precise vec4F xh = saturate(pXh);
        
    if (pParams.m_has_pbits)
    {
        /* @TODO: disable pbit_search for now
        if (pbit_search)
        {
            // compensated rounding+pbit search
            const int iscalep = (1 << (pParams->m_comp_bits + 1)) - 1;
            const float scalep = (float)iscalep;

            if (!pParams->m_endpoints_share_pbit)
            {
                color_quad_i lo[2], hi[2];
                                
                for (int p = 0; p < 2; p++)
                {
                    color_quad_i xMinColor, xMaxColor;

                    // Notes: The pbit controls which quantization intervals are selected.
                    // total_levels=2^(comp_bits+1), where comp_bits=4 for mode 0, etc.
                    // pbit 0: v=(b*2)/(total_levels-1), pbit 1: v=(b*2+1)/(total_levels-1) where b is the component bin from [0,total_levels/2-1] and v is the [0,1] component value
                    // rearranging you get for pbit 0: b=floor(v*(total_levels-1)/2+.5)
                    // rearranging you get for pbit 1: b=floor((v*(total_levels-1)-1)/2+.5)
                    xMinColor = int4((xl * scalep - p) / 2.0f + 0.5f) * 2 + p;
                    xMinColor = clamp(xMinColor, p, iscalep - 1 + p);
                    xMaxColor = int4((xh * scalep - p) / 2.0f + 0.5f) * 2 + p;
                    xMaxColor = clamp(xMaxColor, p, iscalep - 1 + p);
                                                                                
                    lo[p] = xMinColor;
                    hi[p] = xMaxColor;

                    lo[0] >>= 1;
                    hi[0] >>= 1;
                }

                fixDegenerateEndpoints(mode, &lo[0], &hi[0], &xl, &xh, iscalep >> 1);
                fixDegenerateEndpoints(mode, &lo[1], &hi[1], &xl, &xh, iscalep >> 1);

                uint pbits[2];
                
                pbits[0] = 0; pbits[1] = 0;
                evaluate_solution(&lo[0], &hi[0], pbits, pParams, pResults, num_pixels, pPixels);

                pbits[0] = 0; pbits[1] = 1;
                evaluate_solution(&lo[0], &hi[1], pbits, pParams, pResults, num_pixels, pPixels);

                pbits[0] = 1; pbits[1] = 0;
                evaluate_solution(&lo[1], &hi[0], pbits, pParams, pResults, num_pixels, pPixels);
                
                pbits[0] = 1; pbits[1] = 1;
                evaluate_solution(&lo[1], &hi[1], pbits, pParams, pResults, num_pixels, pPixels);
            }
            else
            {
                // Endpoints share pbits
                color_quad_i lo[2], hi[2];

                for (int p = 0; p < 2; p++)
                {
                    color_quad_i xMinColor, xMaxColor;
                                
                    xMinColor = int4((xl * scalep - p) / 2.0f + 0.5f) * 2 + p;
                    xMinColor = clamp(xMinColor, p, iscalep - 1 + p);
                    xMaxColor = int4((xh * scalep - p) / 2.0f + 0.5f) * 2 + p;
                    xMaxColor = clamp(xMaxColor, p, iscalep - 1 + p);
                                        
                    lo[p] = xMinColor;
                    hi[p] = xMaxColor;

                    lo[0] >>= 1;
                    hi[0] >>= 1;
                }

                fixDegenerateEndpoints(mode, &lo[0], &hi[0], &xl, &xh, iscalep >> 1);
                fixDegenerateEndpoints(mode, &lo[1], &hi[1], &xl, &xh, iscalep >> 1);
                
                uint pbits[2];
                
                pbits[0] = 0; pbits[1] = 0;
                evaluate_solution(&lo[0], &hi[0], pbits, pParams, pResults, num_pixels, pPixels);

                pbits[0] = 1; pbits[1] = 1;
                evaluate_solution(&lo[1], &hi[1], pbits, pParams, pResults, num_pixels, pPixels);
            }
        }
        else*/
        {
            // compensated rounding
            const int iscalep = (1 << (pParams.m_comp_bits + 1)) - 1;
            precise const float scalep = (float)iscalep;

            const int totalComps = pParams.m_has_alpha ? 4 : 3;

            uint best_pbits[2];
            color_quad_i bestMinColor, bestMaxColor;
                        
            if (!pParams.m_endpoints_share_pbit)
            {
                precise float best_err0 = 1e+9;
                precise float best_err1 = 1e+9;
                                
                for (int p = 0; p < 2; p++)
                {
                    color_quad_i xMinColor, xMaxColor;

                    // Notes: The pbit controls which quantization intervals are selected.
                    // total_levels=2^(comp_bits+1), where comp_bits=4 for mode 0, etc.
                    // pbit 0: v=(b*2)/(total_levels-1), pbit 1: v=(b*2+1)/(total_levels-1) where b is the component bin from [0,total_levels/2-1] and v is the [0,1] component value
                    // rearranging you get for pbit 0: b=floor(v*(total_levels-1)/2+.5)
                    // rearranging you get for pbit 1: b=floor((v*(total_levels-1)-1)/2+.5)
                    precise float4 xminc = (xl * scalep - p) / 2.0f + 0.5f;
                    xMinColor = int4(xminc) * 2 + p;
                    xMinColor = clamp(xMinColor, p, iscalep - 1 + p);
                    precise float4 xmaxc = (xh * scalep - p) / 2.0f + 0.5f;
                    xMaxColor = int4(xmaxc) * 2 + p;
                    xMaxColor = clamp(xMaxColor, p, iscalep - 1 + p);
                                                                                
                    color_quad_i scaledLow = scale_color(xMinColor, pParams);
                    color_quad_i scaledHigh = scale_color(xMaxColor, pParams);

                    precise float err0 = 0;
                    precise float err1 = 0;
                    for (int i = 0; i < totalComps; i++)
                    {
                        err0 += square(scaledLow[i] - xl[i]*255.0f);
                        err1 += square(scaledHigh[i] - xh[i]*255.0f);
                    }

                    if (err0 < best_err0)
                    {
                        best_err0 = err0;
                        best_pbits[0] = p;
                        
                        bestMinColor = xMinColor >> 1;
                    }

                    if (err1 < best_err1)
                    {
                        best_err1 = err1;
                        best_pbits[1] = p;
                        
                        bestMaxColor = xMaxColor >> 1;
                    }
                }
            }
            else
            {
                // Endpoints share pbits
                precise float best_err = 1e+9;

                for (int p = 0; p < 2; p++)
                {
                    color_quad_i xMinColor, xMaxColor;
                    
                    precise float4 xminc = (xl * scalep - p) / 2.0f + 0.5f;
                    xMinColor = int4(xminc) * 2 + p;
                    xMinColor = clamp(xMinColor, p, iscalep - 1 + p);
                    precise float4 xmaxc = (xh * scalep - p) / 2.0f + 0.5f;
                    xMaxColor = int4(xmaxc) * 2 + p;
                    xMaxColor = clamp(xMaxColor, p, iscalep - 1 + p);
                                        
                    color_quad_i scaledLow = scale_color(xMinColor, pParams);
                    color_quad_i scaledHigh = scale_color(xMaxColor, pParams);

                    precise float err = 0;
                    for (int i = 0; i < totalComps; i++)
                        err += square((scaledLow[i]/255.0f) - xl[i]) + square((scaledHigh[i]/255.0f) - xh[i]);

                    if (err < best_err)
                    {
                        best_err = err;
                        best_pbits[0] = p;
                        best_pbits[1] = p;
                        
                        bestMinColor = xMinColor >> 1;
                        bestMaxColor = xMaxColor >> 1;
                    }
                }
            }

            fixDegenerateEndpoints(mode, bestMinColor, bestMaxColor, xl, xh, iscalep >> 1);

            uint best_pbits_mask = best_pbits[0] | (best_pbits[1] << 1);
            if ((pResults.m_best_overall_err == UINT_MAX) || color_quad_i_notequals(bestMinColor, pResults.m_low_endpoint) || color_quad_i_notequals(bestMaxColor, pResults.m_high_endpoint) || (best_pbits_mask != pResults.m_pbits))
            {
                evaluate_solution(bestMinColor, bestMaxColor, best_pbits, pParams, pResults, num_pixels, pPixels);
            }
        }
    }
    else
    {
        const int iscale = (1 << pParams.m_comp_bits) - 1;
        const precise float scale = (float)iscale;

        precise float4 fxl = xl * scale + .5f;
        precise float4 fxh = xh * scale + .5f;
        color_quad_i trialMinColor = clamp(int4(fxl), 0, 255);
        color_quad_i trialMaxColor = clamp(int4(fxh), 0, 255);

        fixDegenerateEndpoints(mode, trialMinColor, trialMaxColor, xl, xh, iscale);

        if ((pResults.m_best_overall_err == UINT_MAX) || color_quad_i_notequals(trialMinColor, pResults.m_low_endpoint) || color_quad_i_notequals(trialMaxColor, pResults.m_high_endpoint))
        {
            uint pbits[2];
            pbits[0] = 0;
            pbits[1] = 0;

            evaluate_solution(trialMinColor, trialMaxColor, pbits, pParams, pResults, num_pixels, pPixels);
        }
    }

    return pResults.m_best_overall_err;
}

// Note: In mode 6, m_has_alpha will only be true for transparent blocks.
static uint color_cell_compression(uint mode, const color_cell_compressor_params pParams, inout color_cell_compressor_results pResults,
    uint num_pixels, const color_quad_i pPixels[16], bool refinement)
{
    pResults.m_best_overall_err = UINT_MAX;

    if ((mode != 6) && (mode != 7))
    {
        assert(!pParams.m_has_alpha);
    }

    if ((mode <= 2) || (mode == 4) || (mode >= 6))
    {
        color_quad_i c = pPixels[0];
        bool allSame = true;
        for (uint ii = 1; ii < num_pixels; ii++)
        {
            if (!all(c == pPixels[ii]))
            {
                allSame = false;
                break;
            }
        }

        if (allSame)
        {
            ModePackResult res = pack_mode_to_one_color(mode, pParams, pResults, c, num_pixels, pPixels);
            for (uint ip = 0; ip < num_pixels; ++ip)
                pResults.m_selectors[ip] = res.bestSelector;
            return res.err;
        }
    }

    precise vec4F meanColor = 0.0f;
    for (uint im = 0; im < num_pixels; im++)
        meanColor += float4(pPixels[im]);
    precise vec4F meanColorScaled = meanColor * (1.0f / num_pixels);

    meanColor = saturate(meanColor * (1.0f / (num_pixels * 255.0f)));

    precise vec4F axis;
    if (pParams.m_has_alpha)
    {
        precise vec4F v = 0.0f;
        for (uint ia = 0; ia < num_pixels; ia++)
        {
            vec4F color = float4(pPixels[ia]) - meanColorScaled;

            precise vec4F a = color * color.r;
            precise vec4F b = color * color.g;
            precise vec4F c = color * color.b;
            precise vec4F d = color * color.a;

            precise vec4F n = ia ? v : color;
            n = vec4F_normalize(n);

            v.r += dot4(a, n);
            v.g += dot4(b, n);
            v.b += dot4(c, n);
            v.a += dot4(d, n);
        }
        axis = v;
        axis = vec4F_normalize(axis);
    }
    else
    {
        precise float cov[6];
        cov[0] = 0; cov[1] = 0; cov[2] = 0;
        cov[3] = 0; cov[4] = 0;    cov[5] = 0;

        for (uint ic = 0; ic < num_pixels; ic++)
        {
            precise float3 p = float3(pPixels[ic].rgb);

            precise float r = p.r - meanColorScaled.r;
            precise float g = p.g - meanColorScaled.g;
            precise float b = p.b - meanColorScaled.b;
                
            cov[0] += r*r;
            cov[1] += r*g;
            cov[2] += r*b;
            cov[3] += g*g;
            cov[4] += g*b;
            cov[5] += b*b;
        }

        precise float vfr, vfg, vfb;
        //vfr = hi[0] - lo[0];
        //vfg = hi[1] - lo[1];
        //vfb = hi[2] - lo[2];
        // This is more stable.
        vfr = .9f;
        vfg = 1.0f;
        vfb = .7f;

        for (uint iter = 0; iter < 3; iter++)
        {
            precise float r = vfr*cov[0] + vfg*cov[1] + vfb*cov[2];
            precise float g = vfr*cov[1] + vfg*cov[3] + vfb*cov[4];
            precise float b = vfr*cov[2] + vfg*cov[4] + vfb*cov[5];

            precise float m = max3(abs(r), abs(g), abs(b));
            if (m > 1e-10f)
            {
                m = 1.0f / m;
                r *= m;
                g *= m;
                b *= m;
            }

            //float delta = square(vfr - r) + square(vfg - g) + square(vfb - b);

            vfr = r;
            vfg = g;
            vfb = b;

            //if ((iter > 1) && (delta < 1e-8f))
            //    break;
        }

        precise float len = vfr*vfr + vfg*vfg + vfb*vfb;

        if (len < 1e-10f)
            axis = 0.0f;
        else
        {
            len = 1.0f / sqrt(len);
            vfr *= len;
            vfg *= len;
            vfb *= len;
            axis = float4(vfr, vfg, vfb, 0);
        }
    }

    if (dot4(axis, axis) < .5f)
    {
        if (pParams.m_perceptual)
            axis = float4(.213f, .715f, .072f, pParams.m_has_alpha ? .715f : 0);
        else
            axis = float4(1.0f, 1.0f, 1.0f, pParams.m_has_alpha ? 1.0f : 0);
        axis = vec4F_normalize(axis);
    }

    precise float l = 1e+9f, h = -1e+9f;

    for (uint i = 0; i < num_pixels; i++)
    {
        precise vec4F q = float4(pPixels[i]) - meanColorScaled;
        precise float d = dot4(q, axis);

        l = min(l, d);
        h = max(h, d);
    }

    l *= (1.0f / 255.0f);
    h *= (1.0f / 255.0f);

    precise vec4F b0 = axis * l;
    precise vec4F b1 = axis * h;
    precise vec4F c0 = meanColor + b0;
    precise vec4F c1 = meanColor + b1;
    precise vec4F minColor = saturate(c0);
    precise vec4F maxColor = saturate(c1);
                
    precise vec4F whiteVec = 1.0f;
    if (dot4(minColor, whiteVec) > dot4(maxColor, whiteVec))
    {
        vec4F temp = minColor;
        minColor = maxColor;
        maxColor = temp;
    }

    if (!find_optimal_solution(mode, minColor, maxColor, pParams, pResults, glob_is_pbit_search(), num_pixels, pPixels))
        return 0;
    
    if (!refinement)
        return pResults.m_best_overall_err;
    
    // Note: m_refinement_passes is always 1, so hardcode to one loop iteration
    //for (uint i = 0; i < g_params.m_refinement_passes; i++)
    {
        precise vec4F xl = 0.0f, xh = 0.0f;
        if (pParams.m_has_alpha)
            compute_least_squares_endpoints_rgba(num_pixels, pResults.m_selectors, pParams.m_weights_index, xl, xh, pPixels);
        else
        {
            compute_least_squares_endpoints_rgb(num_pixels, pResults.m_selectors, pParams.m_weights_index, xl, xh, pPixels);
            xl.a = 255.0f;
            xh.a = 255.0f;
        }

        xl = xl * (1.0f / 255.0f);
        xh = xh * (1.0f / 255.0f);

        if (!find_optimal_solution(mode, xl, xh, pParams, pResults, glob_is_pbit_search(), num_pixels, pPixels))
            return 0;
    }

#if !defined(OPT_FASTMODES_ONLY) && !defined(OPT_ULTRAFAST_ONLY)
    if (g_params.m_uber_level > 0)
    {
        int selectors_temp0[16], selectors_temp1[16];
        for (uint i = 0; i < num_pixels; i++)
            selectors_temp0[i] = pResults->m_pSelectors[i];

        const int max_selector = pParams->m_num_selector_weights - 1;

        uint min_sel = 16;
        uint max_sel = 0;
        for (uint i = 0; i < num_pixels; i++)
        {
            uint sel = selectors_temp0[i];
            min_sel = min(min_sel, sel);
            max_sel = max(max_sel, sel);
        }

        vec4F xl = 0.0f, xh = 0.0f;

        if (g_params.m_uber1_mask & 1)
        {
            for (uint i = 0; i < num_pixels; i++)
            {
                uint sel = selectors_temp0[i];
                if ((sel == min_sel) && (sel < (pParams->m_num_selector_weights - 1)))
                    sel++;
                selectors_temp1[i] = sel;
            }
                        
            if (pParams->m_has_alpha)
                compute_least_squares_endpoints_rgba(num_pixels, selectors_temp1, pParams->m_weights_index, &xl, &xh, pPixels);
            else
            {
                compute_least_squares_endpoints_rgb(num_pixels, selectors_temp1, pParams->m_weights_index, &xl, &xh, pPixels);
                xl.a = 255.0f;
                xh.a = 255.0f;
            }

            xl *= 1.0f / 255.0f;
            xh *= 1.0f / 255.0f;

            if (!find_optimal_solution(mode, &xl, &xh, pParams, pResults, glob_is_pbit_search(), num_pixels, pPixels))
                return 0;
        }

        if (g_params.m_uber1_mask & 2)
        {
            for (uint i = 0; i < num_pixels; i++)
            {
                uint sel = selectors_temp0[i];
                if ((sel == max_sel) && (sel > 0))
                    sel--;
                selectors_temp1[i] = sel;
            }

            if (pParams->m_has_alpha)
                compute_least_squares_endpoints_rgba(num_pixels, selectors_temp1, pParams->m_weights_index, &xl, &xh, pPixels);
            else
            {
                compute_least_squares_endpoints_rgb(num_pixels, selectors_temp1, pParams->m_weights_index, &xl, &xh, pPixels);
                xl.a = 255.0f;
                xh.a = 255.0f;
            }

            xl *= 1.0f / 255.0f;
            xh *= 1.0f / 255.0f;

            if (!find_optimal_solution(mode, &xl, &xh, pParams, pResults, glob_is_pbit_search(), num_pixels, pPixels))
                return 0;
        }

        if (g_params.m_uber1_mask & 4)
        {
            for (uint i = 0; i < num_pixels; i++)
            {
                uint sel = selectors_temp0[i];
                if ((sel == min_sel) && (sel < (pParams->m_num_selector_weights - 1)))
                    sel++;
                else if ((sel == max_sel) && (sel > 0))
                    sel--;
                selectors_temp1[i] = sel;
            }

            if (pParams->m_has_alpha)
                compute_least_squares_endpoints_rgba(num_pixels, selectors_temp1, pParams->m_weights_index, &xl, &xh, pPixels);
            else
            {
                compute_least_squares_endpoints_rgb(num_pixels, selectors_temp1, pParams->m_weights_index, &xl, &xh, pPixels);
                xl.a = 255.0f;
                xh.a = 255.0f;
            }

            xl *= 1.0f / 255.0f;
            xh *= 1.0f / 255.0f;

            if (!find_optimal_solution(mode, &xl, &xh, pParams, pResults, glob_is_pbit_search(), num_pixels, pPixels))
                return 0;
        }

        const uint uber_err_thresh = (num_pixels * 56) >> 4;
        if ((g_params.m_uber_level >= 2) && (pResults->m_best_overall_err > uber_err_thresh))
        {
            const int Q = (g_params.m_uber_level >= 4) ? (g_params.m_uber_level - 2) : 1;
            for (int ly = -Q; ly <= 1; ly++)
            {
                for (int hy = max_selector - 1; hy <= (max_selector + Q); hy++)
                {
                    if ((ly == 0) && (hy == max_selector))
                        continue;

                    for (uint i = 0; i < num_pixels; i++)
                        selectors_temp1[i] = (int)clamp(floor((float)max_selector * ((float)(int)selectors_temp0[i] - (float)ly) / ((float)hy - (float)ly) + .5f), 0.0f, (float)max_selector);

                    xl = 0.0f;
                    xh = 0.0f;
                    if (pParams->m_has_alpha)
                        compute_least_squares_endpoints_rgba(num_pixels, selectors_temp1, pParams->m_weights_index, &xl, &xh, pPixels);
                    else
                    {
                        compute_least_squares_endpoints_rgb(num_pixels, selectors_temp1, pParams->m_weights_index, &xl, &xh, pPixels);
                        xl.a = 255.0f;
                        xh.a = 255.0f;
                    }

                    xl *= 1.0f / 255.0f;
                    xh *= 1.0f / 255.0f;

                    if (!find_optimal_solution(mode, &xl, &xh, pParams, pResults, glob_is_pbit_search() && (g_params.m_uber_level >= 2), num_pixels, pPixels))
                        return 0;
                }
            }
        }
    }
#endif // #if !defined(OPT_FASTMODES_ONLY) && !defined(OPT_ULTRAFAST_ONLY)

    if ((mode <= 2) || (mode == 4) || (mode >= 6))
    {
        color_cell_compressor_results avg_results = (color_cell_compressor_results)0;
                    
        avg_results.m_best_overall_err = pResults.m_best_overall_err;
        avg_results.m_selectors = pResults.m_selectors;
        
        color_quad_i avg_c = int4(.5f + meanColor * 255.0f);

        ModePackResult avg_res = pack_mode_to_one_color(mode, pParams, avg_results, avg_c, num_pixels, pPixels);

        if (avg_res.err < pResults.m_best_overall_err)
        {
            pResults.m_best_overall_err = avg_res.err;
            pResults.m_low_endpoint = avg_results.m_low_endpoint;
            pResults.m_high_endpoint = avg_results.m_high_endpoint;
            pResults.m_pbits = avg_results.m_pbits;
            for (uint i = 0; i < num_pixels; ++i)
                pResults.m_selectors[i] = avg_res.bestSelector;
        }
    }
                    
    return pResults.m_best_overall_err;
}

static uint color_cell_compression_est(uint mode, const color_cell_compressor_params pParams, uint best_err_so_far, uint num_pixels, const color_quad_i pPixels[16])
{
    assert((pParams.m_num_selector_weights == 4) || (pParams.m_num_selector_weights == 8));

    float lr = 255, lg = 255, lb = 255;
    float hr = 0, hg = 0, hb = 0;
    for (uint i = 0; i < num_pixels; i++)
    {
        int3 p = pPixels[i].rgb;

        float r = p.r;
        float g = p.g;
        float b = p.b;
        
        lr = min(lr, r);
        lg = min(lg, g);
        lb = min(lb, b);

        hr = max(hr, r);
        hg = max(hg, g);
        hb = max(hb, b);
    }
            
    const uint N = 1 << g_bc7_color_index_bitcount[mode];
                        
    uint total_err = 0;
    
    float sr = lr;
    float sg = lg;
    float sb = lb;

    float dir = hr - lr;
    float dig = hg - lg;
    float dib = hb - lb;

    float far = dir;
    float fag = dig;
    float fab = dib;

    float low = far * sr + fag * sg + fab * sb;
    float high = far * hr + fag * hg + fab * hb;

    float scale = ((float)N - 1) / (float)(high - low);
    float inv_n = 1.0f / ((float)N - 1);

    float total_errf = 0;

    // We don't handle perceptual very well here, but the difference is very slight (<.05 dB avg Luma PSNR across a large corpus) and the perf lost was high (2x slower).
    if ((pParams.m_weights[0] != 1) || (pParams.m_weights[1] != 1) || (pParams.m_weights[2] != 1))
    {
        float wr = pParams.m_weights[0];
        float wg = pParams.m_weights[1];
        float wb = pParams.m_weights[2];

        for (uint i = 0; i < num_pixels; i++)
        {
            const color_quad_i pC = pPixels[i];

            float d = far * (float)pC.r + fag * (float)pC.g + fab * (float)pC.b;

            float s = clamp(floor((d - low) * scale + .5f) * inv_n, 0.0f, 1.0f);

            float itr = sr + dir * s;
            float itg = sg + dig * s;
            float itb = sb + dib * s;

            float dr = itr - (float)pC.r;
            float dg = itg - (float)pC.g;
            float db = itb - (float)pC.b;

            total_errf += wr * dr * dr + wg * dg * dg + wb * db * db;
        }
    }
    else
    {
        for (uint i = 0; i < num_pixels; i++)
        {
            const color_quad_i pC = pPixels[i];

            float d = far * (float)pC.r + fag * (float)pC.g + fab * (float)pC.b;

            float s = clamp(floor((d - low) * scale + .5f) * inv_n, 0.0f, 1.0f);

            float itr = sr + dir * s;
            float itg = sg + dig * s;
            float itb = sb + dib * s;

            float dr = itr - (float)pC.r;
            float dg = itg - (float)pC.g;
            float db = itb - (float)pC.b;

            total_errf += dr * dr + dg * dg + db * db;
        }
    }

    total_err = (int)total_errf;

    return total_err;
}

static uint color_cell_compression_est_mode7(uint mode, const color_cell_compressor_params pParams, uint best_err_so_far, uint num_pixels, const color_quad_i pPixels[16])
{
    assert((mode == 7) && (pParams.m_num_selector_weights == 4));

    float lr = 255, lg = 255, lb = 255, la = 255;
    float hr = 0, hg = 0, hb = 0, ha = 0;
    for (uint i = 0; i < num_pixels; i++)
    {
        int4 p = pPixels[i];
        float r = p.r;
        float g = p.g;
        float b = p.b;
        float a = p.a;
        
        lr = min(lr, r);
        lg = min(lg, g);
        lb = min(lb, b);
        la = min(la, a);

        hr = max(hr, r);
        hg = max(hg, g);
        hb = max(hb, b);
        ha = max(ha, a);
    }
            
    const uint N = 4;
                        
    uint total_err = 0;
    
    float sr = lr;
    float sg = lg;
    float sb = lb;
    float sa = la;

    float dir = hr - lr;
    float dig = hg - lg;
    float dib = hb - lb;
    float dia = ha - la;

    float far = dir;
    float fag = dig;
    float fab = dib;
    float faa = dia;

    float low = far * sr + fag * sg + fab * sb + faa * sa;
    float high = far * hr + fag * hg + fab * hb + faa * ha;

    float scale = ((float)N - 1) / (float)(high - low);
    float inv_n = 1.0f / ((float)N - 1);

    float total_errf = 0;

    // We don't handle perceptual very well here, but the difference is very slight (<.05 dB avg Luma PSNR across a large corpus) and the perf lost was high (2x slower).
    if ( (!pParams.m_perceptual) && ((pParams.m_weights[0] != 1) || (pParams.m_weights[1] != 1) || (pParams.m_weights[2] != 1) || (pParams.m_weights[3] != 1)) )
    {
        float wr = pParams.m_weights[0];
        float wg = pParams.m_weights[1];
        float wb = pParams.m_weights[2];
        float wa = pParams.m_weights[3];

        for (uint i = 0; i < num_pixels; i++)
        {
            const color_quad_i pC = pPixels[i];

            float d = far * (float)pC.r + fag * (float)pC.g + fab * (float)pC.b + faa * (float)pC.a;

            float s = clamp(floor((d - low) * scale + .5f) * inv_n, 0.0f, 1.0f);

            float itr = sr + dir * s;
            float itg = sg + dig * s;
            float itb = sb + dib * s;
            float ita = sa + dia * s;

            float dr = itr - (float)pC.r;
            float dg = itg - (float)pC.g;
            float db = itb - (float)pC.b;
            float da = ita - (float)pC.a;

            total_errf += wr * dr * dr + wg * dg * dg + wb * db * db + wa * da * da;
        }
    }
    else
    {
        for (uint i = 0; i < num_pixels; i++)
        {
            const color_quad_i pC = pPixels[i];

            float d = far * (float)pC.r + fag * (float)pC.g + fab * (float)pC.b + faa * (float)pC.a;

            float s = clamp(floor((d - low) * scale + .5f) * inv_n, 0.0f, 1.0f);

            float itr = sr + dir * s;
            float itg = sg + dig * s;
            float itb = sb + dib * s;
            float ita = sa + dia * s;

            float dr = itr - (float)pC.r;
            float dg = itg - (float)pC.g;
            float db = itb - (float)pC.b;
            float da = ita - (float)pC.a;

            total_errf += dr * dr + dg * dg + db * db + da * da;
        }
    }

    total_err = (int)total_errf;

    return total_err;
}

static uint estimate_partition(uint mode, const color_quad_i pPixels[16])
{
    const uint total_subsets = g_bc7_num_subsets[mode];
    uint total_partitions = min(g_params.m_max_partitions_mode[mode>>2][mode&3], 1U << g_bc7_partition_bits[mode]);

    if (total_partitions <= 1)
        return 0;

    uint best_err = UINT_MAX;
    uint best_partition = 0;

    color_cell_compressor_params params;
    color_cell_compressor_params_clear(params);

    params.m_weights_index = (g_bc7_color_index_bitcount[mode] == 2) ? kBC7Weights2Index : kBC7Weights3Index;
    params.m_num_selector_weights = 1 << g_bc7_color_index_bitcount[mode];

    params.m_weights = g_params.m_weights;

    // Note: m_mode67_error_weight_mul was always 1, removed

    params.m_perceptual = glob_is_perceptual();

    for (uint partition = 0; partition < total_partitions; partition++)
    {
        int pPartition[16];
        if (total_subsets == 3)
            pPartition = g_bc7_partition3[partition];
        else
            pPartition = g_bc7_partition2[partition];

        color_quad_i subset_colors[3][16];
        uint subset_total_colors[3];
        subset_total_colors[0] = 0;
        subset_total_colors[1] = 0;
        subset_total_colors[2] = 0;
        
        for (uint index = 0; index < 16; index++)
        {
            const uint p = pPartition[index];

            subset_colors[p][subset_total_colors[p]] = pPixels[index];
            subset_total_colors[p]++;
        }

        uint total_subset_err = 0;

        for (uint subset = 0; subset < total_subsets; subset++)
        {
            uint err;
            if (mode == 7)
                err = color_cell_compression_est_mode7(mode, params, best_err, subset_total_colors[subset], subset_colors[subset]);
            else
                err = color_cell_compression_est(mode, params, best_err, subset_total_colors[subset], subset_colors[subset]);

            total_subset_err += err;

        } // subset

        if (total_subset_err < best_err)
        {
            best_err = total_subset_err;
            best_partition = partition;
            if (!best_err)
                break;
        }

        if (total_subsets == 2)
        {
            if ((partition == BC7E_2SUBSET_CHECKERBOARD_PARTITION_INDEX) && (best_partition != BC7E_2SUBSET_CHECKERBOARD_PARTITION_INDEX))
                break;
        }

    } // partition

    return best_partition;
}

struct solution
{
    uint m_index;
    uint m_err;
};

static uint estimate_partition_list(uint mode, const color_quad_i pPixels[16],
    inout solution pSolutions[4], int max_solutions)
{
    const int orig_max_solutions = max_solutions;

    const uint total_subsets = g_bc7_num_subsets[mode];
    uint total_partitions = min(g_params.m_max_partitions_mode[mode>>2][mode&3], 1U << g_bc7_partition_bits[mode]);

    if (total_partitions <= 1)
    {
        pSolutions[0].m_index = 0;
        pSolutions[0].m_err = 0;
        return 1;
    }
    else if (max_solutions >= total_partitions)
    {
        for (int i = 0; i < total_partitions; i++)
        {
            pSolutions[i].m_index = i;
            pSolutions[i].m_err = i;
        }
        return total_partitions;
    }

    const int HIGH_FREQUENCY_SORTED_PARTITION_THRESHOLD = 4;
    if (total_subsets == 2)
    {
        if (max_solutions < HIGH_FREQUENCY_SORTED_PARTITION_THRESHOLD)
            max_solutions = HIGH_FREQUENCY_SORTED_PARTITION_THRESHOLD;
    }
                        
    color_cell_compressor_params params;
    color_cell_compressor_params_clear(params);

    params.m_weights_index = (g_bc7_color_index_bitcount[mode] == 2) ? kBC7Weights2Index : kBC7Weights3Index;
    params.m_num_selector_weights = 1 << g_bc7_color_index_bitcount[mode];

    params.m_weights = g_params.m_weights;

    // Note: m_mode67_error_weight_mul was always 1, removed

    params.m_perceptual = glob_is_perceptual();

    int num_solutions = 0;

    for (uint partition = 0; partition < total_partitions; partition++)
    {
        int pPartition[16];
        if (total_subsets == 3)
            pPartition = g_bc7_partition3[partition];
        else
            pPartition = g_bc7_partition2[partition];

        color_quad_i subset_colors[3][16];
        uint subset_total_colors[3];
        subset_total_colors[0] = 0;
        subset_total_colors[1] = 0;
        subset_total_colors[2] = 0;

        for (uint index = 0; index < 16; index++)
        {
            const uint p = pPartition[index];

            subset_colors[p][subset_total_colors[p]] = pPixels[index];
            subset_total_colors[p]++;
        }
                
        uint total_subset_err = 0;

        for (uint subset = 0; subset < total_subsets; subset++)
        {
            uint err;
            if (mode == 7)
                err = color_cell_compression_est_mode7(mode, params, UINT_MAX, subset_total_colors[subset], subset_colors[subset]);
            else
                err = color_cell_compression_est(mode, params, UINT_MAX, subset_total_colors[subset], subset_colors[subset]);

            total_subset_err += err;

        } // subset

        int i;
        for (i = 0; i < num_solutions; i++)
        {
            if (total_subset_err < pSolutions[i].m_err)
                break;
        }
                        
        if (i < num_solutions)
        {
            int solutions_to_move = (max_solutions - 1) - i;
            int num_elements_at_i = num_solutions - i;
            if (solutions_to_move > num_elements_at_i)
                solutions_to_move = num_elements_at_i;
                                                                
            assert(((i + 1) + solutions_to_move) <= max_solutions);
            assert((i + solutions_to_move) <= num_solutions);
            
            for (int j = solutions_to_move - 1; j >= 0; --j)
            {
                pSolutions[i + j + 1] = pSolutions[i + j];
            }
        }

        if (num_solutions < max_solutions)
            num_solutions++;

        if (i < num_solutions)
        {
            pSolutions[i].m_err = total_subset_err;

            pSolutions[i].m_index = partition;
        }

        //@TODO: disabled this for now since it produces different result
        // on different SIMD widths.
        //if ((total_subsets == 2) && (partition == BC7E_2SUBSET_CHECKERBOARD_PARTITION_INDEX))
        //{
        //    if (simd_all(i >= HIGH_FREQUENCY_SORTED_PARTITION_THRESHOLD))
        //        break;
        //}

    } // partition

#if 0
    for (int i = 0; i < num_solutions; i++)
    {
        assert(pSolutions[i].m_index < total_partitions);
    }

    for (int i = 0; i < (num_solutions - 1); i++)
    {
        assert(pSolutions[i].m_err <= pSolutions[i + 1].m_err);
    }
#endif

    return min(num_solutions, orig_max_solutions);
}

static inline void set_block_bits(inout uint pWords[4], uint val, uint num_bits, inout uint pCur_ofs)
{
    assert(num_bits < 32);
    uint limit = 1U << num_bits;
    assert(val < limit);
        
    while (num_bits)
    {
        const uint n = min(32 - (pCur_ofs & 31), num_bits);

        pWords[pCur_ofs >> 5] |= (val << (pCur_ofs & 31));

        val >>= n;
        num_bits -= n;
        pCur_ofs += n;
    }

    assert(pCur_ofs <= 128);
}

struct bc7_optimization_results
{
    int m_selectors[16];        // 64B
    int m_alpha_selectors[16];  // 64B
    color_quad_i m_low[3];      // 12B
    color_quad_i m_high[3];     // 12B
    uint m_error;               // 4B
    uint m_mode;                // 4B
    uint m_partition;           // 4B
    uint m_pbits;               // 4B [3][2] array of one bit each
    uint m_rotation_index_sel;  // 4B 4 bits rotation, 4 bits index selector
}; // = 172B

static uint4 encode_bc7_block(const bc7_optimization_results pResults)
{
    const uint best_mode = pResults.m_mode;

    const uint total_subsets = g_bc7_num_subsets[best_mode];

    const uint total_partitions = 1 << g_bc7_partition_bits[best_mode];

    int pPartition[16];
    if (total_subsets == 1)
        pPartition = g_bc7_partition1;
    else if (total_subsets == 2)
        pPartition = g_bc7_partition2[pResults.m_partition];
    else
        pPartition = g_bc7_partition3[pResults.m_partition];

    int color_selectors[16] = pResults.m_selectors;
    int alpha_selectors[16] = pResults.m_alpha_selectors;

    color_quad_i low[3], high[3];
    low[0] = pResults.m_low[0];
    low[1] = pResults.m_low[1];
    low[2] = pResults.m_low[2];

    high[0] = pResults.m_high[0];
    high[1] = pResults.m_high[1];
    high[2] = pResults.m_high[2];
    
    uint rpbits = pResults.m_pbits;
    uint pbits[3][2];
    pbits[0][0] = (rpbits & 1) ? 1 : 0;
    pbits[0][1] = (rpbits & 2) ? 1 : 0;
    pbits[1][0] = (rpbits & 4) ? 1 : 0;
    pbits[1][1] = (rpbits & 8) ? 1 : 0;
    pbits[2][0] = (rpbits & 16) ? 1 : 0;
    pbits[2][1] = (rpbits & 32) ? 1 : 0;

    int anchor[3];
    anchor[0] = -1;
    anchor[1] = -1;
    anchor[2] = -1;

    int index_selector = pResults.m_rotation_index_sel >> 4;
    int rotation = pResults.m_rotation_index_sel & 0xF;

    for (uint k = 0; k < total_subsets; k++)
    {
        uint anchor_index = 0;
        if (k)
        {
            if ((total_subsets == 3) && (k == 1))
            {
                anchor_index = g_bc7_table_anchor_index_third_subset_1[pResults.m_partition];
            }
            else if ((total_subsets == 3) && (k == 2))
            {
                anchor_index = g_bc7_table_anchor_index_third_subset_2[pResults.m_partition];
            }
            else
            {
                anchor_index = g_bc7_table_anchor_index_second_subset[pResults.m_partition];
            }
        }

        anchor[k] = anchor_index;

        const uint color_index_bits = get_bc7_color_index_size(best_mode, index_selector);
        const uint num_color_indices = 1 << color_index_bits;

        if (color_selectors[anchor_index] & (num_color_indices >> 1))
        {
            for (uint i = 0; i < 16; i++)
            {
                if (pPartition[i] == k)
                    color_selectors[i] = (num_color_indices - 1) - color_selectors[i];
            }

            if (get_bc7_mode_has_seperate_alpha_selectors(best_mode))
            {
                int3 t = low[k].rgb;
                low[k].rgb = high[k].rgb;
                high[k].rgb = t;
            }
            else
            {
                color_quad_i tmp = low[k];
                low[k] = high[k];
                high[k] = tmp;
            }

            if (!g_bc7_mode_has_shared_p_bits[best_mode])
            {
                uint t = pbits[k][0];
                pbits[k][0] = pbits[k][1];
                pbits[k][1] = t;
            }
        }

        if (get_bc7_mode_has_seperate_alpha_selectors(best_mode))
        {
            const uint alpha_index_bits = get_bc7_alpha_index_size(best_mode, index_selector);
            const uint num_alpha_indices = 1 << alpha_index_bits;

            if (alpha_selectors[anchor_index] & (num_alpha_indices >> 1))
            {
                for (uint i = 0; i < 16; i++)
                {
                    if (pPartition[i] == k)
                        alpha_selectors[i] = (num_alpha_indices - 1) - alpha_selectors[i];
                }

                int t = low[k].a;
                low[k].a = high[k].a;
                high[k].a = t;
            }
        }
    }

    uint block[4] = { 0,0,0,0 };

    uint cur_bit_ofs = 0;
        
    set_block_bits(block, 1 << best_mode, best_mode + 1, cur_bit_ofs);

    if ((best_mode == 4) || (best_mode == 5))
        set_block_bits(block, rotation, 2, cur_bit_ofs);

    if (best_mode == 4)
        set_block_bits(block, index_selector, 1, cur_bit_ofs);

    if (total_partitions > 1)
        set_block_bits(block, pResults.m_partition, (total_partitions == 64) ? 6 : 4, cur_bit_ofs);

    const uint total_comps = (best_mode >= 4) ? 4 : 3;
    for (uint comp = 0; comp < total_comps; comp++)
    {
        for (uint subset = 0; subset < total_subsets; subset++)
        {
            set_block_bits(block, low[subset][comp], (comp == 3) ? g_bc7_alpha_precision_table[best_mode] : g_bc7_color_precision_table[best_mode], cur_bit_ofs);
            set_block_bits(block, high[subset][comp], (comp == 3) ? g_bc7_alpha_precision_table[best_mode] : g_bc7_color_precision_table[best_mode], cur_bit_ofs);
        }
    }

    if (g_bc7_mode_has_p_bits[best_mode])
    {
        for (uint subset = 0; subset < total_subsets; subset++)
        {
            set_block_bits(block, pbits[subset][0], 1, cur_bit_ofs);
            if (!g_bc7_mode_has_shared_p_bits[best_mode])
                set_block_bits(block, pbits[subset][1], 1, cur_bit_ofs);
        }
    }

    for (uint y = 0; y < 4; y++)
    {
        for (uint x = 0; x < 4; x++)
        {
            int idx = x + y * 4;

            uint n = index_selector ? get_bc7_alpha_index_size(best_mode, index_selector) : get_bc7_color_index_size(best_mode, index_selector);

            if ((idx == anchor[0]) || (idx == anchor[1]) || (idx == anchor[2]))
                n--;

            set_block_bits(block, index_selector ? alpha_selectors[idx] : color_selectors[idx], n, cur_bit_ofs);
        }
    }

    if (get_bc7_mode_has_seperate_alpha_selectors(best_mode))
    {
        for (uint y = 0; y < 4; y++)
        {
            for (uint x = 0; x < 4; x++)
            {
                int idx = x + y * 4;

                uint n = index_selector ? get_bc7_color_index_size(best_mode, index_selector) : get_bc7_alpha_index_size(best_mode, index_selector);

                if ((idx == anchor[0]) || (idx == anchor[1]) || (idx == anchor[2]))
                    n--;

                set_block_bits(block, index_selector ? color_selectors[idx] : alpha_selectors[idx], n, cur_bit_ofs);
            }
        }
    }

    assert(cur_bit_ofs == 128);
    return uint4(block[0], block[1], block[2], block[3]);
}

static inline uint4 encode_bc7_block_mode6(const bc7_optimization_results pResults)
{
    color_quad_i low, high;
    uint pbits[2];
        
    uint invert_selectors = 0;
    uint invert_maskz = 0;
    uint invert_maskw = 0;
    if (pResults.m_selectors[0] & 8)
    {
        invert_selectors = 15;
        invert_maskz = 0xFFFFFFF0;
        invert_maskw = 0xFFFFFFFF;

        low = pResults.m_high[0];
        high = pResults.m_low[0];

        pbits[0] = (pResults.m_pbits & 2) ? 1 : 0;
        pbits[1] = (pResults.m_pbits & 1) ? 1 : 0;
    }
    else
    {
        low = pResults.m_low[0];
        high = pResults.m_high[0];

        pbits[0] = (pResults.m_pbits & 1) ? 1 : 0;
        pbits[1] = (pResults.m_pbits & 2) ? 1 : 0;
    }

    uint4 r = 0;

    r.x = 1 << 6;

    r.x |= (low.r << 7);
    r.x |= (high.r << 14);

    r.x |= (low.g << 21);
    r.x |= (high.g << 28); // 4 bits
    r.y |= (high.g >> 4); // 3 bits

    r.y |= (low.b << 3);
    r.y |= (high.b << 10);

    r.y |= (low.a << 17);
    r.y |= (high.a << 24);

    r.y |= (pbits[0] << 31);
        
    r.z = pbits[1];
    
    r.z |= ((invert_selectors ^ pResults.m_selectors[0]) << 1);

    r.z |= pResults.m_selectors[1] << 4;
    r.z |= pResults.m_selectors[2] << 8;
    r.z |= pResults.m_selectors[3] << 12;
    r.z |= pResults.m_selectors[4] << 16;
    
    r.z |= pResults.m_selectors[5] << 20;
    r.z |= pResults.m_selectors[6] << 24;
    r.z |= pResults.m_selectors[7] << 28;
    r.w |= pResults.m_selectors[8] << 0;

    r.w |= pResults.m_selectors[9] << 4;
    r.w |= pResults.m_selectors[10] << 8;
    r.w |= pResults.m_selectors[11] << 12;
    r.w |= pResults.m_selectors[12] << 16;

    r.w |= pResults.m_selectors[13] << 20;
    r.w |= pResults.m_selectors[14] << 24;
    r.w |= pResults.m_selectors[15] << 28;
    
    r.z ^= invert_maskz;
    r.w ^= invert_maskw;

    return r;
}

static void handle_alpha_block_mode4(const color_quad_i pPixels[16], color_cell_compressor_params pParams, uint lo_a, uint hi_a,
    inout bc7_optimization_results pOpt_results4)
{
    pParams.m_has_alpha = false;
    pParams.m_comp_bits = 5;
    pParams.m_has_pbits = false;
    pParams.m_endpoints_share_pbit = false;
    pParams.m_perceptual = glob_is_perceptual();

    for (uint index_selector = 0; index_selector < 2; index_selector++)
    {
        if ((g_params.m_mode4_index_mask & (1 << index_selector)) == 0)
            continue;

        if (index_selector)
        {
            pParams.m_weights_index = kBC7Weights3Index;
            pParams.m_num_selector_weights = 8;
        }
        else
        {
            pParams.m_weights_index = kBC7Weights2Index;
            pParams.m_num_selector_weights = 4;
        }
                                
        color_cell_compressor_results results = (color_cell_compressor_results)0;
        
        uint trial_err = color_cell_compression(4, pParams, results, 16, pPixels, true);
        assert(trial_err == results.m_best_overall_err);

        uint la = min((lo_a + 2) >> 2, 63u);
        uint ha = min((hi_a + 2) >> 2, 63u);

        if (la == ha)
        {
            if (lo_a != hi_a)
            {
                if (ha != 63)
                    ha++;
                else if (la != 0)
                    la--;
            }
        }

        uint best_alpha_err = UINT_MAX;
        uint best_la = 0, best_ha = 0;
        int best_alpha_selectors[16];
                        
        for (int pss = 0; pss < 2; pss++)
        {
            int vals[8];

            if (index_selector == 0)
            {
                vals[0] = (la << 2) | (la >> 4);
                vals[7] = (ha << 2) | (ha >> 4);

                for (uint i = 1; i < 7; i++)
                    vals[i] = (vals[0] * (64 - get_table_bc7_weight(kBC7Weights3Index + i)) + vals[7] * get_table_bc7_weight(kBC7Weights3Index + i) + 32) >> 6;
            }
            else
            {
                vals[0] = (la << 2) | (la >> 4);
                vals[3] = (ha << 2) | (ha >> 4);

                const int w_s1 = 21, w_s2 = 43;
                vals[1] = (vals[0] * (64 - w_s1) + vals[3] * w_s1 + 32) >> 6;
                vals[2] = (vals[0] * (64 - w_s2) + vals[3] * w_s2 + 32) >> 6;
            }

            uint trial_alpha_err = 0;

            int trial_alpha_selectors[16];
            for (uint i = 0; i < 16; i++)
            {
                const int a = pPixels[i].a;

                int s = 0;
                int be = abs(a - vals[0]);

                int e = abs(a - vals[1]); if (e < be) { be = e; s = 1; }
                e = abs(a - vals[2]); if (e < be) { be = e; s = 2; }
                e = abs(a - vals[3]); if (e < be) { be = e; s = 3; }

                if (index_selector == 0)
                {
                    e = abs(a - vals[4]); if (e < be) { be = e; s = 4; }
                    e = abs(a - vals[5]); if (e < be) { be = e; s = 5; }
                    e = abs(a - vals[6]); if (e < be) { be = e; s = 6; }
                    e = abs(a - vals[7]); if (e < be) { be = e; s = 7; }
                }

                trial_alpha_err += (be * be) * pParams.m_weights[3];

                trial_alpha_selectors[i] = s;
            }

            if (trial_alpha_err < best_alpha_err)
            {
                best_alpha_err = trial_alpha_err;
                best_la = la;
                best_ha = ha;
                best_alpha_selectors = trial_alpha_selectors;
            }

            if (pss == 0)
            {
                precise float xl, xh;
                compute_least_squares_endpoints_a(16, trial_alpha_selectors, index_selector ? kBC7Weights2Index : kBC7Weights3Index, xl, xh, pPixels);
                if (xl > xh)
                    swapf(xl, xh);
                xl = floor(xl * (63.0f / 255.0f) + .5f);
                xh = floor(xh * (63.0f / 255.0f) + .5f);
                la = clamp((int)xl, 0, 63);
                ha = clamp((int)xh, 0, 63);
            }
                        
        } // pss

#if !defined(OPT_FASTMODES_ONLY) && !defined(OPT_ULTRAFAST_ONLY)
        if (g_params.m_uber_level > 0)
        {
            const int D = min((int)g_params.m_uber_level, 3);
            for (int ld = -D; ld <= D; ld++)
            {
                for (int hd = -D; hd <= D; hd++)
                {
                    la = clamp((int)best_la + ld, 0, 63);
                    ha = clamp((int)best_ha + hd, 0, 63);
                    
                    int vals[8];

                    if (index_selector == 0)
                    {
                        vals[0] = (la << 2) | (la >> 4);
                        vals[7] = (ha << 2) | (ha >> 4);

                        for (uint i = 1; i < 7; i++)
                            vals[i] = (vals[0] * (64 - get_table_bc7_weight(kBC7Weights3Index + i)) + vals[7] * get_table_bc7_weight(kBC7Weights3Index + i) + 32) >> 6;
                    }
                    else
                    {
                        vals[0] = (la << 2) | (la >> 4);
                        vals[3] = (ha << 2) | (ha >> 4);

                        const int w_s1 = 21, w_s2 = 43;
                        vals[1] = (vals[0] * (64 - w_s1) + vals[3] * w_s1 + 32) >> 6;
                        vals[2] = (vals[0] * (64 - w_s2) + vals[3] * w_s2 + 32) >> 6;
                    }

                    uint trial_alpha_err = 0;

                    int trial_alpha_selectors[16];
                    for (uint i = 0; i < 16; i++)
                    {
                        const int a = pPixels[i].a;

                        int s = 0;
                        int be = abs(a - vals[0]);

                        int e = abs(a - vals[1]); if (e < be) { be = e; s = 1; }
                        e = abs(a - vals[2]); if (e < be) { be = e; s = 2; }
                        e = abs(a - vals[3]); if (e < be) { be = e; s = 3; }

                        if (index_selector == 0)
                        {
                            e = abs(a - vals[4]); if (e < be) { be = e; s = 4; }
                            e = abs(a - vals[5]); if (e < be) { be = e; s = 5; }
                            e = abs(a - vals[6]); if (e < be) { be = e; s = 6; }
                            e = abs(a - vals[7]); if (e < be) { be = e; s = 7; }
                        }

                        trial_alpha_err += (be * be) * pParams->m_weights[3];

                        trial_alpha_selectors[i] = s;
                    }

                    if (trial_alpha_err < best_alpha_err)
                    {
                        best_alpha_err = trial_alpha_err;
                        best_la = la;
                        best_ha = ha;
                        for (uint i = 0; i < 16; i++)
                            best_alpha_selectors[i] = trial_alpha_selectors[i];
                    }
                
                } // hd

            } // ld
        }
#endif // #if !defined(OPT_FASTMODES_ONLY) && !defined(OPT_ULTRAFAST_ONLY)

        trial_err += best_alpha_err;

        if (trial_err < pOpt_results4.m_error)
        {
            pOpt_results4.m_error = trial_err;

            pOpt_results4.m_mode = 4;
            pOpt_results4.m_rotation_index_sel = index_selector << 4;
            pOpt_results4.m_partition = 0;

            pOpt_results4.m_low[0] = results.m_low_endpoint;
            pOpt_results4.m_high[0] = results.m_high_endpoint;
            pOpt_results4.m_low[0].a = best_la;
            pOpt_results4.m_high[0].a = best_ha;
            pOpt_results4.m_selectors = results.m_selectors;
            pOpt_results4.m_alpha_selectors = best_alpha_selectors;
        }

    } // index_selector
}

static void handle_alpha_block_mode5(const color_quad_i pPixels[16], color_cell_compressor_params pParams, uint lo_a, uint hi_a,
    inout bc7_optimization_results pOpt_results5)
{
    pParams.m_weights_index = kBC7Weights2Index;
    pParams.m_num_selector_weights = 4;

    pParams.m_comp_bits = 7;
    pParams.m_has_alpha = false;
    pParams.m_has_pbits = false;
    pParams.m_endpoints_share_pbit = false;
    
    pParams.m_perceptual = glob_is_perceptual();
        
    color_cell_compressor_results results5 = (color_cell_compressor_results)0;

    pOpt_results5.m_error = color_cell_compression(5, pParams, results5, 16, pPixels, true);

    pOpt_results5.m_low[0] = results5.m_low_endpoint;
    pOpt_results5.m_high[0] = results5.m_high_endpoint;

    if (lo_a == hi_a)
    {
        pOpt_results5.m_low[0].a = lo_a;
        pOpt_results5.m_high[0].a = hi_a;
        for (uint i = 0; i < 16; i++)
            pOpt_results5.m_alpha_selectors[i] = 0;
    }
    else
    {
        uint mode5_alpha_err = UINT_MAX;

        for (uint pss = 0; pss < 2; pss++)
        {
            int vals[4];
            vals[0] = lo_a;
            vals[3] = hi_a;

            const int w_s1 = 21, w_s2 = 43;
            vals[1] = (vals[0] * (64 - w_s1) + vals[3] * w_s1 + 32) >> 6;
            vals[2] = (vals[0] * (64 - w_s2) + vals[3] * w_s2 + 32) >> 6;

            int trial_alpha_selectors[16];

            uint trial_alpha_err = 0;
            for (uint i = 0; i < 16; i++)
            {
                const int a = pPixels[i].a;

                int s = 0;
                int be = abs(a - vals[0]);
                int e = abs(a - vals[1]); if (e < be) { be = e; s = 1; }
                e = abs(a - vals[2]); if (e < be) { be = e; s = 2; }
                e = abs(a - vals[3]); if (e < be) { be = e; s = 3; }

                trial_alpha_selectors[i] = s;
                                
                trial_alpha_err += (be * be) * pParams.m_weights[3];
            }

            if (trial_alpha_err < mode5_alpha_err)
            {
                mode5_alpha_err = trial_alpha_err;
                pOpt_results5.m_low[0].a = lo_a;
                pOpt_results5.m_high[0].a = hi_a;
                for (uint i = 0; i < 16; i++)
                    pOpt_results5.m_alpha_selectors[i] = trial_alpha_selectors[i];
            }

            if (!pss)
            {
                float xl, xh;
                compute_least_squares_endpoints_a(16, trial_alpha_selectors, kBC7Weights2Index, xl, xh, pPixels);

                uint new_lo_a = clamp((int)floor(xl + .5f), 0, 255);
                uint new_hi_a = clamp((int)floor(xh + .5f), 0, 255);
                if (new_lo_a > new_hi_a)
                    swapu(new_lo_a, new_hi_a);

                if ((new_lo_a == lo_a) && (new_hi_a == hi_a))
                    break;

                lo_a = new_lo_a;
                hi_a = new_hi_a;
            }
        }

#if !defined(OPT_FASTMODES_ONLY) && !defined(OPT_ULTRAFAST_ONLY)
        if (g_params.m_uber_level > 0)
        {
            const int D = min((int)g_params.m_uber_level, 3);
            for (int ld = -D; ld <= D; ld++)
            {
                for (int hd = -D; hd <= D; hd++)
                {
                    lo_a = clamp((int)pOpt_results5->m_low[0].a + ld, 0, 255);
                    hi_a = clamp((int)pOpt_results5->m_high[0].a + hd, 0, 255);
                    
                    int vals[4];
                    vals[0] = lo_a;
                    vals[3] = hi_a;

                    const int w_s1 = 21, w_s2 = 43;
                    vals[1] = (vals[0] * (64 - w_s1) + vals[3] * w_s1 + 32) >> 6;
                    vals[2] = (vals[0] * (64 - w_s2) + vals[3] * w_s2 + 32) >> 6;

                    int trial_alpha_selectors[16];

                    uint trial_alpha_err = 0;
                    for (uint i = 0; i < 16; i++)
                    {
                        const int a = pPixels[i].a;

                        int s = 0;
                        int be = abs(a - vals[0]);
                        int e = abs(a - vals[1]); if (e < be) { be = e; s = 1; }
                        e = abs(a - vals[2]); if (e < be) { be = e; s = 2; }
                        e = abs(a - vals[3]); if (e < be) { be = e; s = 3; }

                        trial_alpha_selectors[i] = s;
                                
                        trial_alpha_err += (be * be) * pParams->m_weights[3];
                    }

                    if (trial_alpha_err < mode5_alpha_err)
                    {
                        mode5_alpha_err = trial_alpha_err;
                        pOpt_results5->m_low[0].a = lo_a;
                        pOpt_results5->m_high[0].a = hi_a;
                        for (uint i = 0; i < 16; i++)
                            pOpt_results5->m_alpha_selectors[i] = trial_alpha_selectors[i];
                    }
                
                } // hd

            } // ld
        }
#endif // #if !defined(OPT_FASTMODES_ONLY) && !defined(OPT_ULTRAFAST_ONLY)

        pOpt_results5.m_error += mode5_alpha_err;
    }

    pOpt_results5.m_mode = 5;
    pOpt_results5.m_rotation_index_sel = 0;
    pOpt_results5.m_selectors = results5.m_selectors;
    pOpt_results5.m_partition = 0;
}

static uint encode_solutions(const solution solutions[4], uint count)
{
    uint res = 0;
    uint shift = 0;
    for (uint i = 0; i < count; ++i)
    {
        res |= solutions[i].m_index << shift;
        shift += 6;
    }
    res |= count << 24;
    return res;
}

static uint decode_solutions(uint enc, solution solutions[4])
{
    uint count = (enc >> 24) & 3;
    for (uint i = 0; i < count; ++i)
    {
        solutions[i].m_index = enc & 0x3F;
        enc >>= 6;
    }
    return count;
}

static uint4 get_lists_alpha(const color_quad_i pPixels[16])
{
    // x = mode 7 lists
    uint4 lists = 0;

    // Mode 7
    #ifndef OPT_ULTRAFAST_ONLY
    if (g_params.m_alpha_use_modes4567 & 0xFF000000)
    {
        uint res = 0;
        solution solutions[4];
        uint num_solutions = estimate_partition_list(7, pPixels, solutions, g_params.m_alpha_max_mode7_partitions_to_try);
        lists.x = encode_solutions(solutions, num_solutions);
    }
    #endif // #ifndef OPT_ULTRAFAST_ONLY
    return lists;
}

static uint4 get_lists_opaque(const color_quad_i pPixels[16])
{
    // x = unused
    // y = mode 1|3 lists
    // z = mode 0 lists
    // w = mode 2 lists
    uint4 lists = 0;
    
    if ((g_params.m_opaq_use_modes0123 & 0xFF00) || (g_params.m_opaq_use_modes0123 & 0xFF000000))
    {
        solution sol13[4];
        uint num_sol13 = 0;
        if (g_params.m_opaq_max_mode13_partitions_to_try == 1)
        {
            sol13[0].m_index = estimate_partition(1, pPixels);
            num_sol13 = 1;
        }
        else
        {
            num_sol13 = estimate_partition_list(1, pPixels, sol13, g_params.m_opaq_max_mode13_partitions_to_try);
        }
        lists.y = encode_solutions(sol13, num_sol13);
    }
    
    if (g_params.m_opaq_use_modes0123 & 0xFF)
    {
        solution sol0[4];
        uint num_sol0 = 0;
        if (g_params.m_opaq_max_mode0_partitions_to_try == 1)
        {
            sol0[0].m_index = estimate_partition(0, pPixels);
            num_sol0 = 1;
        }
        else
        {
            num_sol0 = estimate_partition_list(0, pPixels, sol0, g_params.m_opaq_max_mode0_partitions_to_try);
        }
        lists.z = encode_solutions(sol0, num_sol0);
    }
    
    if (g_params.m_opaq_use_modes0123 & 0xFF0000)
    {
        solution sol2[4];
        uint num_sol2 = 0;
        if (g_params.m_opaq_max_mode2_partitions_to_try == 1)
        {
            sol2[0].m_index = estimate_partition(2, pPixels);
            num_sol2 = 1;
        }
        else
        {
            num_sol2 = estimate_partition_list(2, pPixels, sol2, g_params.m_opaq_max_mode2_partitions_to_try);
        }
        lists.w = encode_solutions(sol2, num_sol2);
    }

    return lists;
}

static void handle_alpha_block_mode4(inout bc7_optimization_results res, const color_quad_i pixels[16], color_cell_compressor_params pParams, int lo_a, int hi_a)
{
    pParams.m_perceptual = glob_is_perceptual();
    color_cell_compressor_params params4 = pParams;

    const int num_rotations = (glob_is_perceptual() || (!(g_params.m_alpha_use_mode45_rotation & 0xFF))) ? 1 : 4;
    for (int rotation = 0; rotation < num_rotations; rotation++)
    {
        if ((g_params.m_mode4_rotation_mask & (1 << rotation)) == 0)
            continue;

        params4.m_weights = pParams.m_weights;
        if (rotation == 1) params4.m_weights = params4.m_weights.agbr;
        if (rotation == 2) params4.m_weights = params4.m_weights.rabg;
        if (rotation == 3) params4.m_weights = params4.m_weights.rgab;

        color_quad_i rot_pixels[16];
        int trial_lo_a = lo_a, trial_hi_a = hi_a;
        if (rotation)
        {
            trial_lo_a = 255;
            trial_hi_a = 0;

            for (uint i = 0; i < 16; i++)
            {
                color_quad_i c = pixels[i];
                if (rotation == 1) c = c.agbr;
                if (rotation == 2) c = c.rabg;
                if (rotation == 3) c = c.rgab;
                rot_pixels[i] = c;

                trial_lo_a = min(trial_lo_a, c.a);
                trial_hi_a = max(trial_hi_a, c.a);
            }
        }
        else
            rot_pixels = pixels;

        bc7_optimization_results trial_res = (bc7_optimization_results)0;
        trial_res.m_error = res.m_error;
        handle_alpha_block_mode4(rot_pixels, params4, trial_lo_a, trial_hi_a, trial_res);
        if (trial_res.m_error < res.m_error)
        {
            res.m_error = trial_res.m_error;
            res.m_mode = 4;
            res.m_rotation_index_sel = rotation | trial_res.m_rotation_index_sel;
            res.m_partition = 0;

            res.m_low[0] = trial_res.m_low[0];
            res.m_high[0] = trial_res.m_high[0];
            res.m_selectors = trial_res.m_selectors;
            res.m_alpha_selectors = trial_res.m_alpha_selectors;
        }
    } // rotation
}

static void handle_alpha_block_mode6(inout bc7_optimization_results res, const color_quad_i pixels[16], color_cell_compressor_params pParams, int lo_a, int hi_a)
{
    pParams.m_perceptual = glob_is_perceptual();
    color_cell_compressor_params params6 = pParams;

    // Note: m_mode67_error_weight_mul was always 1, removed

    color_cell_compressor_results res6 = (color_cell_compressor_results)0;

    params6.m_weights_index = kBC7Weights4Index;
    params6.m_num_selector_weights = 16;

    params6.m_comp_bits = 7;
    params6.m_has_pbits = true;
    params6.m_endpoints_share_pbit = false;
    params6.m_has_alpha = true;

    uint err = color_cell_compression(6, params6, res6, 16, pixels, true);

    if (err < res.m_error)
    {
        res.m_error = err;
        res.m_mode = 6;
        res.m_rotation_index_sel = 0;
        res.m_partition = 0;
        res.m_low[0] = res6.m_low_endpoint;
        res.m_high[0] = res6.m_high_endpoint;
        res.m_pbits = (res.m_pbits & ~3) | res6.m_pbits;
        res.m_selectors = res6.m_selectors;
    }
}

static void handle_alpha_block_mode5(inout bc7_optimization_results res, const color_quad_i pixels[16], color_cell_compressor_params pParams, int lo_a, int hi_a)
{
    pParams.m_perceptual = glob_is_perceptual();
    color_cell_compressor_params params5 = pParams;

    const int num_rotations = (glob_is_perceptual() || (!(g_params.m_alpha_use_mode45_rotation & 0xFF00))) ? 1 : 4;
    for (uint rotation = 0; rotation < num_rotations; rotation++)
    {
        if ((g_params.m_mode5_rotation_mask & (1 << rotation)) == 0)
            continue;

        params5.m_weights = pParams.m_weights;
        if (rotation == 1) params5.m_weights = params5.m_weights.agbr;
        if (rotation == 2) params5.m_weights = params5.m_weights.rabg;
        if (rotation == 3) params5.m_weights = params5.m_weights.rgab;

        color_quad_i rot_pixels[16];
        int trial_lo_a = lo_a, trial_hi_a = hi_a;
        if (rotation)
        {
            trial_lo_a = 255;
            trial_hi_a = 0;

            for (uint i = 0; i < 16; i++)
            {
                color_quad_i c = pixels[i];
                if (rotation == 1) c = c.agbr;
                if (rotation == 2) c = c.rabg;
                if (rotation == 3) c = c.rgab;
                rot_pixels[i] = c;

                trial_lo_a = min(trial_lo_a, c.a);
                trial_hi_a = max(trial_hi_a, c.a);
            }
        }
        else
            rot_pixels = pixels;

        bc7_optimization_results trial_res = (bc7_optimization_results)0;
        trial_res.m_error = 0;
        handle_alpha_block_mode5(rot_pixels, params5, trial_lo_a, trial_hi_a, trial_res);
        if (trial_res.m_error < res.m_error)
        {
            res = trial_res;
            res.m_rotation_index_sel = rotation;
        }
    } // rotation
}

static void handle_alpha_block_mode7(inout bc7_optimization_results res, const color_quad_i pixels[16], color_cell_compressor_params pParams, int lo_a, int hi_a, uint4 solution_lists)
{
    pParams.m_perceptual = glob_is_perceptual();
    solution solutions[4];
    uint num_solutions = decode_solutions(solution_lists.x, solutions);

    color_cell_compressor_params params7 = pParams;

    // Note: m_mode67_error_weight_mul was always 1, removed

    params7.m_weights_index = kBC7Weights2Index;
    params7.m_num_selector_weights = 4;

    params7.m_comp_bits = 5;
    params7.m_has_pbits = true;
    params7.m_endpoints_share_pbit = false;

    params7.m_has_alpha = true;

    const bool disable_faster_part_selection = false;

    for (uint solution_index = 0; solution_index < num_solutions; solution_index++)
    {
        const uint trial_partition = solutions[solution_index].m_index;
        assert(trial_partition < 64);

        const int pPartition[16] = g_bc7_partition2[trial_partition];

        color_quad_i subset_colors[2][16];

        uint subset_total_colors7[2];
        subset_total_colors7[0] = 0;
        subset_total_colors7[1] = 0;

        int subset_pixel_index7[2][16];
        color_cell_compressor_results subset_results7[2];

        for (uint idx = 0; idx < 16; idx++)
        {
            const uint p = pPartition[idx];
            assert(p < 2);

            subset_colors[p][subset_total_colors7[p]] = pixels[idx];
            subset_pixel_index7[p][subset_total_colors7[p]] = idx;
            subset_total_colors7[p]++;
        }

        uint trial_err = 0;
        for (uint subset = 0; subset < 2; subset++)
        {
            uint err = color_cell_compression(7, params7, subset_results7[subset], subset_total_colors7[subset], subset_colors[subset], (num_solutions <= 2) || disable_faster_part_selection);
            assert(err == subset_results7[subset].m_best_overall_err);

            trial_err += err;
            if (trial_err > res.m_error)
                break;
        } // subset

        if (trial_err < res.m_error)
        {
            res.m_error = trial_err;
            res.m_mode = 7;
            res.m_rotation_index_sel = 0;
            res.m_partition = trial_partition;

            for (uint subset = 0; subset < 2; subset++)
            {
                for (uint i = 0; i < subset_total_colors7[subset]; i++)
                {
                    const uint pixel_index = subset_pixel_index7[subset][i];

                    res.m_selectors[pixel_index] = subset_results7[subset].m_selectors[i];
                }

                res.m_low[subset] = subset_results7[subset].m_low_endpoint;
                res.m_high[subset] = subset_results7[subset].m_high_endpoint;
                uint pbits = res.m_pbits;
                pbits &= ~(3 << subset * 2);
                pbits |= subset_results7[subset].m_pbits << subset * 2;
                res.m_pbits = pbits;
            }
        }

    } // solution_index

    if ((num_solutions > 2) && (res.m_mode == 7) && (!disable_faster_part_selection))
    {
        const uint trial_partition = res.m_partition;
        assert(trial_partition < 64);

        const int pPartition[16] = g_bc7_partition2[trial_partition];

        color_quad_i subset_colors[2][16];

        uint subset_total_colors7[2];
        subset_total_colors7[0] = 0;
        subset_total_colors7[1] = 0;

        int subset_pixel_index7[2][16];
        color_cell_compressor_results subset_results7[2];

        for (uint idx = 0; idx < 16; idx++)
        {
            const uint p = pPartition[idx];
            assert(p < 2);

            subset_colors[p][subset_total_colors7[p]] = pixels[idx];
            subset_pixel_index7[p][subset_total_colors7[p]] = idx;
            subset_total_colors7[p]++;
        }

        uint trial_err = 0;
        for (uint subset = 0; subset < 2; subset++)
        {
            uint err = color_cell_compression(7, params7, subset_results7[subset], subset_total_colors7[subset], subset_colors[subset], true);
            assert(err == subset_results7[subset].m_best_overall_err);

            trial_err += err;
            if (trial_err > res.m_error)
                break;
        } // subset

        if (trial_err < res.m_error)
        {
            res.m_error = trial_err;

            for (uint subset = 0; subset < 2; subset++)
            {
                for (uint i = 0; i < subset_total_colors7[subset]; i++)
                {
                    const uint pixel_index = subset_pixel_index7[subset][i];

                    res.m_selectors[pixel_index] = subset_results7[subset].m_selectors[i];
                }

                res.m_low[subset] = subset_results7[subset].m_low_endpoint;
                res.m_high[subset] = subset_results7[subset].m_high_endpoint;
                uint pbits = res.m_pbits;
                pbits &= ~(3 << subset * 2);
                pbits |= subset_results7[subset].m_pbits << subset * 2;
                res.m_pbits = pbits;
            }
        }
    }
}

static void handle_opaque_block_mode4(inout bc7_optimization_results res, const color_quad_i pixels[16], color_cell_compressor_params pParams)
{
    pParams.m_perceptual = glob_is_perceptual();
    color_cell_compressor_params params4 = pParams;

    for (uint rotation = 0; rotation < 4; rotation++)
    {
        if ((g_params.m_mode4_rotation_mask & (1 << rotation)) == 0)
            continue;

        params4.m_weights = pParams.m_weights;
        if (rotation == 1) params4.m_weights = params4.m_weights.agbr;
        if (rotation == 2) params4.m_weights = params4.m_weights.rabg;
        if (rotation == 3) params4.m_weights = params4.m_weights.rgab;

        color_quad_i rot_pixels[16];
        int trial_lo_a = 255, trial_hi_a = 255;
        if (rotation)
        {
            trial_lo_a = 255;
            trial_hi_a = 0;

            for (uint i = 0; i < 16; i++)
            {
                color_quad_i c = pixels[i];
                if (rotation == 1) c = c.agbr;
                if (rotation == 2) c = c.rabg;
                if (rotation == 3) c = c.rgab;
                rot_pixels[i] = c;

                trial_lo_a = min(trial_lo_a, c.a);
                trial_hi_a = max(trial_hi_a, c.a);
            }
        }
        else
            rot_pixels = pixels;

        bc7_optimization_results trial_res = (bc7_optimization_results)0;
        trial_res.m_error = res.m_error;
        handle_alpha_block_mode4(rot_pixels, params4, trial_lo_a, trial_hi_a, trial_res);

        if (trial_res.m_error < res.m_error)
        {
            res.m_error = trial_res.m_error;
            res.m_mode = 4;
            res.m_rotation_index_sel = rotation | trial_res.m_rotation_index_sel;
            res.m_partition = 0;
            res.m_low[0] = trial_res.m_low[0];
            res.m_high[0] = trial_res.m_high[0];
            res.m_selectors = trial_res.m_selectors;
            res.m_alpha_selectors = trial_res.m_alpha_selectors;
        }
    } // rotation
}

static void handle_opaque_block_mode6(inout bc7_optimization_results res, const color_quad_i pixels[16], color_cell_compressor_params pParams)
{
    pParams.m_weights_index = kBC7Weights4Index;
    pParams.m_num_selector_weights = 16;

    pParams.m_comp_bits = 7;
    pParams.m_has_pbits = true;
    pParams.m_endpoints_share_pbit = false;

    pParams.m_perceptual = glob_is_perceptual();

    color_cell_compressor_results results6 = (color_cell_compressor_results)0;

    uint err = color_cell_compression(6, pParams, results6, 16, pixels, true);
    if (err < res.m_error)
    {
        res.m_error = err;
        res.m_mode = 6;
        res.m_rotation_index_sel = 0;
        res.m_partition = 0;
        res.m_low[0] = results6.m_low_endpoint;
        res.m_high[0] = results6.m_high_endpoint;
        res.m_pbits = results6.m_pbits;
        res.m_selectors = results6.m_selectors;
    }
}

static void handle_opaque_block_mode1(inout bc7_optimization_results res, const color_quad_i pixels[16], color_cell_compressor_params pParams, uint4 solution_lists)
{
    pParams.m_perceptual = glob_is_perceptual();
    solution solutions[4];
    uint num_solutions = decode_solutions(solution_lists.y, solutions);
    const bool disable_faster_part_selection = false;
    pParams.m_weights_index = kBC7Weights3Index;
    pParams.m_num_selector_weights = 8;
    pParams.m_comp_bits = 6;
    pParams.m_has_pbits = true;
    pParams.m_endpoints_share_pbit = true;

    for (uint solution_index = 0; solution_index < num_solutions; solution_index++)
    {
        const uint trial_partition = solutions[solution_index].m_index;
        assert(trial_partition < 64);

        const int pPartition[16] = g_bc7_partition2[trial_partition];

        color_quad_i subset_colors[2][16];

        uint subset_total_colors1[2];
        subset_total_colors1[0] = 0;
        subset_total_colors1[1] = 0;

        int subset_pixel_index1[2][16];
        color_cell_compressor_results subset_results1[2];

        for (uint idx = 0; idx < 16; idx++)
        {
            const uint p = pPartition[idx];
            assert(p < 2);

            subset_colors[p][subset_total_colors1[p]] = pixels[idx];
            subset_pixel_index1[p][subset_total_colors1[p]] = idx;
            subset_total_colors1[p]++;
        }

        uint trial_err = 0;
        for (uint subset = 0; subset < 2; subset++)
        {
            uint err = color_cell_compression(1, pParams, subset_results1[subset], subset_total_colors1[subset], subset_colors[subset], (num_solutions <= 2) || disable_faster_part_selection);
            assert(err == subset_results1[subset].m_best_overall_err);

            trial_err += err;
            if (trial_err > res.m_error)
                break;

        } // subset

        if (trial_err < res.m_error)
        {
            res.m_error = trial_err;
            res.m_mode = 1;
            res.m_rotation_index_sel = 0;
            res.m_partition = trial_partition;

            for (uint subset = 0; subset < 2; subset++)
            {
                for (uint i = 0; i < subset_total_colors1[subset]; i++)
                {
                    const uint pixel_index = subset_pixel_index1[subset][i];

                    res.m_selectors[pixel_index] = subset_results1[subset].m_selectors[i];
                }

                res.m_low[subset] = subset_results1[subset].m_low_endpoint;
                res.m_high[subset] = subset_results1[subset].m_high_endpoint;
                uint pbits = res.m_pbits;
                pbits &= ~(3 << subset * 2);
                pbits |= subset_results1[subset].m_pbits << subset * 2;
                res.m_pbits = pbits;
            }
        }
    }

    if ((num_solutions > 2) && (res.m_mode == 1) && (!disable_faster_part_selection))
    {
        const uint trial_partition = res.m_partition;
        assert(trial_partition < 64);

        const int pPartition[16] = g_bc7_partition2[trial_partition];

        color_quad_i subset_colors[2][16];

        uint subset_total_colors1[2];
        subset_total_colors1[0] = 0;
        subset_total_colors1[1] = 0;

        int subset_pixel_index1[2][16];
        color_cell_compressor_results subset_results1[2];

        for (uint idx = 0; idx < 16; idx++)
        {
            const uint p = pPartition[idx];
            assert(p < 2);

            subset_colors[p][subset_total_colors1[p]] = pixels[idx];
            subset_pixel_index1[p][subset_total_colors1[p]] = idx;
            subset_total_colors1[p]++;
        }

        uint trial_err = 0;
        for (uint subset = 0; subset < 2; subset++)
        {
            uint err = color_cell_compression(1, pParams, subset_results1[subset], subset_total_colors1[subset], subset_colors[subset], true);
            assert(err == subset_results1[subset].m_best_overall_err);

            trial_err += err;
            if (trial_err > res.m_error)
                break;

        } // subset

        if (trial_err < res.m_error)
        {
            res.m_error = trial_err;
            for (uint subset = 0; subset < 2; subset++)
            {
                for (uint i = 0; i < subset_total_colors1[subset]; i++)
                {
                    const uint pixel_index = subset_pixel_index1[subset][i];
                    res.m_selectors[pixel_index] = subset_results1[subset].m_selectors[i];
                }

                res.m_low[subset] = subset_results1[subset].m_low_endpoint;
                res.m_high[subset] = subset_results1[subset].m_high_endpoint;
                uint pbits = res.m_pbits;
                pbits &= ~(3 << subset * 2);
                pbits |= subset_results1[subset].m_pbits << subset * 2;
                res.m_pbits = pbits;
            }
        }
    }
}

static void handle_opaque_block_mode0(inout bc7_optimization_results res, const color_quad_i pixels[16], color_cell_compressor_params pParams, uint4 solution_lists)
{
    pParams.m_perceptual = glob_is_perceptual();
    solution solutions[4];
    uint num_solutions = decode_solutions(solution_lists.z, solutions);
    pParams.m_weights_index = kBC7Weights3Index;
    pParams.m_num_selector_weights = 8;
    pParams.m_comp_bits = 4;
    pParams.m_has_pbits = true;
    pParams.m_endpoints_share_pbit = false;

    for (uint solution_index = 0; solution_index < num_solutions; solution_index++)
    {
        const uint best_partition0 = solutions[solution_index].m_index;

        const int pPartition[16] = g_bc7_partition3[best_partition0];

        color_quad_i subset_colors[3][16];

        uint subset_total_colors0[3];
        subset_total_colors0[0] = 0;
        subset_total_colors0[1] = 0;
        subset_total_colors0[2] = 0;

        int subset_pixel_index0[3][16];

        for (uint idx = 0; idx < 16; idx++)
        {
            const uint p = pPartition[idx];

            subset_colors[p][subset_total_colors0[p]] = pixels[idx];
            subset_pixel_index0[p][subset_total_colors0[p]] = idx;
            subset_total_colors0[p]++;
        }

        color_cell_compressor_results subset_results0[3];

        uint mode0_err = 0;
        for (uint subset = 0; subset < 3; subset++)
        {
            uint err = color_cell_compression(0, pParams, subset_results0[subset], subset_total_colors0[subset], subset_colors[subset], true);
            assert(err == subset_results0[subset].m_best_overall_err);

            mode0_err += err;
            if (mode0_err > res.m_error)
                break;
        } // subset

        if (mode0_err < res.m_error)
        {
            res.m_error = mode0_err;
            res.m_mode = 0;
            res.m_rotation_index_sel = 0;
            res.m_partition = best_partition0;
            for (uint subset = 0; subset < 3; subset++)
            {
                for (uint i = 0; i < subset_total_colors0[subset]; i++)
                {
                    const uint pixel_index = subset_pixel_index0[subset][i];
                    res.m_selectors[pixel_index] = subset_results0[subset].m_selectors[i];
                }
                res.m_low[subset] = subset_results0[subset].m_low_endpoint;
                res.m_high[subset] = subset_results0[subset].m_high_endpoint;
                uint pbits = res.m_pbits;
                pbits &= ~(3 << subset * 2);
                pbits |= subset_results0[subset].m_pbits << subset * 2;
                res.m_pbits = pbits;
            }
        }
    }
}

static void handle_opaque_block_mode3(inout bc7_optimization_results res, const color_quad_i pixels[16], color_cell_compressor_params pParams, uint4 solution_lists)
{
    pParams.m_perceptual = glob_is_perceptual();
    solution solutions[4];
    uint num_solutions = decode_solutions(solution_lists.y, solutions);
    const bool disable_faster_part_selection = false;
    pParams.m_weights_index = kBC7Weights2Index;
    pParams.m_num_selector_weights = 4;

    pParams.m_comp_bits = 7;
    pParams.m_has_pbits = true;
    pParams.m_endpoints_share_pbit = false;

    pParams.m_perceptual = glob_is_perceptual();

    for (uint solution_index = 0; solution_index < num_solutions; solution_index++)
    {
        const uint trial_partition = solutions[solution_index].m_index;
        assert(trial_partition < 64);

        const int pPartition[16] = g_bc7_partition2[trial_partition];

        color_quad_i subset_colors[2][16];

        uint subset_total_colors3[2];
        subset_total_colors3[0] = 0;
        subset_total_colors3[1] = 0;

        int subset_pixel_index3[2][16];
        color_cell_compressor_results subset_results3[2];

        for (uint idx = 0; idx < 16; idx++)
        {
            const uint p = pPartition[idx];
            assert(p < 2);

            subset_colors[p][subset_total_colors3[p]] = pixels[idx];
            subset_pixel_index3[p][subset_total_colors3[p]] = idx;
            subset_total_colors3[p]++;
        }

        uint trial_err = 0;
        for (uint subset = 0; subset < 2; subset++)
        {
            uint err = color_cell_compression(3, pParams, subset_results3[subset], subset_total_colors3[subset], subset_colors[subset], (num_solutions <= 2) || disable_faster_part_selection);
            assert(err == subset_results3[subset].m_best_overall_err);

            trial_err += err;
            if (trial_err > res.m_error)
                break;
        } // subset

        if (trial_err < res.m_error)
        {
            res.m_error = trial_err;
            res.m_mode = 3;
            res.m_rotation_index_sel = 0;
            res.m_partition = trial_partition;
            for (uint subset = 0; subset < 2; subset++)
            {
                for (uint i = 0; i < subset_total_colors3[subset]; i++)
                {
                    const uint pixel_index = subset_pixel_index3[subset][i];
                    res.m_selectors[pixel_index] = subset_results3[subset].m_selectors[i];
                }
                res.m_low[subset] = subset_results3[subset].m_low_endpoint;
                res.m_high[subset] = subset_results3[subset].m_high_endpoint;
                uint pbits = res.m_pbits;
                pbits &= ~(3 << subset * 2);
                pbits |= subset_results3[subset].m_pbits << subset * 2;
                res.m_pbits = pbits;
            }
        }

    } // solution_index

    if ((num_solutions > 2) && (res.m_mode == 3) && (!disable_faster_part_selection))
    {
        const uint trial_partition = res.m_partition;
        assert(trial_partition < 64);

        const int pPartition[16] = g_bc7_partition2[trial_partition];

        color_quad_i subset_colors[2][16];

        uint subset_total_colors3[2];
        subset_total_colors3[0] = 0;
        subset_total_colors3[1] = 0;

        int subset_pixel_index3[2][16];
        color_cell_compressor_results subset_results3[2];

        for (uint idx = 0; idx < 16; idx++)
        {
            const uint p = pPartition[idx];
            assert(p < 2);

            subset_colors[p][subset_total_colors3[p]] = pixels[idx];
            subset_pixel_index3[p][subset_total_colors3[p]] = idx;
            subset_total_colors3[p]++;
        }

        uint trial_err = 0;
        for (uint subset = 0; subset < 2; subset++)
        {
            uint err = color_cell_compression(3, pParams, subset_results3[subset], subset_total_colors3[subset], subset_colors[subset], true);
            assert(err == subset_results3[subset].m_best_overall_err);

            trial_err += err;
            if (trial_err > res.m_error)
                break;
        } // subset

        if (trial_err < res.m_error)
        {
            res.m_error = trial_err;
            for (uint subset = 0; subset < 2; subset++)
            {
                for (uint i = 0; i < subset_total_colors3[subset]; i++)
                {
                    const uint pixel_index = subset_pixel_index3[subset][i];
                    res.m_selectors[pixel_index] = subset_results3[subset].m_selectors[i];
                }
                res.m_low[subset] = subset_results3[subset].m_low_endpoint;
                res.m_high[subset] = subset_results3[subset].m_high_endpoint;
                uint pbits = res.m_pbits;
                pbits &= ~(3 << subset * 2);
                pbits |= subset_results3[subset].m_pbits << subset * 2;
                res.m_pbits = pbits;
            }
        }
    }
}

static void handle_opaque_block_mode5(inout bc7_optimization_results res, const color_quad_i pixels[16], color_cell_compressor_params pParams)
{
    pParams.m_perceptual = glob_is_perceptual();
    color_cell_compressor_params params5 = pParams;

    for (uint rotation = 0; rotation < 4; rotation++)
    {
        if ((g_params.m_mode5_rotation_mask & (1 << rotation)) == 0)
            continue;

        params5.m_weights = pParams.m_weights;
        if (rotation == 1) params5.m_weights = params5.m_weights.agbr;
        if (rotation == 2) params5.m_weights = params5.m_weights.rabg;
        if (rotation == 3) params5.m_weights = params5.m_weights.rgab;

        color_quad_i rot_pixels[16];
        int trial_lo_a = 255, trial_hi_a = 255;
        if (rotation)
        {
            trial_lo_a = 255;
            trial_hi_a = 0;

            for (uint i = 0; i < 16; i++)
            {
                color_quad_i c = pixels[i];
                if (rotation == 1) c = c.agbr;
                if (rotation == 2) c = c.rabg;
                if (rotation == 3) c = c.rgab;
                rot_pixels[i] = c;

                trial_lo_a = min(trial_lo_a, c.a);
                trial_hi_a = max(trial_hi_a, c.a);
            }
        }
        else
            rot_pixels = pixels;

        bc7_optimization_results trial_res = (bc7_optimization_results)0;
        trial_res.m_error = 0;
        handle_alpha_block_mode5(rot_pixels, params5, trial_lo_a, trial_hi_a, trial_res);
        if (trial_res.m_error < res.m_error)
        {
            res = trial_res;
            res.m_rotation_index_sel = rotation;
        }
    } // rotation
}

static void handle_opaque_block_mode2(inout bc7_optimization_results res, const color_quad_i pixels[16], color_cell_compressor_params pParams, uint4 solution_lists)
{
    pParams.m_perceptual = glob_is_perceptual();
    solution solutions[4];
    uint num_solutions = decode_solutions(solution_lists.w, solutions);
    pParams.m_weights_index = kBC7Weights2Index;
    pParams.m_num_selector_weights = 4;
    pParams.m_comp_bits = 5;
    pParams.m_has_pbits = false;
    pParams.m_endpoints_share_pbit = false;
    for (uint solution_index = 0; solution_index < num_solutions; solution_index++)
    {
        const int best_partition2 = solutions[solution_index].m_index;

        uint subset_total_colors2[3];
        subset_total_colors2[0] = 0;
        subset_total_colors2[1] = 0;
        subset_total_colors2[2] = 0;

        int subset_pixel_index2[3][16];

        const int pPartition[16] = g_bc7_partition3[best_partition2];

        color_quad_i subset_colors[3][16];

        for (uint idx = 0; idx < 16; idx++)
        {
            const uint p = pPartition[idx];

            subset_colors[p][subset_total_colors2[p]] = pixels[idx];

            subset_pixel_index2[p][subset_total_colors2[p]] = idx;

            subset_total_colors2[p]++;
        }

        color_cell_compressor_results subset_results2[3];

        uint mode2_err = 0;
        for (uint subset = 0; subset < 3; subset++)
        {
            uint err = color_cell_compression(2, pParams, subset_results2[subset], subset_total_colors2[subset], subset_colors[subset], true);
            assert(err == subset_results2[subset].m_best_overall_err);

            mode2_err += err;
            if (mode2_err > res.m_error)
                break;
        } // subset

        if (mode2_err < res.m_error)
        {
            res.m_error = mode2_err;
            res.m_mode = 2;
            res.m_rotation_index_sel = 0;
            res.m_partition = best_partition2;
            for (uint subset = 0; subset < 3; subset++)
            {
                for (uint i = 0; i < subset_total_colors2[subset]; i++)
                {
                    const uint pixel_index = subset_pixel_index2[subset][i];
                    res.m_selectors[pixel_index] = subset_results2[subset].m_selectors[i];
                }
                res.m_low[subset] = subset_results2[subset].m_low_endpoint;
                res.m_high[subset] = subset_results2[subset].m_high_endpoint;
            }
        }
    }
}

static uint4 handle_opaque_block_mode6(const color_quad_i pPixels[16], color_cell_compressor_params pParams)
{
    bc7_optimization_results opt_results = (bc7_optimization_results)0;
        
    uint best_err = UINT_MAX;

    // Mode 6
    pParams.m_weights_index = kBC7Weights4Index;
    pParams.m_num_selector_weights = 16;

    pParams.m_comp_bits = 7;
    pParams.m_has_pbits = true;
    pParams.m_endpoints_share_pbit = false;

    pParams.m_perceptual = glob_is_perceptual();
                
    color_cell_compressor_results results6 = (color_cell_compressor_results)0;

    best_err = color_cell_compression(6, pParams, results6, 16, pPixels, true);
    opt_results.m_error = best_err;
    opt_results.m_mode = 6;
    opt_results.m_rotation_index_sel = 0;
    opt_results.m_partition = 0;

    opt_results.m_low[0] = results6.m_low_endpoint;
    opt_results.m_high[0] = results6.m_high_endpoint;

    opt_results.m_pbits = results6.m_pbits;
    opt_results.m_selectors = results6.m_selectors;

    return encode_bc7_block_mode6(opt_results);
}

StructuredBuffer<uint> s_BufInput : register(t1);

void load_pixel_block(out color_quad_i pixels[16], out float out_lo_a, out float out_hi_a, uint3 id, uint width)
{
    float lo_a = 255, hi_a = 0;
    uint base_pix = (id.y * 4) * width + id.x * 4;
    for (uint i = 0; i < 16; i++)
    {
        uint ix = i & 3;
        uint iy = i >> 2;
        uint craw = s_BufInput[base_pix + iy * width + ix];
        int r = craw & 0xFF;
        int g = (craw >> 8) & 0xFF;
        int b = (craw >> 16) & 0xFF;
        int a = (craw >> 24);
#       ifdef OPT_OPAQUE_ONLY
        a = 255;
#       endif
        pixels[i] = int4(r, g, b, a);

        float fa = a;

        lo_a = min(lo_a, fa);
        hi_a = max(hi_a, fa);
    }
    out_lo_a = lo_a;
    out_hi_a = hi_a;
}

RWStructuredBuffer<uint4> s_BufOutput : register(u2);
RWStructuredBuffer<bc7_optimization_results> s_BufTemp : register(u3);
