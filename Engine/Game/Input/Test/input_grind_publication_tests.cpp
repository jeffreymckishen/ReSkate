// Reuse the real native report broker's constructed providers and neutral
// handoff fixture. This target also links the full production overlay TU.
#define DINGOSDK_CAPTURE_NATIVE_NO_MAIN
#include "input_lease_capture_native_tests.cpp"
#include "Extension/UI/Overlay/scripted_pad.h"
#include "Engine/Core/Log/logging.h"

extern "C" void DingoSDKOverlaySetGrindStickTurn(bool, float, float, float) noexcept;
extern "C" void DingoSDKOverlaySetGrindStickLean(bool, float, float) noexcept;
extern "C" bool input_grind_test_on(bool) noexcept;
extern "C" std::uint64_t input_grind_test_until(bool) noexcept;
extern "C" std::uint64_t input_grind_test_duration() noexcept;
extern "C" bool input_grind_test_observer_inactive() noexcept;
extern "C" unsigned input_grind_unavailable_calls() noexcept;
extern "C" bool input_grind_unavailable_tls_clean() noexcept;
extern "C" ULONGLONG WINAPI input_grind_test_now() noexcept { return fixture::env.wall; }

namespace {
using fixture::check;
void set(bool turn, bool on) {
    if (turn) DingoSDKOverlaySetGrindStickTurn(on, 0.0f, 0.0f, 1.0f);
    else DingoSDKOverlaySetGrindStickLean(on, 0.0f, 0.0f);
}
lease::Receipt lease_state(lease::Handle handle) {
    lease::Receipt receipt; lease::Reason reason{};
    check(service::lease_state(21, handle, receipt, reason), "actual owner reads selected-source lease metadata");
    return receipt;
}
void reset(std::uint64_t at) {
    fixture::time(at);
    set(true, false); set(false, false);
    check(!input_grind_test_on(true) && !input_grind_test_on(false), "both actual authors are inactive before admission");
}
void unrelated_inactive() {
    check(!input_grind_unavailable_calls() && input_grind_unavailable_tls_clean() && input_grind_test_observer_inactive(),
        "unrelated UI/native leaves remain uncalled, TLS clean and private observer inactive");
    const auto logging_status = dingosdk::logging::status();
    check(!logging_status.initialized && !logging_status.file_output && !logging_status.external_console &&
        logging_status.directory.empty(), "real logging remains uninitialized without file or console output");
    service::PublicationScope scope;
    check(scope.owns() && !dingosdk::overlay::scripted_pad_active(),
        "real scripted-pad provider remains inactive under its actual publication gate");
}
void off_while_warming(bool turn, std::uint64_t base) {
    reset(base - 100);
    capture_fixture::prime(base);
    const auto handle = capture_fixture::lease_request();
    check(lease_state(handle).status == lease::Status::warming, "lease starts without an accepted post-admission sample");
    const auto revision = capture_fixture::revision();
    for (std::uint64_t offset = 1; offset <= 4; ++offset) {
        fixture::time(base + offset); set(turn, false);
        check(capture_fixture::revision() == revision, "repeated inactive actual setter does not invalidate publication authority");
        check(lease_state(handle).status == lease::Status::warming, "inactive trainer maintenance preserves warming reservation");
        check(!input_grind_test_on(turn) && !input_grind_test_until(turn), "inactive author has no fabricated future deadline");
    }
    (void)capture_fixture::frame(base + 10);
    (void)capture_fixture::sample(handle);
    check(lease_state(handle).status == lease::Status::active, "actual later selected-source report activates the preserved lease");
    capture_fixture::source_cleanup(handle);
}
void off_while_capturing(bool turn, std::uint64_t base) {
    reset(base - 100);
    const auto handle = capture_fixture::arm(base);
    const auto revision = capture_fixture::revision();
    const auto before = capture_fixture::state(handle);
    for (std::uint64_t offset = 25; offset <= 28; ++offset) {
        fixture::time(base + offset); set(turn, false);
        check(capture_fixture::revision() == revision, "inactive setter preserves an already captured source");
        (void)capture_fixture::sample(handle);
        const auto receipt = capture_fixture::state(handle);
        check(receipt.phase == capture::Phase::capturing && receipt.debt &&
            receipt.publications == before.publications, "inactive maintenance preserves real capture debt without inventing publications");
    }
    capture_fixture::handoff(handle);
}
void active_transitions(bool turn, std::uint64_t base) {
    reset(base - 100);
    const auto handle = capture_fixture::arm(base);
    auto revision = capture_fixture::revision();
    fixture::time(base + 25); set(turn, true);
    check(input_grind_test_on(turn) && input_grind_test_until(turn) == base + 25 + input_grind_test_duration(),
        "active production author retains its exact bounded deadline");
    check(capture_fixture::revision() > revision && lease_state(handle).status == lease::Status::revoked &&
        lease_state(handle).reason == lease::Reason::interference, "enabling actual competing authorship still revokes the source");
    check(capture_fixture::state(handle).phase == capture::Phase::releasing && capture_fixture::state(handle).debt,
        "competing author cannot clear outstanding neutral handoff duty");
    revision = capture_fixture::revision();
    fixture::time(base + 26); set(turn, true);
    check(capture_fixture::revision() > revision && input_grind_test_until(turn) == base + 26 + input_grind_test_duration(),
        "active same-value deadline renewal remains an authority change");
    revision = capture_fixture::revision();
    fixture::time(base + 27); set(turn, false);
    check(capture_fixture::revision() > revision && !input_grind_test_on(turn) && !input_grind_test_until(turn),
        "active-to-off transition still publishes revocation and clears its deadline");
    revision = capture_fixture::revision();
    fixture::time(base + 28); set(turn, false);
    check(capture_fixture::revision() == revision, "subsequent identical off maintenance is silent");
    capture_fixture::handoff(handle);
}
}
int main() {
    unrelated_inactive();
    std::uint64_t base = 1000;
    for (const bool turn : {true, false}) {
        off_while_warming(turn, base); base += 1000;
        off_while_capturing(turn, base); base += 1000;
        active_transitions(turn, base); base += 1000;
    }
    capture_fixture::no_actor_calls();
    unrelated_inactive();
    std::cout << "input_grind_publication groups=6 checks=" << fixture::checks << " native_actions=0\n";
}
