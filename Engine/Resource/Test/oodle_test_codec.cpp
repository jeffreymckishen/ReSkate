// Test-only DLL: never package this as the game's actual codec.
#include <cstdint>

namespace {
bool override_size{};
std::int64_t required_size{};
std::uint64_t decode_calls{};
}

extern "C" __declspec(dllexport) void __cdecl ReSkateTestOodle_Reset() {
    override_size = false;
    required_size = 0;
    decode_calls = 0;
}
extern "C" __declspec(dllexport) void __cdecl ReSkateTestOodle_SetBufferSize(std::int64_t size) {
    override_size = true;
    required_size = size;
}
extern "C" __declspec(dllexport) std::uint64_t __cdecl ReSkateTestOodle_DecodeCalls() { return decode_calls; }

extern "C" __declspec(dllexport) std::int64_t __cdecl OodleLZ_Decompress(
    const void* input, std::int64_t inputSize, void* output, std::int64_t outputSize,
    int, int, int, void*, std::int64_t, void*, void*, void*, std::int64_t, int) {
    ++decode_calls; // Refusal tests need to distinguish validation from entering the codec.
    if (!input || !output || inputSize != 1 || outputSize != 1) return -1;
    *static_cast<unsigned char*>(output) = *static_cast<const unsigned char*>(input);
    return 1;
}

// The buffer a decode into `rawSize` bytes needs: as the real codec, a little more than asked.
extern "C" __declspec(dllexport) std::int64_t __cdecl OodleLZ_GetDecodeBufferSize(int, std::int64_t rawSize, int) {
    return override_size ? required_size : rawSize + 16;
}
