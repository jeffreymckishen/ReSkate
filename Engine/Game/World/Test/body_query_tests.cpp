#include "Engine/Game/World/body_query.h"
#include <iostream>
#include <limits>
#include <stdexcept>
#include <string_view>

using namespace dingosdk::body_query;
namespace {
static_assert(static_cast<unsigned>(Failure::none) == 0 && static_cast<unsigned>(Failure::backend) == 6);
unsigned checks{};
void check(bool value, const char* why) { ++checks; if (!value) throw std::runtime_error(why); }
Request request(std::size_t count = 1) {
    Request out; out.observation.epoch = {7, 11, 100, 3, static_cast<float>(dingosdk::owned_body::native_seconds)}; out.count = count;
    out.observation.mass = 12; out.observation.inertia = {2, 3, 4}; out.observation.rotation = {0, 0, 0, 1};
    for (auto& ray : out.rays) ray = {{1, 2, 3}, {1, -2, 3}};
    return out;
}
void empty(const Result& out) {
    check(!out.available, "partial batch was available");
    for (const auto& hit : out.rays) check(hit.status == Status::unavailable && !hit.body && hit.position == Vec{} && !hit.fraction, "partial geometry escaped");
}
void bounds_and_backend_geometry() {
    auto r = request(); check(valid(r, 1000), "bounded request rejected");
    auto bad = r; bad.count = 0; check(!valid(bad, 1000), "empty batch");
    bad = r; bad.count = maximum_rays + 1; check(!valid(bad, 1000), "ray quota");
    bad = r; bad.exclusions = maximum_exclusions + 1; check(!valid(bad, 1000), "exclusion quota");
    bad = r; bad.observation.epoch.serial = 0; check(!valid(bad, 1000), "missing epoch");
    bad = r; bad.observation.epoch.seconds = .02f; check(!valid(bad, 1000), "uncalibrated step");
    bad = r; bad.observation.epoch.time = std::numeric_limits<double>::quiet_NaN(); check(!valid(bad, 1000), "nonfinite epoch");
    bad = r; bad.rays[0].to = bad.rays[0].from; check(!valid(bad, 1000), "zero direction");
    bad = r; bad.rays[0].to[0] = 100001; check(!valid(bad, 1000), "map bounds");
    bad = r; bad.rays[0].to[0] = 1002; check(!valid(bad, 1000), "distance limit");
    bad = r; bad.rays[0].to[0] = std::numeric_limits<float>::infinity(); check(!valid(bad, 1000), "infinite coordinate");
    Hit hit{Status::hit, {1, 0, 3}, .5f, 1}; check(consistent(r.rays[0], hit), "actual segment hit rejected");
    hit.position[0] = 2; check(!consistent(r.rays[0], hit), "off-segment hit");
    hit = {Status::hit, {1, 0, 3}, -.5f, 1}; check(!consistent(r.rays[0], hit), "negative fraction");
    hit = {Status::hit, {1, 0, 3}, .5f, 33}; check(!consistent(r.rays[0], hit), "body ordinal quota");
    hit.body = 0; check(consistent(r.rays[0], hit), "unqualified body must not fabricate identity");
}
void counts_and_discard_are_bounded() {
    auto r = request(32); unsigned calls{}, fences{};
    const auto fence = [&] { ++fences; return true; };
    const auto clear = [&](const Ray&, unsigned allowance) { ++calls; check(allowance == 2, "per-ray cast allowance"); return Probe{{Status::clear}, 2}; };
    auto out = execute(r, 64, 1000, clear, fence);
    check(out.available && out.native_casts == 64 && calls == 32 && fences == 2, "all-clear maximum batch");
    for (const auto& hit : out.rays) check(hit.status == Status::clear && !hit.body, "clear ray invented identity");
    calls = fences = 0;
    out = execute(r, 63, 1000, [&](const Ray&, unsigned allowance) {
        ++calls; return allowance == 2 ? Probe{{Status::hit, {1, 0, 3}, .5f, 1}, 2} : Probe{{}, allowance, true};
    }, fence);
    check(out.native_casts == 63 && calls == 32 && fences == 2 && out.failure == Failure::budget && out.budget_exhausted, "last retry escaped shared allowance"); empty(out);
    calls = fences = 0;
    out = execute(request(), 64, 1000, [&](const Ray&, unsigned allowance) { ++calls; return Probe{{}, allowance, true}; }, fence);
    check(out.native_casts == 2 && calls == 1 && fences == 2 && out.failure == Failure::ray_limit, "unresolved exclusion silently retried or called clear"); empty(out);
    out = execute(request(), 1, 1000, [](const Ray&, unsigned allowance) { return Probe{{}, allowance, true}; }, fence);
    check(out.native_casts == 1 && out.failure == Failure::budget, "shared exhaustion mislabeled"); empty(out);
    calls = fences = 0;
    out = execute(r, 64, 1000, [&](const Ray&, unsigned) { ++calls; return Probe{}; }, fence);
    check(!out.native_casts && calls == 1 && fences == 2 && out.failure == Failure::query_preconditions_unavailable, "zero-cast preconditions were not distinguished"); empty(out);
    out = execute(request(), 64, 1000, [](const Ray&, unsigned) { return Probe{{}, 1}; }, fence);
    check(out.native_casts == 1 && out.failure == Failure::unavailable, "after-cast unavailable was called a precondition refusal"); empty(out);
    calls = 0;
    out = execute(request(2), 64, 1000, [&](const Ray&, unsigned) {
        return ++calls == 1 ? Probe{{Status::clear}, 1} : Probe{};
    }, fence);
    check(out.native_casts == 1 && calls == 2 && out.failure == Failure::unavailable, "later zero-cast refusal hid earlier native calls"); empty(out);
    calls = 0;
    out = execute(r, 0, 1000, clear, fence);
    check(!calls && !out.native_casts && out.failure == Failure::budget, "zero budget called backend");
    out = execute(request(), 64, 1000, [](const Ray&, unsigned) { return Probe{{Status::clear}, 3}; }, fence);
    check(!out.accounting_valid && out.failure == Failure::backend && !out.native_casts, "malformed count invented a valid actual count"); empty(out);
    out = execute(request(), 64, 1000, [](const Ray&, unsigned) { return Probe{{Status::clear}, 0}; }, fence);
    check(out.failure == Failure::backend, "zero-cast clear admitted"); empty(out);
    out = execute(request(), 64, 1000, [](const Ray&, unsigned) { return Probe{{}, 0, true}; }, fence);
    check(out.failure == Failure::ray_limit && out.budget_exhausted, "precondition detail overrode exhausted retry allowance"); empty(out);
}
void typed_refusal_names_are_stable() {
    check(std::string_view(name(Failure::client_phase_unavailable)) == "client_phase_unavailable", "client phase reason");
    check(std::string_view(name(Failure::local_actor_exclusion_unavailable)) == "local_actor_exclusion_unavailable", "actor exclusion reason");
    check(std::string_view(name(Failure::query_preconditions_unavailable)) == "query_preconditions_unavailable", "query preconditions reason");
    check(std::string_view(name(Failure::query_backend_exception)) == "query_backend_exception", "query exception reason");
}
void every_observation_fence_invalidates_the_whole_batch() {
    // Each field represents a native adapter fence: context, world generation/state, actor,
    // listener clock, owned-body generation and exclusion lifetime. None is a world mutex.
    for (unsigned changed = 0; changed < 7; ++changed) {
        std::array<unsigned, 7> observation{1, 2, 3, 4, 5, 6, 7}; const auto before = observation;
        unsigned calls{};
        const auto out = execute(request(3), 64, 1000, [&](const Ray&, unsigned) {
            if (++calls == 2) ++observation[changed];
            return Probe{{Status::hit, {1, 0, 3}, .5f, 1}, 1};
        }, [&] { return observation == before; });
        check(out.failure == Failure::observation_changed && out.native_casts == 3, "changed observation escaped final fence"); empty(out);
    }
    unsigned calls{}, fences{};
    auto out = execute(request(), 64, 1000, [&](const Ray&, unsigned) { ++calls; return Probe{}; }, [&] { return ++fences == 1; });
    check(calls == 1 && fences == 2 && out.failure == Failure::observation_changed, "failed query omitted after fence");
    out = execute(request(), 64, 1000, [&](const Ray&, unsigned) { ++calls; return Probe{}; }, [] { return false; });
    check(calls == 1 && !out.native_casts && out.failure == Failure::observation_changed, "stale epoch reached backend");
}
void one_budget_charges_actual_retries() {
    Budget budget; check(budget.remaining() == 64, "fresh shared budget");
    for (unsigned i = 0; i < 31; ++i) check(budget.consume(2, 2), "two-call query charge");
    check(budget.remaining() == 2 && budget.consume(1, 2) && budget.remaining() == 1, "mixed one/two cast consumption");
    check(budget.consume(0, 1) && budget.remaining() == 1, "unavailable fabricated a cast");
    check(budget.consume(1, 1) && !budget.remaining(), "final actual call");
    check(budget.consume(0, 0) && !budget.consume(1, 0) && !budget.remaining(), "exhaustion escaped");
    budget = {}; check(!budget.consume(3, 2) && !budget.remaining(), "bad backend failed to poison tick");
    budget = {}; check(budget.remaining(4) == 4 && budget.remaining(1000) == 64, "configured budget raised hard cap");
}
void a_listener_epoch_does_not_freeze_canonical_body_state() {
    const auto r = request(2); const auto canonical = r.observation;
    for (unsigned field = 0; field < 7; ++field) {
        auto latest = canonical, native = canonical; unsigned calls{};
        const auto mutate = [&](dingosdk::owned_body::Sample& sample) {
            switch (field) {
            case 0: sample.position[0] += .001f; break;
            case 1: sample.rotation[2] += .001f; break;
            case 2: sample.velocity[1] += .001f; break;
            case 3: sample.angular_velocity[2] += .001f; break;
            case 4: sample.inertia[0] += .001f; break;
            case 5: sample.mass += .001f; break;
            case 6: sample.velocity[0] = -0.f; break;
            }
        };
        const auto fence = [&] { return same_sample(canonical, latest) && same_sample(canonical, native); };
        auto out = execute(r, 64, 1000, [&](const Ray&, unsigned) {
            ++calls; mutate(native); return Probe{{Status::hit, {1, 0, 3}, .5f, 1}, 1};
        }, fence);
        check(native.epoch == canonical.epoch && out.failure == Failure::observation_changed && out.native_casts == 2,
            "same-listener-epoch native state drift escaped post fence"); empty(out);
        native = canonical; mutate(native); calls = 0;
        out = execute(r, 64, 1000, [&](const Ray&, unsigned) { ++calls; return Probe{{Status::clear}, 1}; }, fence);
        check(!calls && !out.native_casts && out.failure == Failure::observation_changed, "same-epoch native drift reached query");
        // A later read/receipt can publish new latest in the same epoch. Its immutable older
        // token must not become paired with that replacement, even if native now matches it.
        latest = native;
        out = execute(r, 64, 1000, [&](const Ray&, unsigned) { ++calls; return Probe{{Status::clear}, 1}; }, fence);
        check(!calls && !out.native_casts && !same_sample(canonical, latest) && out.failure == Failure::observation_changed,
            "same-epoch latest replacement was mistaken for canonical sample");
        check(same_sample(r.observation, canonical), "query overwrote immutable canonical state");
    }
}
}
int main() {
    try { bounds_and_backend_geometry(); counts_and_discard_are_bounded(); every_observation_fence_invalidates_the_whole_batch(); one_budget_charges_actual_retries();
        a_listener_epoch_does_not_freeze_canonical_body_state(); typed_refusal_names_are_stable();
        std::cout << "body query tests passed: " << checks << " checks\n"; return 0;
    } catch (const std::exception& e) { std::cerr << e.what() << '\n'; return 1; }
}
