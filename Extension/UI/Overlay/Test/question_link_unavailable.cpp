// Exact-header fatal closure for the 16 unrelated retained overlay paths.
// All ImGui functions come from Main's pinned existing genuine static library.
#include "Extension/UI/Overlay/overlay.h"
#include "Extension/UI/Overlay/overlay_internal.h"
#include "Extension/UI/Overlay/gpu_diagnostics.h"
#include "Extension/UI/Overlay/cursor.h"
#include "Extension/UI/Overlay/park_previews.h"
#include "Extension/UI/Overlay/chat_emotes.h"
#include <cstdio>
#include <cstdlib>

namespace {
[[noreturn]] void unrelated_link_path(const char* name) noexcept {
    std::fputs("Unexpected retained UI/render path in question fixture: ", stderr);
    std::fputs(name, stderr);
    std::fputc('\n', stderr);
    std::abort();
}
}

extern "C" void DingoSDKOverlayReadControllerInput(dingosdk::ControllerInput*, bool) {
    unrelated_link_path("DingoSDKOverlayReadControllerInput");
}
namespace dingosdk::overlay {
bool graphics_option_enabled(const wchar_t*) noexcept { unrelated_link_path("graphics_option_enabled"); }
void initialize_graphics_diagnostics() noexcept { unrelated_link_path("initialize_graphics_diagnostics"); }
void record_device_failure(ID3D12Device*, HRESULT, const char*) noexcept { unrelated_link_path("record_device_failure"); }
void watch_gpu_memory() noexcept { unrelated_link_path("watch_gpu_memory"); }
void start_park_previews(std::filesystem::path) { unrelated_link_path("start_park_previews"); }
void start_chat_emotes() { unrelated_link_path("start_chat_emotes"); }
namespace detail {
bool completed(UINT64, DWORD) { unrelated_link_path("completed"); }
void destroy_graphics() { unrelated_link_path("destroy_graphics"); }
ComPtr<IUnknown> object_identity(IUnknown*) { unrelated_link_path("object_identity"); }
Binding* find_binding(IUnknown*) { unrelated_link_path("find_binding"); }
void guarded_render(IDXGISwapChain*, UINT) noexcept { unrelated_link_path("guarded_render"); }
void sync_menu_cursor(bool) { unrelated_link_path("sync_menu_cursor"); }
void request_window_cursor_sync(HWND) { unrelated_link_path("request_window_cursor_sync"); }
BOOL WINAPI clip_cursor(const RECT*) { unrelated_link_path("clip_cursor"); }
BOOL WINAPI set_cursor_pos(int, int) { unrelated_link_path("set_cursor_pos"); }
}
}
