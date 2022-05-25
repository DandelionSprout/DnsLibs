#include <csignal>
#include <fmt/chrono.h>
#include <functional>
#include <future>
#include <gtest/gtest.h>
#include <ldns/ldns.h>
#include <thread>

#include "common/logger.h"
#include "common/utils.h"
#include "dnscrypt/dns_crypt_ldns.h"
#include "net/application_verifier.h"
#include "net/default_verifier.h"
#include "upstream/upstream.h"
#include "upstream/upstream_utils.h"

#include "test_utils.h"

namespace ag::upstream::test {

static constexpr Secs DEFAULT_TIMEOUT(10);
static constexpr Millis DELAY_BETWEEN_REQUESTS{500};

static struct Init {
    Init() {
#ifdef SIGPIPE
        std::signal(SIGPIPE, SIG_IGN);
#endif
    }
} init_;

static Logger logger{"test_upstream"};

namespace concat_err_string {

ErrString &operator+=(ErrString &result, const ErrString &err) {
    if (err) {
        if (!result) {
            result = std::string{};
        }
        if (result) {
            *result += AG_FMT("{}\n", *err);
        }
    }
    return result;
}

} // namespace concat_err_string

static ag::ldns_pkt_ptr create_test_message() {
    ldns_pkt *pkt = ldns_pkt_query_new(
            ldns_dname_new_frm_str("google-public-dns-a.google.com."), LDNS_RR_TYPE_A, LDNS_RR_CLASS_IN, LDNS_RD);
    static size_t id = 0;
    ldns_pkt_set_id(pkt, id++);
    return ag::ldns_pkt_ptr(pkt);
}

[[nodiscard]] static ErrString assert_response(const ldns_pkt &reply) {
    size_t ancount = ldns_pkt_ancount(&reply);
    if (ancount != 1) {
        return AG_FMT("DNS upstream returned reply with wrong number of answers: {}", ancount);
    }
    ldns_rr *first_rr = ldns_rr_list_rr(ldns_pkt_answer(&reply), 0);
    if (ldns_rr_get_type(first_rr) != LDNS_RR_TYPE_A) {
        return AG_FMT("DNS upstream returned wrong answer type instead of A: {}",
                ldns_rr_type2str(ldns_rr_get_type(first_rr)));
    }
    ldns_rdf *rdf = ldns_rr_rdf(first_rr, 0);
    static constexpr std::array<uint8_t, 4> ip8888 = {8, 8, 8, 8};
    if (ldns_rdf_size(rdf) != ip8888.size() || 0 != std::memcmp(ldns_rdf_data(rdf), ip8888.data(), ip8888.size())) {
        return "DNS upstream returned wrong answer instead of 8.8.8.8";
    }
    return std::nullopt;
}

[[nodiscard]] static ErrString check_upstream(Upstream &upstream, const std::string &addr) {
    auto req = create_test_message();
    auto [reply, err] = upstream.exchange(req.get());
    if (err) {
        return AG_FMT("Couldn't talk to upstream {}: {}", addr, *err);
    }
    return assert_response(*reply);
}

using ErrFutures = std::vector<std::future<ErrString>>;

template <typename F>
static ErrFutures make_indexed_futures(size_t count, const F &f) {
    ErrFutures futures;
    futures.reserve(count);
    for (size_t i = 0, e = count; i < e; ++i) {
        futures.emplace_back(ag::utils::async_detached(f, i));
    }
    return futures;
}

static void check_all_futures(ErrFutures &futures) {
    using namespace concat_err_string;
    ErrString err;
    for (auto &future : futures) {
        err += future.get();
    }
    ASSERT_FALSE(err) << *err;
}

template <typename F>
static void parallel_test_basic_n(size_t count, const F &f) {
    auto futures = make_indexed_futures(count, f);
    check_all_futures(futures);
}

template <typename T, typename F>
static void parallel_test_basic(const T &data, const F &function) {
    ErrFutures futures;
    futures.reserve(std::size(data));
    for (const auto &[address, bootstrap, server_ip] : data) {
        std::this_thread::sleep_for(DELAY_BETWEEN_REQUESTS);
        futures.emplace_back(ag::utils::async_detached(function, address, bootstrap, server_ip));
    }
    check_all_futures(futures);
}

class UpstreamTest : public ::testing::Test {
protected:
    std::unique_ptr<SocketFactory> socket_factory;
    std::unique_ptr<UpstreamFactory> upstream_factory;

    void SetUp() override {
#if 0
        // It is too verbose for a CI report, and also the output in the stderr on Windows
        // is too slow, so that tests with small timeouts may fail
        ag::set_default_log_level(TRACE);
#endif
        make_upstream_factory();
    }

    void make_upstream_factory(OutboundProxySettings *oproxy = nullptr) {
        struct SocketFactory::Parameters sf_parameters = {};
#ifndef _WIN32
        sf_parameters.verifier = std::make_unique<DefaultVerifier>();
#else
        sf_parameters.verifier = std::make_unique<ApplicationVerifier>([](const CertificateVerificationEvent &) {
            return std::nullopt;
        });
#endif

#if 0
        static OutboundProxySettings proxy_settings =
                { OutboundProxyProtocol::SOCKS5_UDP, "127.0.0.1", 8888, { { "1", "1" } } };
        sf_parameters.oproxy_settings = &proxy_settings;
#else
        sf_parameters.oproxy_settings = oproxy;
#endif

        socket_factory = std::make_unique<SocketFactory>(std::move(sf_parameters));

        static bool ipv6_available = test_ipv6_connectivity();
        upstream_factory
                = std::make_unique<UpstreamFactory>(UpstreamFactoryConfig{socket_factory.get(), ipv6_available});
    }

    UpstreamFactory::CreateResult create_upstream(const UpstreamOptions &opts) {
        return upstream_factory->create_upstream(opts);
    }

    template <typename T>
    void parallel_test(const T &data) {
        parallel_test_basic(
                data, [this](const auto &address, const auto &bootstrap, const auto &server_ip) -> ErrString {
                    auto [upstream_ptr, upstream_err]
                            = create_upstream({address, bootstrap, DEFAULT_TIMEOUT, server_ip});
                    if (upstream_err) {
                        return AG_FMT("Failed to generate upstream from address {}: {}", address, *upstream_err);
                    }
                    return check_upstream(*upstream_ptr, address);
                });
    }
};

template <typename... Ts>
struct UpstreamParamTest : public UpstreamTest, public ::testing::WithParamInterface<Ts...> {};

TEST_F(UpstreamTest, CreateUpstreamWithWrongOptions) {
    static const UpstreamOptions OPTIONS[] = {
            // malformed ip address
            {"8..8.8:53"},
            {"8.a.8.8:53"},
            {"8.8.8.8:-1"},
            {"[::1::]"},
            {"tcp://8..8.8:53"},

            // no bootstrapper and resolved server address
            {"https://example.com"},
            {"tls://one.one.one.one"},

            // non-plain DNS bootstrapper has no explicit or malformed ip address
            {"https://example.com", {"https://example.com"}},
            {"https://example.com", {"1..1.1"}},
            {"tls://one.one.one.one", {"https://example.com"}},
            {"tls://one.one.one.one", {"1..1.1"}},

            // some degenerate URLs
            {"tls://", {"1.1.1.1"}},
            {"tls:///", {"1.1.1.1"}},
            {"tls://   ", {"1.1.1.1"}},
            {"tls://   /", {"1.1.1.1"}},
            {"tcp://", {}},
            {"tcp:///", {}},
            {"tcp://   ", {}},
            {"tcp://   /", {}},
            {"quic://", {}},
            {"quic://   ", {}},
            {"quic:///", {}},
            {"quic://   /", {}},
            {"https://", {}},
            {"https://   ", {}},
            {"https:///", {}},
            {"https://   /", {}},
    };

    for (const UpstreamOptions &options : OPTIONS) {
        UpstreamFactory::CreateResult r = create_upstream(options);
        ASSERT_TRUE(r.error.has_value()) << options.address;
    }
}

TEST_F(UpstreamTest, UseUpstreamWithWrongOptions) {
    static const UpstreamOptions OPTIONS[]{
            // non existent domain, valid bootstrap
            {"https://qwer.zxcv.asdf.", {"8.8.8.8"}},
            // existent domain, invalid bootstrap
            {"https://dns.adguard.com/dnsquery", {"4.3.2.1"}},
            // DoT
            {"tls://one.one.two.asdf.", {"8.8.8.8"}}, // invalid/valid
            {"tls://one.one.one.one", {"4.3.2.1"}}, // valid/invalid
            {"tls://one.one.one.one:1234", {"8.8.8.8"}}, // invalid/valid
    };

    for (const UpstreamOptions &options : OPTIONS) {
        auto [upstream, uerror] = create_upstream(options);
        ASSERT_FALSE(uerror.has_value()) << uerror.value();

        ag::ldns_pkt_ptr msg = create_test_message();
        auto [reply, eerror] = upstream->exchange(msg.get());
        ASSERT_TRUE(eerror.has_value()) << "Expected this upstream to error out: " << options.address;
    }
}

TEST_F(UpstreamTest, TestBootstrapTimeout) {
    using namespace std::chrono_literals;
    using namespace concat_err_string;
    static constexpr auto timeout = 100ms;
    static constexpr size_t count = 10;
    auto futures = make_indexed_futures(count, [&](size_t index) -> ErrString {
        infolog(logger, "Start {}", index);
        // Specifying some wrong port instead so that bootstrap DNS timed out for sure
        auto [upstream_ptr, upstream_err] = create_upstream({"tls://one.one.one.one", {"8.8.8.8:555"}, timeout});
        if (upstream_err.has_value()) {
            return AG_FMT("Failed to create upstream: {}", upstream_err.value());
        }
        ag::utils::Timer timer;
        auto req = create_test_message();
        auto [reply, reply_err] = upstream_ptr->exchange(req.get());
        if (!reply_err) {
            return "The upstream must have timed out";
        }
        auto elapsed = timer.elapsed<Millis>();
        if (elapsed > 2 * timeout) {
            return AG_FMT("Exchange took more time than the configured timeout: {}", elapsed);
        }
        infolog(logger, "Finished {}", index);
        return std::nullopt;
    });
    ErrString err;
    for (size_t i = 0, e = futures.size(); i < e; ++i) {
        auto &future = futures[i];
        auto future_status = future.wait_for(10 * timeout);
        if (future_status == std::future_status::timeout) {
            err += AG_FMT("No response in time for {}", i);
            errlog(logger, "No response in time for {}", i);
            continue;
        }
        auto result = future.get();
        if (result) {
            err += result;
            errlog(logger, "Aborted: {}", *result);
        } else {
            infolog(logger, "Got result from {}", i);
        }
    }
    if (err) {
        ASSERT_FALSE(err) << *err;
    }
}

struct DnsTruncatedTest : UpstreamParamTest<std::string_view> {};

static constexpr std::string_view truncated_test_data[]{
        // AdGuard DNS
        "94.140.14.14:53",
        // Google DNS
        "8.8.8.8:53",
        // See the details here: https://github.com/AdguardTeam/AdGuardHome/issues/524
        // AdGuard DNS (DNSCrypt)
        "sdns://"
        "AQIAAAAAAAAAFDE3Ni4xMDMuMTMwLjEzMDo1NDQzINErR_JS3PLCu_iZEIbq95zkSV2LFsigxDIuUso_"
        "OQhzIjIuZG5zY3J5cHQuZGVmYXVsdC5uczEuYWRndWFyZC5jb20",
};

TEST_P(DnsTruncatedTest, TestDnsTruncated) {
    const auto &address = GetParam();
    auto [upstream, upstream_err] = create_upstream({std::string(address), {}, Secs(5)});
    ASSERT_FALSE(upstream_err) << "Error while creating an upstream: " << *upstream_err;
    auto request = ag::dnscrypt::create_request_ldns_pkt(
            LDNS_RR_TYPE_TXT, LDNS_RR_CLASS_IN, LDNS_RD, "unit-test2.dns.adguard.com.", std::nullopt);
    ldns_pkt_set_random_id(request.get());
    auto [res, err] = upstream->exchange(request.get());
    ASSERT_FALSE(err) << "Error while making a request: " << *err;
    ASSERT_FALSE(ldns_pkt_tc(res.get())) << "Response must NOT be truncated";
}

INSTANTIATE_TEST_SUITE_P(DnsTruncatedTest, DnsTruncatedTest, testing::ValuesIn(truncated_test_data));

struct UpstreamTestData {
    std::string address;
    std::initializer_list<std::string> bootstrap;
    IpAddress server_ip;
};

static const UpstreamTestData test_upstreams_data[]{
        {"tcp://8.8.8.8", {}},
        {"8.8.8.8:53", {"8.8.8.8:53"}},
        {"1.0.0.1", {}},
        {"1.1.1.1", {"1.0.0.1"}},
        {"tcp://1.1.1.1:53", {}},
        {"94.140.14.14:5353", {}},
        {"tls://1.1.1.1", {}},
        {"tls://9.9.9.9:853", {}},
        {"tls://dns.google", {"8.8.8.8:53"}},
        {"tls://dns.google:853", {"8.8.8.8:53"}},
        {"tls://dns.google:853", {"8.8.8.8"}},
        {"tls://one.one.one.one", {"1.0.0.1"}},
        {"https://dns9.quad9.net:443/dns-query", {"8.8.8.8"}},
        {"https://dns.cloudflare.com/dns-query", {"8.8.8.8:53"}},
        {"https://dns.google/dns-query", {"8.8.8.8"}},
        {// AdGuard DNS (DNSCrypt)
                "sdns://"
                "AQIAAAAAAAAAFDE3Ni4xMDMuMTMwLjEzMDo1NDQzINErR_JS3PLCu_iZEIbq95zkSV2LFsigxDIuUso_"
                "OQhzIjIuZG5zY3J5cHQuZGVmYXVsdC5uczEuYWRndWFyZC5jb20",
                {}},
        {// AdGuard Family (DNSCrypt)
                "sdns://"
                "AQIAAAAAAAAAFDE3Ni4xMDMuMTMwLjEzMjo1NDQzILgxXdexS27jIKRw3C7Wsao5jMnlhvhdRUXWuMm1AFq6ITIuZG5zY3J5cHQuZm"
                "FtaWx5Lm5zMS5hZGd1YXJkLmNvbQ",
                {"8.8.8.8"}},
        {// Cloudflare DNS (DoH)
                "sdns://"
                "AgcAAAAAAAAABzEuMC4wLjGgENk8mGSlIfMGXMOlIlCcKvq7AVgcrZxtjon911-ep0cg63Ul-I8NlFj4GplQGb_"
                "TTLiczclX57DvMV8Q-JdjgRgSZG5zLmNsb3VkZmxhcmUuY29tCi9kbnMtcXVlcnk",
                {"8.8.8.8:53"}},
        {// Google (Plain)
                "sdns://AAcAAAAAAAAABzguOC44Ljg", {}},
        {// AdGuard DNS (DNS-over-TLS)
                "sdns://AwAAAAAAAAAAAAAPZG5zLmFkZ3VhcmQuY29t", {"8.8.8.8:53"}},
        {// DoT 1.1.1.1
                "sdns://AwAAAAAAAAAAAAAHMS4xLjEuMQ", {"8.8.8.8:53"}},
        {// Cloudflare DNS
                "https://1.1.1.1/dns-query", {}},
        {// AdGuard DNS (DNS-over-QUIC)
                "quic://dns.adguard.com:8853", {"8.8.8.8:53"}},
        {// AdGuard DNS (DNS-over-QUIC) stamp with only the port specified in server address field
                "sdns://BAAAAAAAAAAABDo3ODQAD2Rucy5hZGd1YXJkLmNvbQ", {"8.8.8.8:53"}},
};

#ifdef __linux__
#include <cstddef>
#include <dirent.h>

int count_open_fds() {
    DIR *dir = opendir("/proc/self/fd");
    if (dir == nullptr) {
        return -1;
    }

    int count = -3; // '.', '..', dir
    while (readdir(dir)) {
        count++;
    }

    (void) closedir(dir);

    return count;
}
#endif /* __linux__ */

TEST_F(UpstreamTest, TestUpstreams) {
#ifdef __linux__
    int fd_count_before = count_open_fds();
#endif
    parallel_test(test_upstreams_data);
#ifdef __linux__
    // If there was fd leak, new fd number will be different.
    int fd_count_after = count_open_fds();
    ASSERT_EQ(fd_count_before, fd_count_after);
#endif
}

static const UpstreamTestData upstream_dot_bootstrap_test_data[]{
        {
                "tls://one.one.one.one/",
                {"tls://1.1.1.1"},
        },
        {
                "tls://one.one.one.one/",
                {"https://1.1.1.1/dns-query"},
        },
        {
                "tls://one.one.one.one/", {"sdns://AwAAAAAAAAAAAAAHMS4xLjEuMQ"}, // DoT 1.1.1.1
        },
        {
                "tls://one.one.one.one/",
                {"sdns://"
                 "AQIAAAAAAAAAFDE3Ni4xMDMuMTMwLjEzMDo1NDQzINErR_JS3PLCu_iZEIbq95zkSV2LFsigxDIuUso_"
                 "OQhzIjIuZG5zY3J5cHQuZGVmYXVsdC5uczEuYWRndWFyZC5jb20"}, // AdGuard DNS (DNSCrypt)
        },
};

TEST_F(UpstreamTest, TestUpstreamDotBootstrap) {
    parallel_test(upstream_dot_bootstrap_test_data);
}

struct UpstreamDefaultOptionsTest : UpstreamParamTest<std::string> {};

static const std::string test_upstream_default_options_data[]{
        "tls://1.1.1.1",
        "8.8.8.8",
};

TEST_P(UpstreamDefaultOptionsTest, TestUpstreamDefaultOptions) {
    const auto &address = GetParam();
    auto [upstream_ptr, upstream_err] = create_upstream({address, {}, DEFAULT_TIMEOUT});
    ASSERT_FALSE(upstream_err) << "Failed to generate upstream from address " << address << ": " << *upstream_err;
    auto err = check_upstream(*upstream_ptr, address);
    ASSERT_FALSE(err) << *err;
}

INSTANTIATE_TEST_SUITE_P(
        UpstreamDefaultOptionsTest, UpstreamDefaultOptionsTest, testing::ValuesIn(test_upstream_default_options_data));

static const UpstreamTestData test_upstreams_invalid_bootstrap_data[]{
        {
                "tls://dns.adguard.com",
                {"1.1.1.1:555", "8.8.8.8:53"},
        },
        {
                "tls://dns.adguard.com:853",
                {"1.0.0.1", "8.8.8.8:535"},
        },
        {
                "https://dns.cloudflare.com/dns-query",
                {"8.8.8.1", "1.0.0.1"},
        },
        {
                "https://dns9.quad9.net:443/dns-query",
                {"1.2.3.4:79", "8.8.8.8:53"},
        },
        {
                // Cloudflare DNS (DoH)
                "sdns://"
                "AgcAAAAAAAAABzEuMC4wLjGgENk8mGSlIfMGXMOlIlCcKvq7AVgcrZxtjon911-ep0cg63Ul-I8NlFj4GplQGb_"
                "TTLiczclX57DvMV8Q-JdjgRgSZG5zLmNsb3VkZmxhcmUuY29tCi9kbnMtcXVlcnk",
                {"8.8.8.8:53", "8.8.8.1:53"},
        },
        {
                // AdGuard DNS (DNS-over-TLS)
                "sdns://AwAAAAAAAAAAAAAPZG5zLmFkZ3VhcmQuY29t",
                {"1.2.3.4:55", "8.8.8.8"},
        },
};

// Test for DoH and DoT upstreams with two bootstraps (only one is valid)
TEST_F(UpstreamTest, TestUpstreamsInvalidBootstrap) {
    parallel_test(test_upstreams_invalid_bootstrap_data);
}

struct UpstreamsWithServerIpTest : UpstreamParamTest<UpstreamTestData> {};

// Use invalid bootstrap to make sure it fails if tries to use it
static const std::initializer_list<std::string> invalid_bootstrap{"1.2.3.4:55"};

static const UpstreamTestData test_upstreams_with_server_ip_data[]{
        {"tls://dns.adguard.com", invalid_bootstrap, Ipv4Address{176, 103, 130, 130}},
        {"https://dns.adguard.com/dns-query", invalid_bootstrap, Ipv4Address{176, 103, 130, 130}},
        {// AdGuard DNS DOH with the IP address specified
                "sdns://AgcAAAAAAAAADzE3Ni4xMDMuMTMwLjEzMAAPZG5zLmFkZ3VhcmQuY29tCi9kbnMtcXVlcnk", invalid_bootstrap,
                {}},
        {// AdGuard DNS DOT with the IP address specified
                "sdns://AwAAAAAAAAAAEzE3Ni4xMDMuMTMwLjEzMDo4NTMAD2Rucy5hZGd1YXJkLmNvbQ", invalid_bootstrap, {}},
};

TEST_F(UpstreamTest, TestUpstreamsWithServerIp) {
    parallel_test(test_upstreams_with_server_ip_data);
}

struct DeadProxySuccess : UpstreamParamTest<std::tuple<std::string, OutboundProxySettings>> {};

#ifdef _WIN32
// On Windows connections to the dead proxy time out instead of being refused
TEST_P(DeadProxySuccess, DISABLED_test) {
#else
TEST_P(DeadProxySuccess, test) {
#endif
    auto oproxy = std::make_unique<OutboundProxySettings>(std::get<1>(GetParam()));
    make_upstream_factory(oproxy.get());
    auto [upstream_ptr, err] = create_upstream({std::get<0>(GetParam()), {"8.8.8.8"}, DEFAULT_TIMEOUT});
    ASSERT_FALSE(err.has_value()) << err.value();
    err = check_upstream(*upstream_ptr, std::get<0>(GetParam()));
    ASSERT_FALSE(err.has_value()) << err.value();
}

INSTANTIATE_TEST_SUITE_P(TcpOnlyProxy, DeadProxySuccess,
        ::testing::Combine(
                ::testing::Values("tcp://8.8.8.8", "tls://dns.adguard.com", "https://dns.adguard.com/dns-query"),
                ::testing::Values(OutboundProxySettings{OutboundProxyProtocol::HTTP_CONNECT, "127.0.0.1", 42,
                                          std::nullopt, false, true},
                        OutboundProxySettings{
                                OutboundProxyProtocol::HTTPS_CONNECT, "127.0.0.1", 42, std::nullopt, false, true},
                        OutboundProxySettings{
                                OutboundProxyProtocol::SOCKS4, "127.0.0.1", 42, std::nullopt, false, true},
                        OutboundProxySettings{
                                OutboundProxyProtocol::SOCKS5, "127.0.0.1", 42, std::nullopt, false, true})));

INSTANTIATE_TEST_SUITE_P(TcpUdpProxy, DeadProxySuccess,
        ::testing::Combine(::testing::Values("8.8.8.8",
                                   "sdns://"
                                   "AQIAAAAAAAAAFDE3Ni4xMDMuMTMwLjEzMDo1NDQzINErR_JS3PLCu_iZEIbq95zkSV2LFsigxDIuUso_"
                                   "OQhzIjIuZG5zY3J5cHQuZGVmYXVsdC5uczEuYWRndWFyZC5jb20",
                                   "quic://dns.adguard.com:8853"),
                ::testing::Values(OutboundProxySettings{
                        OutboundProxyProtocol::SOCKS5_UDP, "127.0.0.1", 42, std::nullopt, false, true})));

struct DeadProxyFailure : UpstreamParamTest<std::tuple<std::string, OutboundProxySettings>> {};
#ifdef _WIN32
// On Windows connections to the dead proxy time out instead of being refused
TEST_P(DeadProxyFailure, DISABLED_FailedExchange) {
#else
TEST_P(DeadProxyFailure, FailedExchange) {
#endif
    auto oproxy = std::make_unique<OutboundProxySettings>(std::get<1>(GetParam()));
    make_upstream_factory(oproxy.get());
    auto [upstream_ptr, err] = create_upstream({std::get<0>(GetParam()), {"8.8.8.8"}, DEFAULT_TIMEOUT});
    ASSERT_FALSE(err.has_value()) << err.value();
    err = check_upstream(*upstream_ptr, std::get<0>(GetParam()));
    ASSERT_TRUE(err.has_value());
}

INSTANTIATE_TEST_SUITE_P(TcpOnlyProxy, DeadProxyFailure,
        ::testing::Combine(
                ::testing::Values("tcp://8.8.8.8", "tls://dns.adguard.com", "https://dns.adguard.com/dns-query"),
                ::testing::Values(OutboundProxySettings{OutboundProxyProtocol::HTTP_CONNECT, "127.0.0.1", 42},
                        OutboundProxySettings{OutboundProxyProtocol::HTTPS_CONNECT, "127.0.0.1", 42},
                        OutboundProxySettings{OutboundProxyProtocol::SOCKS4, "127.0.0.1", 42},
                        OutboundProxySettings{OutboundProxyProtocol::SOCKS5, "127.0.0.1", 42})));

INSTANTIATE_TEST_SUITE_P(UdpProxy, DeadProxyFailure,
        ::testing::Combine(::testing::Values("8.8.8.8",
                                   "sdns://"
                                   "AQIAAAAAAAAAFDE3Ni4xMDMuMTMwLjEzMDo1NDQzINErR_JS3PLCu_iZEIbq95zkSV2LFsigxDIuUso_"
                                   "OQhzIjIuZG5zY3J5cHQuZGVmYXVsdC5uczEuYWRndWFyZC5jb20",
                                   "quic://dns.adguard.com:8853"),
                ::testing::Values(OutboundProxySettings{OutboundProxyProtocol::SOCKS5_UDP, "127.0.0.1", 42})));

TEST_F(UpstreamTest, DISABLED_ConcurrentRequests) {
    using namespace std::chrono_literals;
    using namespace concat_err_string;
    static constexpr size_t REQUESTS_NUM = 128;
    static constexpr size_t WORKERS_NUM = 16;
    static const UpstreamOptions opts{
            .address = "https://dns.cloudflare.com/dns-query",
            //        .address = "quic://dns.adguard.com:8853", // Uncomment for test DOQ upstream
            .bootstrap = {"8.8.8.8", "1.1.1.1"},
            .timeout = 5s,
            //        .resolved_server_ip = IPV4_ADDRESS_SIZE{104, 19, 199, 29}, // Uncomment for test this server IP
            //        .resolved_server_ip = IPV6_ADDRESS_SIZE{0x26, 0x06, 0x47, 0x00, 0x30, 0x0a, 0x00, 0x00, 0x00,
            //        0x00, 0x00, 0x00, 0x68, 0x13, 0xc7, 0x1d},  // Uncomment for test this server IP
    };
    auto [upstream_ptr, upstream_err] = create_upstream(opts);
    ASSERT_FALSE(upstream_err) << *upstream_err;
    parallel_test_basic_n(WORKERS_NUM, [upstream = upstream_ptr.get()](size_t i) -> ErrString {
        ErrString result_err;
        for (size_t j = 0; j < REQUESTS_NUM; ++j) {
            ag::ldns_pkt_ptr pkt = create_test_message();
            auto [reply, reply_err] = upstream->exchange(pkt.get());
            if (reply_err) {
                result_err += AG_FMT("Upstream i = {} reply error: {}", i, *reply_err);
                continue;
            }
            if (!reply) {
                result_err += "Upstream reply is null";
                continue;
            }
            result_err += assert_response(*reply);
        }
        return result_err;
    });
}

TEST_F(UpstreamTest, DISABLED_doq_easy_test) {
    for (int i = 0; i < 1000; ++i) {
        using namespace std::chrono_literals;
        using namespace concat_err_string;
        static const UpstreamOptions opts{
                .address = "quic://dns.adguard.com:8853", .bootstrap = {"8.8.8.8"}, .timeout = 5s};
        auto [upstream_ptr, upstream_err] = create_upstream(opts);
        ASSERT_FALSE(upstream_err) << *upstream_err;

        ag::ldns_pkt_ptr pkt = create_test_message();

        auto [reply, reply_err] = upstream_ptr.get()->exchange(pkt.get());
        ASSERT_FALSE(reply_err.has_value()) << *reply_err;
        ASSERT_NE(reply, nullptr);
    }
}

} // namespace ag::upstream::test
