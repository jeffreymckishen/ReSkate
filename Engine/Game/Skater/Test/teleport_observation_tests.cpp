#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif
#ifndef NOMINMAX
#define NOMINMAX
#endif
#include <Windows.h>
#include "Engine/Game/Skater/teleport_observation.h"
#include <future>
#include <iostream>
#include <stdexcept>
#include <string_view>
#include <thread>

using namespace dingosdk::teleport_observation;
namespace {
unsigned checks{}, groups{};
void check(bool value, std::string_view name) {
    ++checks;
    if (!value) throw std::runtime_error(std::string(name));
}
struct Reader {
    Queue* queue{};
    Identity current{true, 0x1000};
    std::uintptr_t manager{0x2000};
    std::uint32_t phase{};
    unsigned identity_calls{}, manager_calls{}, phase_calls{};
    bool manager_ok{true}, phase_ok{true}, throw_read{}, mutate_read{}, retire_read{}, change_base{};
    bool replace_manager{}, become_busy{}, lifecycle_aba{};
    std::uint32_t get_error() const noexcept { return GetLastError(); }
    void set_error(std::uint32_t value) const noexcept { SetLastError(value); }
    Identity identity() noexcept { ++identity_calls; return current; }
    bool read_manager(std::uintptr_t base, std::uintptr_t& out) {
        ++manager_calls;
        check(base == 0x1000, "native manager uses captured profile base");
        SetLastError(222);
        if (throw_read) throw std::runtime_error("constructed read fault");
        if (mutate_read) {
            auto mutation = queue->mutate();
            mutation.write().position_teleport_at = 42;
        }
        if (retire_read) current.active = false;
        if (lifecycle_aba) {
            auto mutation = queue->mutate(); mutation.lifecycle_changed();
            current.active = false;
            current.active = true;
        }
        if (change_base) current.base = 0x3000;
        out = replace_manager && manager_calls % 2 == 0 ? manager + 0x100 : manager;
        return manager_ok;
    }
    bool read_phase(std::uintptr_t value, std::uint32_t& out) noexcept {
        ++phase_calls;
        if (value != manager) return false;
        SetLastError(333);
        out = become_busy && phase_calls % 2 == 0 ? 1u : phase;
        return phase_ok;
    }
};
Result observe(Queue& queue, Reader& reader) {
    SetLastError(12345);
    const auto result = queue.observe(reader);
    check(GetLastError() == 12345, "observer preserves LastError on every result");
    return result;
}
void categories() {
    ++groups;
    Queue queue; Reader reader{&queue};
    auto result = observe(queue, reader);
    check(result.known && !result.pending && result.revision == 1, "fresh native idle is known");
    reader.phase = 2;
    check(observe(queue, reader).pending, "fresh native nonzero phase is pending");
    check(reader.manager_calls == 4 && reader.phase_calls == 4, "idle reads never cache native phase");
    reader.current.active = false;
    check(observe(queue, reader).observation == Observation::inactive, "inactive profile is unavailable");
    reader.current.active = true; reader.manager_ok = false;
    check(observe(queue, reader).observation == Observation::manager_read_failed, "manager failure is distinguished");
    reader.manager_ok = true; reader.manager = 0;
    check(observe(queue, reader).observation == Observation::manager_null, "manager null is distinguished");
    reader.manager = 0x2000; reader.phase_ok = false;
    check(observe(queue, reader).observation == Observation::phase_read_failed, "phase failure is distinguished");
    reader.phase_ok = true; reader.throw_read = true;
    check(observe(queue, reader).observation == Observation::exception, "exception is unavailable");
}
void queues_and_reentrance() {
    ++groups;
    Queue queue; Reader reader{&queue};
    {
        auto mutation = queue.mutate();
        mutation.write().position_teleport = std::array<float, 16>{};
        mutation.write().position_teleport_at = 100;
    }
    auto result = observe(queue, reader);
    check(result.known && result.pending && !reader.manager_calls, "actual position queue is pending without native reads");
    {
        auto mutation = queue.mutate();
        mutation.write().position_teleport.reset();
        mutation.write().teleport_token = 77;
    }
    result = observe(queue, reader);
    check(result.known && !result.pending, "placement token queue preserves existing observation semantics");
    {
        auto dispatch = queue.mutate();
        dispatch.begin_dispatch();
        dispatch.write().teleport_token = 0;
        result = observe(queue, reader);
        check(result.known && result.pending, "same-thread placement callback after token clear sees dispatch pending");
        {
            auto nested = queue.mutate(); nested.begin_dispatch();
            check(observe(queue, reader).pending, "nested dispatch stays pending");
            nested.write().position_teleport = std::array<float, 16>{};
            nested.write().position_teleport_at = 200;
        }
        check(observe(queue, reader).pending, "outer dispatch remains busy after nested dispatch returns");
    }
    {
        auto read = queue.mutate();
        check(read.read().position_teleport.has_value() && read.read().position_teleport_at == 200,
            "nested enqueue survives outer dispatcher teardown");
    }
    check(observe(queue, reader).pending, "nested queued position remains pending");
}
void per_request_equipment() {
    ++groups;
    Queue queue;
    auto mutation = queue.mutate();
    auto& state = mutation.write();
    std::array<float, 16> first{}, second{};
    first[12] = 10; second[12] = 20;
    state.set_position(first, true, 100);
    check(state.position_teleport == first && state.position_teleport_on_board == true &&
        state.position_teleport_at == 100, "explicit board option is coupled to its exact queued transform");
    state.set_position(second, false, 200);
    check(state.position_teleport == second && state.position_teleport_on_board == false &&
        state.position_teleport_at == 200, "explicit false is retained with the replacement transform");
    state.set_position(first, std::nullopt, 300);
    check(state.position_teleport == first && !state.position_teleport_on_board.has_value() &&
        state.position_teleport_at == 300, "legacy enqueue clears the prior explicit option");
    state.set_position(second, true, 400);
    const auto dispatched_option = state.position_teleport_on_board;
    state.clear_position();
    check(!state.position_teleport && !state.position_teleport_on_board && state.position_teleport_at == 400,
        "consume or expiry clears both fields without renewing the original stamp");
    state.set_position(first, std::nullopt, 500);
    check(!state.position_teleport_on_board && state.position_teleport == first,
        "a later legacy request cannot inherit the cleared option");
    check(dispatched_option == true, "a captured dispatch option is not changed by a later enqueue");
}
void equipment_request_identity() {
    ++groups;
    EquipmentRequest request;
    request.transition = 0x2000; request.transform[12] = 10; request.on_board = false;
    auto other = request.transform; other[12] = 11;
    check(!request.consume(0, request.transition, other) && !request.consumed,
        "wrong target keeps the legacy path without consuming the scoped option");
    check(!request.consume(0, request.transition + 1, request.transform) && !request.consumed,
        "different transition cannot consume the scoped option");
    check(!request.consume(1, request.transition, request.transform) && !request.consumed,
        "remote request cannot consume the local option");
    check(request.consume(0, request.transition, request.transform) && request.consumed && !request.on_board,
        "the exact local request consumes once and retains explicit false");
    check(!request.consume(0, request.transition, request.transform), "matching replay is refused");
    EquipmentRequest next;
    next.transition = request.transition; next.transform = request.transform; next.on_board = true;
    check(next.consume(0, next.transition, next.transform) && next.on_board,
        "a later distinct request has its own option and consumption state");
    EquipmentRequest unbound;
    check(!unbound.consume(0, 0, unbound.transform) && !unbound.consumed,
        "a missing transition identity cannot qualify a scoped request");
}
void dispatch_destruction() {
    ++groups;
    Queue queue; Reader reader{&queue};
    unsigned stages{};
    try {
        auto dispatch = queue.mutate(); dispatch.begin_dispatch();
        dispatch.write().position_teleport.reset();
        check(observe(queue, reader).pending, "clear-before-constructor interval is pending"); ++stages;
        struct Transition {
            Queue& queue; Reader& reader; unsigned& stages;
            ~Transition() {
                check(observe(queue, reader).pending, "native transition destructor remains inside busy scope"); ++stages;
            }
        } transition{queue, reader, stages};
        check(observe(queue, reader).pending, "native teleport body remains inside busy scope"); ++stages;
        throw std::runtime_error("constructed native C++ unwind");
    } catch (const std::runtime_error&) {}
    check(stages == 3, "constructor/body/destructor observations executed");
    const auto result = observe(queue, reader);
    check(result.known && !result.pending, "dispatch depth drains after transition teardown and C++ unwind");
}
void contention() {
    ++groups;
    Queue queue; Reader reader{&queue};
    std::recursive_mutex broad;
    std::promise<void> broad_held, release_broad;
    auto release = release_broad.get_future();
    std::thread unrelated([&] { std::lock_guard lock(broad); broad_held.set_value(); release.wait(); });
    broad_held.get_future().wait();
    const auto independent = observe(queue, reader);
    release_broad.set_value(); unrelated.join();
    check(independent.known && !independent.pending, "unrelated broad-profile holder cannot refuse narrow observer");
    std::promise<void> queue_held, release_queue;
    auto queue_release = release_queue.get_future();
    std::thread writer([&] { std::lock_guard owner(broad); auto mutation = queue.mutate();
        queue_held.set_value(); queue_release.wait(); });
    queue_held.get_future().wait();
    const auto refused = observe(queue, reader);
    release_queue.set_value(); writer.join();
    check(!refused.known && refused.pending && refused.observation == Observation::lock_refused,
        "real other-thread queue guard remains Try-only unavailable");
}
void fences_and_exhaustion() {
    ++groups;
    Queue queue; Reader reader{&queue}; reader.mutate_read = true;
    auto result = observe(queue, reader);
    check(!result.known && result.pending && result.observation == Observation::queue_changed,
        "recursive mutation during native read cannot publish idle");
    reader.mutate_read = false; reader.retire_read = true;
    check(observe(queue, reader).observation == Observation::inactive, "profile retirement closes observation");
    reader.retire_read = false; reader.current.active = true; reader.change_base = true;
    check(observe(queue, reader).observation == Observation::queue_changed, "base replacement closes observation");
    Queue exhausted(std::numeric_limits<std::uint64_t>::max()); Reader limit_reader{&exhausted};
    check(observe(exhausted, limit_reader).known, "last nonzero revision can be observed before mutation");
    { auto mutation = exhausted.mutate(); mutation.write().position_teleport_at = 1; }
    check(observe(exhausted, limit_reader).observation == Observation::queue_exhausted, "revision never wraps after last mutation");
    { auto mutation = exhausted.mutate(); mutation.write().position_teleport = std::array<float, 16>{}; }
    check(!observe(exhausted, limit_reader).known, "later producer mutation cannot clear exhausted observation state");
    Queue zero(0); Reader invalid{&zero};
    check(observe(zero, invalid).observation == Observation::queue_exhausted, "zero initial revision is unavailable");
    Queue endpoint; Reader close{&endpoint}; close.replace_manager = true;
    check(observe(endpoint, close).observation == Observation::queue_changed, "manager replacement within observation refuses idle");
    close.replace_manager = false; close.become_busy = true;
    check(observe(endpoint, close).pending, "native busy at closing read remains pending");
    close.become_busy = false;
    const auto before = observe(endpoint, close);
    check(same_idle(before, observe(endpoint, close)), "unchanged endpoints qualify transient same-idle witness");
    close.manager += 0x100;
    check(!same_idle(before, observe(endpoint, close)), "same queue revision at different manager cannot qualify witness");
    close.manager = before.manager;
    { auto mutation = endpoint.mutate(); mutation.write().position_teleport = std::array<float, 16>{}; }
    { auto mutation = endpoint.mutate(); mutation.write().position_teleport.reset(); }
    check(!same_idle(before, observe(endpoint, close)), "enqueue-clear ABA after an idle observation changes witness");
    Queue lifecycle; Reader replaced{&lifecycle}; replaced.lifecycle_aba = true;
    check(observe(lifecycle, replaced).observation == Observation::queue_changed,
        "guarded false-true lifecycle interval cannot masquerade as same active/base");
    { auto mutation = lifecycle.mutate(); mutation.lifecycle_changed(); }
    replaced.lifecycle_aba = false;
    check(observe(lifecycle, replaced).known, "fresh operation can observe the new stable lifecycle");
}
void qualification_composition() {
    ++groups;
    Queue queue; Reader reader{&queue};
    // This is only the two actual helper endpoints and the same predicate
    // consumed by action_validate. It makes no fake owner/native completion.
    const auto closed_idle = [&](auto between) {
        const auto opening = observe(queue, reader);
        between();
        const auto closing = observe(queue, reader);
        return same_idle(opening, closing);
    };
    check(closed_idle([] {}), "unchanged idle can close a transient controls observation");
    check(!closed_idle([&] {
        { auto mutation = queue.mutate(); mutation.write().position_teleport = std::array<float, 16>{}; }
        { auto mutation = queue.mutate(); mutation.write().position_teleport.reset(); }
    }), "enqueue-clear between opening and full recapture closure prevents qualification");
    check(!closed_idle([&] {
        auto lifecycle = queue.mutate(); lifecycle.lifecycle_changed();
        reader.current.active = false;
        reader.current.active = true;
    }), "stamped same-value lifecycle replacement between endpoints prevents qualification");
    check(!closed_idle([&] { reader.manager += 0x100; }),
        "different native manager after owner/world recapture prevents qualification");
    check(!closed_idle([&] { reader.phase = 1; }),
        "native phase becoming busy at closing endpoint prevents qualification");
    reader.phase = 0;
    check(!closed_idle([&] { reader.current.active = false; }),
        "inactive closing lifecycle cannot become a qualified controls result");
    reader.current.active = true;
    check(closed_idle([] {}), "a new stable operation does not reuse any previous opening result");
}
}
int main() {
    try {
        categories(); queues_and_reentrance(); dispatch_destruction(); contention(); fences_and_exhaustion();
        qualification_composition(); per_request_equipment(); equipment_request_identity();
        std::cout << "PASS " << groups << " groups " << checks << " checks; constructed SDK queue/native-read facts only\n";
        return 0;
    } catch (const std::exception& error) { std::cerr << "FAIL " << error.what() << '\n'; return 1; }
}
