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
    "textures/16x16.png",
    //"textures/Gradients.png",
};


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
        struct Globals
        {
            int width, height;
            int widthInBlocks, heightInBlocks;
            ispc::bc7e_compress_block_params params;
        };
        Globals glob = {width, height, widthInBlocks, heightInBlocks, settings};

        size_t kernelSourceSize = 0;
        void* kernelSource = ReadFile("src/shaders/metal/bc7e.metal", &kernelSourceSize);
        SmolKernel* kernel = SmolKernelCreate(kernelSource, kernelSourceSize, "bc7e_compress_blocks");

        SmolBuffer* bufGlob = SmolBufferCreate(sizeof(glob), SmolBufferType::Constant);
        SmolBuffer* bufInput = SmolBufferCreate(width * height * 4, SmolBufferType::Structured, 4);
        SmolBuffer* bufOutput = SmolBufferCreate(compressedSize, SmolBufferType::Structured, blockBytes);
        SmolBufferSetData(bufGlob, &glob, sizeof(glob));
        SmolBufferSetData(bufInput, rgba, width * height * 4);
        
        SmolKernelSet(kernel);
        SmolKernelSetBuffer(bufInput, 0, SmolBufferBinding::Constant);
        SmolKernelSetBuffer(bufInput, 1, SmolBufferBinding::Input);
        SmolKernelSetBuffer(bufOutput, 2, SmolBufferBinding::Output);
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
