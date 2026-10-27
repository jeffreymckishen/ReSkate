#pragma once

#include <cstddef>
#include <iostream>
#include <ostream>
#include <sstream>
#include <string>
#include <string_view>

namespace dingosdk::trainer::asset_tools {
enum class ManholeCandidateMode { indices, position_hypothesis };
struct ManholeInspectionProgress {
    bool resource_read_attempted{}, resource_read_complete{}, resource_decode_complete{};
    bool geometry_read_attempted{}, geometry_read_complete{}, geometry_decode_complete{};
    bool inspection_complete{}, indices_consistent{};
};

// This writer targets a native text stream, as used by stdout and a default-mode ofstream.
// The byte and record ceilings include the final summary. Windows expands every LF to CRLF.
class MeshMetadataOutput {
public:
    static constexpr std::size_t maximum_bytes = 1024 * 1024, maximum_records = 8192;
    static constexpr std::size_t maximum_text = 512, summary_reserve = 1024;

    explicit MeshMetadataOutput(std::ostream& output = std::cout) : output_(output) {}

    std::string text(std::string_view source) {
        constexpr char digits[] = "0123456789abcdef";
        std::string result;
        result.reserve(maximum_text);
        for (const unsigned char byte : source) {
            const bool plain = byte >= 0x20 && byte <= 0x7e && byte != '\\';
            const std::size_t width = plain ? 1 : byte == '\\' ? 2 : 4;
            if (width > maximum_text - result.size()) { truncated_ = true; break; }
            if (plain) result += static_cast<char>(byte);
            else if (byte == '\\') result += "\\\\";
            else { result += "\\x"; result += digits[byte >> 4]; result += digits[byte & 15]; }
        }
        return result;
    }
    template <class... Values> bool record(const Values&... values) {
        if (stopped_ || finished_) return false;
        std::ostringstream line;
        (line << ... << values);
        const auto value = line.str();
        constexpr auto record_limit = maximum_bytes - summary_reserve;
        std::size_t encoded_size{};
        if (records_ >= maximum_records - 1 || bytes_ > record_limit ||
            !record_size(value, record_limit - bytes_, encoded_size)) {
            truncated_ = stopped_ = true;
            return false;
        }
        write(value, encoded_size);
        return true;
    }
    void mark_truncated() noexcept { truncated_ = true; }
    bool open() const noexcept { return !stopped_ && !finished_; }
    int finish(bool complete, int failure_code = 1) {
        const bool success = complete && !truncated_ && static_cast<bool>(output_);
        std::ostringstream line;
        line << "SUMMARY\tmode=mesh-metadata\tcomplete=" << (success ? 1 : 0)
             << "\toutput_truncated=" << (truncated_ ? 1 : 0) << "\trecords_before_summary=" << records_
             << "\tbytes_before_summary=" << bytes_ << "\tsuccess_scope=resource_metadata_only"
             << "\tgeometry_payload_read=0\tdependency_closure=unverified";
        const bool reported = summary(line.str(),
            "SUMMARY\tmode=mesh-metadata\tcomplete=0\toutput_truncated=1\terror=summary_budget_exceeded");
        return success && reported ? 0 : failure_code;
    }
    int finish_candidate(const ManholeInspectionProgress& progress, int failure_code = 1,
                         ManholeCandidateMode mode = ManholeCandidateMode::indices) {
        const bool positions = mode == ManholeCandidateMode::position_hypothesis;
        const bool reported = progress.inspection_complete && !truncated_ && static_cast<bool>(output_);
        std::ostringstream line;
        line << "SUMMARY\tmode=" << (positions ? "manhole-position-candidate" : "manhole-candidate")
             << "\tcomplete=0\tinspection_complete=" << (reported ? 1 : 0)
             << "\toutput_truncated=" << (truncated_ ? 1 : 0) << "\trecords_before_summary=" << records_
             << "\tbytes_before_summary=" << bytes_
             << "\tresource_read_attempted=" << progress.resource_read_attempted
             << "\tresource_read_complete=" << progress.resource_read_complete
             << "\tresource_decode_complete=" << progress.resource_decode_complete
             << "\tgeometry_read_attempted=" << progress.geometry_read_attempted
             << "\tgeometry_read_complete=" << progress.geometry_read_complete
             << "\tgeometry_decode_complete=" << progress.geometry_decode_complete
             << "\tindex_range_consistent=" << progress.indices_consistent
             << "\tsuccess_scope=" << (positions ? "position_hypothesis_only" : "candidate_consistency_only")
             << "\tsemantic_qualification=unverified"
             << "\tcontent_identity_authenticated=0\tdependency_closure=unverified";
        if (positions) line << "\tvertex_format_qualified=0\tfourth_lane_interpretation=unverified";
        summary(line.str(),
            positions ?
                "SUMMARY\tmode=manhole-position-candidate\tcomplete=0\tinspection_complete=0\toutput_truncated=1"
                "\tsemantic_qualification=unverified\terror=summary_budget_exceeded" :
                "SUMMARY\tmode=manhole-candidate\tcomplete=0\tinspection_complete=0\toutput_truncated=1"
                "\tsemantic_qualification=unverified\terror=summary_budget_exceeded");
        // Even a consistent inspection does not qualify the unsupported layout or native geometry.
        return failure_code;
    }
private:
    // Include the newline appended by write(), then account for any LFs inside the formatted value.
    static bool record_size(std::string_view value, std::size_t available, std::size_t& size) noexcept {
#ifdef _WIN32
        constexpr std::size_t newline_bytes = 2;
#else
        constexpr std::size_t newline_bytes = 1;
#endif
        if (available < newline_bytes || value.size() > available - newline_bytes) return false;
        size = value.size() + newline_bytes;
#ifdef _WIN32
        for (const char byte : value) {
            if (byte != '\n') continue;
            if (size == available) return false;
            ++size;
        }
#endif
        return true;
    }
    void write(std::string_view value, std::size_t encoded_size) {
        // Unformatted output cannot add padding from the caller's stream width or flags.
        output_.write(value.data(), static_cast<std::streamsize>(value.size()));
        output_.put('\n');
        bytes_ += encoded_size;
        ++records_;
    }
    bool summary(std::string_view value, std::string_view fallback) {
        if (finished_) return false;
        finished_ = stopped_ = true;
        std::size_t encoded_size{};
        if (bytes_ > maximum_bytes || !record_size(value, summary_reserve, encoded_size) ||
            encoded_size > maximum_bytes - bytes_) {
            truncated_ = true;
            if (bytes_ <= maximum_bytes && record_size(fallback, summary_reserve, encoded_size) &&
                encoded_size <= maximum_bytes - bytes_) write(fallback, encoded_size);
            return false;
        }
        write(value, encoded_size);
        return static_cast<bool>(output_);
    }

    std::ostream& output_;
    std::size_t bytes_{}, records_{};
    bool truncated_{}, stopped_{}, finished_{};
};
} // namespace dingosdk::trainer::asset_tools
