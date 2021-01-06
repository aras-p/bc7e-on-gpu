#include <metal_stdlib>
using namespace metal;

//#define OPT_ULTRAFAST_ONLY // disables Mode 7; for opaque only uses Mode 6
//#define OPT_FASTMODES_ONLY // disables m_uber_level being non-zero paths

#define OPT_UBER_LESS_THAN_2_ONLY // disables "slowest" and "veryslow" modes
#define OPT_MAX_PARTITION_TRIES_LESS_THAN_3_ONLY // disables "slowest" mode

//#define DEBUG_FORCE_NO_SHADER_CACHE 3

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
    uint32_t m_max_partitions_mode[8];

    uint4    m_weights;

    uint32_t m_uber_level;
    uint32_t m_refinement_passes;
    
    uint32_t m_mode4_rotation_mask;
    uint32_t m_mode4_index_mask;
    uint32_t m_mode5_rotation_mask;
    uint32_t m_uber1_mask;
    
    bool m_perceptual;
    bool m_pbit_search;
    bool m_mode6_only;
    bool m_unused0;
    
    struct
    {
        uint32_t m_max_mode13_partitions_to_try;
        uint32_t m_max_mode0_partitions_to_try;
        uint32_t m_max_mode2_partitions_to_try;
        bool m_use_mode[7];
        bool m_unused1;
    } m_opaque_settings;

    struct
    {
        uint32_t m_max_mode7_partitions_to_try;
        uint32_t m_mode67_error_weight_mul[4];
                
        bool m_use_mode4;
        bool m_use_mode5;
        bool m_use_mode6;
        bool m_use_mode7;

        bool m_use_mode4_rotation;
        bool m_use_mode5_rotation;
        bool m_unused2;
        bool m_unused3;
    } m_alpha_settings;
};
static_assert(sizeof(bc7e_compress_block_params) == 128, "unexpected bc7e_compress_block_params struct size");

static inline void swapu(thread uint32_t* a, thread uint32_t* b) { uint32_t t = *a; *a = *b; *b = t; }
static inline void swapf(thread float* a, thread float* b) { float t = *a; *a = *b; *b = t; }

static inline float square(float s) { return s * s; }

typedef int4 color_quad_i;
typedef float4 color_quad_f;

static inline bool color_quad_i_equals(uchar4 a, uchar4 b)
{
    return all(a == b);
}

static inline bool color_quad_i_notequals(uchar4 a, uchar4 b)
{
    return !color_quad_i_equals(a, b);
}

typedef float4 vec4F;

static inline vec4F vec4F_normalize(vec4F v)
{
    float lensq = dot(v, v);
    if (lensq != 0.0f)
    {
        float invlen = 1.0f / sqrt(lensq);
        return v * invlen;
    }
    return v;
}

// each partition layout encoded in 32 bits: two bits per pixel
static const constant uint g_bc7_partition2[64] = {
    0x50505050, 0x40404040, 0x54545454, 0x54505040, 0x50404000, 0x55545450, 0x55545040, 0x54504000,
    0x50400000, 0x55555450, 0x55544000, 0x54400000, 0x55555440, 0x55550000, 0x55555500, 0x55000000,
    0x55150100, 0x00004054, 0x15010000, 0x00405054, 0x00004050, 0x15050100, 0x05010000, 0x40505054,
    0x00404050, 0x05010100, 0x14141414, 0x05141450, 0x01155440, 0x00555500, 0x15014054, 0x05414150,
    0x44444444, 0x55005500, 0x11441144, 0x05055050, 0x05500550, 0x11114444, 0x41144114, 0x44111144,
    0x15055054, 0x01055040, 0x05041050, 0x05455150, 0x14414114, 0x50050550, 0x41411414, 0x00141400,
    0x00041504, 0x00105410, 0x10541000, 0x04150400, 0x50410514, 0x41051450, 0x05415014, 0x14054150,
    0x41050514, 0x41505014, 0x40011554, 0x54150140, 0x50505500, 0x00555050, 0x15151010, 0x54540404,
};
static const constant uint g_bc7_partition3[64] = {
    0xaa685050, 0x6a5a5040, 0x5a5a4200, 0x5450a0a8, 0xa5a50000, 0xa0a05050, 0x5555a0a0, 0x5a5a5050,
    0xaa550000, 0xaa555500, 0xaaaa5500, 0x90909090, 0x94949494, 0xa4a4a4a4, 0xa9a59450, 0x2a0a4250,
    0xa5945040, 0x0a425054, 0xa5a5a500, 0x55a0a0a0, 0xa8a85454, 0x6a6a4040, 0xa4a45000, 0x1a1a0500,
    0x0050a4a4, 0xaaa59090, 0x14696914, 0x69691400, 0xa08585a0, 0xaa821414, 0x50a4a450, 0x6a5a0200,
    0xa9a58000, 0x5090a0a8, 0xa8a09050, 0x24242424, 0x00aa5500, 0x24924924, 0x24499224, 0x50a50a50,
    0x500aa550, 0xaaaa4444, 0x66660000, 0xa5a0a5a0, 0x50a050a0, 0x69286928, 0x44aaaa44, 0x66666600,
    0xaa444444, 0x54a854a8, 0x95809580, 0x96969600, 0xa85454a8, 0x80959580, 0xaa141414, 0x96960000,
    0xaaaa1414, 0xa05050a0, 0xa0a5a5a0, 0x96000000, 0x40804080, 0xa9a8a9a8, 0xaaaaaa44, 0x2a4a5254
};

static const constant int g_bc7_table_anchor_index_second_subset[64] =
{
    15,15,15,15,15,15,15,15,        15,15,15,15,15,15,15,15,        15, 2, 8, 2, 2, 8, 8,15,        2, 8, 2, 2, 8, 8, 2, 2,        15,15, 6, 8, 2, 8,15,15,        2, 8, 2, 2, 2,15,15, 6,        6, 2, 6, 8,15,15, 2, 2,        15,15,15,15,15, 2, 2,15
};

static const constant int g_bc7_table_anchor_index_third_subset_1[64] =
{
    3, 3,15,15, 8, 3,15,15,        8, 8, 6, 6, 6, 5, 3, 3,        3, 3, 8,15, 3, 3, 6,10,        5, 8, 8, 6, 8, 5,15,15,        8,15, 3, 5, 6,10, 8,15,        15, 3,15, 5,15,15,15,15,        3,15, 5, 5, 5, 8, 5,10,        5,10, 8,13,15,12, 3, 3
};

static const constant int g_bc7_table_anchor_index_third_subset_2[64] =
{
    15, 8, 8, 3,15,15, 3, 8,        15,15,15,15,15,15,15, 8,        15, 8,15, 3,15, 8,15, 8,        3,15, 6,10,15,15,10, 8,        15, 3,15,10,10, 8, 9,10,        6,15, 8,15, 3, 6, 6, 8,        15, 3,15,15,15,15,15,15,        15,15,15,15, 3,15,15, 8
};

static const constant int g_bc7_num_subsets[8] = { 3, 2, 3, 2, 1, 1, 1, 2 };
static const constant int g_bc7_partition_bits[8] = { 4, 6, 6, 6, 0, 0, 0, 6 };
static const constant int g_bc7_color_index_bitcount[8] = { 3, 3, 2, 2, 2, 2, 4, 2 };
static int get_bc7_color_index_size(int mode, int index_selection_bit) { return g_bc7_color_index_bitcount[mode] + index_selection_bit; }
static const constant int g_bc7_alpha_index_bitcount[8] = { 0, 0, 0, 0, 3, 2, 4, 2 };
static int get_bc7_alpha_index_size(int mode, int index_selection_bit) { return g_bc7_alpha_index_bitcount[mode] - index_selection_bit; }
static const constant int g_bc7_mode_has_p_bits[8] = { 1, 1, 0, 1, 0, 0, 1, 1 };
static const constant int g_bc7_mode_has_shared_p_bits[8] = { 0, 1, 0, 0, 0, 0, 0, 0 };
static const constant int g_bc7_color_precision_table[8] = { 4, 6, 5, 7, 5, 7, 7, 5 };
static const constant int g_bc7_alpha_precision_table[8] = { 0, 0, 0, 0, 6, 8, 7, 5 };
static bool get_bc7_mode_has_seperate_alpha_selectors(int mode) { return (mode == 4) || (mode == 5); }

struct endpoint_err // note: should match C++ code struct
{
    uint16_t m_error;
    uint8_t m_lo;
    uint8_t m_hi;
};

#define kBC7Weights2Index 0
#define kBC7Weights3Index 4
#define kBC7Weights4Index 12

struct LookupTables // note: should match C++ code struct
{
    // optimal endpoint tables
    endpoint_err mode_1[256][2]; // [c][pbit]
    endpoint_err mode_7[256][2][2]; // [c][pbit][hp][lp]
    endpoint_err mode_6[256][2][2]; // [c][hp][lp]
    uint32_t mode_4_3[256]; // [c]
    uint32_t mode_4_2[256]; // [c]
    endpoint_err mode_0[256][2][2]; // [c][hp][lp]

    // weights (what was g_bc7_weights2, g_bc7_weights3, g_bc7_weights4 in ISPC)
    uint32_t g_bc7_weights[4+8+16];
    // Precomputed weight constants used during least fit determination. For each entry in g_bc7_weights[]: w * w, (1.0f - w) * w, (1.0f - w) * (1.0f - w), w
    // (what was g_bc7_weights2x, g_bc7_weights3x, g_bc7_weights4x in ISPC)
    float4 g_bc7_weightsx[4+8+16];
};

const constant uint32_t BC7E_MODE_1_OPTIMAL_INDEX = 2;

const constant uint32_t BC7E_MODE_7_OPTIMAL_INDEX = 1;

const constant uint32_t BC7E_MODE_6_OPTIMAL_INDEX = 5;

const constant uint32_t BC7E_MODE_4_OPTIMAL_INDEX3 = 2;
const constant uint32_t BC7E_MODE_4_OPTIMAL_INDEX2 = 1;

const constant uint32_t BC7E_MODE_0_OPTIMAL_INDEX = 2;


static void compute_least_squares_endpoints_rgba(const uint part_mask, const uint partition, const thread uchar* pSelectors, uint weights_index, thread vec4F* pXl, thread vec4F* pXh, const thread uchar4* pColors, const constant LookupTables* tables)
{
    // Least squares using normal equations: http://www.cs.cornell.edu/~bindel/class/cs3220-s12/notes/lec10.pdf
    // I did this in matrix form first, expanded out all the ops, then optimized it a bit.
    float z00 = 0.0f, z01 = 0.0f, z10 = 0.0f, z11 = 0.0f;
    float4 q00 = 0.0f, t = 0.0f;
    for (uint i = 0, pm = part_mask; i < 16; ++i, pm >>= 2)
    {
        if ((pm & 3) != partition)
            continue;
        auto sel = pSelectors[i];
        float4 wt = tables->g_bc7_weightsx[weights_index+sel];
        z00 += wt.r;
        z10 += wt.g;
        z11 += wt.b;
        float w = wt.a;
        float4 pc = float4(pColors[i]);
        q00 += w * pc; t += pc;
    }

    float4 q10 = t - q00;

    z01 = z10;

    float det = z00 * z11 - z01 * z10;
    if (det != 0.0f)
        det = 1.0f / det;

    float iz00, iz01, iz10, iz11;
    iz00 = z11 * det;
    iz01 = -z01 * det;
    iz10 = -z10 * det;
    iz11 = z00 * det;

    *pXl = iz00 * q00 + iz01 * q10; *pXh = iz10 * q00 + iz11 * q10;
}

static void compute_least_squares_endpoints_a(const uint part_mask, const uint partition, const thread uchar* pSelectors, uint weights_index, thread float* pXl, thread float* pXh, const thread uchar4* pColors, const constant LookupTables* tables)
{
    // Least squares using normal equations: http://www.cs.cornell.edu/~bindel/class/cs3220-s12/notes/lec10.pdf
    // I did this in matrix form first, expanded out all the ops, then optimized it a bit.
    float z00 = 0.0f, z01 = 0.0f, z10 = 0.0f, z11 = 0.0f;
    float q00_a = 0.0f, q10_a = 0.0f, t_a = 0.0f;
    for (uint i = 0, pm = part_mask; i < 16; ++i, pm >>= 2)
    {
        if ((pm & 3) != partition)
            continue;
        const uint32_t sel = pSelectors[i];
        float4 wt = tables->g_bc7_weightsx[weights_index+sel];
        z00 += wt.r;
        z10 += wt.g;
        z11 += wt.b;
        float w = wt.a;

        q00_a += w * pColors[i].a; t_a += pColors[i].a;
    }

    q10_a = t_a - q00_a;

    z01 = z10;

    float det = z00 * z11 - z01 * z10;
    if (det != 0.0f)
        det = 1.0f / det;

    float iz00, iz01, iz10, iz11;
    iz00 = z11 * det;
    iz01 = -z01 * det;
    iz10 = -z10 * det;
    iz11 = z00 * det;

    *pXl = (float)(iz00 * q00_a + iz01 * q10_a); *pXh = (float)(iz10 * q00_a + iz11 * q10_a);
}

struct color_cell_compressor_params
{
    uint32_t m_num_selector_weights;
    uint32_t m_weights_index;
    uint32_t m_comp_bits;
    uint4 m_weights;
    bool m_has_alpha;
    bool m_has_pbits;
    bool m_endpoints_share_pbit;
    bool m_perceptual;
};

static inline void color_cell_compressor_params_clear(thread color_cell_compressor_params* p, const constant bc7e_compress_block_params* pComp_params)
{
    p->m_num_selector_weights = 0;
    p->m_weights_index = 0;
    p->m_comp_bits = 0;
    p->m_perceptual = pComp_params->m_perceptual;
    p->m_weights = pComp_params->m_weights;
    p->m_has_alpha = false;
    p->m_has_pbits = false;
    p->m_endpoints_share_pbit = false;
}

struct color_cell_compressor_results
{
    uint32_t m_best_overall_err;
    uchar4 m_low_endpoint;
    uchar4 m_high_endpoint;
    uchar m_pbits;
    thread uchar* m_pSelectors;
};

static inline color_quad_i scale_color(const thread color_quad_i* pC, const thread color_cell_compressor_params* pParams)
{
    color_quad_i results;

    const uint32_t n = pParams->m_comp_bits + (pParams->m_has_pbits ? 1 : 0);
    assert((n >= 4) && (n <= 8));
    uint4 v = uint4(*pC) << (8 - n);
    v |= v >> n;
    results = int4(v);
    return results;
}

static const constant float pr_weight = (.5f / (1.0f - .2126f)) * (.5f / (1.0f - .2126f));
static const constant float pb_weight = (.5f / (1.0f - .0722f)) * (.5f / (1.0f - .0722f));

static inline uint32_t compute_color_distance_rgb(const thread color_quad_i* pE1, const thread uchar4* pE2, bool perceptual, uint4 weights)
{
    if (perceptual)
    {
        const float l1 = pE1->r * .2126f + pE1->g * .7152f + pE1->b * .0722f;
        const float cr1 = pE1->r - l1;
        const float cb1 = pE1->b - l1;

        const float l2 = pE2->r * .2126f + pE2->g * .7152f + pE2->b * .0722f;
        const float cr2 = pE2->r - l2;
        const float cb2 = pE2->b - l2;

        float dl = l1 - l2;
        float dcr = cr1 - cr2;
        float dcb = cb1 - cb2;

        return (int32_t)(weights[0] * (dl * dl) + weights[1] * pr_weight * (dcr * dcr) + weights[2] * pb_weight * (dcb * dcb));
    }
    else
    {
        float dr = (float)pE1->r - (float)pE2->r;
        float dg = (float)pE1->g - (float)pE2->g;
        float db = (float)pE1->b - (float)pE2->b;
        
        return (int32_t)(weights[0] * dr * dr + weights[1] * dg * dg + weights[2] * db * db);
    }
}

static inline uint32_t compute_color_distance_rgba(const thread color_quad_i* pE1, const thread uchar4* pE2, bool perceptual, uint4 weights)
{
    float da = (float)pE1->a - (float)pE2->a;
    float a_err = weights[3] * (da * da);

    if (perceptual)
    {
        const float l1 = pE1->r * .2126f + pE1->g * .7152f + pE1->b * .0722f;
        const float cr1 = pE1->r - l1;
        const float cb1 = pE1->b - l1;

        const float l2 = pE2->r * .2126f + pE2->g * .7152f + pE2->b * .0722f;
        const float cr2 = pE2->r - l2;
        const float cb2 = pE2->b - l2;

        float dl = l1 - l2;
        float dcr = cr1 - cr2;
        float dcb = cb1 - cb2;

        return (int32_t)(weights[0] * (dl * dl) + weights[1] * pr_weight * (dcr * dcr) + weights[2] * pb_weight * (dcb * dcb) + a_err);
    }
    else
    {
        float dr = (float)pE1->r - (float)pE2->r;
        float dg = (float)pE1->g - (float)pE2->g;
        float db = (float)pE1->b - (float)pE2->b;
        
        return (int32_t)(weights[0] * dr * dr + weights[1] * dg * dg + weights[2] * db * db + a_err);
    }
}

struct ModePackSelColor
{
    color_quad_i col;
    int bestSelector;
};

static ModePackSelColor pack_mode1_to_one_color(const thread color_cell_compressor_params* pParams, thread color_cell_compressor_results* pResults, uchar4 c, const constant LookupTables* tables)
{
    ModePackSelColor res;

    uint32_t best_err = UINT_MAX;
    uint32_t best_p = 0;

    for (uint32_t p = 0; p < 2; p++)
    {
        uint32_t err = tables->mode_1[c.r][p].m_error + tables->mode_1[c.g][p].m_error + tables->mode_1[c.b][p].m_error;
        if (err < best_err)
        {
            best_err = err;
            best_p = p;
        }
    }

    const endpoint_err pEr = tables->mode_1[c.r][best_p];
    const endpoint_err pEg = tables->mode_1[c.g][best_p];
    const endpoint_err pEb = tables->mode_1[c.b][best_p];

    pResults->m_low_endpoint = uchar4(pEr.m_lo, pEg.m_lo, pEb.m_lo, 0);
    pResults->m_high_endpoint = uchar4(pEr.m_hi, pEg.m_hi, pEb.m_hi, 0);
    pResults->m_pbits = best_p;

    res.bestSelector = BC7E_MODE_1_OPTIMAL_INDEX;

    color_quad_i p;
    {
        uint3 low = uint3(((pResults->m_low_endpoint.rgb << 1) | best_p) << 1);
        low |= (low >> 7);
        uint3 high = uint3(((pResults->m_high_endpoint.rgb << 1) | best_p) << 1);
        high |= (high >> 7);
        p.rgb = int3((low * (64 - tables->g_bc7_weights[kBC7Weights3Index+BC7E_MODE_1_OPTIMAL_INDEX]) + high * tables->g_bc7_weights[kBC7Weights3Index+BC7E_MODE_1_OPTIMAL_INDEX] + 32) >> 6);
    }
    p.a = 255;
    res.col = p;
    return res;
}

static ModePackSelColor pack_mode24_to_one_color(const thread color_cell_compressor_params* pParams, thread color_cell_compressor_results* pResults, uchar4 c, const constant LookupTables* tables)
{
    ModePackSelColor res;
    uint32_t er, eg, eb;

    if (pParams->m_num_selector_weights == 8)
    {
        er = tables->mode_4_3[c.r];
        eg = tables->mode_4_3[c.g];
        eb = tables->mode_4_3[c.b];
    }
    else
    {
        er = tables->mode_4_2[c.r];
        eg = tables->mode_4_2[c.g];
        eb = tables->mode_4_2[c.b];
    }
    
    pResults->m_low_endpoint = uchar4(er & 0xFF, eg & 0xFF, eb & 0xFF, 0);
    pResults->m_high_endpoint = uchar4(er >> 8, eg >> 8, eb >> 8, 0);

    res.bestSelector = (pParams->m_num_selector_weights == 8) ? BC7E_MODE_4_OPTIMAL_INDEX3 : BC7E_MODE_4_OPTIMAL_INDEX2;

    color_quad_i p;
    {
        uint3 low = uint3(pResults->m_low_endpoint.rgb << 3);
        low |= (low >> 5);

        uint3 high = uint3(pResults->m_high_endpoint.rgb << 3);
        high |= (high >> 5);

        if (pParams->m_num_selector_weights == 8)
            p.rgb = int3((low * (64 - tables->g_bc7_weights[kBC7Weights3Index+BC7E_MODE_4_OPTIMAL_INDEX3]) + high * tables->g_bc7_weights[kBC7Weights3Index+BC7E_MODE_4_OPTIMAL_INDEX3] + 32) >> 6);
        else
            p.rgb = int3((low * (64 - tables->g_bc7_weights[kBC7Weights2Index+BC7E_MODE_4_OPTIMAL_INDEX2]) + high * tables->g_bc7_weights[kBC7Weights2Index+BC7E_MODE_4_OPTIMAL_INDEX2] + 32) >> 6);
    }
    p.a = 255;
    res.col = p;
    return res;
}

static ModePackSelColor pack_mode0_to_one_color(const thread color_cell_compressor_params* pParams, thread color_cell_compressor_results* pResults, uchar4 c, const constant LookupTables* tables)
{
    ModePackSelColor res;
    uint32_t best_err = UINT_MAX;
    uint32_t best_p = 0;

    for (uint32_t p = 0; p < 4; p++)
    {
        uint32_t err = tables->mode_0[c.r][p >> 1][p & 1].m_error + tables->mode_0[c.g][p >> 1][p & 1].m_error + tables->mode_0[c.b][p >> 1][p & 1].m_error;
        if (err < best_err)
        {
            best_err = err;
            best_p = p;
        }
    }

    const endpoint_err pEr = tables->mode_0[c.r][best_p >> 1][best_p & 1];
    const endpoint_err pEg = tables->mode_0[c.g][best_p >> 1][best_p & 1];
    const endpoint_err pEb = tables->mode_0[c.b][best_p >> 1][best_p & 1];

    pResults->m_low_endpoint = uchar4(pEr.m_lo, pEg.m_lo, pEb.m_lo, 0);
    pResults->m_high_endpoint = uchar4(pEr.m_hi, pEg.m_hi, pEb.m_hi, 0);

    pResults->m_pbits = best_p;

    res.bestSelector = BC7E_MODE_0_OPTIMAL_INDEX;

    color_quad_i p;
    {
        uint3 low = uint3(((pResults->m_low_endpoint.rgb << 1) | (best_p & 1)) << 3);
        low |= (low >> 5);

        uint3 high = uint3(((pResults->m_high_endpoint.rgb << 1) | (best_p >> 1)) << 3);
        high |= (high >> 5);

        p.rgb = int3((low * (64 - tables->g_bc7_weights[kBC7Weights3Index+BC7E_MODE_0_OPTIMAL_INDEX]) + high * tables->g_bc7_weights[kBC7Weights3Index+BC7E_MODE_0_OPTIMAL_INDEX] + 32) >> 6);
    }    
    p.a = 255;
    res.col = p;
    return res;
}

static ModePackSelColor pack_mode6_to_one_color(const thread color_cell_compressor_params* pParams, thread color_cell_compressor_results* pResults, uchar4 c, const constant LookupTables* tables)
{
    ModePackSelColor res;
    uint32_t best_err = UINT_MAX;
    uint32_t best_p = 0;

    for (uint32_t p = 0; p < 4; p++)
    {
        uint32_t hi_p = p >> 1;
        uint32_t lo_p = p & 1;
        uint32_t err = tables->mode_6[c.r][hi_p][lo_p].m_error + tables->mode_6[c.g][hi_p][lo_p].m_error + tables->mode_6[c.b][hi_p][lo_p].m_error + tables->mode_6[c.a][hi_p][lo_p].m_error;
        if (err < best_err)
        {
            best_err = err;
            best_p = p;
        }
    }

    uint32_t best_hi_p = best_p >> 1;
    uint32_t best_lo_p = best_p & 1;

    const endpoint_err pEr = tables->mode_6[c.r][best_hi_p][best_lo_p];
    const endpoint_err pEg = tables->mode_6[c.g][best_hi_p][best_lo_p];
    const endpoint_err pEb = tables->mode_6[c.b][best_hi_p][best_lo_p];
    const endpoint_err pEa = tables->mode_6[c.a][best_hi_p][best_lo_p];

    pResults->m_low_endpoint = uchar4(pEr.m_lo, pEg.m_lo, pEb.m_lo, pEa.m_lo);
    pResults->m_high_endpoint = uchar4(pEr.m_hi, pEg.m_hi, pEb.m_hi, pEa.m_hi);

    pResults->m_pbits = best_p;

    res.bestSelector = BC7E_MODE_6_OPTIMAL_INDEX;

    color_quad_i p;
    {
        uint4 low = uint4((pResults->m_low_endpoint << 1) | best_lo_p);
        uint4 high = uint4((pResults->m_high_endpoint << 1) | best_hi_p);
        
        p = int4((low * (64 - tables->g_bc7_weights[kBC7Weights4Index+BC7E_MODE_6_OPTIMAL_INDEX]) + high * tables->g_bc7_weights[kBC7Weights4Index+BC7E_MODE_6_OPTIMAL_INDEX] + 32) >> 6);
    }
    res.col = p;
    return res;
}

static ModePackSelColor pack_mode7_to_one_color(const thread color_cell_compressor_params* pParams, thread color_cell_compressor_results* pResults, uchar4 c, const constant LookupTables* tables)
{
    ModePackSelColor res;
    uint32_t best_err = UINT_MAX;
    uint32_t best_p = 0;

    for (uint32_t p = 0; p < 4; p++)
    {
        uint32_t hi_p = p >> 1;
        uint32_t lo_p = p & 1;
        uint32_t err = tables->mode_7[c.r][hi_p][lo_p].m_error + tables->mode_7[c.g][hi_p][lo_p].m_error + tables->mode_7[c.b][hi_p][lo_p].m_error + tables->mode_7[c.a][hi_p][lo_p].m_error;
        if (err < best_err)
        {
            best_err = err;
            best_p = p;
        }
    }

    uint32_t best_hi_p = best_p >> 1;
    uint32_t best_lo_p = best_p & 1;

    const endpoint_err pEr = tables->mode_7[c.r][best_hi_p][best_lo_p];
    const endpoint_err pEg = tables->mode_7[c.g][best_hi_p][best_lo_p];
    const endpoint_err pEb = tables->mode_7[c.b][best_hi_p][best_lo_p];
    const endpoint_err pEa = tables->mode_7[c.a][best_hi_p][best_lo_p];

    pResults->m_low_endpoint = uchar4(pEr.m_lo, pEg.m_lo, pEb.m_lo, pEa.m_lo);
    pResults->m_high_endpoint = uchar4(pEr.m_hi, pEg.m_hi, pEb.m_hi, pEa.m_hi);

    pResults->m_pbits = best_p;

    res.bestSelector = BC7E_MODE_7_OPTIMAL_INDEX;

    color_quad_i p;
    {
        uint4 low = uint4((pResults->m_low_endpoint << 1) | best_lo_p);
        uint4 high = uint4((pResults->m_high_endpoint << 1) | best_hi_p);
        
        p = int4((low * (64 - tables->g_bc7_weights[kBC7Weights2Index+BC7E_MODE_7_OPTIMAL_INDEX]) + high * tables->g_bc7_weights[kBC7Weights2Index+BC7E_MODE_7_OPTIMAL_INDEX] + 32) >> 6);
    }
    res.col = p;
    return res;
}

struct ModePackResult
{
    uint32_t err;
    int bestSelector;
    color_quad_i p;
};

static ModePackResult pack_mode_to_one_color(
    int mode,
    const thread color_cell_compressor_params* pParams,
    thread color_cell_compressor_results* pResults,
    uchar4 col,
    const uint part_mask,
    const uint partition,
    const thread uchar4* pPixels,
    const constant LookupTables* tables)
{
    ModePackSelColor sel;
    if (mode == 0)
        sel = pack_mode0_to_one_color(pParams, pResults, col, tables);
    else if (mode == 1)
        sel = pack_mode1_to_one_color(pParams, pResults, col, tables);
    else if (mode == 6)
        sel = pack_mode6_to_one_color(pParams, pResults, col, tables);
    else if (mode == 7)
        sel = pack_mode7_to_one_color(pParams, pResults, col, tables);
    else
        sel = pack_mode24_to_one_color(pParams, pResults, col, tables);

    bool rgba = mode == 6 || mode == 7;
    uint err = 0;
    for (uint i = 0, pm = part_mask; i < 16; ++i, pm >>= 2)
    {
        if ((pm & 3) == partition)
        {
            if (rgba)
                err += compute_color_distance_rgba(&sel.col, &pPixels[i], pParams->m_perceptual, pParams->m_weights);
            else
                err += compute_color_distance_rgb(&sel.col, &pPixels[i], pParams->m_perceptual, pParams->m_weights);
        }
    }
    pResults->m_best_overall_err = err;
    ModePackResult res;
    res.bestSelector = sel.bestSelector;
    res.err = err;
    return res;
}

static uint32_t evaluate_solution(const uchar4 pLow, const uchar4 pHigh, uint pbits,
    const thread color_cell_compressor_params* pParams, thread color_cell_compressor_results* pResults, const uint part_mask, const uint partition, const thread uchar4* pPixels, const constant LookupTables* tables)
{
    color_quad_i quantMinColor = color_quad_i(pLow);
    color_quad_i quantMaxColor = color_quad_i(pHigh);

    if (pParams->m_has_pbits)
    {
        uint minPBit, maxPBit;
        if (pParams->m_endpoints_share_pbit)
            maxPBit = minPBit = pbits & 1;
        else
        {
            minPBit = pbits & 1;
            maxPBit = pbits >> 1;
        }
        quantMinColor = (quantMinColor << 1) | minPBit;
        quantMaxColor = (quantMaxColor << 1) | maxPBit;
    }
    color_quad_i actualMinColor = scale_color(&quantMinColor, pParams);
    color_quad_i actualMaxColor = scale_color(&quantMaxColor, pParams);

    const uint32_t N = pParams->m_num_selector_weights;
    float total_errf = 0;

    float4 ww = float4(pParams->m_weights);
    color_quad_f weightedColors[16];
    weightedColors[0] = float4(actualMinColor);
    weightedColors[N-1] = float4(actualMaxColor);
    for (uint32_t i = 1; i < (N - 1); i++)
    {
        float w = tables->g_bc7_weights[pParams->m_weights_index+i];
        weightedColors[i] = floor((weightedColors[0] * (64.0f - w) + weightedColors[N - 1] * w + 32) * (1.0f / 64.0f));
    }
    
    uchar selectors[16];

    if (!pParams->m_perceptual)
    {
        if (!pParams->m_has_alpha)
        {
            if (N == 16)
            {
                float3 ll = float3(actualMinColor.rgb);
                float3 dd = float3(actualMaxColor.rgb) - ll;
                const float f = N / (dd.r * dd.r + dd.g * dd.g + dd.b * dd.b);
                ll *= -dd;

                for (uint i = 0, pm = part_mask; i < 16; ++i, pm >>= 2)
                {
                    if ((pm & 3) != partition)
                        continue;
                    float3 pp = float3(pPixels[i].rgb);

                    float best_sel = floor(((pp.r * dd.r + ll.r) + (pp.g * dd.g + ll.g) + (pp.b * dd.b + ll.b)) * f + .5f);
                    best_sel = clamp(best_sel, (float)1, (float)(N - 1));
                    float best_sel0 = best_sel - 1;

                    float3 d0 = weightedColors[(int)best_sel0].rgb - pp;
                    float err0 = ww.r * d0.r * d0.r + ww.g * d0.g * d0.g + ww.b * d0.b * d0.b;
                    float3 d1 = weightedColors[(int)best_sel].rgb - pp;
                    float err1 = ww.r * d1.r * d1.r + ww.g * d1.g * d1.g + ww.b * d1.b * d1.b;

                    float min_err = min(err0, err1);
                    total_errf += min_err;
                    selectors[i] = (int)select(best_sel, best_sel0, min_err == err0);
                }
            }
            else
            {
                for (uint i = 0, pm = part_mask; i < 16; ++i, pm >>= 2)
                {
                    if ((pm & 3) != partition)
                        continue;
                    float3 pp = float3(pPixels[i].rgb);
                    float best_err = 1e+30f;
                    int best_sel;
                    for (uint32_t j = 0; j < N; j++)
                    {
                        float3 d = weightedColors[j].rgb - pp;
                        float err = ww.r * d.r * d.r + ww.g * d.g * d.g + ww.b * d.b * d.b;
                        if (err <= best_err)
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
        else
        {
            // alpha
            if (N == 16)
            {
                float4 ll = float4(actualMinColor);
                float4 dd = float4(actualMaxColor) - ll;
                const float f = N / (dd.r * dd.r + dd.g * dd.g + dd.b * dd.b + dd.a * dd.a);
                ll *= -dd;

                for (uint i = 0, pm = part_mask; i < 16; ++i, pm >>= 2)
                {
                    if ((pm & 3) != partition)
                        continue;
                    float4 pp = float4(pPixels[i]);

                    float best_sel = floor(((pp.r * dd.r + ll.r) + (pp.g * dd.g + ll.g) + (pp.b * dd.b + ll.b) + (pp.a * dd.a + ll.a)) * f + .5f);
                    best_sel = clamp(best_sel, (float)1, (float)(N - 1));
                    float best_sel0 = best_sel - 1;
                    
                    float4 d0 = weightedColors[(int)best_sel0] - pp;
                    float err0 = ww.r * d0.r * d0.r + ww.g * d0.g * d0.g + ww.b * d0.b * d0.b + ww.a * d0.a * d0.a;
                    float4 d1 = weightedColors[(int)best_sel] - pp;
                    float err1 = ww.r * d1.r * d1.r + ww.g * d1.g * d1.g + ww.b * d1.b * d1.b + ww.a * d1.a * d1.a;

                    float min_err = min(err0, err1);
                    total_errf += min_err;
                    selectors[i] = (int)select(best_sel, best_sel0, min_err == err0);
                }
            }
            else
            {
                for (uint i = 0, pm = part_mask; i < 16; ++i, pm >>= 2)
                {
                    if ((pm & 3) != partition)
                        continue;
                    float4 pp = float4(pPixels[i]);
                    float best_err = 1e+30f;
                    int best_sel;
                    for (uint32_t j = 0; j < N; j++)
                    {
                        float4 d = weightedColors[j] - pp;
                        float err = ww.r * d.r * d.r + ww.g * d.g * d.g + ww.b * d.b * d.b + ww.a * d.a * d.a;
                        if (err <= best_err)
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
    }
    else
    {
        // perceptual
        ww.g *= pr_weight;
        ww.b *= pb_weight;

        float3 weightedColorsYCrCb[16];
        for (uint32_t i = 0; i < N; i++)
        {
            float3 pp = weightedColors[i].rgb;
            float y = pp.r * .2126f + pp.g * .7152f + pp.b * .0722f;
            weightedColorsYCrCb[i] = float3(y, pp.r - y, pp.b - y);
        }

        if (pParams->m_has_alpha)
        {
            for (uint i = 0, pm = part_mask; i < 16; ++i, pm >>= 2)
            {
                if ((pm & 3) != partition)
                    continue;
                float4 pp = float4(pPixels[i]);
                float y = pp.r * .2126f + pp.g * .7152f + pp.b * .0722f;
                float3 ycrcb = float3(y, pp.r - y, pp.b - y);

                float best_err = 1e+10f;
                int32_t best_sel;
                for (uint32_t j = 0; j < N; j++)
                {
                    float3 d = ycrcb - weightedColorsYCrCb[j];
                    float da = pp.a - weightedColors[j].a;
                    float err = (ww.r * d.x * d.x) + (ww.g * d.y * d.y) + (ww.b * d.z * d.z) + (ww.a * da * da);
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
            for (uint i = 0, pm = part_mask; i < 16; ++i, pm >>= 2)
            {
                if ((pm & 3) != partition)
                    continue;
                float3 pp = float3(pPixels[i].rgb);
                float y = pp.r * .2126f + pp.g * .7152f + pp.b * .0722f;
                float3 ycrcb = float3(y, pp.r - y, pp.b - y);

                float best_err = 1e+10f;
                int32_t best_sel;
                for (uint32_t j = 0; j < N; j++)
                {
                    float3 d = ycrcb - weightedColorsYCrCb[j];
                    float err = (ww.r * d.x * d.x) + (ww.g * d.y * d.y) + (ww.b * d.z * d.z);
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

    uint32_t total_err = total_errf;
    if (total_err < pResults->m_best_overall_err)
    {
        pResults->m_best_overall_err = total_err;
        pResults->m_low_endpoint = pLow;
        pResults->m_high_endpoint = pHigh;
        pResults->m_pbits = pbits;
        for (uint i = 0, pm = part_mask; i < 16; ++i, pm >>= 2)
        {
            if ((pm & 3) != partition)
                continue;
            pResults->m_pSelectors[i] = selectors[i];
        }
    }
    return total_err;
}

static void fixDegenerateEndpoints(uint32_t mode, thread uchar4& pTrialMinColor, thread uchar4& pTrialMaxColor, const vec4F pXl, const vec4F pXh, uint32_t iscale)
{
    if ((mode == 1) || (mode == 4)) // also mode 2
    {
        // fix degenerate case where the input collapses to a single colorspace voxel, and we loose all freedom (test with grayscale ramps)
        for (uint32_t i = 0; i < 3; i++)
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

static uint32_t find_optimal_solution(uint32_t mode, thread vec4F* pXl, thread vec4F* pXh, const thread color_cell_compressor_params* pParams, thread color_cell_compressor_results* pResults,
    bool pbit_search, const uint part_mask, const uint partition, const thread uchar4* pPixels, const constant LookupTables* tables)
{
    vec4F xl = saturate(*pXl);
    vec4F xh = saturate(*pXh);
        
    uchar4 minColor, maxColor;
    uint pbits;
    int final_iscale;
    if (pParams->m_has_pbits)
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

                uint32_t pbits[2];
                
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
                
                uint32_t pbits[2];
                
                pbits[0] = 0; pbits[1] = 0;
                evaluate_solution(&lo[0], &hi[0], pbits, pParams, pResults, num_pixels, pPixels);

                pbits[0] = 1; pbits[1] = 1;
                evaluate_solution(&lo[1], &hi[1], pbits, pParams, pResults, num_pixels, pPixels);
            }
        }
        else*/
        {
            // compensated rounding
            const int iscalep = (1 << (pParams->m_comp_bits + 1)) - 1;
            const float scalep = (float)iscalep;

            const int32_t totalComps = pParams->m_has_alpha ? 4 : 3;

            uint best_pbits = 0;
            uchar4 bestMinColor, bestMaxColor;
                        
            if (!pParams->m_endpoints_share_pbit)
            {
                float best_err0 = 1e+9;
                float best_err1 = 1e+9;
                                
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
                                                                                
                    color_quad_i scaledLow = scale_color(&xMinColor, pParams);
                    color_quad_i scaledHigh = scale_color(&xMaxColor, pParams);

                    float err0 = 0;
                    float err1 = 0;
                    for (int i = 0; i < totalComps; i++)
                    {
                        err0 += square(scaledLow[i] - xl[i]*255.0f);
                        err1 += square(scaledHigh[i] - xh[i]*255.0f);
                    }
                    if (err0 < best_err0)
                    {
                        best_err0 = err0;
                        best_pbits |= p;
                        bestMinColor = uchar4(xMinColor >> 1);
                    }
                    if (err1 < best_err1)
                    {
                        best_err1 = err1;
                        best_pbits |= p << 1;
                        bestMaxColor = uchar4(xMaxColor >> 1);
                    }
                }
            }
            else
            {
                // Endpoints share pbits
                float best_err = 1e+9;

                for (int p = 0; p < 2; p++)
                {
                    color_quad_i xMinColor, xMaxColor;
                                
                    xMinColor = int4((xl * scalep - p) / 2.0f + 0.5f) * 2 + p;
                    xMinColor = clamp(xMinColor, p, iscalep - 1 + p);
                    xMaxColor = int4((xh * scalep - p) / 2.0f + 0.5f) * 2 + p;
                    xMaxColor = clamp(xMaxColor, p, iscalep - 1 + p);
                                        
                    color_quad_i scaledLow = scale_color(&xMinColor, pParams);
                    color_quad_i scaledHigh = scale_color(&xMaxColor, pParams);

                    float err = 0;
                    for (int i = 0; i < totalComps; i++)
                        err += square((scaledLow[i]/255.0f) - xl[i]) + square((scaledHigh[i]/255.0f) - xh[i]);

                    if (err < best_err)
                    {
                        best_err = err;
                        best_pbits |= p | (p<<1);
                        bestMinColor = uchar4(xMinColor >> 1);
                        bestMaxColor = uchar4(xMaxColor >> 1);
                    }
                }
            }
            minColor = bestMinColor;
            maxColor = bestMaxColor;
            pbits = best_pbits;
            final_iscale = iscalep >> 1;
        }
    }
    else
    {
        const int iscale = (1 << pParams->m_comp_bits) - 1;
        const float scale = (float)iscale;

        minColor = uchar4(clamp(int4(xl * scale + .5f), 0, 255));
        maxColor = uchar4(clamp(int4(xh * scale + .5f), 0, 255));
        pbits = 0;
        final_iscale = iscale;
    }
    
    fixDegenerateEndpoints(mode, minColor, maxColor, xl, xh, final_iscale);
    if ((pResults->m_best_overall_err == UINT_MAX) || color_quad_i_notequals(minColor, pResults->m_low_endpoint) || color_quad_i_notequals(maxColor, pResults->m_high_endpoint) || (pbits != pResults->m_pbits))
    {
        evaluate_solution(minColor, maxColor, pbits, pParams, pResults, part_mask, partition, pPixels, tables);
    }
    return pResults->m_best_overall_err;
}

// Note: In mode 6, m_has_alpha will only be true for transparent blocks.
static uint32_t color_cell_compression(uint32_t mode, const thread color_cell_compressor_params* pParams, thread color_cell_compressor_results* pResults,
    const constant bc7e_compress_block_params* pComp_params, const uint part_mask, const uint partition, const thread uchar4* pPixels, bool refinement, const constant LookupTables* tables)
{
    pResults->m_best_overall_err = UINT_MAX;

    if ((mode != 6) && (mode != 7))
    {
        assert(!pParams->m_has_alpha);
    }

    if ((mode <= 2) || (mode == 4) || (mode >= 6))
    {
        bool allSame = true;
        uchar4 c;
        // find first color
        uint pm = part_mask;
        uint pi = 0;
        while (pi < 16)
        {
            if ((pm & 3) == partition)
            {
                c = pPixels[pi];
                break;
            }
            ++pi;
            pm >>= 2;
        }
        // check if all other colors are the same
        while (pi < 16)
        {
            if ((pm & 3) == partition)
            {
                if (!all(c == pPixels[pi]))
                {
                    allSame = false;
                    break;
                }
            }
            ++pi;
            pm >>= 2;
        }
        if (allSame)
        {
            ModePackResult res = pack_mode_to_one_color(mode, pParams, pResults, c, part_mask, partition, pPixels, tables);
            for (uint i = 0, pm = part_mask; i < 16; ++i, pm >>= 2)
            {
                if ((pm & 3) == partition)
                    pResults->m_pSelectors[i] = res.bestSelector;
            }
            return res.err;
        }
    }

    vec4F meanColor = 0.0f;
    uint pixel_count = 0;
    for (uint i = 0, pm = part_mask; i < 16; i++, pm >>= 2)
    {
        if ((pm & 3) == partition)
        {
            meanColor += float4(pPixels[i]);
            ++pixel_count;
        }
    }
    vec4F meanColorScaled = meanColor * (1.0f / pixel_count);
    meanColor = saturate(meanColor * (1.0f / (pixel_count * 255.0f)));

    vec4F axis;
    if (pParams->m_has_alpha)
    {
        vec4F v = 0.0f;
        bool first = true;
        for (uint i = 0, pm = part_mask; i < 16; i++, pm >>= 2)
        {
            if ((pm & 3) != partition)
                continue;
            vec4F color = float4(pPixels[i]) - meanColorScaled;

            vec4F a = color * color.r;
            vec4F b = color * color.g;
            vec4F c = color * color.b;
            vec4F d = color * color.a;

            vec4F n = first ? color : v;
            n = vec4F_normalize(n);

            v.r += dot(a, n);
            v.g += dot(b, n);
            v.b += dot(c, n);
            v.a += dot(d, n);
            first = false;
        }
        axis = v;
        axis = vec4F_normalize(axis);
    }
    else
    {
        float cov[6];
        cov[0] = 0; cov[1] = 0; cov[2] = 0;
        cov[3] = 0; cov[4] = 0; cov[5] = 0;

        for (uint i = 0, pm = part_mask; i < 16; i++, pm >>= 2)
        {
            if ((pm & 3) != partition)
                continue;
            float3 p = float3(pPixels[i].rgb);

            float r = p.r - meanColorScaled.r;
            float g = p.g - meanColorScaled.g;
            float b = p.b - meanColorScaled.b;
                
            cov[0] += r*r;
            cov[1] += r*g;
            cov[2] += r*b;
            cov[3] += g*g;
            cov[4] += g*b;
            cov[5] += b*b;
        }

        float vfr, vfg, vfb;
        //vfr = hi[0] - lo[0];
        //vfg = hi[1] - lo[1];
        //vfb = hi[2] - lo[2];
        // This is more stable.
        vfr = .9f;
        vfg = 1.0f;
        vfb = .7f;

        for (uint32_t iter = 0; iter < 3; iter++)
        {
            float r = vfr*cov[0] + vfg*cov[1] + vfb*cov[2];
            float g = vfr*cov[1] + vfg*cov[3] + vfb*cov[4];
            float b = vfr*cov[2] + vfg*cov[4] + vfb*cov[5];

            float m = max3(abs(r), abs(g), abs(b));
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

        float len = vfr*vfr + vfg*vfg + vfb*vfb;

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

    if (dot(axis, axis) < .5f)
    {
        if (pParams->m_perceptual)
            axis = float4(.213f, .715f, .072f, pParams->m_has_alpha ? .715f : 0);
        else
            axis = float4(1.0f, 1.0f, 1.0f, pParams->m_has_alpha ? 1.0f : 0);
        axis = vec4F_normalize(axis);
    }

    float l = 1e+9f, h = -1e+9f;

    for (uint i = 0, pm = part_mask; i < 16; i++, pm >>= 2)
    {
        if ((pm & 3) != partition)
            continue;
        vec4F q = float4(pPixels[i]) - meanColorScaled;
        float d = dot(q, axis);

        l = min(l, d);
        h = max(h, d);
    }

    l *= (1.0f / 255.0f);
    h *= (1.0f / 255.0f);

    vec4F b0 = axis * l;
    vec4F b1 = axis * h;
    vec4F c0 = meanColor + b0;
    vec4F c1 = meanColor + b1;
    vec4F minColor = saturate(c0);
    vec4F maxColor = saturate(c1);
                
    vec4F whiteVec = 1.0f;
    if (dot(minColor, whiteVec) > dot(maxColor, whiteVec))
    {
        vec4F temp = minColor;
        minColor = maxColor;
        maxColor = temp;
    }

    if (!find_optimal_solution(mode, &minColor, &maxColor, pParams, pResults, pComp_params->m_pbit_search, part_mask, partition, pPixels, tables))
        return 0;
    
    if (!refinement)
        return pResults->m_best_overall_err;
    
    // Note: m_refinement_passes is always 1, so hardcode to one loop iteration
    //for (uint32_t i = 0; i < pComp_params->m_refinement_passes; i++)
    {
        vec4F xl = 0.0f, xh = 0.0f;
        compute_least_squares_endpoints_rgba(part_mask, partition, pResults->m_pSelectors, pParams->m_weights_index, &xl, &xh, pPixels, tables);
        if (!pParams->m_has_alpha)
        {
            xl.a = 255.0f;
            xh.a = 255.0f;
        }

        xl = xl * (1.0f / 255.0f);
        xh = xh * (1.0f / 255.0f);

        if (!find_optimal_solution(mode, &xl, &xh, pParams, pResults, pComp_params->m_pbit_search, part_mask, partition, pPixels, tables))
            return 0;
    }

#if !defined(OPT_FASTMODES_ONLY) && !defined(OPT_ULTRAFAST_ONLY)
    if (pComp_params->m_uber_level > 0)
    {
        uchar selectors_temp0[16], selectors_temp1[16];
        for (uint i = 0; i < 16; i++)
            selectors_temp0[i] = pResults->m_pSelectors[i];

        const uchar max_selector = pParams->m_num_selector_weights - 1;

        uchar min_sel = 16;
        uchar max_sel = 0;
        for (uint i = 0, pm = part_mask; i < 16; ++i, pm >>= 2)
        {
            if ((pm & 3) != partition)
                continue;
            uchar sel = selectors_temp0[i];
            min_sel = min(min_sel, sel);
            max_sel = max(max_sel, sel);
        }

        vec4F xl = 0.0f, xh = 0.0f;
        for (uint uber_it = 0; uber_it < 3; ++uber_it)
        {
            // note: m_uber1_mask is always 7, skip check
            //uint uber_mask = 1 << uber_it;
            //if (!(pComp_params->m_uber1_mask & uber_mask))
            //    continue;
            for (uint i = 0, pm = part_mask; i < 16; ++i, pm >>= 2)
            {
                if ((pm & 3) != partition)
                    continue;
                uchar sel = selectors_temp0[i];
                if ((sel == min_sel) && (sel < max_selector) && (uber_it == 0 || uber_it == 2))
                    sel++;
                else if ((sel == max_sel) && (sel > 0) && (uber_it == 1 || uber_it == 2))
                    sel--;
                selectors_temp1[i] = sel;
            }
            compute_least_squares_endpoints_rgba(part_mask, partition, selectors_temp1, pParams->m_weights_index, &xl, &xh, pPixels, tables);
            if (!pParams->m_has_alpha)
            {
                xl.a = 255.0f;
                xh.a = 255.0f;
            }
            xl *= 1.0f / 255.0f;
            xh *= 1.0f / 255.0f;
            if (!find_optimal_solution(mode, &xl, &xh, pParams, pResults, pComp_params->m_pbit_search, part_mask, partition, pPixels, tables))
                return 0;
        }

#       if !defined(OPT_UBER_LESS_THAN_2_ONLY)
        const uint32_t uber_err_thresh = (num_pixels * 56) >> 4;
        if ((pComp_params->m_uber_level >= 2) && (pResults->m_best_overall_err > uber_err_thresh))
        {
            const int Q = (pComp_params->m_uber_level >= 4) ? (pComp_params->m_uber_level - 2) : 1;
            for (int ly = -Q; ly <= 1; ly++)
            {
                for (int hy = max_selector - 1; hy <= (max_selector + Q); hy++)
                {
                    if ((ly == 0) && (hy == max_selector))
                        continue;

                    for (uint32_t i = 0; i < num_pixels; i++)
                        selectors_temp1[i] = (int)clamp(floor((float)max_selector * ((float)(int)selectors_temp0[i] - (float)ly) / ((float)hy - (float)ly) + .5f), 0.0f, (float)max_selector);

                    xl = 0.0f;
                    xh = 0.0f;
                    compute_least_squares_endpoints_rgba(part_mask, partition, selectors_temp1, pParams->m_weights_index, &xl, &xh, pPixels, tables);
                    if (!pParams->m_has_alpha)
                    {
                        xl.a = 255.0f;
                        xh.a = 255.0f;
                    }

                    xl *= 1.0f / 255.0f;
                    xh *= 1.0f / 255.0f;

                    if (!find_optimal_solution(mode, &xl, &xh, pParams, pResults, pComp_params->m_pbit_search && (pComp_params->m_uber_level >= 2), part_mask, partition, pPixels, tables))
                        return 0;
                }
            }
        }
#       endif // #if !defined(OPT_UBER_LESS_THAN_2_ONLY)
    }
#endif // #if !defined(OPT_FASTMODES_ONLY) && !defined(OPT_ULTRAFAST_ONLY)

    if ((mode <= 2) || (mode == 4) || (mode >= 6))
    {
        color_cell_compressor_results avg_results;
                    
        avg_results.m_best_overall_err = pResults->m_best_overall_err;
        avg_results.m_pSelectors = pResults->m_pSelectors;
        
        uchar4 avg_c = uchar4(.5f + meanColor * 255.0f);

        ModePackResult avg_res = pack_mode_to_one_color(mode, pParams, &avg_results, avg_c, part_mask, partition, pPixels, tables);

        if (avg_res.err < pResults->m_best_overall_err)
        {
            pResults->m_best_overall_err = avg_res.err;
            pResults->m_low_endpoint = avg_results.m_low_endpoint;
            pResults->m_high_endpoint = avg_results.m_high_endpoint;
            pResults->m_pbits = avg_results.m_pbits;

            for (uint i = 0, pm = part_mask; i < 16; ++i, pm >>= 2)
            {
                if ((pm & 3) != partition)
                    continue;
                pResults->m_pSelectors[i] = avg_res.bestSelector;
            }
        }
    }
                    
    return pResults->m_best_overall_err;
}

static uint color_cell_compression_est(uint32_t mode, const thread color_cell_compressor_params* pParams, uint32_t best_err_so_far, const uint part_mask, const uint partition, const thread uchar4* pPixels)
{
    assert((pParams->m_num_selector_weights == 4) || (pParams->m_num_selector_weights == 8));

    float3 ll = 255;
    float3 hh = 0;
    for (uint i = 0, pm = part_mask; i < 16; ++i, pm >>= 2)
    {
        if ((pm & 3) != partition)
            continue;
        float3 p = float3(pPixels[i].rgb);
        ll = min(ll, p);
        hh = max(hh, p);
    }
            
    const uint32_t N = 1 << g_bc7_color_index_bitcount[mode];
    
    float3 ss = ll;
    float3 di = hh - ll;
    float3 fa = di;

    float low = fa.r * ll.r + fa.g * ll.g + fa.b * ll.b;
    float high = fa.r * hh.r + fa.g * hh.g + fa.b * hh.b;

    float scale = ((float)N - 1) / (float)(high - low);
    float inv_n = 1.0f / ((float)N - 1);

    float err = 0;
    // We don't handle perceptual very well here, but the difference is very slight (<.05 dB avg Luma PSNR across a large corpus) and the perf lost was high (2x slower).
    {
        float3 w = float3(pParams->m_weights.rgb);
        for (uint i = 0, pm = part_mask; i < 16; ++i, pm >>= 2)
        {
            if ((pm & 3) != partition)
                continue;
            float3 c = float3(pPixels[i].rgb);

            float d = fa.r * c.r + fa.g * c.g + fa.b * c.b;
            float s = saturate(floor((d - low) * scale + .5f) * inv_n);
            
            float3 it = ss + di * s;
            float3 dd = it - c;
            err += w.r * dd.r * dd.r + w.g * dd.g * dd.g + w.b * dd.b * dd.b;
        }
    }
    return (uint)err;
}

static uint color_cell_compression_est_mode7(uint32_t mode, const thread color_cell_compressor_params* pParams, uint32_t best_err_so_far, const uint part_mask, const uint partition, const thread uchar4* pPixels)
{
    assert((mode == 7) && (pParams->m_num_selector_weights == 4));

    float4 ll = 255;
    float4 hh = 0;
    for (uint i = 0, pm = part_mask; i < 16; ++i, pm >>= 2)
    {
        if ((pm & 3) != partition)
            continue;
        float4 p = float4(pPixels[i]);
        ll = min(ll, p);
        hh = max(hh, p);
    }
            
    const uint32_t N = 4;
                        
    float4 ss = ll;
    float4 di = hh - ll;
    float4 fa = di;

    float low = fa.r * ll.r + fa.g * ll.g + fa.b * ll.b + fa.a * ll.a;
    float high = fa.r * hh.r + fa.g * hh.g + fa.b * hh.b + fa.a * hh.a;

    float scale = ((float)N - 1) / (float)(high - low);
    float inv_n = 1.0f / ((float)N - 1);

    float err = 0;
    // We don't handle perceptual very well here, but the difference is very slight (<.05 dB avg Luma PSNR across a large corpus) and the perf lost was high (2x slower).
    {
        float4 w = pParams->m_perceptual ? float4(1,1,1,1) : float4(pParams->m_weights);
        for (uint i = 0, pm = part_mask; i < 16; ++i, pm >>= 2)
        {
            if ((pm & 3) != partition)
                continue;
            float4 c = float4(pPixels[i]);

            float d = fa.r * c.r + fa.g * c.g + fa.b * c.b + fa.a * c.a;
            float s = saturate(floor((d - low) * scale + .5f) * inv_n);
            
            float4 it = ss + di * s;
            float4 dd = it - c;
            err += w.r * dd.r * dd.r + w.g * dd.g * dd.g + w.b * dd.b * dd.b + w.a * dd.a * dd.a;
        }
    }
    return (uint)err;
}

static uint32_t estimate_partition(uint32_t mode, const uchar4 pixels[16], const constant bc7e_compress_block_params* pComp_params)
{
    const uint32_t total_subsets = g_bc7_num_subsets[mode];
    uint32_t total_partitions = min(pComp_params->m_max_partitions_mode[mode], 1U << g_bc7_partition_bits[mode]);

    if (total_partitions <= 1)
        return 0;

    uint32_t best_err = UINT_MAX;
    uint32_t best_partition = 0;

    color_cell_compressor_params params;
    color_cell_compressor_params_clear(&params, pComp_params);

    params.m_weights_index = (g_bc7_color_index_bitcount[mode] == 2) ? kBC7Weights2Index : kBC7Weights3Index;
    params.m_num_selector_weights = 1 << g_bc7_color_index_bitcount[mode];

    // Note: m_mode67_error_weight_mul was always 1, removed

    for (uint32_t partition = 0; partition < total_partitions; partition++)
    {
        const uint part_mask = (total_subsets == 3) ? g_bc7_partition3[partition] : g_bc7_partition2[partition];

        uint32_t total_subset_err = 0;
        for (uint32_t subset = 0; subset < total_subsets; subset++)
        {
            uint32_t err;
            if (mode == 7)
                err = color_cell_compression_est_mode7(mode, &params, best_err, part_mask, subset, pixels);
            else
                err = color_cell_compression_est(mode, &params, best_err, part_mask, subset, pixels);

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
    uint32_t m_index;
    uint32_t m_err;
};

static uint32_t estimate_partition_list(uint32_t mode, const thread uchar4* pixels, const constant bc7e_compress_block_params* pComp_params,
                                        thread solution* pSolutions, int32_t max_solutions)
{
    const int32_t orig_max_solutions = max_solutions;

    const uint32_t total_subsets = g_bc7_num_subsets[mode];
    uint32_t total_partitions = min(pComp_params->m_max_partitions_mode[mode], 1U << g_bc7_partition_bits[mode]);

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

    const int32_t HIGH_FREQUENCY_SORTED_PARTITION_THRESHOLD = 4;
    if (total_subsets == 2)
    {
        if (max_solutions < HIGH_FREQUENCY_SORTED_PARTITION_THRESHOLD)
            max_solutions = HIGH_FREQUENCY_SORTED_PARTITION_THRESHOLD;
    }
                        
    color_cell_compressor_params params;
    color_cell_compressor_params_clear(&params, pComp_params);

    params.m_weights_index = (g_bc7_color_index_bitcount[mode] == 2) ? kBC7Weights2Index : kBC7Weights3Index;
    params.m_num_selector_weights = 1 << g_bc7_color_index_bitcount[mode];

    // Note: m_mode67_error_weight_mul was always 1, removed

    int32_t num_solutions = 0;

    for (uint32_t partition = 0; partition < total_partitions; partition++)
    {
        const uint part_mask = (total_subsets == 3) ? g_bc7_partition3[partition] : g_bc7_partition2[partition];

        uint32_t total_subset_err = 0;
        for (uint32_t subset = 0; subset < total_subsets; subset++)
        {
            uint32_t err;
            if (mode == 7)
                err = color_cell_compression_est_mode7(mode, &params, UINT_MAX, part_mask, subset, pixels);
            else
                err = color_cell_compression_est(mode, &params, UINT_MAX, part_mask, subset, pixels);

            total_subset_err += err;

        } // subset

        int32_t i;
        for (i = 0; i < num_solutions; i++)
        {
            if (total_subset_err < pSolutions[i].m_err)
                break;
        }
                        
        if (i < num_solutions)
        {
            int32_t solutions_to_move = (max_solutions - 1) - i;
            int32_t num_elements_at_i = num_solutions - i;
            if (solutions_to_move > num_elements_at_i)
                solutions_to_move = num_elements_at_i;
                                                                
            assert(((i + 1) + solutions_to_move) <= max_solutions);
            assert((i + solutions_to_move) <= num_solutions);
            
            for (int32_t j = solutions_to_move - 1; j >= 0; --j)
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

static inline void set_block_bits(thread uint32_t* pWords, uint32_t val, uint32_t num_bits, thread uint32_t* pCur_ofs)
{
    assert(num_bits < 32);
    assert(val < (1U << num_bits));
        
    while (num_bits)
    {
        const uint32_t n = min(32 - (*pCur_ofs & 31), num_bits);

        pWords[*pCur_ofs >> 5] |= (val << (*pCur_ofs & 31));

        val >>= n;
        num_bits -= n;
        *pCur_ofs += n;
    }

    assert(*pCur_ofs <= 128);
}

struct bc7_optimization_results
{
    uchar m_selectors[16];          // 16B
    uchar m_alpha_selectors[16];    // 16B
    uchar4 m_low[3];                // 12B
    uchar4 m_high[3];               // 12B
    uint  m_error;                  // 4B
    uchar m_mode;                   // 1B
    uchar m_partition;              // 1B
    uchar m_pbits;                  // 1B [3][2] array of one bit each
    uchar m_rotation_index_sel;     // 1B low 4 bits rotation, high 4 bits index selector
};
static_assert(sizeof(bc7_optimization_results) == 64, "unexpected bc7_optimization_results struct size");

static uint4 encode_bc7_block(const thread bc7_optimization_results* pResults)
{
    const uint32_t best_mode = pResults->m_mode;

    const uint32_t total_subsets = g_bc7_num_subsets[best_mode];

    const uint32_t total_partitions = 1 << g_bc7_partition_bits[best_mode];

    uint part_mask;
    if (total_subsets == 1)
        part_mask = 0;
    else if (total_subsets == 2)
        part_mask = g_bc7_partition2[pResults->m_partition];
    else
        part_mask = g_bc7_partition3[pResults->m_partition];

    uchar color_selectors[16];
    for (int i = 0; i < 16; i++)
        color_selectors[i] = pResults->m_selectors[i];

    uchar alpha_selectors[16];
    for (int i = 0; i < 16; i++)
        alpha_selectors[i] = pResults->m_alpha_selectors[i];

    uchar4 low[3], high[3];
    low[0] = pResults->m_low[0];
    low[1] = pResults->m_low[1];
    low[2] = pResults->m_low[2];

    high[0] = pResults->m_high[0];
    high[1] = pResults->m_high[1];
    high[2] = pResults->m_high[2];
    
    auto rpbits = pResults->m_pbits;
    uchar pbits[3][2];
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
    
    int index_selector = pResults->m_rotation_index_sel >> 4;
    int rotation = pResults->m_rotation_index_sel & 0xF;

    for (uint32_t k = 0; k < total_subsets; k++)
    {
        uint32_t anchor_index = 0;
        if (k)
        {
            if ((total_subsets == 3) && (k == 1))
            {
                anchor_index = g_bc7_table_anchor_index_third_subset_1[pResults->m_partition];
            }
            else if ((total_subsets == 3) && (k == 2))
            {
                anchor_index = g_bc7_table_anchor_index_third_subset_2[pResults->m_partition];
            }
            else
            {
                anchor_index = g_bc7_table_anchor_index_second_subset[pResults->m_partition];
            }
        }

        anchor[k] = anchor_index;

        const uint32_t color_index_bits = get_bc7_color_index_size(best_mode, index_selector);
        const uint32_t num_color_indices = 1 << color_index_bits;

        if (color_selectors[anchor_index] & (num_color_indices >> 1))
        {
            uint pm = part_mask;
            for (uint32_t i = 0; i < 16; i++)
            {
                if ((pm & 3) == k)
                    color_selectors[i] = (num_color_indices - 1) - color_selectors[i];
                pm >>= 2;
            }

            if (get_bc7_mode_has_seperate_alpha_selectors(best_mode))
            {
                auto t = low[k].rgb;
                low[k].rgb = high[k].rgb;
                high[k].rgb = t;
            }
            else
            {
                auto tmp = low[k];
                low[k] = high[k];
                high[k] = tmp;
            }

            if (!g_bc7_mode_has_shared_p_bits[best_mode])
            {
                uint32_t t = pbits[k][0];
                pbits[k][0] = pbits[k][1];
                pbits[k][1] = t;
            }
        }

        if (get_bc7_mode_has_seperate_alpha_selectors(best_mode))
        {
            const uint32_t alpha_index_bits = get_bc7_alpha_index_size(best_mode, index_selector);
            const uint32_t num_alpha_indices = 1 << alpha_index_bits;

            if (alpha_selectors[anchor_index] & (num_alpha_indices >> 1))
            {
                uint pm = part_mask;
                for (uint32_t i = 0; i < 16; i++)
                {
                    if ((pm & 3) == k)
                        alpha_selectors[i] = (num_alpha_indices - 1) - alpha_selectors[i];
                    pm >>= 2;
                }

                int t = low[k].a;
                low[k].a = high[k].a;
                high[k].a = t;
            }
        }
    }

    uint32_t block[4] = {0};
    uint32_t cur_bit_ofs = 0;
        
    set_block_bits(block, 1 << best_mode, best_mode + 1, &cur_bit_ofs);

    if ((best_mode == 4) || (best_mode == 5))
        set_block_bits(block, rotation, 2, &cur_bit_ofs);

    if (best_mode == 4)
        set_block_bits(block, index_selector, 1, &cur_bit_ofs);

    if (total_partitions > 1)
        set_block_bits(block, pResults->m_partition, (total_partitions == 64) ? 6 : 4, &cur_bit_ofs);

    const uint32_t total_comps = (best_mode >= 4) ? 4 : 3;
    for (uint32_t comp = 0; comp < total_comps; comp++)
    {
        for (uint32_t subset = 0; subset < total_subsets; subset++)
        {
            set_block_bits(block, low[subset][comp], (comp == 3) ? g_bc7_alpha_precision_table[best_mode] : g_bc7_color_precision_table[best_mode], &cur_bit_ofs);
            set_block_bits(block, high[subset][comp], (comp == 3) ? g_bc7_alpha_precision_table[best_mode] : g_bc7_color_precision_table[best_mode], &cur_bit_ofs);
        }
    }

    if (g_bc7_mode_has_p_bits[best_mode])
    {
        for (uint32_t subset = 0; subset < total_subsets; subset++)
        {
            set_block_bits(block, pbits[subset][0], 1, &cur_bit_ofs);
            if (!g_bc7_mode_has_shared_p_bits[best_mode])
                set_block_bits(block, pbits[subset][1], 1, &cur_bit_ofs);
        }
    }

    for (uint32_t y = 0; y < 4; y++)
    {
        for (uint32_t x = 0; x < 4; x++)
        {
            int idx = x + y * 4;

            uint32_t n = index_selector ? get_bc7_alpha_index_size(best_mode, index_selector) : get_bc7_color_index_size(best_mode, index_selector);

            if ((idx == anchor[0]) || (idx == anchor[1]) || (idx == anchor[2]))
                n--;

            set_block_bits(block, index_selector ? alpha_selectors[idx] : color_selectors[idx], n, &cur_bit_ofs);
        }
    }

    if (get_bc7_mode_has_seperate_alpha_selectors(best_mode))
    {
        for (uint32_t y = 0; y < 4; y++)
        {
            for (uint32_t x = 0; x < 4; x++)
            {
                int idx = x + y * 4;

                uint32_t n = index_selector ? get_bc7_color_index_size(best_mode, index_selector) : get_bc7_alpha_index_size(best_mode, index_selector);

                if ((idx == anchor[0]) || (idx == anchor[1]) || (idx == anchor[2]))
                    n--;

                set_block_bits(block, index_selector ? color_selectors[idx] : alpha_selectors[idx], n, &cur_bit_ofs);
            }
        }
    }

    assert(cur_bit_ofs == 128);
    return uint4(block[0], block[1], block[2], block[3]);
}

static void handle_alpha_block_mode4(const thread uchar4* pPixels, const constant bc7e_compress_block_params* pComp_params, thread color_cell_compressor_params* pParams, uint32_t lo_a, uint32_t hi_a,
                                     thread bc7_optimization_results& res, const constant LookupTables* tables, int rotation)
{
    for (uint32_t index_selector = 0; index_selector < 2; index_selector++)
    {
        if ((pComp_params->m_mode4_index_mask & (1 << index_selector)) == 0)
            continue;

        if (index_selector)
        {
            pParams->m_weights_index = kBC7Weights3Index;
            pParams->m_num_selector_weights = 8;
        }
        else
        {
            pParams->m_weights_index = kBC7Weights2Index;
            pParams->m_num_selector_weights = 4;
        }
                                
        color_cell_compressor_results results;
        
        uchar selectors[16];
        results.m_pSelectors = selectors;

        uint32_t trial_err = color_cell_compression(4, pParams, &results, pComp_params, 0, 0, pPixels, true, tables);
        assert(trial_err == results.m_best_overall_err);

        uint32_t la = min((lo_a + 2) >> 2, 63u);
        uint32_t ha = min((hi_a + 2) >> 2, 63u);

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

        uint32_t best_alpha_err = UINT_MAX;
        uint32_t best_la = 0, best_ha = 0;
        uchar best_alpha_selectors[16];
                        
        for (int32_t pass = 0; pass < 2; pass++)
        {
            int32_t vals[8];

            if (index_selector == 0)
            {
                vals[0] = (la << 2) | (la >> 4);
                vals[7] = (ha << 2) | (ha >> 4);

                for (uint32_t i = 1; i < 7; i++)
                    vals[i] = (vals[0] * (64 - tables->g_bc7_weights[kBC7Weights3Index+i]) + vals[7] * tables->g_bc7_weights[kBC7Weights3Index+i] + 32) >> 6;
            }
            else
            {
                vals[0] = (la << 2) | (la >> 4);
                vals[3] = (ha << 2) | (ha >> 4);

                const int32_t w_s1 = 21, w_s2 = 43;
                vals[1] = (vals[0] * (64 - w_s1) + vals[3] * w_s1 + 32) >> 6;
                vals[2] = (vals[0] * (64 - w_s2) + vals[3] * w_s2 + 32) >> 6;
            }

            uint32_t trial_alpha_err = 0;

            uchar trial_alpha_selectors[16];
            for (uint32_t i = 0; i < 16; i++)
            {
                const int32_t a = pPixels[i].a;

                int s = 0;
                int32_t be = abs(a - vals[0]);

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
                for (uint32_t i = 0; i < 16; i++)
                    best_alpha_selectors[i] = trial_alpha_selectors[i];
            }

            if (pass == 0)
            {
                float xl, xh;
                compute_least_squares_endpoints_a(0, 0, trial_alpha_selectors, index_selector ? kBC7Weights2Index : kBC7Weights3Index, &xl, &xh, pPixels, tables);
                if (xl > xh)
                    swapf(&xl, &xh);
                la = clamp((int)floor(xl * (63.0f / 255.0f) + .5f), 0, 63);
                ha = clamp((int)floor(xh * (63.0f / 255.0f) + .5f), 0, 63);
            }
                        
        } // pass

#if !defined(OPT_FASTMODES_ONLY) && !defined(OPT_ULTRAFAST_ONLY)
        if (pComp_params->m_uber_level > 0)
        {
            const int D = min((int)pComp_params->m_uber_level, 3);
            for (int ld = -D; ld <= D; ld++)
            {
                for (int hd = -D; hd <= D; hd++)
                {
                    la = clamp((int)best_la + ld, 0, 63);
                    ha = clamp((int)best_ha + hd, 0, 63);
                    
                    int32_t vals[8];

                    if (index_selector == 0)
                    {
                        vals[0] = (la << 2) | (la >> 4);
                        vals[7] = (ha << 2) | (ha >> 4);

                        for (uint32_t i = 1; i < 7; i++)
                            vals[i] = (vals[0] * (64 - tables->g_bc7_weights[kBC7Weights3Index+i]) + vals[7] * tables->g_bc7_weights[kBC7Weights3Index+i] + 32) >> 6;
                    }
                    else
                    {
                        vals[0] = (la << 2) | (la >> 4);
                        vals[3] = (ha << 2) | (ha >> 4);

                        const int32_t w_s1 = 21, w_s2 = 43;
                        vals[1] = (vals[0] * (64 - w_s1) + vals[3] * w_s1 + 32) >> 6;
                        vals[2] = (vals[0] * (64 - w_s2) + vals[3] * w_s2 + 32) >> 6;
                    }

                    uint32_t trial_alpha_err = 0;

                    uchar trial_alpha_selectors[16];
                    for (uint32_t i = 0; i < 16; i++)
                    {
                        const int32_t a = pPixels[i].a;

                        int s = 0;
                        int32_t be = abs(a - vals[0]);

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
                        for (uint32_t i = 0; i < 16; i++)
                            best_alpha_selectors[i] = trial_alpha_selectors[i];
                    }
                
                } // hd

            } // ld
        }
#endif // #if !defined(OPT_FASTMODES_ONLY) && !defined(OPT_ULTRAFAST_ONLY)

        trial_err += best_alpha_err;

        if (trial_err < res.m_error)
        {
            res.m_error = trial_err;

            res.m_mode = 4;
            res.m_rotation_index_sel = (index_selector << 4) | rotation;
            res.m_partition = 0;

            res.m_low[0] = results.m_low_endpoint;
            res.m_high[0] = results.m_high_endpoint;
            res.m_low[0].a = best_la;
            res.m_high[0].a = best_ha;

            for (uint32_t i = 0; i < 16; i++)
                res.m_selectors[i] = selectors[i];

            for (uint32_t i = 0; i < 16; i++)
                res.m_alpha_selectors[i] = best_alpha_selectors[i];
        }

    } // index_selector
}

static void handle_alpha_block_mode5(const thread uchar4* pPixels, const constant bc7e_compress_block_params* pComp_params, thread const color_cell_compressor_params* pParams, uint32_t lo_a, uint32_t hi_a,
                                     thread bc7_optimization_results* pOpt_results5, const constant LookupTables* tables)
{
    color_cell_compressor_results results5;
    results5.m_pSelectors = pOpt_results5->m_selectors;

    pOpt_results5->m_error = color_cell_compression(5, pParams, &results5, pComp_params, 0, 0, pPixels, true, tables);
    assert(pOpt_results5->m_error == results5.m_best_overall_err);

    pOpt_results5->m_low[0] = results5.m_low_endpoint;
    pOpt_results5->m_high[0] = results5.m_high_endpoint;

    if (lo_a == hi_a)
    {
        pOpt_results5->m_low[0].a = lo_a;
        pOpt_results5->m_high[0].a = hi_a;
        for (uint32_t i = 0; i < 16; i++)
            pOpt_results5->m_alpha_selectors[i] = 0;
    }
    else
    {
        uint32_t mode5_alpha_err = UINT_MAX;

        for (uint32_t pass = 0; pass < 2; pass++)
        {
            int32_t vals[4];
            vals[0] = lo_a;
            vals[3] = hi_a;

            const int32_t w_s1 = 21, w_s2 = 43;
            vals[1] = (vals[0] * (64 - w_s1) + vals[3] * w_s1 + 32) >> 6;
            vals[2] = (vals[0] * (64 - w_s2) + vals[3] * w_s2 + 32) >> 6;

            uchar trial_alpha_selectors[16];

            uint32_t trial_alpha_err = 0;
            for (uint32_t i = 0; i < 16; i++)
            {
                const int32_t a = pPixels[i].a;

                int s = 0;
                int32_t be = abs(a - vals[0]);
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
                for (uint32_t i = 0; i < 16; i++)
                    pOpt_results5->m_alpha_selectors[i] = trial_alpha_selectors[i];
            }

            if (!pass)
            {
                float xl, xh;
                compute_least_squares_endpoints_a(0, 0, trial_alpha_selectors, kBC7Weights2Index, &xl, &xh, pPixels, tables);

                uint32_t new_lo_a = clamp((int)floor(xl + .5f), 0, 255);
                uint32_t new_hi_a = clamp((int)floor(xh + .5f), 0, 255);
                if (new_lo_a > new_hi_a)
                    swapu(&new_lo_a, &new_hi_a);

                if ((new_lo_a == lo_a) && (new_hi_a == hi_a))
                    break;

                lo_a = new_lo_a;
                hi_a = new_hi_a;
            }
        }

#if !defined(OPT_FASTMODES_ONLY) && !defined(OPT_ULTRAFAST_ONLY)
        if (pComp_params->m_uber_level > 0)
        {
            const int D = min((int)pComp_params->m_uber_level, 3);
            for (int ld = -D; ld <= D; ld++)
            {
                for (int hd = -D; hd <= D; hd++)
                {
                    lo_a = clamp((int)pOpt_results5->m_low[0].a + ld, 0, 255);
                    hi_a = clamp((int)pOpt_results5->m_high[0].a + hd, 0, 255);
                    
                    int32_t vals[4];
                    vals[0] = lo_a;
                    vals[3] = hi_a;

                    const int32_t w_s1 = 21, w_s2 = 43;
                    vals[1] = (vals[0] * (64 - w_s1) + vals[3] * w_s1 + 32) >> 6;
                    vals[2] = (vals[0] * (64 - w_s2) + vals[3] * w_s2 + 32) >> 6;

                    uchar trial_alpha_selectors[16];

                    uint32_t trial_alpha_err = 0;
                    for (uint32_t i = 0; i < 16; i++)
                    {
                        const int32_t a = pPixels[i].a;

                        int s = 0;
                        int32_t be = abs(a - vals[0]);
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
                        for (uint32_t i = 0; i < 16; i++)
                            pOpt_results5->m_alpha_selectors[i] = trial_alpha_selectors[i];
                    }
                
                } // hd

            } // ld
        }
#endif // #if !defined(OPT_FASTMODES_ONLY) && !defined(OPT_ULTRAFAST_ONLY)

        pOpt_results5->m_error += mode5_alpha_err;
    }

    pOpt_results5->m_mode = 5;
    pOpt_results5->m_rotation_index_sel = 0;
    pOpt_results5->m_partition = 0;
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

static uint4 get_lists_alpha(const uchar4 pixels[16], const constant bc7e_compress_block_params* pComp_params)
{
    // x = mode 7 lists
    uint4 lists = 0;

    // Mode 7
    #if !defined(OPT_ULTRAFAST_ONLY)
    if (pComp_params->m_alpha_settings.m_use_mode7)
    {
        solution solutions[4];
        uint32_t num_solutions = estimate_partition_list(7, pixels, pComp_params, solutions, pComp_params->m_alpha_settings.m_max_mode7_partitions_to_try);
        lists.x = encode_solutions(solutions, num_solutions);
    }
    #endif // #if !defined(OPT_ULTRAFAST_ONLY)
    return lists;
}

static uint4 get_lists_opaque(const uchar4 pixels[16], const constant bc7e_compress_block_params* pComp_params)
{
    // x = unused
    // y = mode 1|3 lists
    // z = mode 0 lists
    // w = mode 2 lists
    uint4 lists = 0;
    
    if ((pComp_params->m_opaque_settings.m_use_mode[1] || pComp_params->m_opaque_settings.m_use_mode[3]) && !pComp_params->m_mode6_only)
    {
        solution sol13[4];
        uint num_sol13 = 0;
        if (pComp_params->m_opaque_settings.m_max_mode13_partitions_to_try == 1)
        {
            sol13[0].m_index = estimate_partition(1, pixels, pComp_params);
            num_sol13 = 1;
        }
        else
        {
            num_sol13 = estimate_partition_list(1, pixels, pComp_params, sol13, pComp_params->m_opaque_settings.m_max_mode13_partitions_to_try);
        }
        lists.y = encode_solutions(sol13, num_sol13);
    }
    
    if ((pComp_params->m_opaque_settings.m_use_mode[0]) && !pComp_params->m_mode6_only)
    {
        solution sol0[4];
        uint num_sol0 = 0;
        if (pComp_params->m_opaque_settings.m_max_mode0_partitions_to_try == 1)
        {
            sol0[0].m_index = estimate_partition(0, pixels, pComp_params);
            num_sol0 = 1;
        }
        else
        {
            num_sol0 = estimate_partition_list(0, pixels, pComp_params, sol0, pComp_params->m_opaque_settings.m_max_mode0_partitions_to_try);
        }
        lists.z = encode_solutions(sol0, num_sol0);
    }
    
    if ((pComp_params->m_opaque_settings.m_use_mode[2]) && !pComp_params->m_mode6_only)
    {
        solution sol2[4];
        uint num_sol2 = 0;
        if (pComp_params->m_opaque_settings.m_max_mode2_partitions_to_try == 1)
        {
            sol2[0].m_index = estimate_partition(2, pixels, pComp_params);
            num_sol2 = 1;
        }
        else
        {
            num_sol2 = estimate_partition_list(2, pixels, pComp_params, sol2, pComp_params->m_opaque_settings.m_max_mode2_partitions_to_try);
        }
        lists.w = encode_solutions(sol2, num_sol2);
    }

    return lists;
}

static void handle_block_mode4(
                               thread bc7_optimization_results& res,
                               const uchar4 pixels[16],
                               const constant bc7e_compress_block_params* pComp_params,
                               int lo_a,
                               int hi_a,
                               int num_rotations,
                               const constant LookupTables* tables)
{
    color_cell_compressor_params params;
    color_cell_compressor_params_clear(&params, pComp_params);
    params.m_has_alpha = false;
    params.m_comp_bits = 5;
    params.m_has_pbits = false;
    params.m_endpoints_share_pbit = false;

    for (int rotation = 0; rotation < num_rotations; rotation++)
    {
        if ((pComp_params->m_mode4_rotation_mask & (1 << rotation)) == 0)
            continue;

        params.m_weights = pComp_params->m_weights;
        if (rotation == 1) params.m_weights = params.m_weights.agbr;
        if (rotation == 2) params.m_weights = params.m_weights.rabg;
        if (rotation == 3) params.m_weights = params.m_weights.rgab;
                        
        uchar4 rot_pixels[16];
        const thread uchar4* pTrial_pixels = pixels;
        uchar trial_lo_a = lo_a, trial_hi_a = hi_a;
        if (rotation)
        {
            trial_lo_a = 255;
            trial_hi_a = 0;

            for (uint32_t i = 0; i < 16; i++)
            {
                auto c = pixels[i];
                if (rotation == 1) c = c.agbr;
                if (rotation == 2) c = c.rabg;
                if (rotation == 3) c = c.rgab;
                rot_pixels[i] = c;

                trial_lo_a = min(trial_lo_a, c.a);
                trial_hi_a = max(trial_hi_a, c.a);
            }

            pTrial_pixels = rot_pixels;
        }
        handle_alpha_block_mode4(pTrial_pixels, pComp_params, &params, trial_lo_a, trial_hi_a, res, tables, rotation);
    } // rotation
}

static void handle_block_mode5(
                               thread bc7_optimization_results& res,
                               const uchar4 pixels[16],
                               const constant bc7e_compress_block_params* pComp_params,
                               int lo_a,
                               int hi_a,
                               uint num_rotations,
                               const constant LookupTables* tables)
{
    color_cell_compressor_params params;
    color_cell_compressor_params_clear(&params, pComp_params);
    params.m_weights_index = kBC7Weights2Index;
    params.m_num_selector_weights = 4;
    params.m_comp_bits = 7;
    params.m_has_alpha = false;
    params.m_has_pbits = false;
    params.m_endpoints_share_pbit = false;

    for (uint rotation = 0; rotation < num_rotations; rotation++)
    {
        if ((pComp_params->m_mode5_rotation_mask & (1 << rotation)) == 0)
            continue;

        params.m_weights = pComp_params->m_weights;
        if (rotation == 1) params.m_weights = params.m_weights.agbr;
        if (rotation == 2) params.m_weights = params.m_weights.rabg;
        if (rotation == 3) params.m_weights = params.m_weights.rgab;

        uchar4 rot_pixels[16];
        const thread uchar4* pTrial_pixels = pixels;
        uchar trial_lo_a = lo_a, trial_hi_a = hi_a;
        if (rotation)
        {
            trial_lo_a = 255;
            trial_hi_a = 0;

            for (uint32_t i = 0; i < 16; i++)
            {
                auto c = pixels[i];
                if (rotation == 1) c = c.agbr;
                if (rotation == 2) c = c.rabg;
                if (rotation == 3) c = c.rgab;
                rot_pixels[i] = c;

                trial_lo_a = min(trial_lo_a, c.a);
                trial_hi_a = max(trial_hi_a, c.a);
            }

            pTrial_pixels = rot_pixels;
        }

        bc7_optimization_results trial_res;
        trial_res.m_error = 0;
        handle_alpha_block_mode5(pTrial_pixels, pComp_params, &params, trial_lo_a, trial_hi_a, &trial_res, tables);

        if (trial_res.m_error < res.m_error)
        {
            res = trial_res;
            res.m_rotation_index_sel = rotation;
        }
    } // rotation
}

static void handle_alpha_block_mode7(
                                     thread bc7_optimization_results& res,
                                     const uchar4 pixels[16],
                                     const constant bc7e_compress_block_params* pComp_params,
                                     const constant LookupTables* tables,
                                     uint4 solution_lists)
{
    color_cell_compressor_params params;
    color_cell_compressor_params_clear(&params, pComp_params);
    params.m_weights_index = kBC7Weights2Index;
    params.m_num_selector_weights = 4;
    params.m_comp_bits = 5;
    params.m_has_pbits = true;
    params.m_endpoints_share_pbit = false;
    params.m_has_alpha = true;

    const bool disable_faster_part_selection = false;
    solution solutions[4];
    uint num_solutions = decode_solutions(solution_lists.x, solutions);
    for (uint32_t solution_index = 0; solution_index < num_solutions; solution_index++)
    {
        const uint32_t trial_partition = solutions[solution_index].m_index;
        assert(trial_partition < 64);

        const uint part_mask = g_bc7_partition2[trial_partition];

        uchar selectors[16];
        color_cell_compressor_results sub_res[2];

        uint32_t trial_err = 0;
        for (uint32_t subset = 0; subset < 2; subset++)
        {
            thread color_cell_compressor_results* pResults = &sub_res[subset];
            pResults->m_pSelectors = selectors;

            uint32_t err = color_cell_compression(7, &params, pResults, pComp_params, part_mask, subset, pixels, (num_solutions <= 2) || disable_faster_part_selection, tables);
            assert(err == pResults->m_best_overall_err);

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
            for (uint i = 0; i < 16; ++i)
                res.m_selectors[i] = selectors[i];
            res.m_pbits = 0;
            for (uint32_t subset = 0; subset < 2; subset++)
            {
                res.m_low[subset] = sub_res[subset].m_low_endpoint;
                res.m_high[subset] = sub_res[subset].m_high_endpoint;
                res.m_pbits |= sub_res[subset].m_pbits << subset*2;
            }
        }

    } // solution_index

#if !defined(OPT_MAX_PARTITION_TRIES_LESS_THAN_3_ONLY)
    if ((num_solutions > 2) && (res.m_mode == 7) && (!disable_faster_part_selection))
    {
        const uint32_t trial_partition = res.m_partition;
        assert(trial_partition < 64);

        const uint part_mask = g_bc7_partition2[trial_partition];

        uchar selectors[16];
        color_cell_compressor_results sub_res[2];

        uint32_t trial_err = 0;
        for (uint32_t subset = 0; subset < 2; subset++)
        {
            thread color_cell_compressor_results* pResults = &sub_res[subset];
            pResults->m_pSelectors = selectors;

            uint32_t err = color_cell_compression(7, &params, pResults, pComp_params, part_mask, subset, pixels, true, tables);
            assert(err == pResults->m_best_overall_err);

            trial_err += err;
            if (trial_err > res.m_error)
                break;
        } // subset

        if (trial_err < res.m_error)
        {
            res.m_error = trial_err;
            for (uint i = 0; i < 16; ++i)
                res.m_selectors[i] = selectors[i];
            res.m_pbits = 0;
            for (uint32_t subset = 0; subset < 2; subset++)
            {
                res.m_low[subset] = sub_res[subset].m_low_endpoint;
                res.m_high[subset] = sub_res[subset].m_high_endpoint;
                res.m_pbits |= sub_res[subset].m_pbits << subset*2;
            }
        }
    }
#endif // #if !defined(OPT_MAX_PARTITION_TRIES_LESS_THAN_3_ONLY)
}

static void handle_block_mode6(
                               thread bc7_optimization_results& res,
                               const uchar4 pixels[16],
                               const constant bc7e_compress_block_params* pComp_params,
                               const constant LookupTables* tables,
                               bool has_alpha)
{
    color_cell_compressor_params params;
    color_cell_compressor_params_clear(&params, pComp_params);
    params.m_weights_index = kBC7Weights4Index;
    params.m_num_selector_weights = 16;
    params.m_comp_bits = 7;
    params.m_has_pbits = true;
    params.m_endpoints_share_pbit = false;
    params.m_has_alpha = has_alpha;
    // Note: m_mode67_error_weight_mul was always 1, removed

    uchar selectors[16];
    color_cell_compressor_results cres;
    cres.m_pSelectors = selectors;

    uint err = color_cell_compression(6, &params, &cres, pComp_params, 0, 0, pixels, true, tables);
    if (err < res.m_error)
    {
        res.m_error = err;
        res.m_mode = 6;
        res.m_rotation_index_sel = 0;
        res.m_partition = 0;
        res.m_low[0] = cres.m_low_endpoint;
        res.m_high[0] = cres.m_high_endpoint;
        res.m_pbits = cres.m_pbits;
        for (int i = 0; i < 16; ++i)
            res.m_selectors[i] = selectors[i];
    }
}

static void handle_opaque_block_mode1(
                                     thread bc7_optimization_results& res,
                                     const uchar4 pixels[16],
                                     const constant bc7e_compress_block_params* pComp_params,
                                     const constant LookupTables* tables,
                                     uint4 solution_lists)
{
    color_cell_compressor_params params;
    color_cell_compressor_params_clear(&params, pComp_params);
    params.m_weights_index = kBC7Weights3Index;
    params.m_num_selector_weights = 8;
    params.m_comp_bits = 6;
    params.m_has_pbits = true;
    params.m_endpoints_share_pbit = true;

    const bool disable_faster_part_selection = false;
    solution solutions[4];
    uint num_solutions = decode_solutions(solution_lists.y, solutions);
    for (uint32_t solution_index = 0; solution_index < num_solutions; solution_index++)
    {
        const uint32_t trial_partition = solutions[solution_index].m_index;
        assert(trial_partition < 64);

        const uint part_mask = g_bc7_partition2[trial_partition];
                    
        uchar selectors[16];
        color_cell_compressor_results sub_res[2];

        uint32_t trial_err = 0;
        for (uint32_t subset = 0; subset < 2; subset++)
        {
            thread color_cell_compressor_results* pResults = &sub_res[subset];
            pResults->m_pSelectors = selectors;

            uint32_t err = color_cell_compression(1, &params, pResults, pComp_params, part_mask, subset, pixels, (num_solutions <= 2) || disable_faster_part_selection, tables);
            assert(err == pResults->m_best_overall_err);

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
            for (uint i = 0; i < 16; ++i)
                res.m_selectors[i] = selectors[i];
            res.m_pbits = 0;
            for (uint32_t subset = 0; subset < 2; subset++)
            {
                res.m_low[subset] = sub_res[subset].m_low_endpoint;
                res.m_high[subset] = sub_res[subset].m_high_endpoint;
                res.m_pbits |= sub_res[subset].m_pbits << subset*2;
            }
        }
    }

#if !defined(OPT_MAX_PARTITION_TRIES_LESS_THAN_3_ONLY)
    if ((num_solutions > 2) && (res.m_mode == 1) && (!disable_faster_part_selection))
    {
        const uint32_t trial_partition = res.m_partition;
        assert(trial_partition < 64);

        const uint part_mask = g_bc7_partition2[trial_partition];
                    
        uchar selectors[16];
        color_cell_compressor_results sub_res[2];

        uint32_t trial_err = 0;
        for (uint32_t subset = 0; subset < 2; subset++)
        {
            thread color_cell_compressor_results* pResults = &sub_res[subset];
            pResults->m_pSelectors = selectors;

            uint32_t err = color_cell_compression(1, &params, pResults, pComp_params, part_mask, subset, pixels, true, tables);
            assert(err == pResults->m_best_overall_err);

            trial_err += err;
            if (trial_err > res.m_error)
                break;
                
        } // subset

        if (trial_err < res.m_error)
        {
            res.m_error = trial_err;
            for (uint i = 0; i < 16; ++i)
                res.m_selectors[i] = selectors[i];
            res.m_pbits = 0;
            for (uint32_t subset = 0; subset < 2; subset++)
            {
                res.m_low[subset] = sub_res[subset].m_low_endpoint;
                res.m_high[subset] = sub_res[subset].m_high_endpoint;
                res.m_pbits |= sub_res[subset].m_pbits << subset*2;
            }
        }
    }
#endif // #if !defined(OPT_MAX_PARTITION_TRIES_LESS_THAN_3_ONLY)
}

static void handle_opaque_block_mode0(
                                     thread bc7_optimization_results& res,
                                     const uchar4 pixels[16],
                                     const constant bc7e_compress_block_params* pComp_params,
                                     const constant LookupTables* tables,
                                     uint4 solution_lists)
{
    color_cell_compressor_params params;
    color_cell_compressor_params_clear(&params, pComp_params);
    params.m_weights_index = kBC7Weights3Index;
    params.m_num_selector_weights = 8;
    params.m_comp_bits = 4;
    params.m_has_pbits = true;
    params.m_endpoints_share_pbit = false;

    solution solutions[4];
    uint num_solutions = decode_solutions(solution_lists.z, solutions);
    for (uint32_t solution_index = 0; solution_index < num_solutions; solution_index++)
    {
        const uint32_t best_partition = solutions[solution_index].m_index;

        const uint part_mask = g_bc7_partition3[best_partition];

        color_cell_compressor_results sub_res[3];
        uchar selectors[16];

        uint32_t mode_err = 0;
        for (uint32_t subset = 0; subset < 3; subset++)
        {
            thread color_cell_compressor_results* pResults = &sub_res[subset];
            pResults->m_pSelectors = selectors;

            uint32_t err = color_cell_compression(0, &params, pResults, pComp_params, part_mask, subset, pixels, true, tables);
            assert(err == pResults->m_best_overall_err);

            mode_err += err;
            if (mode_err > res.m_error)
                break;
        } // subset

        if (mode_err < res.m_error)
        {
            res.m_error = mode_err;
            res.m_mode = 0;
            res.m_rotation_index_sel = 0;
            res.m_partition = best_partition;
            for (uint i = 0; i < 16; ++i)
                res.m_selectors[i] = selectors[i];
            res.m_pbits = 0;
            for (uint32_t subset = 0; subset < 3; subset++)
            {
                res.m_low[subset] = sub_res[subset].m_low_endpoint;
                res.m_high[subset] = sub_res[subset].m_high_endpoint;
                res.m_pbits |= sub_res[subset].m_pbits << subset*2;
            }
        }
    }
}

static void handle_opaque_block_mode3(
                                     thread bc7_optimization_results& res,
                                     const uchar4 pixels[16],
                                     const constant bc7e_compress_block_params* pComp_params,
                                     const constant LookupTables* tables,
                                     uint4 solution_lists)
{
    color_cell_compressor_params params;
    color_cell_compressor_params_clear(&params, pComp_params);
    params.m_weights_index = kBC7Weights2Index;
    params.m_num_selector_weights = 4;
    params.m_comp_bits = 7;
    params.m_has_pbits = true;
    params.m_endpoints_share_pbit = false;

    solution solutions[4];
    uint num_solutions = decode_solutions(solution_lists.y, solutions);
    const bool disable_faster_part_selection = false;
    for (uint32_t solution_index = 0; solution_index < num_solutions; solution_index++)
    {
        const uint32_t trial_partition = solutions[solution_index].m_index;
        assert(trial_partition < 64);

        const uint part_mask = g_bc7_partition2[trial_partition];
        uchar selectors[16];
        color_cell_compressor_results sub_res[2];

        uint32_t trial_err = 0;
        for (uint32_t subset = 0; subset < 2; subset++)
        {
            thread color_cell_compressor_results* pResults = &sub_res[subset];
            pResults->m_pSelectors = selectors;

            uint32_t err = color_cell_compression(3, &params, pResults, pComp_params, part_mask, subset, pixels, (num_solutions <= 2) || disable_faster_part_selection, tables);
            assert(err == pResults->m_best_overall_err);

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
            for (uint i = 0; i < 16; ++i)
                res.m_selectors[i] = selectors[i];
            res.m_pbits = 0;
            for (uint32_t subset = 0; subset < 2; subset++)
            {
                res.m_low[subset] = sub_res[subset].m_low_endpoint;
                res.m_high[subset] = sub_res[subset].m_high_endpoint;
                res.m_pbits |= sub_res[subset].m_pbits << subset*2;
            }
        }

    } // solution_index

#if !defined(OPT_MAX_PARTITION_TRIES_LESS_THAN_3_ONLY)
    if ((num_solutions > 2) && (res.m_mode == 3) && (!disable_faster_part_selection))
    {
        const uint32_t trial_partition = res.m_partition;
        assert(trial_partition < 64);

        const uint part_mask = g_bc7_partition2[trial_partition];

        uchar selectors[16];
        color_cell_compressor_results sub_res[2];

        uint32_t trial_err = 0;
        for (uint32_t subset = 0; subset < 2; subset++)
        {
            thread color_cell_compressor_results* pResults = &sub_res[subset];
            pResults->m_pSelectors = selectors;

            uint32_t err = color_cell_compression(3, &params, pResults, pComp_params, part_mask, subset, pixels, true, tables);
            assert(err == pResults->m_best_overall_err);

            trial_err += err;
            if (trial_err > res.m_error)
                break;
        } // subset

        if (trial_err < res.m_error)
        {
            res.m_error = trial_err;
            for (uint i = 0; i < 16; ++i)
                res.m_selectors[i] = selectors[i];
            res.m_pbits = 0;
            for (uint32_t subset = 0; subset < 2; subset++)
            {
                res.m_low[subset] = sub_res[subset].m_low_endpoint;
                res.m_high[subset] = sub_res[subset].m_high_endpoint;
                res.m_pbits |= sub_res[subset].m_pbits << subset*2;
            }
        }
    }
#endif // #if !defined(OPT_MAX_PARTITION_TRIES_LESS_THAN_3_ONLY)
}

static void handle_opaque_block_mode2(
                                     thread bc7_optimization_results& res,
                                     const uchar4 pixels[16],
                                     const constant bc7e_compress_block_params* pComp_params,
                                     const constant LookupTables* tables,
                                     uint4 solution_lists)
{
    color_cell_compressor_params params;
    color_cell_compressor_params_clear(&params, pComp_params);
    params.m_weights_index = kBC7Weights2Index;
    params.m_num_selector_weights = 4;
    params.m_comp_bits = 5;
    params.m_has_pbits = false;
    params.m_endpoints_share_pbit = false;

    solution solutions[4];
    uint num_solutions = decode_solutions(solution_lists.w, solutions);
    for (uint32_t solution_index = 0; solution_index < num_solutions; solution_index++)
    {
        const int32_t best_partition = solutions[solution_index].m_index;
                    
        const uint part_mask = g_bc7_partition3[best_partition];

        uchar selectors[16];
        color_cell_compressor_results sub_res[3];
                    
        uint32_t mode_err = 0;
        for (uint32_t subset = 0; subset < 3; subset++)
        {
            thread color_cell_compressor_results* pResults = &sub_res[subset];
            pResults->m_pSelectors = selectors;

            uint32_t err = color_cell_compression(2, &params, pResults, pComp_params, part_mask, subset, pixels, true, tables);
            assert(err == pResults->m_best_overall_err);

            mode_err += err;
            if (mode_err > res.m_error)
                break;
        } // subset

        if (mode_err < res.m_error)
        {
            res.m_error = mode_err;
            res.m_mode = 2;
            res.m_rotation_index_sel = 0;
            res.m_partition = best_partition;
            for (uint i = 0; i < 16; ++i)
                res.m_selectors[i] = selectors[i];

            for (uint32_t subset = 0; subset < 3; subset++)
            {
                res.m_low[subset] = sub_res[subset].m_low_endpoint;
                res.m_high[subset] = sub_res[subset].m_high_endpoint;
            }
        }
    }
}

struct Globals // note: should match C++ code struct
{
    uint width, height;
    uint widthInBlocks, heightInBlocks;
    bc7e_compress_block_params params;
};
static_assert(sizeof(Globals) == 144, "unexpected Globals struct size");

void load_pixel_block(uchar4 pixels[16], thread uchar& out_lo_a, thread uchar& out_hi_a, uint3 id, const device uint* bufInput, uint width)
{
    uchar lo_a = 255, hi_a = 0;
    uint base_pix = (id.y * 4) * width + id.x * 4;
    for (uint i = 0; i < 16; i++)
    {
        uint ix = i & 3;
        uint iy = i >> 2;
        uint craw = bufInput[base_pix + iy * width + ix];
        uchar r = craw & 0xFF;
        uchar g = (craw >> 8) & 0xFF;
        uchar b = (craw >> 16) & 0xFF;
        uchar a = (craw >> 24);
#if defined(DEBUG_FORCE_NO_SHADER_CACHE)
        r |= DEBUG_FORCE_NO_SHADER_CACHE;
        a |= DEBUG_FORCE_NO_SHADER_CACHE;
#endif

        pixels[i] = uchar4(r, g, b, a);

        lo_a = min(lo_a, a);
        hi_a = max(hi_a, a);
    }
    out_lo_a = lo_a;
    out_hi_a = hi_a;
}

// First pass: figures out mode partition lists
// (writes them into the output texture buffer)
// - Up to 4 partitions for mode; partition indices encoded in 6 bits each, then list size
// - x: mode 7
// - y: mode 1|3
// - z: mode 0
// - w: mode 2
kernel void bc7e_estimate_partition_lists(
    constant Globals& glob [[buffer(0)]],
    const device uint* bufInput [[buffer(1)]],
    device uint4* bufLists [[buffer(2)]],
    device bc7_optimization_results* bufTemp [[buffer(3)]],
    uint3 id [[thread_position_in_grid]])
{
    if (id.x >= glob.widthInBlocks || id.y >= glob.heightInBlocks)
        return;
    
    color_cell_compressor_params params;
    color_cell_compressor_params_clear(&params, &glob.params);
    
    uchar4 pixels[16];
    uchar lo_a, hi_a;
    load_pixel_block(pixels, lo_a, hi_a, id, bufInput, glob.width);
    const bool has_alpha = (lo_a < 255);

    uint4 lists = 0;
    
    if (has_alpha)
        lists = get_lists_alpha(pixels, &glob.params);
    else
    {
#ifdef OPT_ULTRAFAST_ONLY
        ;
#else
        if (glob.params.m_mode6_only)
            ;
        else
            lists = get_lists_opaque(pixels, &glob.params);
#endif
    }

    uint block_index = id.y * glob.widthInBlocks + id.x;
    bufTemp[block_index].m_error = UINT_MAX;
    bufLists[block_index] = lists;
}

kernel void bc7e_compress_blocks_mode4_alpha(
    constant Globals& glob [[buffer(0)]],
    const device uint* bufInput [[buffer(1)]],
    device bc7_optimization_results* bufTemp [[buffer(3)]],
    const constant LookupTables* tables [[buffer(4)]],
    uint3 id [[thread_position_in_grid]])
{
    if (id.x >= glob.widthInBlocks || id.y >= glob.heightInBlocks)
        return;
        
    uchar4 pixels[16];
    uchar lo_a, hi_a;
    load_pixel_block(pixels, lo_a, hi_a, id, bufInput, glob.width);
    const bool has_alpha = (lo_a < 255);
    if (!has_alpha)
        return;
    if (!glob.params.m_alpha_settings.m_use_mode4)
        return;

    uint block_index = id.y * glob.widthInBlocks + id.x;
    uint prev_error = bufTemp[block_index].m_error;
    bc7_optimization_results res;
    res.m_error = prev_error;

    const int num_rotations = (glob.params.m_perceptual || (!glob.params.m_alpha_settings.m_use_mode4_rotation)) ? 1 : 4;
    handle_block_mode4(res, pixels, &glob.params, lo_a, hi_a, num_rotations, tables);
    if (res.m_error < prev_error)
        bufTemp[block_index] = res;
}

kernel void bc7e_compress_blocks_mode4_opaq(
    constant Globals& glob [[buffer(0)]],
    const device uint* bufInput [[buffer(1)]],
    device bc7_optimization_results* bufTemp [[buffer(3)]],
    const constant LookupTables* tables [[buffer(4)]],
    uint3 id [[thread_position_in_grid]])
{
#if !defined(OPT_ULTRAFAST_ONLY)
    if (id.x >= glob.widthInBlocks || id.y >= glob.heightInBlocks)
        return;
        
    uchar4 pixels[16];
    uchar lo_a, hi_a;
    load_pixel_block(pixels, lo_a, hi_a, id, bufInput, glob.width);
    const bool has_alpha = (lo_a < 255);
    if (has_alpha)
        return;
    if (glob.params.m_mode6_only || glob.params.m_perceptual || !glob.params.m_opaque_settings.m_use_mode[4])
        return;

    uint block_index = id.y * glob.widthInBlocks + id.x;
    uint prev_error = bufTemp[block_index].m_error;
    bc7_optimization_results res;
    res.m_error = prev_error;
    handle_block_mode4(res, pixels, &glob.params, 255, 255, 4, tables);
    if (res.m_error < prev_error)
        bufTemp[block_index] = res;
#endif // #if !defined(OPT_ULTRAFAST_ONLY)
}

kernel void bc7e_compress_blocks_mode6(
    constant Globals& glob [[buffer(0)]],
    const device uint* bufInput [[buffer(1)]],
    device bc7_optimization_results* bufTemp [[buffer(3)]],
    const constant LookupTables* tables [[buffer(4)]],
    uint3 id [[thread_position_in_grid]])
{
    if (id.x >= glob.widthInBlocks || id.y >= glob.heightInBlocks)
        return;

    uchar4 pixels[16];
    uchar lo_a, hi_a;
    load_pixel_block(pixels, lo_a, hi_a, id, bufInput, glob.width);
    const bool has_alpha = (lo_a < 255);
    if (has_alpha && !glob.params.m_alpha_settings.m_use_mode6)
        return;
    if (!has_alpha && !glob.params.m_opaque_settings.m_use_mode[6])
        return;

    uint block_index = id.y * glob.widthInBlocks + id.x;
    uint prev_error = bufTemp[block_index].m_error;
    bc7_optimization_results res;
    res.m_error = prev_error;

    handle_block_mode6(res, pixels, &glob.params, tables, has_alpha);
    if (res.m_error < prev_error)
        bufTemp[block_index] = res;
}

kernel void bc7e_compress_blocks_mode5(
    constant Globals& glob [[buffer(0)]],
    const device uint* bufInput [[buffer(1)]],
    device bc7_optimization_results* bufTemp [[buffer(3)]],
    const constant LookupTables* tables [[buffer(4)]],
    uint3 id [[thread_position_in_grid]])
{
    if (id.x >= glob.widthInBlocks || id.y >= glob.heightInBlocks)
        return;

    uchar4 pixels[16];
    uchar lo_a, hi_a;
    load_pixel_block(pixels, lo_a, hi_a, id, bufInput, glob.width);
    const bool has_alpha = (lo_a < 255);
    
    uint block_index = id.y * glob.widthInBlocks + id.x;
    uint prev_error = bufTemp[block_index].m_error;
    bc7_optimization_results res;
    res.m_error = prev_error;

    uint num_rotations = 4;
    if (has_alpha)
    {
        if (!glob.params.m_alpha_settings.m_use_mode5)
            return;
        if (glob.params.m_perceptual || !glob.params.m_alpha_settings.m_use_mode5_rotation)
            num_rotations = 1;
    }
    else
    {
        if (glob.params.m_perceptual || !glob.params.m_opaque_settings.m_use_mode[5] || glob.params.m_mode6_only)
            return;
    }
    handle_block_mode5(res, pixels, &glob.params, lo_a, hi_a, num_rotations, tables);
    if (res.m_error < prev_error)
        bufTemp[block_index] = res;
}

kernel void bc7e_compress_blocks_mode2(
    constant Globals& glob [[buffer(0)]],
    const device uint* bufInput [[buffer(1)]],
    const device uint4* bufLists [[buffer(2)]],
    device bc7_optimization_results* bufTemp [[buffer(3)]],
    const constant LookupTables* tables [[buffer(4)]],
    uint3 id [[thread_position_in_grid]])
{
#if !defined(OPT_ULTRAFAST_ONLY)
    if (id.x >= glob.widthInBlocks || id.y >= glob.heightInBlocks)
        return;

    uchar4 pixels[16];
    uchar lo_a, hi_a;
    load_pixel_block(pixels, lo_a, hi_a, id, bufInput, glob.width);
    const bool has_alpha = (lo_a < 255);
    if (has_alpha)
        return;
    if (!glob.params.m_opaque_settings.m_use_mode[2] || glob.params.m_mode6_only)
        return;

    uint block_index = id.y * glob.widthInBlocks + id.x;
    uint prev_error = bufTemp[block_index].m_error;
    bc7_optimization_results res;
    res.m_error = prev_error;

    uint4 lists = bufLists[block_index];
    handle_opaque_block_mode2(res, pixels, &glob.params, tables, lists);
    if (res.m_error < prev_error)
        bufTemp[block_index] = res;
#endif // #if !defined(OPT_ULTRAFAST_ONLY)
}

kernel void bc7e_compress_blocks_mode1(
    constant Globals& glob [[buffer(0)]],
    const device uint* bufInput [[buffer(1)]],
    const device uint4* bufLists [[buffer(2)]],
    device bc7_optimization_results* bufTemp [[buffer(3)]],
    const constant LookupTables* tables [[buffer(4)]],
    uint3 id [[thread_position_in_grid]])
{
#if !defined(OPT_ULTRAFAST_ONLY)
    if (id.x >= glob.widthInBlocks || id.y >= glob.heightInBlocks)
        return;

    uchar4 pixels[16];
    uchar lo_a, hi_a;
    load_pixel_block(pixels, lo_a, hi_a, id, bufInput, glob.width);
    const bool has_alpha = (lo_a < 255);
    if (has_alpha)
        return;
    if (!glob.params.m_opaque_settings.m_use_mode[1] || glob.params.m_mode6_only)
        return;

    uint block_index = id.y * glob.widthInBlocks + id.x;
    uint prev_error = bufTemp[block_index].m_error;
    bc7_optimization_results res;
    res.m_error = prev_error;

    uint4 lists = bufLists[block_index];
    handle_opaque_block_mode1(res, pixels, &glob.params, tables, lists);
    if (res.m_error < prev_error)
        bufTemp[block_index] = res;
#endif // #if !defined(OPT_ULTRAFAST_ONLY)
}

kernel void bc7e_compress_blocks_mode0(
    constant Globals& glob [[buffer(0)]],
    const device uint* bufInput [[buffer(1)]],
    const device uint4* bufLists [[buffer(2)]],
    device bc7_optimization_results* bufTemp [[buffer(3)]],
    const constant LookupTables* tables [[buffer(4)]],
    uint3 id [[thread_position_in_grid]])
{
#if !defined(OPT_ULTRAFAST_ONLY)
    if (id.x >= glob.widthInBlocks || id.y >= glob.heightInBlocks)
        return;

    uchar4 pixels[16];
    uchar lo_a, hi_a;
    load_pixel_block(pixels, lo_a, hi_a, id, bufInput, glob.width);
    const bool has_alpha = (lo_a < 255);
    if (has_alpha)
        return;
    if (!glob.params.m_opaque_settings.m_use_mode[0] || glob.params.m_mode6_only)
        return;

    uint block_index = id.y * glob.widthInBlocks + id.x;
    uint prev_error = bufTemp[block_index].m_error;
    bc7_optimization_results res;
    res.m_error = prev_error;

    uint4 lists = bufLists[block_index];
    handle_opaque_block_mode0(res, pixels, &glob.params, tables, lists);
    if (res.m_error < prev_error)
        bufTemp[block_index] = res;
#endif // #if !defined(OPT_ULTRAFAST_ONLY)
}

kernel void bc7e_compress_blocks_mode3(
    constant Globals& glob [[buffer(0)]],
    const device uint* bufInput [[buffer(1)]],
    const device uint4* bufLists [[buffer(2)]],
    device bc7_optimization_results* bufTemp [[buffer(3)]],
    const constant LookupTables* tables [[buffer(4)]],
    uint3 id [[thread_position_in_grid]])
{
#if !defined(OPT_ULTRAFAST_ONLY)
    if (id.x >= glob.widthInBlocks || id.y >= glob.heightInBlocks)
        return;

    uchar4 pixels[16];
    uchar lo_a, hi_a;
    load_pixel_block(pixels, lo_a, hi_a, id, bufInput, glob.width);
    const bool has_alpha = (lo_a < 255);
    if (has_alpha)
        return;
    if (!glob.params.m_opaque_settings.m_use_mode[3] || glob.params.m_mode6_only)
        return;

    uint block_index = id.y * glob.widthInBlocks + id.x;
    uint prev_error = bufTemp[block_index].m_error;
    bc7_optimization_results res;
    res.m_error = prev_error;

    uint4 lists = bufLists[block_index];
    handle_opaque_block_mode3(res, pixels, &glob.params, tables, lists);
    if (res.m_error < prev_error)
        bufTemp[block_index] = res;
#endif // #if !defined(OPT_ULTRAFAST_ONLY)
}

kernel void bc7e_compress_blocks_mode7(
    constant Globals& glob [[buffer(0)]],
    const device uint* bufInput [[buffer(1)]],
    const device uint4* bufLists [[buffer(2)]],
    device bc7_optimization_results* bufTemp [[buffer(3)]],
    const constant LookupTables* tables [[buffer(4)]],
    uint3 id [[thread_position_in_grid]])
{
#if !defined(OPT_ULTRAFAST_ONLY)
    if (id.x >= glob.widthInBlocks || id.y >= glob.heightInBlocks)
        return;

    uchar4 pixels[16];
    uchar lo_a, hi_a;
    load_pixel_block(pixels, lo_a, hi_a, id, bufInput, glob.width);
    const bool has_alpha = (lo_a < 255);
    if (!has_alpha)
        return;
    if (!glob.params.m_alpha_settings.m_use_mode7)
        return;

    uint block_index = id.y * glob.widthInBlocks + id.x;
    uint prev_error = bufTemp[block_index].m_error;
    bc7_optimization_results res;
    res.m_error = prev_error;

    uint4 lists = bufLists[block_index];
    handle_alpha_block_mode7(res, pixels, &glob.params, tables, lists);
    if (res.m_error < prev_error)
        bufTemp[block_index] = res;
#endif // #if !defined(OPT_ULTRAFAST_ONLY)
}

kernel void bc7e_encode_blocks(
    constant Globals& glob [[buffer(0)]],
    device uint4* bufOutput [[buffer(2)]],
    const device bc7_optimization_results* bufTemp [[buffer(3)]],
    uint3 id [[thread_position_in_grid]])
{
    if (id.x >= glob.widthInBlocks || id.y >= glob.heightInBlocks)
        return;
    uint block_index = id.y * glob.widthInBlocks + id.x;
    bc7_optimization_results res = bufTemp[block_index];
    bufOutput[block_index] = encode_bc7_block(&res);
}
