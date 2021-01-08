# bc7e-on-gpu

An experiment at trying to port Binomial's **BC7E** texture compressor (https://github.com/BinomialLLC/bc7e) to a GPU compute shader.

Currently it does nothing good, just resulted in some twitter rants :)

* Thread 1: initial Metal attempts https://twitter.com/aras_p/status/1340731771659423744
* Thread 2: initial DX11/HLSL fxc attempts https://twitter.com/aras_p/status/1341712976756281345
* Thread 3: initial Vulkan/HLSL (dxc/glslang) attempts https://twitter.com/aras_p/status/1342920648897785856
* Thread 4: back to Metal, make it not terrible https://twitter.com/aras_p/status/1344341238217113601
* TODO!

Current state (2021 Jan):

* Metal supports "ultrafast", "veryfast", "fast" and "basic" quality modes, produces identical results to CPU ISPC code, runs slightly faster than CPU code (except for "ultrafast" mode where CPU is faster).
* DX11 & Vulkan support "ultrafast", "veryfast" and "fast" quality modes, does *not* produce idential results as CPU ISPC code, runs slightly (DX11) or a lot (Vulkan) slower than CPU.

I suspect in order to get this into a decent state on the GPU it needs way more reshuffling to improve GPU occupancy, etc. etc.
