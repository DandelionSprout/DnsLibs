#include "upstream/upstream_utils.h"
#include "gtest/gtest.h"
#include <magic_enum.hpp>

using namespace std::chrono_literals;

static constexpr auto timeout = 500ms;

namespace ag::upstream::test {

struct UpstreamUtilsTest : ::testing::Test {
protected:
    void SetUp() override {
        Logger::set_log_level(LogLevel::LOG_LEVEL_TRACE);
    }
};

TEST_F(UpstreamUtilsTest, InvalidUpstreamOnline) {
    auto err = ag::test_upstream({"123.12.32.1:1493", {}, timeout}, false, nullptr, false);
    ASSERT_TRUE(err) << "Cannot be successful";
}

TEST_F(UpstreamUtilsTest, ValidUpstreamOnline) {
    auto err = ag::test_upstream({"8.8.8.8:53", {}, 10 * timeout}, false, nullptr, false);
    ASSERT_FALSE(err) << "Cannot fail: " << *err;

    // Test for DoT with 2 bootstraps. Only one is valid
    // Use stub verifier b/c certificate verification is not part of the tested logic
    // and would fail on platforms where it is unsupported by ag::default_verifier
    err = ag::test_upstream(
            {"tls://1.1.1.1", {"1.2.3.4", "8.8.8.8"}, 10 * timeout}, false,
            [](const CertificateVerificationEvent &) {
                return std::nullopt;
            },
            false);
    ASSERT_FALSE(err) << "Cannot fail: " << *err;
}

TEST_F(UpstreamUtilsTest, InvalidUpstreamOfflineLooksValid) {
    auto err = ag::test_upstream({"123.12.32.1:1493", {}, timeout}, false, nullptr, true);
    ASSERT_FALSE(err) << "Cannot fail: " << *err;
}

TEST_F(UpstreamUtilsTest, InvalidUpstreamOfflineUnknownScheme) {
    auto err = ag::test_upstream({"unk://123.12.32.1:1493", {}, timeout}, false, nullptr, true);
    ASSERT_TRUE(err) << "Cannot be successful";
}

} // namespace ag::upstream::test
