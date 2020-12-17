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
#ifdef _MSC_VER
#include <direct.h>
#else
#include <sys/stat.h>
#endif

static const char* kTestFiles[] =
{
    "textures/2dSignsCrop.png",
    //"textures/16x16.png",
    //"textures/Gradients.png",
};

struct Globals // note: should match Metal code struct
{
    int width, height;
    int widthInBlocks, heightInBlocks;
    ispc::bc7e_compress_block_params params;
};

struct endpoint_err // note: should match Metal code struct
{
    uint16_t m_error;
    uint8_t m_lo;
    uint8_t m_hi;
};

struct OptimalEndpointTables // note: should match Metal code struct
{
    endpoint_err mode_1[256][2]; // [c][pbit]
    endpoint_err mode_7[256][2][2]; // [c][pbit][hp][lp]
    endpoint_err mode_6[256][2][2]; // [c][hp][lp]
    uint32_t mode_4_3[256]; // [c]
    uint32_t mode_4_2[256]; // [c]
    endpoint_err mode_0[256][2][2]; // [c][hp][lp]
};

static OptimalEndpointTables s_Tables;

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


static void metal_bc7e_compress_block_init()
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
    metal_bc7e_compress_block_init();
    ic::init_pfor();
    if (!SmolComputeCreate())
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

static bool TestOnFile(const char* fileName)
{
    // load input image file
    printf("Testing file %s: ", fileName);
    int width = 0, height = 0, channels = 0;
    stbi_uc* rgba = stbi_load(fileName, &width, &height, &channels, 4);
    if (rgba == nullptr)
    {
        printf("could not read input file\n");
        return false;
    }
    printf("%ix%i ch=%i\n", width, height, channels);
    
    if ((width % 4) != 0 || (height % 4) != 0)
    {
        printf("  currently only multiple of 4 image sizes are supported, was %ix%i\n", width, height);
        stbi_image_free(rgba);
        return false;
    }
    
    const int widthInBlocks = (width+3) / 4;
    const int heightInBlocks = (height+3) / 4;
    const int blockBytes = 16;
    const size_t compressedSize = widthInBlocks * heightInBlocks * blockBytes;
    const size_t rawSize = width * height * 4;
    unsigned char* resExp = new unsigned char[compressedSize];
    unsigned char* resGot = new unsigned char[compressedSize];
    memset(resExp, 0x77, compressedSize);
    memset(resGot, 0x77, compressedSize);

    bool perceptual = true;
    int quality = 0;
    
    // compress with bc7e for expected/reference result
    ispc::bc7e_compress_block_params settings;
    switch(quality)
    {
        case 0: ispc::bc7e_compress_block_params_init_ultrafast(&settings, perceptual); break;
        case 1: ispc::bc7e_compress_block_params_init_veryfast(&settings, perceptual); break;
        case 2: ispc::bc7e_compress_block_params_init_fast(&settings, perceptual); break;
        case 3: ispc::bc7e_compress_block_params_init_basic(&settings, perceptual); break;
        case 4: ispc::bc7e_compress_block_params_init_slow(&settings, perceptual); break;
    }
    {

        ic::pfor(heightInBlocks, 1, [&](int blockY, int threadIdx)
        {
            const int kBatchSize = 32;
            unsigned char blocks[kBatchSize][16 * 4];
            int counter = 0;
            unsigned char* sliceOutput = resExp + blockY * widthInBlocks * blockBytes;
            for (int x = 0; x < width; x += 4)
            {
                fetch_block(blocks[counter++], x, blockY*4, width, height, rgba);
                if (counter == kBatchSize)
                {
                    ispc::bc7e_compress_blocks(counter, (uint64_t*)sliceOutput, (const uint32_t*)blocks, &settings);
                    sliceOutput += counter * blockBytes;
                    counter = 0;
                }
            }
            if (counter != 0)
            {
                ispc::bc7e_compress_blocks(counter, (uint64_t*)sliceOutput, (const uint32_t*)blocks, &settings);
            }
        });
    }
    
    // compress with smol-compute
    {
        Globals glob = {width, height, widthInBlocks, heightInBlocks, settings};

        size_t kernelSourceSize = 0;
        void* kernelSource = ReadFile("src/shaders/metal/bc7e.metal", &kernelSourceSize);
        printf("  compile Metal compression shader...\n");
        uint64_t tComp0 = stm_now();
        SmolKernel* kernel = SmolKernelCreate(kernelSource, kernelSourceSize, "bc7e_compress_blocks");
        printf("  compiled in %.1fs\n", stm_sec(stm_since(tComp0)));

        SmolBuffer* bufTables = SmolBufferCreate(sizeof(s_Tables), SmolBufferType::Constant);
        SmolBuffer* bufGlob = SmolBufferCreate(sizeof(glob), SmolBufferType::Constant);
        SmolBuffer* bufInput = SmolBufferCreate(width * height * 4, SmolBufferType::Structured, 4);
        SmolBuffer* bufOutput = SmolBufferCreate(compressedSize, SmolBufferType::Structured, blockBytes);
        SmolBufferSetData(bufTables, &s_Tables, sizeof(s_Tables));
        SmolBufferSetData(bufGlob, &glob, sizeof(glob));
        SmolBufferSetData(bufInput, rgba, width * height * 4);
        
        SmolKernelSet(kernel);
        SmolKernelSetBuffer(bufTables, 0, SmolBufferBinding::Constant);
        SmolKernelSetBuffer(bufGlob, 1, SmolBufferBinding::Constant);
        SmolKernelSetBuffer(bufInput, 2, SmolBufferBinding::Input);
        SmolKernelSetBuffer(bufOutput, 3, SmolBufferBinding::Output);
        SmolKernelDispatch(widthInBlocks, heightInBlocks, 1, 4, 4, 1);

        SmolBufferGetData(bufOutput, resGot, compressedSize);
        SmolBufferDelete(bufGlob);
        SmolBufferDelete(bufInput);
        SmolBufferDelete(bufOutput);
        SmolKernelDelete(kernel);
    }
    
    // check if they match
    bool result = true;
    if (memcmp(resExp, resGot, compressedSize) != 0)
    {
        printf("  did not match reference\n");
        result = false;
        unsigned char* rgbaExp = new unsigned char[rawSize];
        unsigned char* rgbaGot = new unsigned char[rawSize];
        memset(rgbaExp, 0x77, rawSize);
        memset(rgbaGot, 0x77, rawSize);
        decompress_bc7(width, height, resExp, rgbaExp);
        decompress_bc7(width, height, resGot, rgbaGot);
        stbi_write_tga("artifacts/exp.tga", width, height, 4, rgbaExp);
        stbi_write_tga("artifacts/got.tga", width, height, 4, rgbaGot);
        delete[] rgbaExp;
        delete[] rgbaGot;
    }

    // cleanup
    delete[] resExp;
    delete[] resGot;
    stbi_image_free(rgba);
    return result;
}


int main()
{
    Initialize();
    int errorCount = 0;
    for (auto fileName : kTestFiles)
    {
        if (!TestOnFile(fileName))
            ++errorCount;
    }
    if (errorCount != 0)
    {
        printf("ERROR: %i tests failed\n", errorCount);
    }
    return errorCount ? 1 : 0;
}
