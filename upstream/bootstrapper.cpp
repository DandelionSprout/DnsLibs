#include <algorithm>
#include <cassert>

#include "common/utils.h"
#include "dnsstamp/dns_stamp.h"

#include "bootstrapper.h"

#define log_addr(l_, lvl_, addr_, fmt_, ...) lvl_##log(l_, "[{}] " fmt_, addr_, ##__VA_ARGS__)

namespace ag {

using std::chrono::duration_cast;

static constexpr int64_t RESOLVE_TRYING_INTERVAL_MS = 7000;
static constexpr int64_t TEMPORARY_DISABLE_INTERVAL_MS = 7000;

// For each resolver a half of time out is given for a try. If one fails, it's moved to the end
// of the list to give it a chance in the future.
//
// Note: in case of success MUST always return vector of addresses in address field of result
Bootstrapper::ResolveResult Bootstrapper::resolve() {
    if (SocketAddress addr(m_server_name, m_server_port); addr.valid()) {
        return {{addr}, m_server_name, Millis(0), std::nullopt};
    }

    if (m_resolvers.empty()) {
        return {{}, m_server_name, Millis(0), "Empty bootstrap list"};
    }

    HashSet<SocketAddress> addrs;
    utils::Timer whole_resolve_timer;
    Millis timeout = m_timeout;
    ErrString error;

    for (size_t tried = 0, failed = 0, curr = 0; tried < m_resolvers.size(); ++tried, curr = tried - failed) {
        const ResolverPtr &resolver = m_resolvers[curr];
        utils::Timer single_resolve_timer;
        Millis try_timeout = std::max(timeout / 2, Resolver::MIN_TIMEOUT);
        Resolver::Result result = resolver->resolve(m_server_name, m_server_port, try_timeout);
        if (result.error.has_value()) {
            log_addr(m_log, dbg, m_server_name, "Failed to resolve host: {}", result.error.value());
            std::rotate(m_resolvers.begin() + curr, m_resolvers.begin() + curr + 1, m_resolvers.end());
            ++failed;
            if (addrs.empty()) {
                error = AG_FMT("{}{}\n", error.has_value() ? error.value() : "", result.error.value());
            }
        } else {
            std::move(result.addresses.begin(), result.addresses.end(), std::inserter(addrs, addrs.begin()));
            error.reset();
            break;
        }
        timeout -= single_resolve_timer.elapsed<Millis>();
        if (timeout <= Resolver::MIN_TIMEOUT) {
            log_addr(m_log, dbg, m_server_name, "Stop resolving loop as timeout reached ({})", m_timeout);
            break;
        }
    }

    if (m_log.is_enabled(LogLevel::LOG_LEVEL_DEBUG)) {
        for (const SocketAddress &a : addrs) {
            log_addr(m_log, dbg, m_server_name, "Resolved address: {}", a.str());
        }
    }

    auto elapsed = whole_resolve_timer.elapsed<Millis>();

    std::vector<SocketAddress> addresses(std::move_iterator(addrs.begin()), std::move_iterator(addrs.end()));
    return {std::move(addresses), m_server_name, elapsed, std::move(error)};
}

ErrString Bootstrapper::temporary_disabler_check() {
    using namespace std::chrono;
    if (m_resolve_fail_times_ms.first) {
        if (int64_t tries_timeout_ms = m_resolve_fail_times_ms.first + RESOLVE_TRYING_INTERVAL_MS;
                m_resolve_fail_times_ms.second > tries_timeout_ms) {
            auto now_ms = duration_cast<Millis>(steady_clock::now().time_since_epoch()).count();
            if (int64_t disabled_for_ms = now_ms - tries_timeout_ms,
                    remaining_ms = TEMPORARY_DISABLE_INTERVAL_MS - disabled_for_ms;
                    remaining_ms > 0) {
                return AG_FMT("Bootstrapping this server is disabled for {}ms, too many failures", remaining_ms);
            } else {
                m_resolve_fail_times_ms.first = 0;
            }
        }
    }
    return std::nullopt;
}

void Bootstrapper::temporary_disabler_update(const ErrString &error) {
    using namespace std::chrono;
    if (error) {
        auto now_ms = duration_cast<Millis>(steady_clock::now().time_since_epoch()).count();
        m_resolve_fail_times_ms.second = now_ms;
        if (!m_resolve_fail_times_ms.first) {
            m_resolve_fail_times_ms.first = m_resolve_fail_times_ms.second;
        }
    } else {
        m_resolve_fail_times_ms.first = 0;
    }
}

Bootstrapper::ResolveResult Bootstrapper::get() {
    std::scoped_lock l(m_resolved_cache_mutex);
    if (!m_resolved_cache.empty()) {
        return {m_resolved_cache, m_server_name, Millis(0), std::nullopt};
    } else if (auto error = temporary_disabler_check()) {
        return {{}, m_server_name, Millis(0), error};
    }

    ResolveResult result = resolve();
    assert(result.error.has_value() == result.addresses.empty());
    temporary_disabler_update(result.error);
    m_resolved_cache = result.addresses;
    return result;
}

void Bootstrapper::remove_resolved(const SocketAddress &addr) {
    std::scoped_lock l(m_resolved_cache_mutex);
    m_resolved_cache.erase(std::remove(m_resolved_cache.begin(), m_resolved_cache.end(), addr), m_resolved_cache.end());
}

static std::vector<ResolverPtr> create_resolvers(const Logger &log, const Bootstrapper::Params &p) {
    std::vector<ResolverPtr> resolvers;
    resolvers.reserve(p.bootstrap.size());

    UpstreamOptions opts{};
    opts.outbound_interface = p.outbound_interface;
    for (const std::string &server : p.bootstrap) {
        if (!p.upstream_config.ipv6_available && SocketAddress(ag::utils::split_host_port(server).first, 0).is_ipv6()) {
            continue;
        }
        opts.address = server;
        ResolverPtr resolver = std::make_unique<Resolver>(opts, p.upstream_config);
        if (ErrString err = resolver->init(); !err.has_value()) {
            resolvers.emplace_back(std::move(resolver));
        } else {
            log_addr(log, warn, p.address_string, "Failed to create resolver '{}': {}", server, err.value());
        }
    }

    if (p.bootstrap.empty() && !ag::utils::str_to_socket_address(p.address_string).valid()) {
        log_addr(log, warn, p.address_string, "Got empty or invalid list of servers for bootstrapping");
    }

    return resolvers;
}

Bootstrapper::Bootstrapper(const Params &p)
        : m_log(__func__)
        , m_timeout(p.timeout)
        , m_resolvers(create_resolvers(m_log, p)) {
    auto [host, port] = utils::split_host_port(p.address_string);
    m_server_port = std::strtol(std::string(port).c_str(), nullptr, 10);
    if (m_server_port == 0) {
        m_server_port = p.default_port;
    }
    m_server_name = host;
}

ErrString Bootstrapper::init() {
    if (m_resolvers.empty() && !SocketAddress(m_server_name, m_server_port).valid()) {
        return "Failed to create any resolver";
    }

    return std::nullopt;
}

std::string Bootstrapper::address() const {
    return AG_FMT("{}:{}", m_server_name, m_server_port);
}

} // namespace ag