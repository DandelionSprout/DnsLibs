#pragma once

#include <stdint.h>
#include <stddef.h>
#include <stdbool.h>

#ifdef _WIN32
#  define AG_EXPORT extern __declspec(dllexport)
#elif defined(__GNUC__)
#  define AG_EXPORT __attribute__ ((visibility("default")))
#else
#  define AG_EXPORT
#endif

#define ARRAY_OF(T) struct { T *data; uint32_t size; }

#ifdef __cplusplus
extern "C" {
#endif

//
// Public types
//

typedef enum {
    AGLL_ERR,
    AGLL_WARN,
    AGLL_INFO,
    AGLL_DEBUG,
    AGLL_TRACE,
} ag_log_level;

typedef ARRAY_OF(uint8_t) ag_buffer;

typedef struct {
    /**
     * Server address, one of the following kinds:
     *     8.8.8.8:53 -- plain DNS (must specify IP address, not hostname)
     *     tcp://8.8.8.8:53 -- plain DNS over TCP (must specify IP address, not hostname)
     *     tls://dns.adguard.com -- DNS-over-TLS
     *     https://dns.adguard.com/dns-query -- DNS-over-HTTPS
     *     sdns://... -- DNS stamp (see https://dnscrypt.info/stamps-specifications)
     *     quic://dns.adguard.com:853 -- DNS-over-QUIC
     */
    const char *address;

    /** List of plain DNS servers to be used to resolve the hostname in upstreams's address. */
    ARRAY_OF(const char *) bootstrap;

    /** Timeout, 0 means "default" */
    uint32_t timeout_ms;

    /** Upstream's IP address. If specified, the bootstrapper is NOT used. */
    ag_buffer resolved_ip_address;

    /** User-provided ID for this upstream */
    int32_t id;

    /** Index of the network interface to route traffic through, 0 is default */
    uint32_t outbound_interface_index;
} ag_upstream_options;

typedef struct {
    /** The upstreams to use for discovery of DNS64 prefixes (usually the system DNS servers) */
    ARRAY_OF(ag_upstream_options) upstreams;

    /** How many times, at most, to try DNS64 prefixes discovery before giving up */
    uint32_t max_tries;

    /** How long to wait before a dns64 prefixes discovery attempt */
    uint32_t wait_time_ms;
} ag_dns64_settings;

typedef enum {
    AGLP_UDP,
    AGLP_TCP
} ag_listener_protocol;

/**
 * Specifies how to respond to blocked requests.
 *
 * A request is blocked if it matches a blocking AdBlock-style rule,
 * or a blocking hosts-style rule. A blocking hosts-style rule is
 * a hosts-style rule with a loopback or all-zeroes address.
 *
 * Requests matching a hosts-style rule with an address that is
 * neither loopback nor all-zeroes are always responded
 * with the address specified by the rule.
 */
typedef enum {
    /** Respond with REFUSED response code */
    AGBM_REFUSED,
    /** Respond with NXDOMAIN response code */
    AGBM_NXDOMAIN,
    /**
     * Respond with an address that is all-zeroes, or
     * a custom blocking address, if it is specified, or
     * an empty SOA response if request type is not A/AAAA.
     */
    AGBM_ADDRESS,
} ag_dnsproxy_blocking_mode;

typedef struct {
    /** The address to listen on */
    const char *address;

    /** The port to listen on */
    uint16_t port;

    /** The protocol to listen for */
    ag_listener_protocol protocol;

    /** If true, don't close the TCP connection after sending the first response */
    bool persistent;

    /** Close the TCP connection this long after the last request received */
    uint32_t idle_timeout_ms;
} ag_listener_settings;

typedef enum {
    /** Plain HTTP proxy */
    AGOPP_HTTP_CONNECT,

    /** HTTPs proxy */
    AGOPP_HTTPS_CONNECT,

    /** Socks4 proxy */
    AGOPP_SOCKS4,

    /** Socks5 proxy without UDP support */
    AGOPP_SOCKS5,

    /** Socks5 proxy with UDP support */
    AGOPP_SOCKS5_UDP,
} ag_outbound_proxy_protocol;

typedef struct {
    const char *username;
    const char *password;
} ag_outbound_proxy_auth_info;

typedef struct {
    /** The proxy protocol */
    ag_outbound_proxy_protocol protocol;

    /** The proxy server IP address or hostname */
    const char *address;

    /** The proxy server port */
    uint16_t port;

    /**
     * List of the DNS server URLs to be used to resolve a hostname in the proxy server address.
     * The URLs MUST contain the resolved server addresses, not hostnames.
     * E.g. `https://94.140.14.14` is correct, while `dns.adguard.com:53` is not.
     * MUST NOT be empty in case the `address` is a hostname.
     */
    ARRAY_OF(const char *) bootstrap;

    /** The authentication information */
    ag_outbound_proxy_auth_info *auth_info;

    /** If true and the proxy connection is secure, the certificate won't be verified */
    bool trust_any_certificate;

    /**
     * Whether the DNS proxy should ignore the outbound proxy and route queries directly
     * to target hosts even if it's determined as unavailable
     */
    bool ignore_if_unavailable;
} ag_outbound_proxy_settings;

typedef struct {
    /** Filter ID */
    int32_t id;
    /** Path to the filter list file or string with rules, depending on value of in_memory */
    const char *data;
    /** If true, data is rules, otherwise data is path to file with rules */
    bool in_memory;
} ag_filter_params;

typedef struct {
    ARRAY_OF(ag_filter_params) filters;
} ag_filter_engine_params;

typedef struct {
    /** List of upstreams */
    ARRAY_OF(ag_upstream_options) upstreams;
    /** List of fallback upstreams, which will be used if none of the usual upstreams respond */
    ARRAY_OF(ag_upstream_options) fallbacks;
    /**
     * Requests for these domains will be forwarded directly to the fallback upstreams, if there are any.
     * A wildcard character, `*`, which stands for any number of characters, is allowed to appear multiple
     * times anywhere except at the end of the domain (which implies that a domain consisting only of
     * wildcard characters is invalid).
     */
    ARRAY_OF(const char *) fallback_domains;
    /** (Optional) DNS64 prefix discovery settings */
    ag_dns64_settings *dns64;
    /** TTL of a blocking response */
    uint32_t blocked_response_ttl_secs;
    /** Filtering engine parameters */
    ag_filter_engine_params filter_params;
    /** List of listener parameters */
    ARRAY_OF(ag_listener_settings) listeners;
    /** Outbound proxy settings */
    ag_outbound_proxy_settings *outbound_proxy;
    /** If true, all AAAA requests will be blocked */
    bool block_ipv6;
    /** If true, the bootstrappers are allowed to fetch AAAA records */
    bool ipv6_available;
    /** How to respond to requests blocked by AdBlock-style rules */
    ag_dnsproxy_blocking_mode adblock_rules_blocking_mode;
    /** How to respond to requests blocked by hosts-style rules */
    ag_dnsproxy_blocking_mode hosts_rules_blocking_mode;
    /** Custom IPv4 address to return for filtered requests */
    const char *custom_blocking_ipv4;
    /** Custom IPv6 address to return for filtered requests */
    const char *custom_blocking_ipv6;
    /** Maximum number of cached responses (may be 0) */
    uint32_t dns_cache_size;
    /** Enable optimistic DNS caching */
    bool optimistic_cache;
    /**
     * Enable DNSSEC OK extension.
     * This options tells server that we want to receive DNSSEC records along with normal queries.
     * If they exist, request processed event will have DNSSEC flag on.
     * WARNING: may increase data usage and probability of TCP fallbacks.
     */
    bool enable_dnssec_ok;
    /** If enabled, detect retransmitted requests and handle them using fallback upstreams only */
    bool enable_retransmission_handling;
    /** If enabled, strip Encrypted Client Hello parameters from responses. */
    bool block_ech;
    /** If true, all upstreams are queried in parallel, and the first response is returned. */
    bool enable_parallel_upstream_queries;
    /**
     * If true, normal queries will be forwarded to fallback upstreams if all normal upstreams failed.
     * Otherwise, fallback upstreams will only be used to resolve domains from `fallback_domains`.
     */
    bool enable_fallback_on_upstreams_failure;
    /**
     * If true, when all upstreams (including fallback upstreams) fail to provide a response,
     * the proxy will respond with a SERVFAIL packet. Otherwise, no response is sent on such a failure.
     */
    bool enable_servfail_on_upstreams_failure;
    /** Enable HTTP/3 for DNS-over-HTTPS upstreams if it's able to connect quicker. */
    bool enable_http3;
} ag_dnsproxy_settings;

typedef struct {
    /** Queried domain name */
    const char *domain;
    /** Query type */
    const char *type;
    /** Processing start time, in milliseconds since UNIX epoch */
    int64_t start_time;
    /** Time spent on processing */
    int32_t elapsed;
    /** DNS reply status */
    const char *status;
    /** A string representation of the DNS reply sent */
    const char *answer;
    /** A string representation of the original upstream's DNS reply (present when blocked by CNAME) */
    const char *original_answer;
    /** ID of the upstream that provided this answer */
    const int32_t *upstream_id;
    /** Number of bytes sent to the upstream */
    int32_t bytes_sent;
    /** Number of bytes received from the upstream */
    int32_t bytes_received;
    /** List of matched rules (full rule text) */
    ARRAY_OF(const char *) rules;
    /** Corresponding filter ID for each matched rule */
    ARRAY_OF(const int32_t) filter_list_ids;
    /** True if the matched rule is a whitelist rule */
    bool whitelist;
    /** If not NULL, contains the error description */
    const char *error;
    /** True if this response was served from the cache */
    bool cache_hit;
    /** True if this response has DNSSEC rrsig */
    bool dnssec;
} ag_dns_request_processed_event;

typedef struct {
    /** Leaf certificate */
    ag_buffer certificate;
    /** Certificate chain */
    ARRAY_OF(ag_buffer) chain;
} ag_certificate_verification_event;

/** Called synchronously right after a request has been processed, but before a response is returned. */
typedef void (*ag_dns_request_processed_cb)(const ag_dns_request_processed_event *);

typedef enum {
    AGCVR_OK,

    AGCVR_ERROR_CREATE_CERT,
    AGCVR_ERROR_ACCESS_TO_STORE,
    AGCVR_ERROR_CERT_VERIFICATION,

    AGCVR_COUNT
} ag_certificate_verification_result;

/** Called synchronously when a certificate needs to be verified */
typedef ag_certificate_verification_result (*ag_certificate_verification_cb)(const ag_certificate_verification_event *);

/**
 * Called when we need to log a message.
 * The message is already formatted, including the line terminator.
 */
typedef void (*ag_log_cb)(void *attachment, ag_log_level level, const char *message, uint32_t length);

typedef struct {
    ag_dns_request_processed_cb on_request_processed;
    ag_certificate_verification_cb on_certificate_verification;
} ag_dnsproxy_events;

typedef enum {
    AGSPT_PLAIN,
    AGSPT_DNSCRYPT,
    AGSPT_DOH,
    AGSPT_TLS,
    AGSPT_DOQ,
} ag_stamp_proto_type;

typedef enum {
    /** Resolver does DNSSEC validation */
    AGSIP_DNSSEC = 1 << 0,
    /** Resolver does not record logs */
    AGSIP_NO_LOG = 1 << 1,
    /** Resolver doesn't intentionally block domains */
    AGSIP_NO_FILTER = 1 << 2,
} ag_server_informal_properties;

typedef struct {
    /** Protocol */
    ag_stamp_proto_type proto;
    /** IP address and/or port */
    const char *server_addr;
    /**
     * Provider means different things depending on the stamp type
     * DNSCrypt: the DNSCrypt provider name
     * DOH and DOT: server's hostname
     * Plain DNS: not specified
     */
    const char *provider_name;
    /** (For DoH) absolute URI path, such as /dns-query */
    const char *path;
    /** The DNSCrypt provider’s Ed25519 public key, as 32 raw bytes. Empty for other types. */
    ag_buffer server_public_key;
    /**
     * Hash is the SHA256 digest of one of the TBS certificate found in the validation chain, typically
     * the certificate used to sign the resolver’s certificate. Multiple hashes can be provided for seamless
     * rotations.
     */
    ARRAY_OF(ag_buffer) hashes;
    /** Server properties */
    ag_server_informal_properties properties;
} ag_dns_stamp;

typedef void ag_dns_rule_template;

typedef enum {
    AGRGO_IMPORTANT = 1 << 0, /**< Add $important modifier. */
    AGRGO_DNSTYPE = 1 << 1, /**< Add $dnstype modifier. */
} ag_rule_generation_options;

typedef struct {
    ARRAY_OF(const ag_dns_rule_template *) templates; /**< A set of rule templates. */
    uint32_t allowed_options;                         /**< Options that are allowed to be passed to `generate_rule`. */
    uint32_t required_options; /**< Options that are required for the generated rule to be correct. */
    bool blocking;             /**< Whether something will be blocked or un-blocked as a result of this action. */
} ag_dns_filtering_log_action;

typedef enum {
    AGDPIR_PROXY_NOT_SET,
    AGDPIR_EVENT_LOOP_NOT_SET,
    AGDPIR_INVALID_ADDRESS,
    AGDPIR_EMPTY_PROXY,
    AGDPIR_PROTOCOL_ERROR,
    AGDPIR_LISTENER_INIT_ERROR,
    AGDPIR_INVALID_IPV4,
    AGDPIR_INVALID_IPV6,
    AGDPIR_UPSTREAM_INIT_ERROR,
    AGDPIR_FALLBACK_FILTER_INIT_ERROR,
    AGDPIR_FILTER_LOAD_ERROR,
    AGDPIR_MEM_LIMIT_REACHED,
    AGDPIR_NON_UNIQUE_FILTER_ID,
    AGDPIR_OK,
} ag_dnsproxy_init_result;

//
// API functions
//

typedef void ag_dnsproxy;

/**
 * Initialize and start a proxy.
 * @param out_result upon return, contains the result of the operation
 * @param out_message upon return, contains the error or warning message, or is unchanged
 * @return a proxy handle, or NULL in case of an error
 */
AG_EXPORT ag_dnsproxy *ag_dnsproxy_init(const ag_dnsproxy_settings *settings, const ag_dnsproxy_events *events,
                                        ag_dnsproxy_init_result *out_result, const char **out_message);

/**
 * Stop and destroy a proxy.
 * @param proxy a proxy handle
 */
AG_EXPORT void ag_dnsproxy_deinit(ag_dnsproxy *proxy);

/**
 * Process a DNS message and return the response.
 * The caller is responsible for freeing both buffers with `ag_buffer_free()`.
 * @param message a DNS request in wire format
 * @return a DNS response in wire format
 */
AG_EXPORT ag_buffer ag_dnsproxy_handle_message(ag_dnsproxy *proxy, ag_buffer message);

/**
 * Return the current proxy settings. The caller is responsible for freeing
 * the returned pointer with `ag_dnsproxy_settings_free()`.
 * @return the current proxy settings
 */
AG_EXPORT ag_dnsproxy_settings *ag_dnsproxy_get_settings(ag_dnsproxy *proxy);

/**
 * Return the default proxy settings. The caller is responsible for freeing
 * the returned pointer with `ag_dnsproxy_settings_free()`.
 * @return the default proxy settings
 */
AG_EXPORT ag_dnsproxy_settings *ag_dnsproxy_settings_get_default();

/**
 * Free a dnsproxy_settings pointer.
 */
AG_EXPORT void ag_dnsproxy_settings_free(ag_dnsproxy_settings *settings);

/**
 * Free a buffer.
 */
AG_EXPORT void ag_buffer_free(ag_buffer buf);

/**
 * Set the log verbosity level.
 */
AG_EXPORT void ag_set_log_level(ag_log_level level);

/**
 * Set the logging function.
 * @param attachment an argument to the logging function
 */
AG_EXPORT void ag_set_log_callback(ag_log_cb callback, void *attachment);

/**
 * Parse a DNS stamp string. The caller is responsible for freeing
 * the result with `ag_parse_dns_stamp_result_free()`.
 * @param stamp_str "sdns://..." string
 * @param error on output, if an error occurred, contains the error description (free with `ag_str_free()`)
 * @return a parsed stamp, or NULL if an error occurred.
 */
AG_EXPORT ag_dns_stamp *ag_dns_stamp_from_str(const char *stamp_str, const char **error);

/**
 * Free a ag_parse_dns_stamp_result pointer.
 */
AG_EXPORT void ag_dns_stamp_free(ag_dns_stamp *stamp);

/**
 * Convert a DNS stamp to "sdns://..." string.
 * Free the string with `ag_str_free()`
 */
AG_EXPORT const char *ag_dns_stamp_to_str(ag_dns_stamp *stamp);

/**
 * Convert a DNS stamp to string that can be used as an upstream URL.
 * Free the string with `ag_str_free()`
 */
AG_EXPORT const char *ag_dns_stamp_pretty_url(ag_dns_stamp *stamp);

/**
 * Convert a DNS stamp to string that can NOT be used as an upstream URL, but may be prettier.
 * Free the string with `ag_str_free()`
 */
AG_EXPORT const char *ag_dns_stamp_prettier_url(ag_dns_stamp *stamp);

/**
 * Check if an upstream is valid and working.
 * The caller is responsible for freeing the result with `ag_str_free()`.
 * @param ipv6_available whether IPv6 is available, if true, bootstrapper is allowed to make AAAA queries
 * @param offline Don't perform online upstream check
 * @return NULL if everything is ok, or
 *         an error message.
 */
AG_EXPORT const char *ag_test_upstream(const ag_upstream_options *upstream, bool ipv6_available,
                                       ag_certificate_verification_cb on_certificate_verification, bool offline);

/**
 * Check if string is a valid rule
 */
AG_EXPORT bool ag_is_valid_dns_rule(const char *str);

/**
 * Return the C API version (hash of this file).
 */
AG_EXPORT const char *ag_get_capi_version();

/**
 * Return the DNS proxy library version.
 * Do NOT free the returned string.
 */
AG_EXPORT const char *ag_dnsproxy_version();

/**
 * Free a string.
 */
AG_EXPORT void ag_str_free(const char *str);

#ifdef _WIN32
/**
 * Disable the SetUnhandledExceptionFilter function.
 */
AG_EXPORT void ag_disable_SetUnhandledExceptionFilter(void);

/**
 * Enable the SetUnhandledExceptionFilter function.
 */
AG_EXPORT void ag_enable_SetUnhandledExceptionFilter(void);
#endif

/**
 * Suggest an action based on filtering log event.
 * @return NULL on error. Action freed with `ag_dns_filtering_log_action_free()` on success.
 */
AG_EXPORT ag_dns_filtering_log_action *ag_dns_filtering_log_action_from_event(
        const ag_dns_request_processed_event *event);

/**
 * Free an action.
 */
AG_EXPORT void ag_dns_filtering_log_action_free(ag_dns_filtering_log_action *action);

/**
 * Generate a rule from a template (obtained from `ag_dns_filtering_log_action`) and a corresponding event.
 * @return NULL on error. Rule freed with `ag_str_free()` on success.
 */
AG_EXPORT char *ag_dns_generate_rule_with_options(
        const ag_dns_rule_template *tmplt, const ag_dns_request_processed_event *event, uint32_t options);

#ifdef __cplusplus
} // extern "C"
#endif
