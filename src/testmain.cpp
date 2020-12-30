#include "../external/bc7e/bc7e_ispc.h"
#include "../external/bc7enc/bc7decomp.h"
#include "../external/ic_pfor.h"
#include "../external/sokol_time.h"
#include "../external/smolcompute.h"
#include "../external/stb_image.h"
#include "../external/stb_image_write.h"
#include <assert.h>
#include <stdio.h>
#include <string.h>
#include <string>
#include <vector>
#ifdef _MSC_VER
#include <direct.h>
#else
#include <sys/stat.h>
#endif

const bool kDoCapture = false;
const int kQuality = 3;
const int kRunCount = kDoCapture ? 1 : 8;
const bool kRequireExactResultsMatch = true;
const float kAllowedPsnrDiff = 80;


static const char* kTestFileNames[] =
{
	"textures/20x20.png",
    "textures/2dSignsCrop.png",
    "textures/AoCrop-gray.png",
    "textures/DecalRust.png",
    "textures/EllenBodyCrop_MADS.png",
    "textures/frymire_1024.png",
    "textures/Gradients.png",
    "textures/Gradients2.png",
    "textures/GrassWindCrop.png",
    "textures/normal-b-crop-nm.png",
    "textures/RgbColCrop.png",
    "textures/train-nm.png",
};

typedef std::vector<unsigned char> ByteVector;

struct TestFile
{
    std::string filePath;
    std::string fileNameBase;
    int width = 0;
    int height = 0;
    int widthInBlocks = 0;
    int heightInBlocks = 0;
    int channels = 0;
    ByteVector rgba;
    ByteVector bc7exp;
    ByteVector bc7got;
    float timeRef = 1.0e20f;
    float timeGot = 1.0e20f;
    bool errors = false;
};

struct Globals // note: should match shader code struct
{
    int width, height;
    int widthInBlocks, heightInBlocks;
    ispc::bc7e_compress_block_params params;
};

struct endpoint_err // note: should match shader code struct
{
    uint16_t m_error;
    uint8_t m_lo;
    uint8_t m_hi;
};

struct LookupTables // note: should match shader code struct
{
    // optimal endpoint tables
    endpoint_err mode_1[256][2]; // [c][pbit]
    endpoint_err mode_7[256][2][2]; // [c][pbit][hp][lp]
    endpoint_err mode_6[256][2][2]; // [c][hp][lp]
    uint32_t mode_4_3[256]; // [c]
    uint32_t mode_4_2[256]; // [c]
    endpoint_err mode_0[256][2][2]; // [c][hp][lp]
    
    // what was g_bc7_weights2, g_bc7_weights3, g_bc7_weights4 in ISPC
    uint32_t g_bc7_weights[4+8+16] =
    {
        0, 21, 43, 64,
        0, 9, 18, 27, 37, 46, 55, 64,
        0, 4, 9, 13, 17, 21, 26, 30, 34, 38, 43, 47, 51, 55, 60, 64,
    };
    // what was g_bc7_weights2x, g_bc7_weights3x, g_bc7_weights4x in ISPC
    float g_bc7_weightsx[(4+8+16)*4] =
    {
        // 2x
        0.000000f, 0.000000f, 1.000000f, 0.000000f, 0.107666f, 0.220459f, 0.451416f, 0.328125f, 0.451416f, 0.220459f, 0.107666f, 0.671875f, 1.000000f, 0.000000f, 0.000000f, 1.000000f,
        // 3x
        0.000000f, 0.000000f, 1.000000f, 0.000000f, 0.019775f, 0.120850f, 0.738525f, 0.140625f, 0.079102f, 0.202148f, 0.516602f, 0.281250f, 0.177979f, 0.243896f, 0.334229f, 0.421875f, 0.334229f, 0.243896f, 0.177979f, 0.578125f, 0.516602f, 0.202148f,
        0.079102f, 0.718750f, 0.738525f, 0.120850f, 0.019775f, 0.859375f, 1.000000f, 0.000000f, 0.000000f, 1.000000f,
        // 4x
        0.000000f, 0.000000f, 1.000000f, 0.000000f, 0.003906f, 0.058594f, 0.878906f, 0.062500f, 0.019775f, 0.120850f, 0.738525f, 0.140625f, 0.041260f, 0.161865f, 0.635010f, 0.203125f, 0.070557f, 0.195068f, 0.539307f, 0.265625f, 0.107666f, 0.220459f,
        0.451416f, 0.328125f, 0.165039f, 0.241211f, 0.352539f, 0.406250f, 0.219727f, 0.249023f, 0.282227f, 0.468750f, 0.282227f, 0.249023f, 0.219727f, 0.531250f, 0.352539f, 0.241211f, 0.165039f, 0.593750f, 0.451416f, 0.220459f, 0.107666f, 0.671875f, 0.539307f, 0.195068f, 0.070557f, 0.734375f,
        0.635010f, 0.161865f, 0.041260f, 0.796875f, 0.738525f, 0.120850f, 0.019775f, 0.859375f, 0.878906f, 0.058594f, 0.003906f, 0.937500f, 1.000000f, 0.000000f, 0.000000f, 1.000000f
    };
};

static LookupTables s_Tables;

// initialization code ported from bc7e.ispc
static const uint32_t g_bc7_weights2[4] = { 0, 21, 43, 64 };
static const uint32_t g_bc7_weights3[8] = { 0, 9, 18, 27, 37, 46, 55, 64 };
static const uint32_t g_bc7_weights4[16] = { 0, 4, 9, 13, 17, 21, 26, 30, 34, 38, 43, 47, 51, 55, 60, 64 };
static const uint32_t BC7E_MODE_1_OPTIMAL_INDEX = 2;
static const uint32_t BC7E_MODE_7_OPTIMAL_INDEX = 1;
static const uint32_t BC7E_MODE_6_OPTIMAL_INDEX = 5;
static const uint32_t BC7E_MODE_4_OPTIMAL_INDEX3 = 2;
static const uint32_t BC7E_MODE_4_OPTIMAL_INDEX2 = 1;
static const uint32_t BC7E_MODE_0_OPTIMAL_INDEX = 2;


static void gpu_bc7e_compress_block_init()
{
    // Mode 0: 444.1
    for (int c = 0; c < 256; c++)
    {
        for (uint32_t hp = 0; hp < 2; hp++)
        {
            for (uint32_t lp = 0; lp < 2; lp++)
            {
                endpoint_err best;
                best.m_error = (uint16_t)UINT16_MAX;

                for (uint32_t l = 0; l < 16; l++)
                {
                    uint32_t low = ((l << 1) | lp) << 3;
                    low |= (low >> 5);

                    for (uint32_t h = 0; h < 16; h++)
                    {
                        uint32_t high = ((h << 1) | hp) << 3;
                        high |= (high >> 5);

                        const int k = (low * (64 - g_bc7_weights3[BC7E_MODE_0_OPTIMAL_INDEX]) + high * g_bc7_weights3[BC7E_MODE_0_OPTIMAL_INDEX] + 32) >> 6;

                        const int err = (k - c) * (k - c);
                        if (err < best.m_error)
                        {
                            best.m_error = (uint16_t)err;
                            best.m_lo = (uint8_t)l;
                            best.m_hi = (uint8_t)h;
                        }
                    } // h
                } // l

                s_Tables.mode_0[c][hp][lp] = best;
            } // lp
        } // hp
    } // c

    // Mode 1: 666.1
    for (int c = 0; c < 256; c++)
    {
        for (uint32_t lp = 0; lp < 2; lp++)
        {
            endpoint_err best;
            best.m_error = (uint16_t)UINT16_MAX;

            for (uint32_t l = 0; l < 64; l++)
            {
                uint32_t low = ((l << 1) | lp) << 1;
                low |= (low >> 7);

                for (uint32_t h = 0; h < 64; h++)
                {
                    uint32_t high = ((h << 1) | lp) << 1;
                    high |= (high >> 7);

                    const int k = (low * (64 - g_bc7_weights3[BC7E_MODE_1_OPTIMAL_INDEX]) + high * g_bc7_weights3[BC7E_MODE_1_OPTIMAL_INDEX] + 32) >> 6;

                    const int err = (k - c) * (k - c);
                    if (err < best.m_error)
                    {
                        best.m_error = (uint16_t)err;
                        best.m_lo = (uint8_t)l;
                        best.m_hi = (uint8_t)h;
                    }
                } // h
            } // l

            s_Tables.mode_1[c][lp] = best;
        } // lp
    } // c

    // Mode 6: 777.1 4-bit indices
    for (int c = 0; c < 256; c++)
    {
        for (uint32_t hp = 0; hp < 2; hp++)
        {
            for (uint32_t lp = 0; lp < 2; lp++)
            {
                endpoint_err best;
                best.m_error = (uint16_t)UINT16_MAX;

                for (uint32_t l = 0; l < 128; l++)
                {
                    uint32_t low = (l << 1) | lp;
                
                    for (uint32_t h = 0; h < 128; h++)
                    {
                        uint32_t high = (h << 1) | hp;
                    
                        const int k = (low * (64 - g_bc7_weights4[BC7E_MODE_6_OPTIMAL_INDEX]) + high * g_bc7_weights4[BC7E_MODE_6_OPTIMAL_INDEX] + 32) >> 6;

                        const int err = (k - c) * (k - c);
                        if (err < best.m_error)
                        {
                            best.m_error = (uint16_t)err;
                            best.m_lo = (uint8_t)l;
                            best.m_hi = (uint8_t)h;
                        }
                    } // h
                } // l

                s_Tables.mode_6[c][hp][lp] = best;
            } // lp
        } // hp
    } // c

    //Mode 4: 555 3-bit indices
    for (int c = 0; c < 256; c++)
    {
        endpoint_err best;
        best.m_error = (uint16_t)UINT16_MAX;
        best.m_lo = 0;
        best.m_hi = 0;

        for (uint32_t l = 0; l < 32; l++)
        {
            uint32_t low = l << 3;
            low |= (low >> 5);

            for (uint32_t h = 0; h < 32; h++)
            {
                uint32_t high = h << 3;
                high |= (high >> 5);

                const int k = (low * (64 - g_bc7_weights3[BC7E_MODE_4_OPTIMAL_INDEX3]) + high * g_bc7_weights3[BC7E_MODE_4_OPTIMAL_INDEX3] + 32) >> 6;

                const int err = (k - c) * (k - c);
                if (err < best.m_error)
                {
                    best.m_error = (uint16_t)err;
                    best.m_lo = (uint8_t)l;
                    best.m_hi = (uint8_t)h;
                }
            } // h
        } // l

        s_Tables.mode_4_3[c] = (uint32_t)best.m_lo | (((uint32_t)best.m_hi) << 8);
    } // c
    
    // Mode 4: 555 2-bit indices
    for (int c = 0; c < 256; c++)
    {
        endpoint_err best;
        best.m_error = (uint16_t)UINT16_MAX;
        best.m_lo = 0;
        best.m_hi = 0;

        for (uint32_t l = 0; l < 32; l++)
        {
            uint32_t low = l << 3;
            low |= (low >> 5);

            for (uint32_t h = 0; h < 32; h++)
            {
                uint32_t high = h << 3;
                high |= (high >> 5);

                const int k = (low * (64 - g_bc7_weights2[BC7E_MODE_4_OPTIMAL_INDEX2]) + high * g_bc7_weights2[BC7E_MODE_4_OPTIMAL_INDEX2] + 32) >> 6;

                const int err = (k - c) * (k - c);
                if (err < best.m_error)
                {
                    best.m_error = (uint16_t)err;
                    best.m_lo = (uint8_t)l;
                    best.m_hi = (uint8_t)h;
                }
            } // h
        } // l

        s_Tables.mode_4_2[c] = (uint32_t)best.m_lo | (((uint32_t)best.m_hi) << 8);
    } // c

    // Mode 7: 555.1 2-bit indices
    for (int c = 0; c < 256; c++)
    {
        endpoint_err best;
        best.m_error = (uint16_t)UINT16_MAX;
        best.m_lo = 0;
        best.m_hi = 0;

        for (uint32_t hp = 0; hp < 2; hp++)
        {
            for (uint32_t lp = 0; lp < 2; lp++)
            {
                for (uint32_t l = 0; l < 32; l++)
                {
                    uint32_t low = ((l << 1) | lp) << 2;
                    low |= (low >> 6);

                    for (uint32_t h = 0; h < 32; h++)
                    {
                        uint32_t high = ((h << 1) | hp) << 2;
                        high |= (high >> 6);

                        const int k = (low * (64 - g_bc7_weights2[BC7E_MODE_7_OPTIMAL_INDEX]) + high * g_bc7_weights2[BC7E_MODE_7_OPTIMAL_INDEX] + 32) >> 6;

                        const int err = (k - c) * (k - c);
                        if (err < best.m_error)
                        {
                            best.m_error = (uint16_t)err;
                            best.m_lo = (uint8_t)l;
                            best.m_hi = (uint8_t)h;
                        }
                    } // h
                } // l

                s_Tables.mode_7[c][hp][lp] = best;
            
            } // hp
        } // lp
    } // c
}


static void create_folder(const char* path)
{
#ifdef _MSC_VER
    _mkdir(path);
#else
    mkdir(path, S_IRWXU|S_IRWXG|S_IROTH|S_IXOTH);
#endif
}


static void Initialize()
{
    stm_setup();
    ispc::bc7e_compress_block_init();
    gpu_bc7e_compress_block_init();
    ic::init_pfor();
    if (!SmolComputeCreate(SmolComputeCreateFlags::EnableCapture/* | SmolComputeCreateFlags::EnableDebugLayers | SmolComputeCreateFlags::UseSoftwareRenderer*/))
    {
        printf("Failed to initialize smol-compute\n");
    }
    create_folder("artifacts");
}


static void fetch_block(unsigned char block[16 * 4], int x, int y, int width, int height, const unsigned char* rgba)
{
    int xleft = 4;
    if (x + 3 >= width)
        xleft = width - x;
    int yleft;
    for (yleft = 0; yleft < 4; ++yleft)
    {
        if (y + yleft >= height)
            break;
        memcpy(block + yleft * 16, rgba + width * 4 * (y + yleft) + x * 4, xleft * 4);
    }
    if (xleft < 4)
    {
        switch (xleft)
        {
            case 0: assert(false);
            case 1:
                for (int yy = 0; yy < yleft; ++yy)
                {
                    memcpy(block + yy * 16 + 1 * 4, block + yy * 16 + 0 * 4, 4);
                    memcpy(block + yy * 16 + 2 * 4, block + yy * 16 + 0 * 4, 8);
                }
                break;
            case 2:
                for (int yy = 0; yy < yleft; ++yy)
                    memcpy(block + yy * 16 + 2 * 4, block + yy * 16 + 0 * 4, 8);
                break;
            case 3:
                for (int yy = 0; yy < yleft; ++yy)
                    memcpy(block + yy * 16 + 3 * 4, block + yy * 16 + 1 * 4, 4);
                break;
        }
    }
    int yy = 0;
    for (; yleft < 4; ++yleft, ++yy)
        memcpy(block + yleft * 16, block + yy * 16, 4 * 4);
}

static void store_block_4x4(unsigned char block[16 * 4], int x, int y, int width, int height, unsigned char* rgba)
{
    int storeX = (x + 4 > width) ? width - x : 4;
    int storeY = (y + 4 > height) ? height - y : 4;
    for (int row = 0; row < storeY; ++row)
    {
        unsigned char* dst = rgba + (y + row) * width * 4 + x * 4;
        memcpy(dst, block + row * 4 * 4, storeX * 4);
    }
}

static void decompress_bc7(int width, int height, const unsigned char* input, unsigned char* rgba)
{
    int blocksX = (width + 3) / 4;
    int blocksY = (height + 3) / 4;
    for (int by = 0; by < blocksY; ++by)
    {
        for (int bx = 0; bx < blocksX; ++bx)
        {
            unsigned char block[16 * 4];
            bc7decomp::unpack_bc7(input, (bc7decomp::color_rgba*)block);
            store_block_4x4(block, bx * 4, by * 4, width, height, rgba);
            input += 16;
        }
    }
}


static void* ReadFile(const char* path, size_t* outSize)
{
    *outSize = 0;
    FILE* f = fopen(path, "rb");
    if (f == nullptr)
        return nullptr;
    fseek(f, 0, SEEK_END);
    *outSize = ftell(f);
    fseek(f, 0, SEEK_SET);
    void* buffer = malloc(*outSize);
    if (buffer == nullptr)
        return nullptr;
    fread(buffer, *outSize, 1, f);
    fclose(f);
    return buffer;
}

static SmolKernel* s_Bc7KernelLists;
static SmolKernel* s_Bc7KernelCompress0;
static SmolKernel* s_Bc7KernelCompress1;
static SmolKernel* s_Bc7KernelCompress2;
static SmolKernel* s_Bc7KernelCompress3;
static SmolKernel* s_Bc7KernelCompress4a;
static SmolKernel* s_Bc7KernelCompress4o;
static SmolKernel* s_Bc7KernelCompress5;
static SmolKernel* s_Bc7KernelCompress6;
static SmolKernel* s_Bc7KernelCompress7;
static SmolKernel* s_Bc7KernelEncode;
static SmolBuffer* s_Bc7TablesBuffer;
static SmolBuffer* s_Bc7GlobBuffer;
static SmolBuffer* s_Bc7InputBuffer;
static SmolBuffer* s_Bc7TempBuffer;
static SmolBuffer* s_Bc7OutputBuffer;
static uint8_t* s_Bc7DecompressExpected;
static uint8_t* s_Bc7DecompressGot;

#ifdef _MSC_VER
typedef unsigned char BYTE;
#include "../build/bc7e_encode.h"
#include "../build/bc7e_lists.h"
static bool InitializeCompressorShaders()
{
    //s_Bc7KernelLists = SmolKernelCreate(g_Bc7BytecodeLists, sizeof(g_Bc7BytecodeLists));
    s_Bc7KernelLists = SmolKernelCreate(g_Bc7BytecodeLists, sizeof(g_Bc7BytecodeLists), "bc7e_estimate_partition_lists");
	if (s_Bc7KernelLists == nullptr)
	{
		printf("ERROR: failed to create lists compute shader\n");
		return false;
	}
	//s_Bc7KernelEncode = SmolKernelCreate(g_Bc7BytecodeEncode, sizeof(g_Bc7BytecodeEncode));
    s_Bc7KernelEncode = SmolKernelCreate(g_Bc7BytecodeEncode, sizeof(g_Bc7BytecodeEncode), "bc7e_compress_blocks");
	if (s_Bc7KernelEncode == nullptr)
	{
		printf("ERROR: failed to create encode compute shader\n");
		return false;
	}
    return true;
}
#else
static bool InitializeCompressorShaders()
{
	size_t kernelSourceSize = 0;
	void* kernelSource = ReadFile("src/shaders/metal/bc7e.metal", &kernelSourceSize);
	if (kernelSource == nullptr)
	{
		printf("ERROR: could not read compute shader source file\n");
		return false;
	}
	SmolKernelCreateFlags flags = SmolKernelCreateFlags::GenerateDebugInfo;
	{
        uint64_t tComp0 = stm_now();
		s_Bc7KernelLists = SmolKernelCreate(kernelSource, kernelSourceSize, "bc7e_estimate_partition_lists", flags);
		if (s_Bc7KernelLists == nullptr)
		{
			printf("ERROR: failed to create lists compute shader\n");
			return false;
		}
        printf(" (lists %.1fs)", stm_sec(stm_since(tComp0)));
	}
    {
        uint64_t tComp0 = stm_now();
        s_Bc7KernelCompress0 = SmolKernelCreate(kernelSource, kernelSourceSize, "bc7e_compress_blocks_mode0", flags);
        if (s_Bc7KernelCompress0 == nullptr)
        {
            printf("ERROR: failed to create mode0 compute shader\n");
            return false;
        }
        printf(" (0 %.1fs)", stm_sec(stm_since(tComp0)));
    }
    {
        uint64_t tComp0 = stm_now();
        s_Bc7KernelCompress1 = SmolKernelCreate(kernelSource, kernelSourceSize, "bc7e_compress_blocks_mode1", flags);
        if (s_Bc7KernelCompress1 == nullptr)
        {
            printf("ERROR: failed to create mode1 compute shader\n");
            return false;
        }
        printf(" (1 %.1fs)", stm_sec(stm_since(tComp0)));
    }
    {
        uint64_t tComp0 = stm_now();
        s_Bc7KernelCompress2 = SmolKernelCreate(kernelSource, kernelSourceSize, "bc7e_compress_blocks_mode2", flags);
        if (s_Bc7KernelCompress2 == nullptr)
        {
            printf("ERROR: failed to create mode2 compute shader\n");
            return false;
        }
        printf(" (2 %.1fs)", stm_sec(stm_since(tComp0)));
    }
    {
        uint64_t tComp0 = stm_now();
        s_Bc7KernelCompress3 = SmolKernelCreate(kernelSource, kernelSourceSize, "bc7e_compress_blocks_mode3", flags);
        if (s_Bc7KernelCompress3 == nullptr)
        {
            printf("ERROR: failed to create mode3 compute shader\n");
            return false;
        }
        printf(" (3 %.1fs)", stm_sec(stm_since(tComp0)));
    }
    {
        uint64_t tComp0 = stm_now();
        s_Bc7KernelCompress4a = SmolKernelCreate(kernelSource, kernelSourceSize, "bc7e_compress_blocks_mode4_alpha", flags);
        if (s_Bc7KernelCompress4a == nullptr)
        {
            printf("ERROR: failed to create mode4a compute shader\n");
            return false;
        }
        printf(" (4a %.1fs)", stm_sec(stm_since(tComp0)));
    }
    {
        uint64_t tComp0 = stm_now();
        s_Bc7KernelCompress4o = SmolKernelCreate(kernelSource, kernelSourceSize, "bc7e_compress_blocks_mode4_opaq", flags);
        if (s_Bc7KernelCompress4o == nullptr)
        {
            printf("ERROR: failed to create mode4o compute shader\n");
            return false;
        }
        printf(" (4o %.1fs)", stm_sec(stm_since(tComp0)));
    }
    {
        uint64_t tComp0 = stm_now();
        s_Bc7KernelCompress5 = SmolKernelCreate(kernelSource, kernelSourceSize, "bc7e_compress_blocks_mode5", flags);
        if (s_Bc7KernelCompress5 == nullptr)
        {
            printf("ERROR: failed to create mode5 compute shader\n");
            return false;
        }
        printf(" (5 %.1fs)", stm_sec(stm_since(tComp0)));
    }
    {
        uint64_t tComp0 = stm_now();
        s_Bc7KernelCompress6 = SmolKernelCreate(kernelSource, kernelSourceSize, "bc7e_compress_blocks_mode6", flags);
        if (s_Bc7KernelCompress6 == nullptr)
        {
            printf("ERROR: failed to create mode6 compute shader\n");
            return false;
        }
        printf(" (6 %.1fs)", stm_sec(stm_since(tComp0)));
    }
    {
        uint64_t tComp0 = stm_now();
        s_Bc7KernelCompress7 = SmolKernelCreate(kernelSource, kernelSourceSize, "bc7e_compress_blocks_mode7", flags);
        if (s_Bc7KernelCompress7 == nullptr)
        {
            printf("ERROR: failed to create mode7 compute shader\n");
            return false;
        }
        printf(" (7 %.1fs)", stm_sec(stm_since(tComp0)));
    }
	{
        uint64_t tComp0 = stm_now();
		s_Bc7KernelEncode = SmolKernelCreate(kernelSource, kernelSourceSize, "bc7e_encode_blocks", flags);
		if (s_Bc7KernelEncode == nullptr)
		{
			printf("ERROR: failed to create encode compute shader\n");
			return false;
		}
        printf(" (encode %.1fs)", stm_sec(stm_since(tComp0)));
	}
	free(kernelSource);
    return true;
}
#endif

static bool InitializeCompressorResources(size_t maxRgbaSize, size_t maxBc7Size)
{
    printf("Initialize shaders...\n");
    uint64_t tComp0 = stm_now();
    if (!InitializeCompressorShaders())
        return false;
    printf("  shaders created in %.1fs\n", stm_sec(stm_since(tComp0)));


	printf("Initialize buffers...\n");
    s_Bc7TablesBuffer = SmolBufferCreate(sizeof(s_Tables), SmolBufferType::Structured, 4);
    s_Bc7GlobBuffer = SmolBufferCreate(sizeof(Globals), SmolBufferType::Constant);
    s_Bc7InputBuffer = SmolBufferCreate(maxRgbaSize, SmolBufferType::Structured, 4);
    s_Bc7TempBuffer = SmolBufferCreate(maxBc7Size / 16 * 64, SmolBufferType::Structured, 64); // 64 bytes per block
    s_Bc7OutputBuffer = SmolBufferCreate(maxBc7Size, SmolBufferType::Structured, 16);
    SmolBufferSetData(s_Bc7TablesBuffer, &s_Tables, sizeof(s_Tables));

	s_Bc7DecompressExpected = new uint8_t[maxRgbaSize];
    s_Bc7DecompressGot = new uint8_t[maxRgbaSize];

    return true;
}

static void CleanupCompressorResources()
{
	SmolKernelDelete(s_Bc7KernelLists);
    SmolKernelDelete(s_Bc7KernelCompress0);
    SmolKernelDelete(s_Bc7KernelCompress1);
    SmolKernelDelete(s_Bc7KernelCompress2);
    SmolKernelDelete(s_Bc7KernelCompress3);
    SmolKernelDelete(s_Bc7KernelCompress4a);
    SmolKernelDelete(s_Bc7KernelCompress4o);
    SmolKernelDelete(s_Bc7KernelCompress5);
    SmolKernelDelete(s_Bc7KernelCompress6);
    SmolKernelDelete(s_Bc7KernelCompress7);
    SmolKernelDelete(s_Bc7KernelEncode);
    SmolBufferDelete(s_Bc7TablesBuffer);
	SmolBufferDelete(s_Bc7GlobBuffer);
	SmolBufferDelete(s_Bc7InputBuffer);
    SmolBufferDelete(s_Bc7TempBuffer);
	SmolBufferDelete(s_Bc7OutputBuffer);
}

inline int get_luma(const unsigned char* rgba)
{
	return (13938u * rgba[0] + 46869u * rgba[1] + 4729u * rgba[2] + 32768u) >> 16u;
}

static float eval_psnr(int width, int height, int channels, const unsigned char* rgbaOrig, const unsigned char* rgbaDecoded)
{
	double squareErr = 0;
	for (int i = 0; i < width * height * 4; i += 4)
	{
		int lumaDif = get_luma(rgbaOrig + i) - get_luma(rgbaDecoded + i);
		squareErr += lumaDif * lumaDif;
		if (channels == 4)
		{
			int dif = (int)rgbaOrig[i + 3] - (int)rgbaDecoded[i + 3];
			squareErr += dif * dif;
		}
	}
	double mse = squareErr / (width * height * (channels == 4 ? 2 : 1));
	double rmse = sqrt(mse);
	double psnr = log10(255 / rmse) * 20;
	if (psnr < 0) psnr = 0;
	if (psnr > 300) psnr = 300;
	return (float)psnr;
}


static bool TestOnFile(TestFile& tf)
{
    printf("  testing %s\n", tf.fileNameBase.c_str());
    const int kBC7BlockBytes = 16;
    const size_t compressedSize = tf.bc7exp.size();
    const size_t rawSize = tf.rgba.size();
    memset(tf.bc7exp.data(), 0x77, compressedSize);
    memset(tf.bc7got.data(), 0x77, compressedSize);

    bool perceptual = true;
    
    // compress with bc7e for expected/reference result
    ispc::bc7e_compress_block_params settings;
    switch(kQuality)
    {
        case 0: ispc::bc7e_compress_block_params_init_ultrafast(&settings, perceptual); break;
        case 1: ispc::bc7e_compress_block_params_init_veryfast(&settings, perceptual); break;
        case 2: ispc::bc7e_compress_block_params_init_fast(&settings, perceptual); break;
        case 3: ispc::bc7e_compress_block_params_init_basic(&settings, perceptual); break;
        case 4: ispc::bc7e_compress_block_params_init_slow(&settings, perceptual); break;
    }
    {
        uint64_t t0 = stm_now();
        ic::pfor(tf.heightInBlocks, 1, [&](int blockY, int threadIdx)
        {
            const int kBatchSize = 64;
            unsigned char blocks[kBatchSize][16 * 4];
            int counter = 0;
            unsigned char* sliceOutput = tf.bc7exp.data() + blockY * tf.widthInBlocks * kBC7BlockBytes;
            for (int x = 0; x < tf.width; x += 4)
            {
                fetch_block(blocks[counter++], x, blockY*4, tf.width, tf.height, tf.rgba.data());
                if (counter == kBatchSize)
                {
                    ispc::bc7e_compress_blocks(counter, (uint64_t*)sliceOutput, (const uint32_t*)blocks, &settings);
                    sliceOutput += counter * kBC7BlockBytes;
                    counter = 0;
                }
            }
            if (counter != 0)
            {
                ispc::bc7e_compress_blocks(counter, (uint64_t*)sliceOutput, (const uint32_t*)blocks, &settings);
            }
        });
        float sec = (float)stm_sec(stm_since(t0));
        tf.timeRef = std::min(tf.timeRef, sec);
    }
    
    // compress with compute shader
    {
        const bool hasAlpha = tf.channels == 4;
        uint64_t t0 = stm_now();
        Globals glob = {tf.width, tf.height, tf.widthInBlocks, tf.heightInBlocks, settings};

        SmolBufferSetData(s_Bc7GlobBuffer, &glob, sizeof(glob));
        SmolBufferSetData(s_Bc7InputBuffer, tf.rgba.data(), tf.rgba.size());
        
        SmolKernelSet(s_Bc7KernelLists);
        SmolKernelSetBuffer(s_Bc7GlobBuffer, 0, SmolBufferBinding::Constant);
        SmolKernelSetBuffer(s_Bc7InputBuffer, 1, SmolBufferBinding::Input);
        SmolKernelSetBuffer(s_Bc7OutputBuffer, 2, SmolBufferBinding::Output);
        SmolKernelSetBuffer(s_Bc7TempBuffer, 3, SmolBufferBinding::Output);
        SmolKernelDispatch(tf.widthInBlocks, tf.heightInBlocks, 1, 64, 1, 1);

        // ISPC code does compression mode choices in this order:
        // alpha: 4 6 5 7
        // opaque: 6 1 0 3 5 2 4
        // so we do the same, overall in this order: 4a 6 1 0 3 5 2 4o 7

        if ((hasAlpha && settings.m_alpha_settings.m_use_mode4))
        {
            SmolKernelSet(s_Bc7KernelCompress4a);
            SmolKernelSetBuffer(s_Bc7GlobBuffer, 0, SmolBufferBinding::Constant);
            SmolKernelSetBuffer(s_Bc7InputBuffer, 1, SmolBufferBinding::Input);
            SmolKernelSetBuffer(s_Bc7OutputBuffer, 2, SmolBufferBinding::Input);
            SmolKernelSetBuffer(s_Bc7TempBuffer, 3, SmolBufferBinding::Output);
            SmolKernelSetBuffer(s_Bc7TablesBuffer, 4, SmolBufferBinding::Constant);
            SmolKernelDispatch(tf.widthInBlocks, tf.heightInBlocks, 1, 64, 1, 1);
        }
        if (settings.m_opaque_settings.m_use_mode[6] || (hasAlpha && settings.m_alpha_settings.m_use_mode6))
        {
            SmolKernelSet(s_Bc7KernelCompress6);
            SmolKernelSetBuffer(s_Bc7GlobBuffer, 0, SmolBufferBinding::Constant);
            SmolKernelSetBuffer(s_Bc7InputBuffer, 1, SmolBufferBinding::Input);
            SmolKernelSetBuffer(s_Bc7OutputBuffer, 2, SmolBufferBinding::Input);
            SmolKernelSetBuffer(s_Bc7TempBuffer, 3, SmolBufferBinding::Output);
            SmolKernelSetBuffer(s_Bc7TablesBuffer, 4, SmolBufferBinding::Constant);
            SmolKernelDispatch(tf.widthInBlocks, tf.heightInBlocks, 1, 64, 1, 1);
        }
        if (settings.m_opaque_settings.m_use_mode[0])
        {
            SmolKernelSet(s_Bc7KernelCompress0);
            SmolKernelSetBuffer(s_Bc7GlobBuffer, 0, SmolBufferBinding::Constant);
            SmolKernelSetBuffer(s_Bc7InputBuffer, 1, SmolBufferBinding::Input);
            SmolKernelSetBuffer(s_Bc7OutputBuffer, 2, SmolBufferBinding::Input);
            SmolKernelSetBuffer(s_Bc7TempBuffer, 3, SmolBufferBinding::Output);
            SmolKernelSetBuffer(s_Bc7TablesBuffer, 4, SmolBufferBinding::Constant);
            SmolKernelDispatch(tf.widthInBlocks, tf.heightInBlocks, 1, 64, 1, 1);
        }
        if (settings.m_opaque_settings.m_use_mode[1])
        {
            SmolKernelSet(s_Bc7KernelCompress1);
            SmolKernelSetBuffer(s_Bc7GlobBuffer, 0, SmolBufferBinding::Constant);
            SmolKernelSetBuffer(s_Bc7InputBuffer, 1, SmolBufferBinding::Input);
            SmolKernelSetBuffer(s_Bc7OutputBuffer, 2, SmolBufferBinding::Input);
            SmolKernelSetBuffer(s_Bc7TempBuffer, 3, SmolBufferBinding::Output);
            SmolKernelSetBuffer(s_Bc7TablesBuffer, 4, SmolBufferBinding::Constant);
            SmolKernelDispatch(tf.widthInBlocks, tf.heightInBlocks, 1, 64, 1, 1);
        }
        if (settings.m_opaque_settings.m_use_mode[3])
        {
            SmolKernelSet(s_Bc7KernelCompress3);
            SmolKernelSetBuffer(s_Bc7GlobBuffer, 0, SmolBufferBinding::Constant);
            SmolKernelSetBuffer(s_Bc7InputBuffer, 1, SmolBufferBinding::Input);
            SmolKernelSetBuffer(s_Bc7OutputBuffer, 2, SmolBufferBinding::Input);
            SmolKernelSetBuffer(s_Bc7TempBuffer, 3, SmolBufferBinding::Output);
            SmolKernelSetBuffer(s_Bc7TablesBuffer, 4, SmolBufferBinding::Constant);
            SmolKernelDispatch(tf.widthInBlocks, tf.heightInBlocks, 1, 64, 1, 1);
        }
        if (settings.m_opaque_settings.m_use_mode[5] || (hasAlpha && settings.m_alpha_settings.m_use_mode5))
        {
            SmolKernelSet(s_Bc7KernelCompress5);
            SmolKernelSetBuffer(s_Bc7GlobBuffer, 0, SmolBufferBinding::Constant);
            SmolKernelSetBuffer(s_Bc7InputBuffer, 1, SmolBufferBinding::Input);
            SmolKernelSetBuffer(s_Bc7OutputBuffer, 2, SmolBufferBinding::Input);
            SmolKernelSetBuffer(s_Bc7TempBuffer, 3, SmolBufferBinding::Output);
            SmolKernelSetBuffer(s_Bc7TablesBuffer, 4, SmolBufferBinding::Constant);
            SmolKernelDispatch(tf.widthInBlocks, tf.heightInBlocks, 1, 64, 1, 1);
        }
        if (settings.m_opaque_settings.m_use_mode[2])
        {
            SmolKernelSet(s_Bc7KernelCompress2);
            SmolKernelSetBuffer(s_Bc7GlobBuffer, 0, SmolBufferBinding::Constant);
            SmolKernelSetBuffer(s_Bc7InputBuffer, 1, SmolBufferBinding::Input);
            SmolKernelSetBuffer(s_Bc7OutputBuffer, 2, SmolBufferBinding::Input);
            SmolKernelSetBuffer(s_Bc7TempBuffer, 3, SmolBufferBinding::Output);
            SmolKernelSetBuffer(s_Bc7TablesBuffer, 4, SmolBufferBinding::Constant);
            SmolKernelDispatch(tf.widthInBlocks, tf.heightInBlocks, 1, 64, 1, 1);
        }
        if (settings.m_opaque_settings.m_use_mode[4])
        {
            SmolKernelSet(s_Bc7KernelCompress4o);
            SmolKernelSetBuffer(s_Bc7GlobBuffer, 0, SmolBufferBinding::Constant);
            SmolKernelSetBuffer(s_Bc7InputBuffer, 1, SmolBufferBinding::Input);
            SmolKernelSetBuffer(s_Bc7OutputBuffer, 2, SmolBufferBinding::Input);
            SmolKernelSetBuffer(s_Bc7TempBuffer, 3, SmolBufferBinding::Output);
            SmolKernelSetBuffer(s_Bc7TablesBuffer, 4, SmolBufferBinding::Constant);
            SmolKernelDispatch(tf.widthInBlocks, tf.heightInBlocks, 1, 64, 1, 1);
        }
        if (hasAlpha && settings.m_alpha_settings.m_use_mode7)
        {
            SmolKernelSet(s_Bc7KernelCompress7);
            SmolKernelSetBuffer(s_Bc7GlobBuffer, 0, SmolBufferBinding::Constant);
            SmolKernelSetBuffer(s_Bc7InputBuffer, 1, SmolBufferBinding::Input);
            SmolKernelSetBuffer(s_Bc7OutputBuffer, 2, SmolBufferBinding::Input);
            SmolKernelSetBuffer(s_Bc7TempBuffer, 3, SmolBufferBinding::Output);
            SmolKernelSetBuffer(s_Bc7TablesBuffer, 4, SmolBufferBinding::Constant);
            SmolKernelDispatch(tf.widthInBlocks, tf.heightInBlocks, 1, 64, 1, 1);
        }

        SmolKernelSet(s_Bc7KernelEncode);
        SmolKernelSetBuffer(s_Bc7GlobBuffer, 0, SmolBufferBinding::Constant);
        SmolKernelSetBuffer(s_Bc7OutputBuffer, 2, SmolBufferBinding::Output);
        SmolKernelSetBuffer(s_Bc7TempBuffer, 3, SmolBufferBinding::Input);
        SmolKernelDispatch(tf.widthInBlocks, tf.heightInBlocks, 1, 64, 1, 1);

        SmolBufferGetData(s_Bc7OutputBuffer, tf.bc7got.data(), tf.bc7got.size());
        float sec = (float)stm_sec(stm_since(t0));
        tf.timeGot = std::min(tf.timeGot, sec);
    }
    
    // check if they match
    bool result = true;
    if (memcmp(tf.bc7exp.data(), tf.bc7got.data(), tf.bc7got.size()) != 0)
    {
		memset(s_Bc7DecompressExpected, 0x77, rawSize);
		memset(s_Bc7DecompressGot, 0x77, rawSize);
		decompress_bc7(tf.width, tf.height, tf.bc7exp.data(), s_Bc7DecompressExpected);
		decompress_bc7(tf.width, tf.height, tf.bc7got.data(), s_Bc7DecompressGot);
        int maxDiff = 0;
        size_t maxDiffIdx = 0;
        for (size_t i = 0; i < tf.width * tf.height * 4; ++i)
        {
            int vexp = s_Bc7DecompressExpected[i];
			int vgot = s_Bc7DecompressGot[i];
            int diff = abs(vexp - vgot);
            if (diff > maxDiff)
            {
                maxDiff = diff;
                maxDiffIdx = i;
            }
        }
        float psnr = eval_psnr(tf.width, tf.height, tf.channels, s_Bc7DecompressExpected, s_Bc7DecompressGot);
        if (psnr < kAllowedPsnrDiff || kRequireExactResultsMatch)
        {
            int maxDiffX = maxDiffIdx / 4 % tf.width;
			int maxDiffY = maxDiffIdx / 4 / tf.width;
            int maxDiffCh = maxDiffIdx % 4;
            printf("    ERROR: did not match reference (PSNR diff %.2f; max pixel diff %i at pixel %i,%i ch %i block %i,%i)\n", psnr, maxDiff, maxDiffX, maxDiffY, maxDiffCh, maxDiffX/4, maxDiffY/4);
            tf.errors = true;
            result = false;
            stbi_write_tga(("artifacts/"+tf.fileNameBase+"-exp.tga").c_str(), tf.width, tf.height, 4, s_Bc7DecompressExpected);
            stbi_write_tga(("artifacts/"+tf.fileNameBase+"-got.tga").c_str(), tf.width, tf.height, 4, s_Bc7DecompressGot);
            size_t printed = 0;
            size_t blockCount = tf.bc7got.size() / 16;
            const uint32_t* ptrExp = (const uint32_t*)tf.bc7exp.data();
            const uint32_t* ptrGot = (const uint32_t*)tf.bc7got.data();
            for (size_t i = 0; i < blockCount; ++i, ptrExp += 4, ptrGot += 4)
            {
                if (memcmp(ptrExp, ptrGot, 16) == 0)
                    continue;
                if (printed > 4)
                {
                    printf("    ...more skipped\n");
                    break;
                }
                printf("    block %6zi exp %08x %08x %08x %08x\n", i, ptrExp[0], ptrExp[1], ptrExp[2], ptrExp[3]);
                printf("       (%3i,%3i) got %08x %08x %08x %08x\n", int(i) % tf.widthInBlocks, int(i) / tf.widthInBlocks, ptrGot[0], ptrGot[1], ptrGot[2], ptrGot[3]);
                ++printed;
            }
		}
    }
    return result;
}


int main()
{
    Initialize();
    int errorCount = 0;
    
    // Read image files
    printf("Load input images...\n");
    std::vector<TestFile> testFiles;
    size_t maxRgbaSize = 0;
    size_t maxBc7Size = 0;
    for (auto fileName : kTestFileNames)
    {
        TestFile tf;
        tf.filePath = fileName;
        size_t fileNameBaseStart = tf.filePath.find_last_of('/');
        if (fileNameBaseStart == std::string::npos)
            fileNameBaseStart = 0;
        else
            fileNameBaseStart++;
        size_t fileNameBaseEnd = tf.filePath.find_last_of('.');
        if (fileNameBaseEnd == std::string::npos)
            fileNameBaseEnd = tf.filePath.size();
        tf.fileNameBase = tf.filePath.substr(fileNameBaseStart, fileNameBaseEnd - fileNameBaseStart);
        stbi_uc* rgba = stbi_load(fileName, &tf.width, &tf.height, &tf.channels, 4);
        if (rgba == nullptr)
        {
            printf("ERROR: could not read input file '%s'\n", fileName);
            ++errorCount;
            continue;
        }
        if ((tf.width % 4) != 0 || (tf.height % 4) != 0)
        {
            printf("ERROR: only multiple of 4 image sizes are supported, was %ix%i for %s\n", tf.width, tf.height, fileName);
            stbi_image_free(rgba);
            ++errorCount;
            continue;
        }
        
        size_t rgbaSize = tf.width * tf.height * 4;
        maxRgbaSize = std::max(maxRgbaSize, rgbaSize);
        tf.rgba.resize(rgbaSize);
        memcpy(tf.rgba.data(), rgba, tf.rgba.size());
        stbi_image_free(rgba);
        
        tf.widthInBlocks = (tf.width + 3) / 4;
        tf.heightInBlocks = (tf.height + 3) / 4;
        size_t bc7size = tf.widthInBlocks * tf.heightInBlocks * 16;
        maxBc7Size = std::max(maxBc7Size, bc7size);
        tf.bc7exp.resize(bc7size);
        tf.bc7got.resize(bc7size);
        
        testFiles.emplace_back(tf);
    }
    
    // Create compression shaders & buffers
    if (kDoCapture)
        SmolCaptureStart();
    if (!InitializeCompressorResources(maxRgbaSize, maxBc7Size))
    {
        ++errorCount;
    }
    else
    {
        printf("Running tests on %zi images...\n", testFiles.size());
        for (int ir = 0; ir < kRunCount; ++ir)
        {
            printf("Run %i of %i...\n", ir+1, kRunCount);
            for (auto& tf : testFiles)
            {
                if (!TestOnFile(tf))
                    ++errorCount;
            }
        }
        if (kDoCapture)
            SmolCaptureFinish();
        
        printf("Timing results, Mpix/sec CPU vs GPU:\n");
        double mpixsRefSum = 0, mpixsGotSum = 0;
        int resultsCount = 0;
        for (const auto& tf : testFiles)
        {
            if (tf.errors)
                continue;
            double mpix = tf.width * tf.height / 1000000.0;
            double mpixsRef = mpix / tf.timeRef;
            double mpixsGot = mpix / tf.timeGot;
            mpixsGotSum += mpixsGot;
            mpixsRefSum += mpixsRef;
            ++resultsCount;
            printf("  %20s %6.1f %6.1f\n", tf.fileNameBase.c_str(), mpixsRef, mpixsGot);
        }
        if (resultsCount != 0)
        {
            printf("  %20s %6.1f %6.1f\n", "<average>", mpixsRefSum/resultsCount, mpixsGotSum/resultsCount);
        }
    }
    
    if (errorCount != 0)
        printf("ERROR: %i tests failed\n", errorCount);
    else
        printf("All OK!\n");

    CleanupCompressorResources();
    SmolComputeDelete();

    return errorCount ? 1 : 0;
}
