#pragma once

#include "asset_mesh_output.h"
#include <algorithm>
#include <atomic>
#include <charconv>
#include <chrono>
#include <cstdint>
#include <filesystem>
#include <fstream>
#include <iostream>
#include <iterator>
#include <stdexcept>
#include <string>
#include <string_view>
#include <system_error>
#include <utility>

namespace dingosdk::trainer::asset_tools {
namespace mesh_output_test_detail {
namespace fs = std::filesystem;

#ifdef _WIN32
inline constexpr std::string_view native_newline = "\r\n";
#else
inline constexpr std::string_view native_newline = "\n";
#endif

struct Capture {
    std::string bytes;
    int result{};

    std::size_t summary_offset() const {
        const auto offset = bytes.rfind("SUMMARY\t");
        if (offset == std::string::npos) throw std::runtime_error("Synthetic output lacks its summary");
        return offset;
    }
    std::string_view field(std::string_view name) const {
        const std::string key = "\t" + std::string(name) + "=";
        const auto begin = bytes.find(key, summary_offset());
        if (begin == std::string::npos) throw std::runtime_error("Synthetic summary lacks a required field");
        const auto value = begin + key.size();
        const auto end = bytes.find_first_of("\t\r\n", value);
        if (end == std::string::npos) throw std::runtime_error("Synthetic summary field is unterminated");
        return std::string_view(bytes).substr(value, end - value);
    }
    std::size_t number(std::string_view name) const {
        const auto text = field(name);
        std::size_t value{};
        const auto parsed = std::from_chars(text.data(), text.data() + text.size(), value);
        if (parsed.ec != std::errc{} || parsed.ptr != text.data() + text.size())
            throw std::runtime_error("Synthetic summary field is not a decimal count");
        return value;
    }
};

class Fixture {
public:
    Fixture() : temporary_parent_(fs::canonical(fs::temp_directory_path())) {
        static std::atomic<std::uint64_t> sequence{};
        const auto stamp = std::chrono::steady_clock::now().time_since_epoch().count();
        for (unsigned attempt = 0; attempt < 128; ++attempt) {
            const auto name = "reskate-mesh-output-" + std::to_string(stamp) + "-" +
                std::to_string(sequence.fetch_add(1, std::memory_order_relaxed));
            const auto candidate = temporary_parent_ / name;
            if (fs::create_directory(candidate)) { root_ = candidate; break; }
        }
        if (root_.empty()) throw std::runtime_error("Could not create an owned output fixture");
    }
    ~Fixture() { cleanup(); }
    Fixture(const Fixture&) = delete;
    Fixture& operator=(const Fixture&) = delete;

    template <class Writer> Capture capture(Writer&& writer) const {
        const auto resolved = fs::canonical(root_);
        if (!resolved.is_absolute() || resolved != root_ || resolved.parent_path() != temporary_parent_)
            throw std::runtime_error("Synthetic output root changed before writing");
        const auto path = resolved / "output.txt";
        // Deliberately omit binary: MSVC's real text stream expands each LF to CRLF.
        std::ofstream output(path, std::ios::out | std::ios::trunc);
        if (!output) throw std::runtime_error("Synthetic native text output could not open");
        MeshMetadataOutput diagnostic(output);
        const int result = writer(diagnostic);
        output.close();
        if (!output) throw std::runtime_error("Synthetic native text output failed");
        std::ifstream input(path, std::ios::binary);
        if (!input) throw std::runtime_error("Synthetic binary output read could not open");
        std::string bytes{std::istreambuf_iterator<char>(input), std::istreambuf_iterator<char>()};
        if (input.bad()) throw std::runtime_error("Synthetic binary output read failed");
        return {std::move(bytes), result};
    }

private:
    fs::path temporary_parent_, root_;

    void cleanup() noexcept {
        if (root_.empty()) return;
        std::error_code error;
        const auto resolved = fs::canonical(root_, error);
        // Recursive removal is restricted to this exact, resolved direct child of the verified temp parent.
        if (error || !resolved.is_absolute() || resolved != root_ || resolved.parent_path() != temporary_parent_ ||
            !resolved.filename().string().starts_with("reskate-mesh-output-")) {
            std::cerr << "Synthetic output cleanup refused an unverified root\n";
            return;
        }
        fs::remove_all(resolved, error);
        if (error) std::cerr << "Synthetic output cleanup incomplete: " << error.message() << '\n';
        root_.clear();
    }
};

inline ManholeInspectionProgress completed_progress() {
    ManholeInspectionProgress progress;
    progress.resource_read_attempted = progress.resource_read_complete = progress.resource_decode_complete = true;
    progress.geometry_read_attempted = progress.geometry_read_complete = progress.geometry_decode_complete = true;
    progress.inspection_complete = progress.indices_consistent = true;
    return progress;
}
} // namespace mesh_output_test_detail

inline int mesh_output_self_test() {
    using namespace mesh_output_test_detail;
    std::size_t cases{}, checks{}, failures{};
    const auto check = [&](bool accepted, std::string_view message) {
        ++checks;
        if (!accepted) { ++failures; std::cerr << "FAIL: " << message << '\n'; }
    };
    const auto run = [&](std::string_view name, const auto& test) {
        ++cases;
        try { test(); }
        catch (const std::exception& error) { ++failures; std::cerr << "FAIL: " << name << ": " << error.what() << '\n'; }
    };
    const auto verify_summary = [&](const Capture& capture, std::string_view mode, std::size_t records) {
        const auto offset = capture.summary_offset();
        check(capture.field("mode") == mode, "summary keeps the requested diagnostic mode");
        check(capture.number("bytes_before_summary") == offset, "reported bytes equal the actual binary-file summary offset");
        check(capture.number("records_before_summary") == records, "reported records exclude the one reserved summary");
        check(capture.bytes.size() <= MeshMetadataOutput::maximum_bytes, "the full encoded file including summary stays within its byte limit");
        check(capture.bytes.size() - offset <= MeshMetadataOutput::summary_reserve, "the encoded summary fits its own reserved bytes");
        check(capture.bytes.ends_with(native_newline), "the actual native text stream supplies the expected final newline");
    };
    constexpr auto record_budget = MeshMetadataOutput::maximum_bytes - MeshMetadataOutput::summary_reserve;
    constexpr auto newline_bytes = native_newline.size();

    run("sixteen record CRLF accounting regression", [&] {
        Fixture fixture;
        const auto capture = fixture.capture([&](MeshMetadataOutput& output) {
            bool accepted = true;
            for (std::size_t i = 0; i < 16; ++i)
                accepted = output.record(std::string(i == 15 ? 210 : 206, 'x')) && accepted;
            check(accepted, "all sixteen synthetic records are admitted");
            return output.finish_candidate(completed_progress());
        });
        verify_summary(capture, "manhole-candidate", 16);
        check(capture.summary_offset() == 3300 + 16 * newline_bytes,
              "sixteen records have 3300 payload bytes plus sixteen native newlines");
#ifdef _WIN32
        check(capture.summary_offset() == 3332, "Windows reports 3332 actual bytes rather than the old logical count 3316");
#else
        check(capture.summary_offset() == 3316, "non-Windows explicitly exercises LF text output rather than claiming CRLF coverage");
#endif
        check(capture.result == 1 && capture.field("complete") == "0" && capture.field("inspection_complete") == "1" &&
              capture.field("output_truncated") == "0", "a complete candidate inspection still remains unqualified and exits one");
        check(capture.field("resource_read_complete") == "1" && capture.field("geometry_read_complete") == "1" &&
              capture.field("resource_decode_complete") == "1" && capture.field("geometry_decode_complete") == "1",
              "output accounting preserves the candidate progress flags");
    });
    run("embedded newlines use real text expansion", [&] {
        Fixture fixture;
        const auto capture = fixture.capture([&](MeshMetadataOutput& output) {
            check(output.record("alpha\nbeta\n"), "an embedded-newline record is admitted");
            return output.finish(true);
        });
        verify_summary(capture, "mesh-metadata", 1);
        const std::string expected = "alpha" + std::string(native_newline) + "beta" +
            std::string(native_newline) + std::string(native_newline);
        check(std::string_view(capture.bytes).substr(0, capture.summary_offset()) == expected,
              "every embedded LF and the appended LF is represented in physical byte accounting");
        check(capture.result == 0 && capture.field("complete") == "1", "metadata completion remains successful");
    });
    run("exact byte fit reserves the summary", [&] {
        Fixture fixture;
        const auto capture = fixture.capture([&](MeshMetadataOutput& output) {
            check(output.record(std::string(record_budget - newline_bytes, 'x')), "a record exactly filling the record-byte allowance is admitted");
            return output.finish(true);
        });
        verify_summary(capture, "mesh-metadata", 1);
        check(capture.summary_offset() == record_budget, "the encoded record consumes the exact record budget");
        check(capture.result == 0 && capture.field("complete") == "1" && capture.field("output_truncated") == "0",
              "an exact fit is not reported as truncation");
    });
    run("one byte beyond the record budget refuses before output", [&] {
        Fixture fixture;
        const auto capture = fixture.capture([&](MeshMetadataOutput& output) {
            check(!output.record(std::string(record_budget - newline_bytes + 1, 'x')), "a record one encoded byte too large is refused");
            check(!output.open(), "budget refusal closes the record writer");
            return output.finish(true);
        });
        verify_summary(capture, "mesh-metadata", 0);
        check(capture.summary_offset() == 0, "no bytes of an oversized record are emitted");
        check(capture.result == 1 && capture.field("complete") == "0" && capture.field("output_truncated") == "1",
              "oversized output cannot retain successful completion");
    });
    run("embedded newline expansion participates at the exact boundary", [&] {
        Fixture fixture;
        const std::string prefix(record_budget - 2 * newline_bytes - 1, 'x');
        const auto fit = fixture.capture([&](MeshMetadataOutput& output) {
            check(output.record(prefix, "\nY"), "embedded LF plus appended LF exactly fit their encoded allowance");
            return output.finish(true);
        });
        verify_summary(fit, "mesh-metadata", 1);
        check(fit.summary_offset() == record_budget && fit.result == 0, "the multiline exact fit consumes the physical budget");
        const auto overflow = fixture.capture([&](MeshMetadataOutput& output) {
            check(!output.record(prefix, "\nYY"), "one more payload byte refuses after newline expansion is charged");
            return output.finish(true);
        });
        verify_summary(overflow, "mesh-metadata", 0);
        check(overflow.summary_offset() == 0 && overflow.result == 1 && overflow.field("output_truncated") == "1",
              "an expanded overflow emits only its failure summary");
    });
    run("full record budget cannot consume the candidate summary reserve", [&] {
        Fixture fixture;
        const auto capture = fixture.capture([&](MeshMetadataOutput& output) {
            check(output.record(std::string(record_budget - newline_bytes, 'x')), "the initial exact-fit record is admitted");
            check(!output.record(""), "even an empty additional record needs a newline byte budget");
            return output.finish_candidate(completed_progress());
        });
        verify_summary(capture, "manhole-candidate", 1);
        check(capture.summary_offset() == record_budget, "the second record cannot enter the reserved summary area");
        check(capture.result == 1 && capture.field("complete") == "0" && capture.field("inspection_complete") == "0" &&
              capture.field("output_truncated") == "1", "truncated candidate output suppresses inspection completion");
    });
    run("record count reserves one terminal summary", [&] {
        Fixture fixture;
        const auto capture = fixture.capture([&](MeshMetadataOutput& output) {
            bool accepted = true;
            for (std::size_t i = 0; i < MeshMetadataOutput::maximum_records - 1; ++i)
                accepted = output.record("") && accepted;
            check(accepted, "all records before the reserved summary slot are accepted");
            check(!output.record(""), "the reserved summary slot cannot be used for another record");
            return output.finish(true);
        });
        verify_summary(capture, "mesh-metadata", MeshMetadataOutput::maximum_records - 1);
        check(capture.summary_offset() == (MeshMetadataOutput::maximum_records - 1) * newline_bytes,
              "all empty records still charge native newline bytes");
        check(static_cast<std::size_t>(std::count(capture.bytes.begin(), capture.bytes.end(), '\n')) == MeshMetadataOutput::maximum_records,
              "the full file contains the permitted record count including summary");
        check(capture.result == 1 && capture.field("output_truncated") == "1", "record-count refusal remains visible");
    });
    run("text clipping suppresses candidate completion", [&] {
        Fixture fixture;
        const auto capture = fixture.capture([&](MeshMetadataOutput& output) {
            const auto clipped = output.text(std::string(MeshMetadataOutput::maximum_text + 1, 'x'));
            check(clipped.size() == MeshMetadataOutput::maximum_text, "text clipping retains only its declared limit");
            check(output.record(clipped), "a clipped text value can still be reported");
            return output.finish_candidate(completed_progress());
        });
        verify_summary(capture, "manhole-candidate", 1);
        check(capture.summary_offset() == MeshMetadataOutput::maximum_text + newline_bytes, "clipped text has truthful encoded byte accounting");
        check(capture.result == 1 && capture.field("complete") == "0" && capture.field("inspection_complete") == "0" &&
              capture.field("output_truncated") == "1", "clipping cannot create a fully reported inspection");
    });
    run("the terminal summary cannot be emitted repeatedly", [&] {
        Fixture fixture;
        const auto capture = fixture.capture([&](MeshMetadataOutput& output) {
            check(output.record("one"), "the pre-summary record is accepted");
            const int first = output.finish(true);
            check(output.finish(true) != 0, "a repeated metadata finish refuses success");
            check(!output.record("after-summary"), "records after the terminal summary are refused");
            check(output.finish_candidate(completed_progress()) == 1, "a second summary kind cannot append another terminal record");
            return first;
        });
        verify_summary(capture, "mesh-metadata", 1);
        check(capture.result == 0 && capture.bytes.find("SUMMARY\t") == capture.summary_offset(), "only the first successful summary is emitted");
        check(capture.bytes.find("after-summary") == std::string::npos, "post-terminal attempts add no bytes");
    });
    run("empty output and explicit failure code retain their contract", [&] {
        Fixture fixture;
        const auto empty = fixture.capture([](MeshMetadataOutput& output) { return output.finish(true); });
        verify_summary(empty, "mesh-metadata", 0);
        check(empty.summary_offset() == 0 && empty.result == 0 && empty.field("complete") == "1", "an empty complete report uses only its reserved summary");
        const auto refused = fixture.capture([](MeshMetadataOutput& output) { return output.finish(false, 2); });
        verify_summary(refused, "mesh-metadata", 0);
        check(refused.result == 2 && refused.field("complete") == "0", "metadata argument failures retain their requested exit code");
        const auto candidate = fixture.capture([](MeshMetadataOutput& output) { return output.finish_candidate({}, 2); });
        verify_summary(candidate, "manhole-candidate", 0);
        check(candidate.result == 2 && candidate.field("complete") == "0" && candidate.field("inspection_complete") == "0",
              "candidate argument failures retain their requested exit code and incomplete flags");
    });

    std::cout << "mesh_output: " << cases << " cases, " << checks << " checks, " << failures << " failures"
              << ", native_newline_bytes=" << newline_bytes << '\n';
    return failures ? 1 : 0;
}
} // namespace dingosdk::trainer::asset_tools
