#include "../external/bc7e/bc7e_ispc.h"
#include "../external/ic_pfor.h"
#include "../external/sokol_time.h"
#include "../external/stb_image.h"
#include <assert.h>
#include <stdio.h>
#include <string.h>


static void Initialize()
{
    stm_setup();
    ispc::bc7e_compress_block_init();
    ic::init_pfor();
}

static const char* kTestFiles[] =
{
    "textures/16x16.png",
};


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
    unsigned char* resExp = new unsigned char[compressedSize];
    unsigned char* resGot = new unsigned char[compressedSize];
    memset(resExp, 0x77, compressedSize);
    memset(resGot, 0x77, compressedSize);
    
    bool perceptual = true;
    int quality = 0;
    
    // compress with bc7e for expected/reference result
    {
        ispc::bc7e_compress_block_params settings;
        switch(quality)
        {
            case 0: ispc::bc7e_compress_block_params_init_ultrafast(&settings, perceptual); break;
            case 1: ispc::bc7e_compress_block_params_init_veryfast(&settings, perceptual); break;
            case 2: ispc::bc7e_compress_block_params_init_fast(&settings, perceptual); break;
            case 3: ispc::bc7e_compress_block_params_init_basic(&settings, perceptual); break;
            case 4: ispc::bc7e_compress_block_params_init_slow(&settings, perceptual); break;
        }

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

    // cleanup
    delete[] resExp;
    delete[] resGot;
    stbi_image_free(rgba);
    return true;
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
