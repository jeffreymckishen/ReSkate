#pragma once
#include <array>
#include <atomic>
#include <cstdint>

namespace dingosdk::body_follow_native { class NativeMotionEntry; }
namespace dingosdk::body_follow_service { bool dispatch(body_follow_native::NativeMotionEntry&); }
namespace dingosdk::client_source::detail { class MotionEntryFactory; }

namespace dingosdk::body_follow_native {
// Internal only. The installed motion wrapper is the sole production factory.
// This borrows one current engine call; it does not retain native children.
class NativeMotionEntry {
public:
    using Original = void (*)(std::uintptr_t, std::uintptr_t, const std::array<float, 16>*, std::uint8_t);
    ~NativeMotionEntry();
    NativeMotionEntry(const NativeMotionEntry&) = delete;
    NativeMotionEntry& operator=(const NativeMotionEntry&) = delete;
    NativeMotionEntry(NativeMotionEntry&&) = delete;
    NativeMotionEntry& operator=(NativeMotionEntry&&) = delete;
    bool current() const noexcept;
    std::uint64_t serial() const noexcept { return serial_; }
    std::uintptr_t rig() const noexcept { return rig_; }
    std::uintptr_t context() const noexcept { return context_; }
    const std::array<float, 16>* supplied() const noexcept { return supplied_; }
private:
    friend class client_source::detail::MotionEntryFactory;
    friend bool body_follow_service::dispatch(NativeMotionEntry&);
    // Defined only in constructed fixtures; it is never a runtime factory/API.
    friend struct CallbackEntryTestAccess;
    NativeMotionEntry(Original, std::uintptr_t, std::uintptr_t,
        const std::array<float, 16>*, std::uint8_t) noexcept;
    static std::atomic<std::uint64_t> next_serial_;
    static thread_local NativeMotionEntry* active_;
    NativeMotionEntry* previous_{};
    Original original_{};
    std::uintptr_t rig_{}, context_{};
    const std::array<float, 16>* supplied_{};
    std::uint64_t serial_{};
    std::uint32_t thread_{};
    std::uint8_t flags_{};
    bool used_{};
};
} // namespace dingosdk::body_follow_native
