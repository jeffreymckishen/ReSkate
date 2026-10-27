// A test codec exercises DLL discovery and quotas without the game's proprietary Oodle DLL.
#include "Engine/Resource/cas_codec.h"
#include <Windows.h>
#include <cstddef>
#include <cstdint>
#include <initializer_list>
#include <iostream>
#include <limits>
#include <stdexcept>
#include <string_view>
#include <vector>

namespace {
namespace fb = dingosdk::frostbite;
using Bytes = std::vector<std::byte>;

Bytes block(std::uint32_t decoded_size, std::uint8_t compression, std::initializer_list<std::byte> payload) {
    const auto encoded_size = payload.size();
    Bytes result{
        static_cast<std::byte>((decoded_size >> 24) & 0xff), static_cast<std::byte>((decoded_size >> 16) & 0xff),
        static_cast<std::byte>((decoded_size >> 8) & 0xff), static_cast<std::byte>(decoded_size & 0xff),
        static_cast<std::byte>(compression), std::byte{0},
        static_cast<std::byte>((encoded_size >> 8) & 0xff), static_cast<std::byte>(encoded_size & 0xff)};
    result.insert(result.end(), payload.begin(), payload.end());
    return result;
}
Bytes joined(Bytes first, const Bytes& second) {
    first.insert(first.end(), second.begin(), second.end());
    return first;
}
template<class Function> Function fixture_export(HMODULE module, const char* name) {
    const auto address = GetProcAddress(module, name);
    if (!address) throw std::runtime_error("A test codec control export is missing");
#pragma warning(push)
#pragma warning(disable: 4191)
    return reinterpret_cast<Function>(address);
#pragma warning(pop)
}
} // namespace

int wmain(int argc, wchar_t** argv) {
    std::size_t cases{}, checks{}, failures{};
    const auto check = [&](bool condition, const char* message) {
        ++checks;
        if (!condition) throw std::runtime_error(message);
    };
    const auto run = [&](const char* name, const auto& test) {
        ++cases;
        try { test(); }
        catch (const std::exception& error) {
            ++failures;
            std::cerr << "FAILED: " << name << ": " << error.what() << '\n';
        }
    };
    const auto expect_error = [&](const Bytes& encoded, const fb::CasDecodeOptions& options, std::string_view expected) {
        bool refused{};
        try { (void)fb::decode_cas(encoded, options); }
        catch (const std::exception& error) {
            refused = true;
            check(std::string_view(error.what()).find(expected) != std::string_view::npos,
                  "decode refused for an unexpected reason");
        }
        check(refused, "decode unexpectedly accepted invalid input");
    };
    try {
        if (argc != 2) throw std::runtime_error("Pass the directory containing the test Oodle DLL");
        if (GetModuleHandleW(L"oo2core_9_win64.dll"))
            throw std::runtime_error("The fixture must exercise discovery before Oodle is loaded");
        const std::filesystem::path game_root(argv[1]);
        const auto options = [&](std::size_t limit) { return fb::CasDecodeOptions{game_root, limit}; };
        const auto raw_one = block(1, 0, {std::byte{0x2a}});
        const auto oodle_one = block(1, 0x11, {std::byte{0x2a}});
        const auto raw_three = block(3, 0, {std::byte{0x01}, std::byte{0x02}, std::byte{0x03}});
        const auto two_blocks = joined(raw_one, block(2, 0, {std::byte{0x01}, std::byte{0x02}}));
        constexpr std::string_view quota_error = "CAS block exceeds the remaining output limit";

        run("cumulative quota refuses before Oodle discovery", [&] {
            expect_error(joined(raw_one, oodle_one), options(1), quota_error);
            check(!GetModuleHandleW(L"oo2core_9_win64.dll"), "exhausted output budget must not discover the codec");
        });
        run("raw output exactly meets its limit", [&] {
            check(fb::decode_cas(raw_three, options(3)) == Bytes{std::byte{1}, std::byte{2}, std::byte{3}},
                  "exact raw limit preserves every byte");
        });
        run("multiple raw blocks exactly meet the limit", [&] {
            check(fb::decode_cas(two_blocks, options(3)) == Bytes{std::byte{0x2a}, std::byte{1}, std::byte{2}},
                  "the output budget is shared across blocks");
        });
        run("later raw block exceeds the remaining limit", [&] { expect_error(two_blocks, options(2), quota_error); });
        run("remaining limit is checked before payload interpretation", [&] {
            expect_error(joined(raw_one, block(2, 0, {})), options(2), quota_error);
        });
        run("zero output budget", [&] {
            check(fb::decode_cas({}, options(0)).empty(), "empty input needs no output budget");
            check(fb::decode_cas(block(0, 0, {}), options(0)).empty(), "an empty raw block stays empty");
            expect_error(raw_one, options(0), quota_error);
            expect_error(oodle_one, options(0), quota_error);
            check(!GetModuleHandleW(L"oo2core_9_win64.dll"), "zero budget must not discover the codec");
        });
        run("truncated block headers", [&] {
            for (std::size_t length = 1; length < 8; ++length)
                expect_error(Bytes(raw_one.begin(), raw_one.begin() + static_cast<std::ptrdiff_t>(length)), options(1), "Truncated CAS block header");
        });
        run("truncated block payload", [&] {
            auto truncated = raw_one;
            truncated.pop_back();
            expect_error(truncated, options(1), "Truncated CAS stream");
        });
        run("raw length mismatch", [&] {
            expect_error(block(2, 0, {std::byte{1}}), options(2), "Raw CAS block size does not match its header");
        });
        run("maximum declared block refuses under a small budget", [&] {
            expect_error(block(0x00ffffff, 0x11, {}), options(7072), quota_error);
            check(!GetModuleHandleW(L"oo2core_9_win64.dll"), "maximum declaration must refuse before codec discovery");
        });
        run("fixture loads and decodes with default options", [&] {
            check(fb::decode_cas(oodle_one, {game_root}) == Bytes{std::byte{0x2a}}, "the real fixture path still decodes its byte");
            check(GetModuleHandleW(L"oo2core_9_win64.dll") != nullptr, "positive decode must load the fixture module");
        });

        const auto module = GetModuleHandleW(L"oo2core_9_win64.dll");
        if (!module) throw std::runtime_error("Cannot continue destination tests without the fixture module");
        const auto reset = fixture_export<void (__cdecl*)()>(module, "ReSkateTestOodle_Reset");
        const auto set_size = fixture_export<void (__cdecl*)(std::int64_t)>(module, "ReSkateTestOodle_SetBufferSize");
        const auto decode_calls = fixture_export<std::uint64_t (__cdecl*)()>(module, "ReSkateTestOodle_DecodeCalls");
        const auto bounded = [&](std::size_t destination_limit) {
            auto value = options(1);
            value.maximumOodleBufferSize = destination_limit;
            return value;
        };
        constexpr std::size_t padded_floor = 0x40001; // One logical byte still needs the existing protective padding.
        constexpr std::string_view destination_error = "Oodle destination exceeds the safety limit";

        run("destination cap cannot remove protective padding", [&] {
            reset();
            expect_error(oodle_one, bounded(padded_floor - 1), destination_error);
            check(decode_calls() == 0, "padding refusal must precede decompression");
        });
        run("exact padded destination is allowed", [&] {
            reset();
            check(fb::decode_cas(oodle_one, bounded(padded_floor)) == Bytes{std::byte{0x2a}}, "exact padded floor is sufficient");
            check(decode_calls() == 1, "an admitted block enters decompression exactly once");
        });
        run("zero destination cap refuses", [&] {
            reset();
            expect_error(oodle_one, bounded(0), destination_error);
            check(decode_calls() == 0, "zero destination cap must precede decompression");
        });
        run("provider requirement larger than cap refuses", [&] {
            reset();
            set_size(0x50000);
            expect_error(oodle_one, bounded(padded_floor), destination_error);
            check(decode_calls() == 0, "provider requirement must not be clamped before decompression");
        });
        run("exact provider destination is allowed", [&] {
            reset();
            set_size(0x50000);
            check(fb::decode_cas(oodle_one, bounded(0x50000)) == Bytes{std::byte{0x2a}}, "exact provider requirement is sufficient");
            check(decode_calls() == 1, "an admitted provider requirement enters decompression once");
        });
        run("largest provider requirement refuses before allocation", [&] {
            reset();
            set_size((std::numeric_limits<std::int64_t>::max)());
            expect_error(oodle_one, bounded(padded_floor), "Oodle destination");
            check(decode_calls() == 0, "an enormous provider destination must not reach decompression");
        });
        run("negative provider destination refuses", [&] {
            for (const std::int64_t invalid : {std::int64_t{-1}, (std::numeric_limits<std::int64_t>::min)()}) {
                reset();
                set_size(invalid);
                expect_error(oodle_one, bounded(padded_floor), "Oodle returned an invalid destination size");
                check(decode_calls() == 0, "negative provider requirement must precede decompression");
            }
        });
        run("zero provider destination refuses", [&] {
            reset();
            set_size(0);
            expect_error(oodle_one, bounded(padded_floor), "Oodle returned an invalid destination size");
            check(decode_calls() == 0, "zero provider requirement must precede decompression");
        });
        run("Oodle destination cap does not change raw decoding", [&] {
            reset();
            check(fb::decode_cas(raw_one, bounded(0)) == Bytes{std::byte{0x2a}}, "destination cap is specific to Oodle storage");
            check(decode_calls() == 0, "raw decoding never enters Oodle");
        });
        run("remaining quota refuses before an already loaded codec", [&] {
            reset();
            expect_error(joined(raw_one, oodle_one), options(1), quota_error);
            check(decode_calls() == 0, "an exhausted budget never calls an already loaded codec");
        });
        reset();
    } catch (const std::exception& error) {
        ++failures;
        std::cerr << "FAILED: fixture setup: " << error.what() << '\n';
    }
    std::cout << "oodle_path: " << cases << " cases, " << checks << " checks, " << failures << " failures\n";
    return failures ? 1 : 0;
}
