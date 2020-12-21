#define STB_IMAGE_IMPLEMENTATION
#include "../external/stb_image.h"
#define STB_IMAGE_WRITE_IMPLEMENTATION
#include "../external/stb_image_write.h"
#define SOKOL_IMPL
#include "../external/sokol_time.h"
#define IC_PFOR_IMPLEMENTATION
#include "../external/ic_pfor.h"

#ifdef _MSC_VER
#define SMOL_COMPUTE_IMPLEMENTATION 1
#define SMOL_COMPUTE_D3D11 1
#include "../external/smolcompute.h"
#endif