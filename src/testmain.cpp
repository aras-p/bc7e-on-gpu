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

const int kQuality = 2;
const int kRunCount = 8;


static const char* kTestFileNames[] =
{
    "textures/2dSignsCrop.png",
    "textures/16x16.png",
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

static SmolKernel* s_Bc7Kernel;
static SmolBuffer* s_Bc7TablesBuffer;
static SmolBuffer* s_Bc7GlobBuffer;
static SmolBuffer* s_Bc7InputBuffer;
static SmolBuffer* s_Bc7OutputBuffer;

static bool InitializeMetalCompressorBuffers(size_t maxRgbaSize, size_t maxBc7Size)
{
    printf("Initialize Metal shaders & buffers...\n");
    size_t kernelSourceSize = 0;
    void* kernelSource = ReadFile("src/shaders/metal/bc7e.metal", &kernelSourceSize);
    if (kernelSource == nullptr)
    {
        printf("ERROR: could not read compute shader source file\n");
        return false;
    }
    uint64_t tComp0 = stm_now();
    s_Bc7Kernel = SmolKernelCreate(kernelSource, kernelSourceSize, "bc7e_compress_blocks");
    free(kernelSource);
    if (s_Bc7Kernel == nullptr)
    {
        printf("ERROR: failed to create compute shader\n");
        return false;
    }
    printf("  shader created in %.1fs\n", stm_sec(stm_since(tComp0)));

    s_Bc7TablesBuffer = SmolBufferCreate(sizeof(s_Tables), SmolBufferType::Constant);
    s_Bc7GlobBuffer = SmolBufferCreate(sizeof(Globals), SmolBufferType::Constant);
    s_Bc7InputBuffer = SmolBufferCreate(maxRgbaSize, SmolBufferType::Structured, 4);
    s_Bc7OutputBuffer = SmolBufferCreate(maxBc7Size, SmolBufferType::Structured, 16);
    SmolBufferSetData(s_Bc7TablesBuffer, &s_Tables, sizeof(s_Tables));
    return true;
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
        float sec = stm_sec(stm_since(t0));
        tf.timeRef = std::min(tf.timeRef, sec);
    }
    
    // compress with compute shader
    {
        uint64_t t0 = stm_now();
        Globals glob = {tf.width, tf.height, tf.widthInBlocks, tf.heightInBlocks, settings};

        SmolBufferSetData(s_Bc7GlobBuffer, &glob, sizeof(glob));
        SmolBufferSetData(s_Bc7InputBuffer, tf.rgba.data(), tf.rgba.size());
        
        SmolKernelSet(s_Bc7Kernel);
        SmolKernelSetBuffer(s_Bc7TablesBuffer, 0, SmolBufferBinding::Constant);
        SmolKernelSetBuffer(s_Bc7GlobBuffer, 1, SmolBufferBinding::Constant);
        SmolKernelSetBuffer(s_Bc7InputBuffer, 2, SmolBufferBinding::Input);
        SmolKernelSetBuffer(s_Bc7OutputBuffer, 3, SmolBufferBinding::Output);
        SmolKernelDispatch(tf.widthInBlocks, tf.heightInBlocks, 1, 32, 1, 1);

        SmolBufferGetData(s_Bc7OutputBuffer, tf.bc7got.data(), tf.bc7got.size());
        float sec = stm_sec(stm_since(t0));
        tf.timeGot = std::min(tf.timeGot, sec);
    }
    
    // check if they match
    bool result = true;
    if (memcmp(tf.bc7exp.data(), tf.bc7got.data(), tf.bc7got.size()) != 0)
    {
        printf("    ERROR: did not match reference\n");
        tf.errors = true;
        result = false;
        unsigned char* rgbaExp = new unsigned char[rawSize];
        unsigned char* rgbaGot = new unsigned char[rawSize];
        memset(rgbaExp, 0x77, rawSize);
        memset(rgbaGot, 0x77, rawSize);
        decompress_bc7(tf.width, tf.height, tf.bc7exp.data(), rgbaExp);
        decompress_bc7(tf.width, tf.height, tf.bc7got.data(), rgbaGot);
        stbi_write_tga(("artifacts/"+tf.fileNameBase+"-exp.tga").c_str(), tf.width, tf.height, 4, rgbaExp);
        stbi_write_tga(("artifacts/"+tf.fileNameBase+"-got.tga").c_str(), tf.width, tf.height, 4, rgbaGot);
        delete[] rgbaExp;
        delete[] rgbaGot;
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
    if (!InitializeMetalCompressorBuffers(maxRgbaSize, maxBc7Size))
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
    return errorCount ? 1 : 0;
}
