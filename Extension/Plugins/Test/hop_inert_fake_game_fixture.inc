    // Entry counters preserve the base fake's refusals. An empty lease/capture
    // state alone would miss an accidental request that the fake rejected.
    unsigned input_lease_calls{}, input_capture_calls{};
    bool input_lease_request(std::uint64_t owner, std::uint32_t user, dingosdk::input_lease::Handle& handle,
        dingosdk::input_lease::Reason& reason) override {
        ++input_lease_calls; return Game::input_lease_request(owner, user, handle, reason);
    }
    bool input_lease_read(std::uint64_t owner, dingosdk::input_lease::Handle handle,
        dingosdk::input_lease::Snapshot& snapshot, dingosdk::input_lease::Reason& reason) override {
        ++input_lease_calls; return Game::input_lease_read(owner, handle, snapshot, reason);
    }
    bool input_lease_renew(std::uint64_t owner, dingosdk::input_lease::Handle handle,
        const dingosdk::input_lease::Snapshot& snapshot, dingosdk::input_lease::Reason& reason) override {
        ++input_lease_calls; return Game::input_lease_renew(owner, handle, snapshot, reason);
    }
    bool input_lease_release(std::uint64_t owner, dingosdk::input_lease::Handle handle,
        dingosdk::input_lease::Reason& reason) override {
        ++input_lease_calls; return Game::input_lease_release(owner, handle, reason);
    }
    bool input_lease_state(std::uint64_t owner, dingosdk::input_lease::Handle handle,
        dingosdk::input_lease::Receipt& receipt, dingosdk::input_lease::Reason& reason) override {
        ++input_lease_calls; return Game::input_lease_state(owner, handle, receipt, reason);
    }
    bool input_lease_acknowledge(std::uint64_t owner, dingosdk::input_lease::Handle handle,
        dingosdk::input_lease::Reason& reason) override {
        ++input_lease_calls; return Game::input_lease_acknowledge(owner, handle, reason);
    }
    bool input_lease_capture_request(std::uint64_t owner, dingosdk::input_lease::Handle handle,
        const dingosdk::input_lease::Snapshot& snapshot, dingosdk::input_lease_capture::Reason& reason) override {
        ++input_capture_calls; return Game::input_lease_capture_request(owner, handle, snapshot, reason);
    }
    bool input_lease_capture_state(std::uint64_t owner, dingosdk::input_lease::Handle handle,
        dingosdk::input_lease_capture::Receipt& receipt) override {
        ++input_capture_calls; return Game::input_lease_capture_state(owner, handle, receipt);
    }
    bool input_lease_capture_release(std::uint64_t owner, dingosdk::input_lease::Handle handle) override {
        ++input_capture_calls; return Game::input_lease_capture_release(owner, handle);
    }
    bool input_lease_capture_acknowledge(std::uint64_t owner, dingosdk::input_lease::Handle handle) override {
        ++input_capture_calls; return Game::input_lease_capture_acknowledge(owner, handle);
    }
