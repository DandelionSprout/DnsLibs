#import "AGDnsProxy.h"
#import <TargetConditionals.h>
#if !TARGET_OS_IPHONE
#import "NSTask+AGTimeout.h"
#endif

#include <sys/socket.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <resolv.h>
#include <poll.h>
#include <cassert>
#include <optional>
#include <string>

#include "common/logger.h"
#include <dnsproxy.h>
#include <upstream_utils.h>
#include "common/cesu8.h"


static constexpr size_t FILTER_PARAMS_MEM_LIMIT_BYTES = 8 * 1024 * 1024;

static constexpr int BINDFD_WAIT_MS = 10000;

/**
 * @param str an STL string
 * @return an NSString converted from the C++ string
 */
static NSString *convert_string(const std::string &str) {
    return @(ag::utf8_to_cesu8(str).c_str());
}

NSErrorDomain const AGDnsProxyErrorDomain = @"com.adguard.dnsproxy";

@implementation AGLogger
+ (void) setLevel: (AGLogLevel) level
{
    ag::Logger::set_log_level((ag::LogLevel)level);
}

+ (void) setCallback: (logCallback) func
{
    ag::Logger::set_callback([func](ag::LogLevel level, std::string_view message) mutable {
        func((AGLogLevel) level, message.data(), message.size());
    });
}
@end


#pragma pack(push,1)
struct iphdr {
#if BYTE_ORDER == LITTLE_ENDIAN
    u_int   ip_hl:4;        /* header length */
    u_int   ip_v:4;         /* version */
#endif
#if BYTE_ORDER == BIG_ENDIAN
    u_int   ip_v:4;         /* version */
    u_int   ip_hl:4;        /* header length */
#endif
    uint8_t ip_tos;         /* type of service */
    uint16_t    ip_len;         /* total length */
    uint16_t    ip_id;          /* identification */
    uint16_t    ip_off;         /* fragment offset field */
    uint8_t ip_ttl;         /* time to live */
    uint8_t ip_p;           /* protocol */
    uint16_t    ip_sum;         /* checksum */
    struct  in_addr ip_src;
    struct  in_addr ip_dst; /* source and dest address */
};

struct udphdr {
    uint16_t    uh_sport;       /* source port */
    uint16_t    uh_dport;       /* destination port */
    uint16_t    uh_ulen;        /* udp length */
    uint16_t    uh_sum;         /* udp checksum */
};

// Home-made IPv6 header struct
struct iphdr6 {
#if BYTE_ORDER == LITTLE_ENDIAN
    uint32_t ip6_unused:28;    /* traffic class and flow label */
    uint32_t ip6_v:4;          /* version (constant 0x6) */
#endif
#if BYTE_ORDER == BIG_ENDIAN
    uint32_t ip6_v:4;          /* version (constant 0x6) */
    uint32_t ip6_unused:28;    /* traffic class and flow label */
#endif
    uint16_t ip6_pl;    /* payload length */
    uint8_t ip6_nh;     /* next header (same as protocol) */
    uint8_t ip6_hl;     /* hop limit */
    in6_addr_t ip6_src; /* source address */
    in6_addr_t ip6_dst; /* destination address */
};
#pragma pack(pop)

static uint16_t ip_checksum(const void *ip_header, uint32_t header_length) {
    uint32_t checksum = 0;
    const uint16_t *data = (uint16_t *)ip_header;
    while (header_length > 1) {
        checksum += *data;
        data++;
        header_length -= 2;
    }
    if (header_length > 0) {
        checksum += *(uint8_t*)data;
    }

    checksum = (checksum >> 16) + (checksum & 0xffff);
    checksum = (checksum >> 16) + (checksum & 0xffff);

    return (uint16_t) (~checksum & 0xffff);
}

// Compute sum of buf as if it is a vector of uint16_t, padding with zeroes at the end if needed
static uint16_t checksum(const void *buf, size_t len, uint32_t sum) {
    uint32_t i;
    for (i = 0; i < (len & ~1U); i += 2) {
        sum += (uint16_t)ntohs(*((uint16_t *)((uint8_t*)buf + i)));
        if (sum > 0xFFFF) {
            sum -= 0xFFFF;
        }
    }

    if (i < len) {
        sum += ((uint8_t*)buf)[i] << 8;
        if (sum > 0xFFFF) {
            sum -= 0xFFFF;
        }
    }

    return (uint16_t) sum;
}

static uint16_t udp_checksum(const struct iphdr *ip_header, const struct udphdr *udp_header,
        const void *buf, size_t len) {
    uint16_t sum = ip_header->ip_p + ntohs(udp_header->uh_ulen);
    sum = checksum(&ip_header->ip_src, 2 * sizeof(ip_header->ip_src), sum);
    sum = checksum(buf, len, sum);
    sum = checksum(udp_header, sizeof(*udp_header), sum);
    // 0xffff should be transmitted as is
    if (sum != 0xffff) {
        sum = ~sum;
    }
    return htons(sum);
}

static uint16_t udp_checksum_v6(const struct iphdr6 *ip6_header,
                                const struct udphdr *udp_header,
                                const void *buf, size_t len) {
    uint16_t sum = ip6_header->ip6_nh + ntohs(udp_header->uh_ulen);
    sum = checksum(&ip6_header->ip6_src, 2 * sizeof(ip6_header->ip6_src), sum);
    sum = checksum(buf, len, sum);
    sum = checksum(udp_header, sizeof(*udp_header), sum);
    // 0xffff should be transmitted as is
    if (sum != 0xffff) {
        sum = ~sum;
    }
    return htons(sum);
}

static NSData *create_response_packet(const struct iphdr *ip_header, const struct udphdr *udp_header,
        const std::vector<uint8_t> &payload) {
    struct udphdr reverse_udp_header = {};
    reverse_udp_header.uh_sport = udp_header->uh_dport;
    reverse_udp_header.uh_dport = udp_header->uh_sport;
    reverse_udp_header.uh_ulen = htons(sizeof(reverse_udp_header) + payload.size());

    struct iphdr reverse_ip_header = {};
    reverse_ip_header.ip_v = ip_header->ip_v;
    reverse_ip_header.ip_hl = 5; // ip header without options
    reverse_ip_header.ip_tos = ip_header->ip_tos;
    reverse_ip_header.ip_len = htons(ntohs(reverse_udp_header.uh_ulen) + reverse_ip_header.ip_hl * 4);
    reverse_ip_header.ip_id = ip_header->ip_id;
    reverse_ip_header.ip_ttl = ip_header->ip_ttl;
    reverse_ip_header.ip_p = ip_header->ip_p;
    reverse_ip_header.ip_src = ip_header->ip_dst;
    reverse_ip_header.ip_dst = ip_header->ip_src;

    reverse_ip_header.ip_sum = ip_checksum(&reverse_ip_header, sizeof(reverse_ip_header));
    reverse_udp_header.uh_sum = udp_checksum(&reverse_ip_header, &reverse_udp_header,
        payload.data(), payload.size());

    NSMutableData *reverse_packet = [[NSMutableData alloc] initWithCapacity: reverse_ip_header.ip_len];
    [reverse_packet appendBytes: &reverse_ip_header length: sizeof(reverse_ip_header)];
    [reverse_packet appendBytes: &reverse_udp_header length: sizeof(reverse_udp_header)];
    [reverse_packet appendBytes: payload.data() length: payload.size()];

    return reverse_packet;
}

static NSData *create_response_packet_v6(const struct iphdr6 *ip6_header,
                                         const struct udphdr *udp_header,
                                         const std::vector<uint8_t> &payload) {
    struct udphdr resp_udp_header = {};
    resp_udp_header.uh_sport = udp_header->uh_dport;
    resp_udp_header.uh_dport = udp_header->uh_sport;
    resp_udp_header.uh_ulen = htons(sizeof(resp_udp_header) + payload.size());

    struct iphdr6 resp_ip6_header = *ip6_header;
    resp_ip6_header.ip6_src = ip6_header->ip6_dst;
    resp_ip6_header.ip6_dst = ip6_header->ip6_src;
    resp_ip6_header.ip6_pl = resp_udp_header.uh_ulen;

    resp_udp_header.uh_sum = udp_checksum_v6(&resp_ip6_header, &resp_udp_header,
                                             payload.data(), payload.size());

    NSUInteger packet_length = sizeof(resp_ip6_header) + resp_ip6_header.ip6_pl;
    NSMutableData *response_packet = [[NSMutableData alloc] initWithCapacity: packet_length];
    [response_packet appendBytes: &resp_ip6_header length: sizeof(resp_ip6_header)];
    [response_packet appendBytes: &resp_udp_header length: sizeof(resp_udp_header)];
    [response_packet appendBytes: payload.data() length: payload.size()];

    return response_packet;
}

static ag::server_stamp convert_stamp(AGDnsStamp *stamp) {
    ag::server_stamp native{};
    native.proto = (ag::stamp_proto_type) stamp.proto;
    if (stamp.serverAddr) {
        native.server_addr_str = stamp.serverAddr.UTF8String;
    }
    if (stamp.providerName) {
        native.provider_name = stamp.providerName.UTF8String;
    }
    if (stamp.path) {
        native.path = stamp.path.UTF8String;
    }
    if (auto *pubkey = stamp.serverPublicKey; pubkey) {
        native.server_pk.assign((uint8_t *) pubkey.bytes, (uint8_t *) pubkey.bytes + pubkey.length);
    }
    if (stamp.hashes) {
        for (NSData *hash in stamp.hashes) {
            native.hashes.emplace_back((uint8_t *) hash.bytes, (uint8_t *) hash.bytes + hash.length);
        }
    }
    uint64_t props = 0;
    if (stamp.dnssec) {
        props |= ag::DNSSEC;
    }
    if (stamp.noFilter) {
        props |= ag::NO_FILTER;
    }
    if (stamp.noLog) {
        props |= ag::NO_LOG;
    }
    native.props = (ag::server_informal_properties) props;
    return native;
}

@implementation AGDnsUpstream
- (instancetype) initWithNative: (const ag::upstream_options *) settings
{
    self = [super init];
    _address = convert_string(settings->address);
    _id = settings->id;
    NSMutableArray<NSString *> *bootstrap =
        [[NSMutableArray alloc] initWithCapacity: settings->bootstrap.size()];
    for (const std::string &server : settings->bootstrap) {
        [bootstrap addObject: convert_string(server)];
    }
    _bootstrap = bootstrap;
    _timeoutMs = settings->timeout.count();
    if (const std::string *name = std::get_if<std::string>(&settings->outbound_interface)) {
        _outboundInterfaceName = convert_string(*name);
    }
    return self;
}

- (instancetype) initWithAddress: (NSString *) address
        bootstrap: (NSArray<NSString *> *) bootstrap
        timeoutMs: (NSInteger) timeoutMs
        serverIp: (NSData *) serverIp
        id: (NSInteger) id
        outboundInterfaceName: (NSString *) outboundInterfaceName
{
    self = [super init];
    _address = address;
    _bootstrap = bootstrap;
    _timeoutMs = timeoutMs;
    _serverIp = serverIp;
    _id = id;
    _outboundInterfaceName = outboundInterfaceName;
    return self;
}

- (instancetype)initWithCoder:(NSCoder *)coder {
    self = [super init];
    if (self) {
        _address = [coder decodeObjectForKey:@"_address"];
        _bootstrap = [coder decodeObjectForKey:@"_bootstrap"];
        _timeoutMs = [coder decodeInt64ForKey:@"_timeoutMs"];
        _serverIp = [coder decodeObjectForKey:@"_serverIp"];
        _id = [coder decodeInt64ForKey:@"_id"];
        _outboundInterfaceName = [coder decodeObjectForKey:@"_outboundInterfaceName"];
    }

    return self;
}

- (void)encodeWithCoder:(NSCoder *)coder {
    [coder encodeObject:self.address forKey:@"_address"];
    [coder encodeObject:self.bootstrap forKey:@"_bootstrap"];
    [coder encodeInt64:self.timeoutMs forKey:@"_timeoutMs"];
    [coder encodeObject:self.serverIp forKey:@"_serverIp"];
    [coder encodeInt64:self.id forKey:@"_id"];
    [coder encodeObject:self.outboundInterfaceName forKey:@"_outboundInterfaceName"];
}

- (NSString*)description {
    return [NSString stringWithFormat:
            @"[(%p)AGDnsUpstream: address=%@, bootstrap=(%@), timeoutMs=%ld, serverIp=%@, id=%ld]",
            self, _address, [_bootstrap componentsJoinedByString:@", "], _timeoutMs, [[NSString alloc] initWithData:_serverIp encoding:NSUTF8StringEncoding], _id];
}

@end

@implementation AGDns64Settings
- (instancetype) initWithNative: (const ag::dns64_settings *) settings
{
    self = [super init];
    NSMutableArray<AGDnsUpstream *> *upstreams = [[NSMutableArray alloc] initWithCapacity: settings->upstreams.size()];
    for (auto &us : settings->upstreams) {
        [upstreams addObject: [[AGDnsUpstream alloc] initWithNative: &us]];
    }
    _upstreams = upstreams;
    _maxTries = settings->max_tries;
    _waitTimeMs = settings->wait_time.count();
    return self;
}

- (instancetype) initWithUpstreams: (NSArray<AGDnsUpstream *> *) upstreams
                          maxTries: (NSInteger) maxTries waitTimeMs: (NSInteger) waitTimeMs
{
    self = [super init];
    _upstreams = upstreams;
    _maxTries = maxTries;
    _waitTimeMs = waitTimeMs;
    return self;
}

- (instancetype)initWithCoder:(NSCoder *)coder {
    self = [super init];
    if (self) {
        _upstreams = [coder decodeObjectForKey:@"_upstreams"];
        _maxTries = [coder decodeInt64ForKey:@"_maxTries"];
        _waitTimeMs = [coder decodeInt64ForKey:@"_waitTimeMs"];
    }

    return self;
}

- (void)encodeWithCoder:(NSCoder *)coder {
    [coder encodeObject:self.upstreams forKey:@"_upstreams"];
    [coder encodeInt64:self.maxTries forKey:@"_maxTries"];
    [coder encodeInt64:self.waitTimeMs forKey:@"_waitTimeMs"];
}

- (NSString*)description {
    return [NSString stringWithFormat:
            @"[(%p)AGDns64Settings: waitTimeMs=%ld, upstreams=%@]",
            self, _waitTimeMs, _upstreams];
}

@end

@implementation AGListenerSettings
- (instancetype)initWithNative:(const ag::listener_settings *)settings
{
    self = [super init];
    _address = convert_string(settings->address);
    _port = settings->port;
    _proto = (AGListenerProtocol) settings->protocol;
    _persistent = settings->persistent;
    _idleTimeoutMs = settings->idle_timeout.count();
    return self;
}

- (instancetype)initWithAddress:(NSString *)address
                           port:(NSInteger)port
                          proto:(AGListenerProtocol)proto
                     persistent:(BOOL)persistent
                  idleTimeoutMs:(NSInteger)idleTimeoutMs
{
    self = [super init];
    _address = address;
    _port = port;
    _proto = proto;
    _persistent = persistent;
    _idleTimeoutMs = idleTimeoutMs;
    return self;
}

- (instancetype)initWithCoder:(NSCoder *)coder {
    self = [super init];
    if (self) {
        _address = [coder decodeObjectForKey:@"_address"];
        _port = [coder decodeInt64ForKey:@"_port"];
        _proto = (AGListenerProtocol) [coder decodeIntForKey:@"_proto"];
        _persistent = [coder decodeBoolForKey:@"_persistent"];
        _idleTimeoutMs = [coder decodeInt64ForKey:@"_idleTimeoutMs"];
    }

    return self;
}

- (void)encodeWithCoder:(NSCoder *)coder {
    [coder encodeObject:self.address forKey:@"_address"];
    [coder encodeInt64:self.port forKey:@"_port"];
    [coder encodeInt:self.proto forKey:@"_proto"];
    [coder encodeBool:self.persistent forKey:@"_persistent"];
    [coder encodeInt64:self.idleTimeoutMs forKey:@"_idleTimeoutMs"];
}

- (NSString*)description {
    return [NSString stringWithFormat:
            @"[(%p)AGListenerSettings: address=%@, port=%ld, proto=%ld]",
            self, _address, _port, _proto];
}

@end

@implementation AGOutboundProxyAuthInfo
- (instancetype) initWithUsername: (NSString *)username
                         password: (NSString *)password
{
    self = [super init];
    if (self) {
        _username = username;
        _password = password;
    }
    return self;
}

- (instancetype) initWithNative: (const ag::outbound_proxy_auth_info *)info
{
    self = [super init];
    if (self) {
        _username = convert_string(info->username);
        _password = convert_string(info->password);
    }
    return self;
}

- (instancetype) initWithCoder: (NSCoder *)coder
{
    self = [super init];
    if (self) {
        _username = [coder decodeObjectForKey:@"_username"];
        _password = [coder decodeObjectForKey:@"_password"];
    }
    return self;
}

- (void)encodeWithCoder:(NSCoder *)coder
{
    [coder encodeObject:self.username forKey:@"_username"];
    [coder encodeObject:self.password forKey:@"_password"];
}

- (NSString*)description {
    return [NSString stringWithFormat:@"[(%p)AGOutboundProxyAuthInfo: username=%@]", self, _username];
}

@end

@implementation AGOutboundProxySettings
- (instancetype) initWithProtocol: (AGOutboundProxyProtocol)protocol
                          address: (NSString *)address
                             port: (NSInteger)port
                         authInfo: (AGOutboundProxyAuthInfo *)authInfo
              trustAnyCertificate: (BOOL)trustAnyCertificate
{
    self = [super init];
    if (self) {
        _protocol = protocol;
        _address = address;
        _port = port;
        _authInfo = authInfo;
        _trustAnyCertificate = trustAnyCertificate;
    }
    return self;
}

- (instancetype) initWithNative: (const ag::outbound_proxy_settings *)settings
{
    self = [super init];
    if (self) {
        _protocol = (AGOutboundProxyProtocol)settings->protocol;
        _address = convert_string(settings->address);
        _port = settings->port;
        if (settings->auth_info.has_value()) {
            _authInfo = [[AGOutboundProxyAuthInfo alloc] initWithNative: &settings->auth_info.value()];
        }
        _trustAnyCertificate = settings->trust_any_certificate;
    }
    return self;
}

- (instancetype) initWithCoder: (NSCoder *)coder
{
    self = [super init];
    if (self) {
        _protocol = (AGOutboundProxyProtocol)[coder decodeIntForKey:@"_protocol"];
        _address = [coder decodeObjectForKey:@"_address"];
        _port = [coder decodeInt64ForKey:@"_port"];
        _authInfo = [coder decodeObjectForKey:@"_authInfo"];
        _trustAnyCertificate = [coder decodeBoolForKey:@"_trustAnyCertificate"];
    }
    return self;
}

- (void) encodeWithCoder: (NSCoder *)coder
{
    [coder encodeInt:self.protocol forKey:@"_protocol"];
    [coder encodeObject:self.address forKey:@"_address"];
    [coder encodeInt64:self.port forKey:@"_port"];
    [coder encodeObject:self.authInfo forKey:@"_authInfo"];
    [coder encodeBool:self.trustAnyCertificate forKey:@"_trustAnyCertificate"];
}

- (NSString*)description {
    return [NSString stringWithFormat:
            @"[(%p)AGOutboundProxySettings: protocol=%ld, address=%@, port=%ld, authInfo=%@, trustAnyCertificate=%@]",
            self, _protocol, _address, _port, _authInfo, _trustAnyCertificate ? @"YES" : @"NO"];
}

@end

@implementation AGDnsFilterParams
- (instancetype) initWithId:(NSInteger)id
                       data:(NSString *)data
                   inMemory:(BOOL)inMemory
{
    self = [super init];
    if (self) {
        _id = id;
        _data = data;
        _inMemory = inMemory;
    }
    return self;
}

- (instancetype)initWithCoder:(NSCoder *)coder {
    self = [super init];
    if (self) {
        _id = [coder decodeInt64ForKey:@"_id"];
        _data = [coder decodeObjectForKey:@"_data"];
        _inMemory = [coder decodeBoolForKey:@"_inMemory"];
    }

    return self;
}

- (void)encodeWithCoder:(NSCoder *)coder {
    [coder encodeInt64:self.id forKey:@"_id"];
    [coder encodeObject:self.data forKey:@"_data"];
    [coder encodeBool:self.inMemory forKey:@"_inMemory"];
}

- (NSString*)description {
    return [NSString stringWithFormat:@"[(%p)AGDnsFilterParams: id=%ld]", self, _id];
}

@end

@implementation AGDnsProxyConfig

- (instancetype) initWithNative: (const ag::dnsproxy_settings *) settings
{
    self = [super init];
    NSMutableArray<AGDnsUpstream *> *upstreams =
        [[NSMutableArray alloc] initWithCapacity: settings->upstreams.size()];
    for (const ag::upstream_options &us : settings->upstreams) {
        [upstreams addObject: [[AGDnsUpstream alloc] initWithNative: &us]];
    }
    _upstreams = upstreams;
    NSMutableArray<AGDnsUpstream *> *fallbacks =
            [[NSMutableArray alloc] initWithCapacity: settings->fallbacks.size()];
    for (const ag::upstream_options &us : settings->fallbacks) {
        [fallbacks addObject: [[AGDnsUpstream alloc] initWithNative: &us]];
    }
    _fallbacks = fallbacks;
    NSMutableArray<NSString *> *fallbackDomains =
            [[NSMutableArray alloc] initWithCapacity: settings->fallback_domains.size()];
    for (auto &domain : settings->fallback_domains) {
        [fallbackDomains addObject: convert_string(domain)];
    }
    _fallbackDomains = fallbackDomains;
    _filters = nil;
    _blockedResponseTtlSecs = settings->blocked_response_ttl_secs;
    if (settings->dns64.has_value()) {
        _dns64Settings = [[AGDns64Settings alloc] initWithNative: &settings->dns64.value()];
    }
    NSMutableArray<AGListenerSettings *> *listeners =
            [[NSMutableArray alloc] initWithCapacity: settings->listeners.size()];
    for (const ag::listener_settings &ls : settings->listeners) {
        [listeners addObject: [[AGListenerSettings alloc] initWithNative: &ls]];
    }
    _listeners = listeners;
    if (settings->outbound_proxy.has_value()) {
        _outboundProxy = [[AGOutboundProxySettings alloc] initWithNative: &settings->outbound_proxy.value()];
    }
    _ipv6Available = settings->ipv6_available;
    _blockIpv6 = settings->block_ipv6;
    _adblockRulesBlockingMode = (AGBlockingMode) settings->adblock_rules_blocking_mode;
    _hostsRulesBlockingMode = (AGBlockingMode) settings->hosts_rules_blocking_mode;
    _customBlockingIpv4 = convert_string(settings->custom_blocking_ipv4);
    _customBlockingIpv6 = convert_string(settings->custom_blocking_ipv6);
    _dnsCacheSize = settings->dns_cache_size;
    _optimisticCache = settings->optimistic_cache;
    _enableDNSSECOK = settings->enable_dnssec_ok;
    return self;
}

- (instancetype) initWithUpstreams: (NSArray<AGDnsUpstream *> *) upstreams
        fallbacks: (NSArray<AGDnsUpstream *> *) fallbacks
        fallbackDomains: (NSArray<NSString *> *) fallbackDomains
        detectSearchDomains: (BOOL) detectSearchDomains
        filters: (NSArray<AGDnsFilterParams *> *) filters
        blockedResponseTtlSecs: (NSInteger) blockedResponseTtlSecs
        dns64Settings: (AGDns64Settings *) dns64Settings
        listeners: (NSArray<AGListenerSettings *> *) listeners
        outboundProxy: (AGOutboundProxySettings *) outboundProxy
        ipv6Available: (BOOL) ipv6Available
        blockIpv6: (BOOL) blockIpv6
        adblockRulesBlockingMode: (AGBlockingMode) adblockRulesBlockingMode
        hostsRulesBlockingMode: (AGBlockingMode) hostsRulesBlockingMode
        customBlockingIpv4: (NSString *) customBlockingIpv4
        customBlockingIpv6: (NSString *) customBlockingIpv6
        dnsCacheSize: (NSUInteger) dnsCacheSize
        optimisticCache: (BOOL) optimisticCache
        enableDNSSECOK: (BOOL) enableDNSSECOK
        enableRetransmissionHandling: (BOOL) enableRetransmissionHandling
        helperPath: (NSString *) helperPath
{
    const ag::dnsproxy_settings &defaultSettings = ag::dnsproxy_settings::get_default();
    self = [self initWithNative: &defaultSettings];
    if (upstreams != nil) {
        _upstreams = upstreams;
    }
    _fallbacks = fallbacks;
    _fallbackDomains = fallbackDomains;
    _detectSearchDomains = detectSearchDomains;
    _filters = filters;
    if (blockedResponseTtlSecs != 0) {
        _blockedResponseTtlSecs = blockedResponseTtlSecs;
    }
    _dns64Settings = dns64Settings;
    _listeners = listeners;
    _outboundProxy = outboundProxy;
    _ipv6Available = ipv6Available;
    _blockIpv6 = blockIpv6;
    _adblockRulesBlockingMode = adblockRulesBlockingMode;
    _hostsRulesBlockingMode = hostsRulesBlockingMode;
    _customBlockingIpv4 = customBlockingIpv4;
    _customBlockingIpv6 = customBlockingIpv6;
    _dnsCacheSize = dnsCacheSize;
    _optimisticCache = optimisticCache;
    _enableDNSSECOK = enableDNSSECOK;
    _helperPath = helperPath;
    _enableRetransmissionHandling = enableRetransmissionHandling;
    return self;
}

- (instancetype)initWithCoder:(NSCoder *)coder {
    self = [super init];
    if (self) {
        _upstreams = [coder decodeObjectForKey:@"_upstreams"];
        _fallbacks = [coder decodeObjectForKey:@"_fallbacks"];
        _fallbackDomains = [coder decodeObjectForKey:@"_fallbackDomains"];
        _detectSearchDomains = [coder decodeBoolForKey:@"_detectSearchDomains"];
        _filters = [coder decodeObjectForKey:@"_filters"];
        _blockedResponseTtlSecs = [coder decodeInt64ForKey:@"_blockedResponseTtlSecs"];
        _dns64Settings = [coder decodeObjectForKey:@"_dns64Settings"];
        _listeners = [coder decodeObjectForKey:@"_listeners"];
        _outboundProxy = [coder decodeObjectForKey:@"_outboundProxy"];
        _ipv6Available = [coder decodeBoolForKey:@"_ipv6Available"];
        _blockIpv6 = [coder decodeBoolForKey:@"_blockIpv6"];
        _adblockRulesBlockingMode = (AGBlockingMode) [coder decodeIntForKey:@"_adblockRulesBlockingMode"];
        _hostsRulesBlockingMode = (AGBlockingMode) [coder decodeIntForKey:@"_hostsRulesBlockingMode"];
        _customBlockingIpv4 = [coder decodeObjectForKey:@"_customBlockingIpv4"];
        _customBlockingIpv6 = [coder decodeObjectForKey:@"_customBlockingIpv6"];
        _dnsCacheSize = [coder decodeInt64ForKey:@"_dnsCacheSize"];
        _optimisticCache = [coder decodeBoolForKey:@"_optimisticCache"];
        _enableDNSSECOK = [coder decodeBoolForKey:@"_enableDNSSECOK"];
        _enableRetransmissionHandling = [coder decodeBoolForKey:@"_enableRetransmissionHandling"];
        _helperPath = [coder decodeObjectForKey:@"_helperPath"];
    }

    return self;
}

- (void)encodeWithCoder:(NSCoder *)coder {
    [coder encodeObject:self.upstreams forKey:@"_upstreams"];
    [coder encodeObject:self.fallbacks forKey:@"_fallbacks"];
    [coder encodeObject:self.fallbackDomains forKey:@"_fallbackDomains"];
    [coder encodeBool:self.detectSearchDomains forKey:@"_detectSearchDomains"];
    [coder encodeObject:self.filters forKey:@"_filters"];
    [coder encodeInt64:self.blockedResponseTtlSecs forKey:@"_blockedResponseTtlSecs"];
    [coder encodeObject:self.dns64Settings forKey:@"_dns64Settings"];
    [coder encodeObject:self.listeners forKey:@"_listeners"];
    [coder encodeObject:self.outboundProxy forKey:@"_outboundProxy"];
    [coder encodeBool:self.ipv6Available forKey:@"_ipv6Available"];
    [coder encodeBool:self.blockIpv6 forKey:@"_blockIpv6"];
    [coder encodeInt:self.adblockRulesBlockingMode forKey:@"_adblockRulesBlockingMode"];
    [coder encodeInt:self.hostsRulesBlockingMode forKey:@"_hostsRulesBlockingMode"];
    [coder encodeObject:self.customBlockingIpv4 forKey:@"_customBlockingIpv4"];
    [coder encodeObject:self.customBlockingIpv6 forKey:@"_customBlockingIpv6"];
    [coder encodeInt64:self.dnsCacheSize forKey:@"_dnsCacheSize"];
    [coder encodeBool:self.optimisticCache forKey:@"_optimisticCache"];
    [coder encodeBool:self.enableDNSSECOK forKey:@"_enableDNSSECOK"];
    [coder encodeBool:self.enableRetransmissionHandling forKey:@"_enableRetransmissionHandling"];
    [coder encodeObject:self.helperPath forKey:@"_helperPath"];
}

- (NSString*)description {
    return [NSString stringWithFormat:@"[(%p)AGDnsProxyConfig:\n"
            "ipv6Available=%@,\n"
            "blockIpv6=%@,\n"
            "adblockRulesBlockingMode=%ld,\n"
            "hostsRulesBlockingMode=%ld,\n"
            "customBlockingIpv4=%@,\n"
            "customBlockingIpv6=%@,\n"
            "enableDNSSECOK=%@,\n"
            "enableRetransmissionHandling=%@,\n"
            "detectSearchDomains=%@,\n"
            "outboundProxy=%@,\n"
            "upstreams=%@,\n"
            "fallbacks=%@,\n"
            "fallbackDomains=%@,\n"
            "filters=%@,\n"
            "dns64Settings=%@,\n"
            "listeners=%@]",
            self, _ipv6Available ? @"YES" : @"NO", _blockIpv6 ? @"YES" : @"NO", _adblockRulesBlockingMode, _hostsRulesBlockingMode, _customBlockingIpv4,
            _customBlockingIpv6, _enableDNSSECOK ? @"YES" : @"NO", _enableRetransmissionHandling ? @"YES" : @"NO", _detectSearchDomains ? @"YES" : @"NO",
            _outboundProxy, _upstreams, _fallbacks, _fallbackDomains, _filters, _dns64Settings, _listeners];
}

+ (instancetype) getDefault
{
    const ag::dnsproxy_settings &defaultSettings = ag::dnsproxy_settings::get_default();
    return [[AGDnsProxyConfig alloc] initWithNative: &defaultSettings];
}
@end

@implementation AGDnsRequestProcessedEvent
- (instancetype) init: (const ag::dns_request_processed_event &)event
{
    _domain = convert_string(event.domain);
    _type = convert_string(event.type);
    _startTime = event.start_time;
    _elapsed = event.elapsed;
    _status = convert_string(event.status);
    _answer = convert_string(event.answer);
    _originalAnswer = convert_string(event.original_answer);
    _upstreamId = event.upstream_id ? [NSNumber numberWithInt:*event.upstream_id] : nil;
    _bytesSent = event.bytes_sent;
    _bytesReceived = event.bytes_received;

    NSMutableArray<NSString *> *rules =
        [[NSMutableArray alloc] initWithCapacity: event.rules.size()];
    NSMutableArray<NSNumber *> *filterListIds =
        [[NSMutableArray alloc] initWithCapacity: event.rules.size()];
    for (size_t i = 0; i < event.rules.size(); ++i) {
        [rules addObject: convert_string(event.rules[i])];
        [filterListIds addObject: [NSNumber numberWithInt: event.filter_list_ids[i]]];
    }
    _rules = rules;
    _filterListIds = filterListIds;

    _whitelist = event.whitelist;
    _error = convert_string(event.error);

    _cacheHit = event.cache_hit;

    _dnssec = event.dnssec;

    return self;
}

- (instancetype)initWithCoder:(NSCoder *)coder {
    self = [super init];
    if (self) {
        _domain = [coder decodeObjectForKey:@"_domain"];
        _type = [coder decodeObjectForKey:@"_type"];
        _startTime = [coder decodeInt64ForKey:@"_startTime"];
        _elapsed = [coder decodeInt64ForKey:@"_elapsed"];
        _status = [coder decodeObjectForKey:@"_status"];
        _answer = [coder decodeObjectForKey:@"_answer"];
        _originalAnswer = [coder decodeObjectForKey:@"_originalAnswer"];
        _upstreamId = [coder decodeObjectForKey:@"_upstreamId"];
        _bytesSent = [coder decodeInt64ForKey:@"_bytesSent"];
        _bytesReceived = [coder decodeInt64ForKey:@"_bytesReceived"];
        _rules = [coder decodeObjectForKey:@"_rules"];
        _filterListIds = [coder decodeObjectForKey:@"_filterListIds"];
        _whitelist = [coder decodeBoolForKey:@"_whitelist"];
        _error = [coder decodeObjectForKey:@"_error"];
        _cacheHit = [coder decodeBoolForKey:@"_cacheHit"];
        _dnssec = [coder decodeBoolForKey:@"_dnssec"];
    }

    return self;
}

- (void)encodeWithCoder:(NSCoder *)coder {
    [coder encodeObject:self.domain forKey:@"_domain"];
    [coder encodeObject:self.type forKey:@"_type"];
    [coder encodeInt64:self.startTime forKey:@"_startTime"];
    [coder encodeInt64:self.elapsed forKey:@"_elapsed"];
    [coder encodeObject:self.status forKey:@"_status"];
    [coder encodeObject:self.answer forKey:@"_answer"];
    [coder encodeObject:self.originalAnswer forKey:@"_originalAnswer"];
    [coder encodeObject:self.upstreamId forKey:@"_upstreamId"];
    [coder encodeInt64:self.bytesSent forKey:@"_bytesSent"];
    [coder encodeInt64:self.bytesReceived forKey:@"_bytesReceived"];
    [coder encodeObject:self.rules forKey:@"_rules"];
    [coder encodeObject:self.filterListIds forKey:@"_filterListIds"];
    [coder encodeBool:self.whitelist forKey:@"_whitelist"];
    [coder encodeObject:self.error forKey:@"_error"];
    [coder encodeBool:self.cacheHit forKey:@"_cacheHit"];
    [coder encodeBool:self.dnssec forKey:@"_dnssec"];
}

- (NSString*)description {
    return [NSString stringWithFormat:
            @"[(%p)AGDnsRequestProcessedEvent: domain=%@, "
            "type=%@, "
            "status=%@, "
            "answer=%@, "
            "originalAnswer=%@, "
            "upstreamId=%@, "
            "filterListIds=%@, "
            "whitelist=%@, "
            "error=%@, "
            "cacheHit=%@, "
            "dnssec=%@]",
            self, _domain, _type, _status, _answer, _originalAnswer, _upstreamId, _filterListIds,
            _whitelist ? @"YES" : @"NO", _error, _cacheHit ? @"YES" : @"NO", _dnssec ? @"YES" : @"NO"];
}

@end

@implementation AGDnsProxyEvents
@end

@implementation AGDnsProxy {
    ag::dnsproxy proxy;
    std::optional<ag::Logger> log;
    AGDnsProxyEvents *events;
    dispatch_queue_t queue;
    BOOL initialized;
}

- (void)dealloc
{
    if (initialized) {
        @throw [NSException exceptionWithName:@"Illegal state"
                                       reason:@"AGDnsProxy was not stopped before dealloc"
                                     userInfo:nil];
    }
}

- (void)stop {
    if (initialized) {
        self->proxy.deinit();
        initialized = NO;
    }
}

static SecCertificateRef convertCertificate(const std::vector<uint8_t> &cert) {
    NSData *data = [NSData dataWithBytesNoCopy: (void *)cert.data() length: cert.size() freeWhenDone: NO];
    CFDataRef certRef = (__bridge CFDataRef)data;
    return SecCertificateCreateWithData(NULL, (CFDataRef)certRef);
}

static std::string getTrustCreationErrorStr(OSStatus status) {
#if !TARGET_OS_IPHONE || (IOS_VERSION_MAJOR >= 11 && IOS_VERSION_MINOR >= 3)
    auto *err = (__bridge_transfer NSString *) SecCopyErrorMessageString(status, NULL);
    return [err UTF8String];
#else
    return AG_FMT("Failed to create trust object from chain: {}", status);
#endif
}

template <typename T>
using AGUniqueCFRef = ag::UniquePtr<std::remove_pointer_t<T>, &CFRelease>;

+ (std::optional<std::string>) verifyCertificate: (ag::certificate_verification_event *) event log: (ag::Logger &) log
{
    tracelog(log, "[Verification] App callback");

    NSMutableArray *trustArray = [[NSMutableArray alloc] initWithCapacity: event->chain.size() + 1];

    SecCertificateRef cert = convertCertificate(event->certificate);
    if (!cert) {
        dbglog(log, "[Verification] Failed to create certificate object");
        return "Failed to create certificate object";
    }
    [trustArray addObject:(__bridge_transfer id) cert];

    for (const auto &chainCert : event->chain) {
        cert = convertCertificate(chainCert);
        if (!cert) {
            dbglog(log, "[Verification] Failed to create certificate object");
            return "Failed to create certificate object";
        }
        [trustArray addObject:(__bridge_transfer id) cert];
    }

    AGUniqueCFRef<SecPolicyRef> policy{SecPolicyCreateBasicX509()};
    SecTrustRef trust;
    OSStatus status = SecTrustCreateWithCertificates((__bridge CFTypeRef) trustArray, policy.get(), &trust);

    if (status != errSecSuccess) {
        std::string err = getTrustCreationErrorStr(status);
        dbglog(log, "[Verification] Failed to create trust object from chain: {}", err);
        return err;
    }

    AGUniqueCFRef<SecTrustRef> trustRef{trust};

    SecTrustSetAnchorCertificates(trust, NULL);
    SecTrustSetAnchorCertificatesOnly(trust, NO);
    SecTrustResultType trustResult;
    SecTrustEvaluate(trust, &trustResult);

    // https://developer.apple.com/documentation/security/sectrustresulttype/ksectrustresultunspecified?language=objc
    // This value indicates that evaluation reached an (implicitly trusted) anchor certificate without
    // any evaluation failures, but never encountered any explicitly stated user-trust preference.
    if (trustResult == kSecTrustResultUnspecified || trustResult == kSecTrustResultProceed) {
        dbglog(log, "[Verification] Succeeded");
        return std::nullopt;
    }

    std::string errStr;
    switch (trustResult) {
    case kSecTrustResultDeny:
        errStr = "The user specified that the certificate should not be trusted";
        break;
    case kSecTrustResultRecoverableTrustFailure:
        errStr = "Trust is denied, but recovery may be possible";
        break;
    case kSecTrustResultFatalTrustFailure:
        errStr = "Trust is denied and no simple fix is available";
        break;
    case kSecTrustResultOtherError:
        errStr = "A value that indicates a failure other than trust evaluation";
        break;
    case kSecTrustResultInvalid:
        errStr = "An indication of an invalid setting or result";
        break;
    default:
        errStr = AG_FMT("Unknown error code: {}", trustResult);
        break;
    }

    dbglog(log, "[Verification] Failed to verify: {}", errStr);
    return errStr;
}

static ag::upstream_options convert_upstream(AGDnsUpstream *upstream) {
    std::vector<std::string> bootstrap;
    if (upstream.bootstrap != nil) {
        bootstrap.reserve([upstream.bootstrap count]);
        for (NSString *server in upstream.bootstrap) {
            bootstrap.emplace_back([server UTF8String]);
        }
    }
    ag::IpAddress addr;
    if (upstream.serverIp != nil && [upstream.serverIp length] == 4) {
        addr.emplace<ag::Uint8Array<4>>();
        std::memcpy(std::get<ag::Uint8Array<4>>(addr).data(),
                    [upstream.serverIp bytes], [upstream.serverIp length]);
    } else if (upstream.serverIp != nil && [upstream.serverIp length] == 16) {
        addr.emplace<ag::Uint8Array<16>>();
        std::memcpy(std::get<ag::Uint8Array<16>>(addr).data(),
                    [upstream.serverIp bytes], [upstream.serverIp length]);
    }
    ag::IfIdVariant iface;
    if (upstream.outboundInterfaceName != nil) {
        iface.emplace<std::string>(upstream.outboundInterfaceName.UTF8String);
    }
    return ag::upstream_options{[upstream.address UTF8String],
                                std::move(bootstrap),
                                std::chrono::milliseconds(upstream.timeoutMs),
                                std::move(addr),
                                (int32_t) upstream.id,
                                std::move(iface)};
}

static std::vector<ag::upstream_options> convert_upstreams(NSArray<AGDnsUpstream *> *upstreams) {
    std::vector<ag::upstream_options> converted;
    if (upstreams != nil) {
        converted.reserve([upstreams count]);
        for (AGDnsUpstream *upstream in upstreams) {
            converted.emplace_back(convert_upstream(upstream));
        }
    }
    return converted;
}

static void append_search_domains(std::vector<std::string> &fallback_domains) {
    struct __res_state resState = {0};
    res_ninit(&resState);
    for (int i = 0; i < MAXDNSRCH; ++i) {
        if (resState.dnsrch[i]) {
            std::string_view search_domain = resState.dnsrch[i];
            if (!search_domain.empty() && search_domain.back() == '.') {
                search_domain.remove_suffix(1);
            }
            if (!search_domain.empty() && search_domain.front() == '.') {
                search_domain.remove_prefix(1);
            }
            if (!search_domain.empty()) {
                fallback_domains.emplace_back(AG_FMT("*.{}", search_domain));
            }
        }
    }
    res_nclose(&resState);
}

#if !TARGET_OS_IPHONE

typedef struct {
    int ourFd;
    int theirFd;
} fd_pair_t;

static fd_pair_t makeFdPairForTask() {
    int pair[2] = {-1, -1};
    int r = socketpair(AF_UNIX, SOCK_STREAM, 0, pair);
    if (r == -1) {
        goto error;
    }
    r = evutil_make_socket_closeonexec(pair[0]);
    if (r == -1) {
        goto error;
    }
    r = evutil_make_socket_closeonexec(pair[1]);
    if (r == -1) {
        goto error;
    }
    return (fd_pair_t) {pair[0], pair[1]};
    error:
    close(pair[0]);
    close(pair[1]);
    return (fd_pair_t) {-1, -1};
}

// Bind an fd using adguard-tun-helper
static int bindFd(NSString *helperPath, NSString *address, NSNumber *port, AGListenerProtocol proto, NSError **error) {
    NSString *protoString = nil;
    switch (proto) {
    case AGLP_UDP:
        protoString = @"udp";
        break;
    case AGLP_TCP:
        protoString = @"tcp";
        break;
    }
    if (protoString == nil) {
        *error = [NSError errorWithDomain:AGDnsProxyErrorDomain
                                     code:AGDPE_PROXY_INIT_ERROR
                                 userInfo:@{NSLocalizedDescriptionKey: @"Bad listener protocol"}];
        return -1;
    }

    fd_pair_t fdPair = makeFdPairForTask();
    if (fdPair.ourFd == -1 || fdPair.theirFd == -1) {
        *error = [NSError errorWithDomain:AGDnsProxyErrorDomain
                                     code:AGDPE_PROXY_INIT_ERROR
                                 userInfo:@{NSLocalizedDescriptionKey: @"Failed to make an fd pair"}];
        return -1;
    }

    auto *task = [[NSTask alloc] init];
    task.launchPath = helperPath;
    task.arguments = @[@"--bind", address, port.stringValue, protoString];
    NSFileHandle *nullDevice = [NSFileHandle fileHandleWithNullDevice];
    task.standardInput = nullDevice;
    task.standardOutput = [[NSFileHandle alloc] initWithFileDescriptor:fdPair.theirFd closeOnDealloc:NO];
    task.standardError = nullDevice;
    [task launch];
    close(fdPair.theirFd);

    evutil_make_socket_nonblocking(fdPair.ourFd);

    pollfd pfd[] = {{.fd = fdPair.ourFd, .events = POLLIN}};
    ssize_t r = poll(pfd, 1, 30 * 1000);
    if (r != 1) {
        if (r == 0) {
            *error = [NSError errorWithDomain:AGDnsProxyErrorDomain
                                         code:AGDPE_PROXY_INIT_ERROR
                                     userInfo:@{NSLocalizedDescriptionKey: @"Poll timed out"}];
        } else {
            *error = [NSError errorWithDomain:AGDnsProxyErrorDomain
                                         code:AGDPE_PROXY_INIT_ERROR
                                     userInfo:@{NSLocalizedDescriptionKey:
                                                [NSString stringWithFormat:
                                                        @"Poll failed: %d (%s)", errno, strerror(errno)]}];
        }
        close(fdPair.ourFd);
        [task interrupt];
        return -1;
    }

    char buf[1]{};
    char cmsgspace[CMSG_SPACE(sizeof(int))]{};
    iovec vec{
            .iov_base = buf,
            .iov_len = sizeof(buf)};
    msghdr msg{
            .msg_iov = &vec,
            .msg_iovlen = 1,
            .msg_control = &cmsgspace,
            .msg_controllen = CMSG_LEN(sizeof(int))};

    r = recvmsg(fdPair.ourFd, &msg, 0);
    if (r < 0) {
        *error = [NSError errorWithDomain:AGDnsProxyErrorDomain
                                     code:AGDPE_PROXY_INIT_ERROR
                                 userInfo:@{NSLocalizedDescriptionKey:
                                            [NSString stringWithFormat:@"Failed to receive fd: %s", strerror(errno)]}];
        close(fdPair.ourFd);
        [task interrupt];
        return -1;
    }
    close(fdPair.ourFd);
    // Error will be handled after.
    [task waitUntilExitOrInterruptAfterTimeoutMs:BINDFD_WAIT_MS];

    for (cmsghdr *cmsg = CMSG_FIRSTHDR(&msg); cmsg; cmsg = CMSG_NXTHDR(&msg, cmsg)) {
        if (cmsg->cmsg_level == SOL_SOCKET && cmsg->cmsg_type == SCM_RIGHTS) {
            int receivedFd = *(int *) CMSG_DATA(cmsg);
            return receivedFd;
        }
    }

    *error = [NSError errorWithDomain:AGDnsProxyErrorDomain
                                 code:AGDPE_PROXY_INIT_ERROR
                             userInfo:@{NSLocalizedDescriptionKey: @"Failed to receive fd: control message not found"}];
    return -1;
}

#endif // !TARGET_OS_IPHONE

- (instancetype) initWithConfig: (AGDnsProxyConfig *) config
                        handler: (AGDnsProxyEvents *) handler
                          error: (NSError **) error
{
    self = [super init];
    if (!self) {
        return nil;
    }
    self->initialized = NO;

    self->log = ag::Logger{"AGDnsProxy"};

    infolog(*self->log, "Initializing dns proxy...");

    ag::dnsproxy_settings settings = ag::dnsproxy_settings::get_default();
    settings.upstreams = convert_upstreams(config.upstreams);
    settings.fallbacks = convert_upstreams(config.fallbacks);

    if (config.fallbackDomains) {
        for (NSString *domain in config.fallbackDomains) {
            settings.fallback_domains.emplace_back(domain.UTF8String);
        }
    }
    if (config.detectSearchDomains) {
        append_search_domains(settings.fallback_domains);
    }

    settings.blocked_response_ttl_secs = (uint32_t) config.blockedResponseTtlSecs;

    if (config.filters != nil) {
        settings.filter_params.filters.reserve([config.filters count]);
        for (AGDnsFilterParams *fp in config.filters) {
            dbglog(*self->log, "Filter id={} {}={}", fp.id, fp.inMemory ? "content" : "path", fp.data.UTF8String);

            settings.filter_params.filters.emplace_back(
                ag::dnsfilter::filter_params{(int32_t) fp.id, fp.data.UTF8String, (bool) fp.inMemory});
        }
#if TARGET_OS_IPHONE
        settings.filter_params.mem_limit = FILTER_PARAMS_MEM_LIMIT_BYTES;
#endif
    }

    void *obj = (__bridge void *)self;
    self->queue = dispatch_queue_create("com.adguard.dnslibs.AGDnsProxy.queue", nil);
    self->events = handler;
    ag::dnsproxy_events native_events = {};
    if (handler != nil && handler.onRequestProcessed != nil) {
         native_events.on_request_processed =
            [obj] (const ag::dns_request_processed_event &event) {
                auto *sself = (__bridge AGDnsProxy *)obj;
                @autoreleasepool {
                    auto *objCEvent = [[AGDnsRequestProcessedEvent alloc] init: event];
                    __weak AGDnsProxyEvents *weakObjCEvents = sself->events;
                    dispatch_async(sself->queue, ^{
                        __strong AGDnsProxyEvents *objCEvents = weakObjCEvents;
                        if (objCEvents) {
                            objCEvents.onRequestProcessed(objCEvent);
                        }
                    });
                }
            };
    }
    native_events.on_certificate_verification =
        [obj] (ag::certificate_verification_event event) -> std::optional<std::string> {
            @autoreleasepool {
                AGDnsProxy *sself = (__bridge AGDnsProxy *)obj;
                return [AGDnsProxy verifyCertificate: &event log: *sself->log];
            }
        };

    if (config.dns64Settings != nil) {
        NSArray<AGDnsUpstream *> *dns64_upstreams = config.dns64Settings.upstreams;
        if (dns64_upstreams == nil) {
            dbglog(*self->log, "DNS64 upstreams list is nil");
        } else if ([dns64_upstreams count] == 0) {
            dbglog(*self->log, "DNS64 upstreams list is empty");
        } else {
            settings.dns64 = ag::dns64_settings{
                    .upstreams = convert_upstreams(dns64_upstreams),
                    .max_tries = config.dns64Settings.maxTries > 0
                                 ? static_cast<uint32_t>(config.dns64Settings.maxTries) : 0,
                    .wait_time = std::chrono::milliseconds(config.dns64Settings.waitTimeMs),
            };
        }
    }

    std::vector<std::shared_ptr<void>> closefds; // Close fds on return
    if (config.listeners != nil) {
        closefds.reserve(config.listeners.count);
        settings.listeners.clear();
        settings.listeners.reserve(config.listeners.count);
        for (AGListenerSettings *listener in config.listeners) {
            int listenerFd = -1;
#if !TARGET_OS_IPHONE
            if (config.helperPath) {
                listenerFd = bindFd(config.helperPath, listener.address, @(listener.port), listener.proto, error);
                if (listenerFd == -1) {
                    return nil;
                }
                closefds.emplace_back(nullptr, [listenerFd](void *p) {
                    close(listenerFd);
                }); // Close on return (listener does dup())
            }
#endif
            settings.listeners.emplace_back((ag::listener_settings) {
                .address = listener.address.UTF8String,
                .port = (uint16_t) listener.port,
                .protocol = (ag::utils::transport_protocol) listener.proto,
                .persistent = (bool) listener.persistent,
                .idle_timeout = std::chrono::milliseconds(listener.idleTimeoutMs),
                .fd = listenerFd,
            });
        }
    }

    settings.ipv6_available = config.ipv6Available;
    settings.block_ipv6 = config.blockIpv6;

    settings.adblock_rules_blocking_mode = (ag::dnsproxy_blocking_mode) config.adblockRulesBlockingMode;
    settings.hosts_rules_blocking_mode = (ag::dnsproxy_blocking_mode) config.hostsRulesBlockingMode;
    if (config.customBlockingIpv4 != nil) {
        settings.custom_blocking_ipv4 = [config.customBlockingIpv4 UTF8String];
    }
    if (config.customBlockingIpv6 != nil) {
        settings.custom_blocking_ipv6 = [config.customBlockingIpv6 UTF8String];
    }

    settings.dns_cache_size = config.dnsCacheSize;
    settings.optimistic_cache = config.optimisticCache;
    settings.enable_dnssec_ok = config.enableDNSSECOK;
    settings.enable_retransmission_handling = config.enableRetransmissionHandling;

    auto [ret, err_or_warn] = self->proxy.init(std::move(settings), std::move(native_events));
    if (!ret) {
        auto str = AG_FMT("Failed to initialize the DNS proxy: {}", *err_or_warn);
        errlog(*self->log, "{}", str);
        if (error) {
            if (err_or_warn == ag::dnsproxy::LISTENER_ERROR) {
                *error = [NSError errorWithDomain: AGDnsProxyErrorDomain
                                             code: AGDPE_PROXY_INIT_LISTENER_ERROR
                                         userInfo: @{ NSLocalizedDescriptionKey: convert_string(str) }];
            } else {
                *error = [NSError errorWithDomain: AGDnsProxyErrorDomain
                                             code: AGDPE_PROXY_INIT_ERROR
                                         userInfo: @{ NSLocalizedDescriptionKey: convert_string(str) }];
            }
        }
        return nil;
    }
    if (error && err_or_warn) {
        auto str = AG_FMT("DNS proxy initialized with warnings:\n{}", *err_or_warn);
        *error = [NSError errorWithDomain: AGDnsProxyErrorDomain
                                     code: AGDPE_PROXY_INIT_WARNING
                                 userInfo: @{ NSLocalizedDescriptionKey: convert_string(str) }];
    }
    self->initialized = YES;

    infolog(*self->log, "Dns proxy initialized");

    return self;
}

- (NSData *)handleIPv4Packet:(NSData *)packet
{
    auto *ip_header = (struct iphdr *) packet.bytes;
    // @todo: handle tcp packets also
    if (ip_header->ip_p != IPPROTO_UDP) {
        return nil;
    }

    NSInteger ip_header_length = ip_header->ip_hl * 4;
    auto *udp_header = (struct udphdr *) ((Byte *) packet.bytes + ip_header_length);
    NSInteger header_length = ip_header_length + sizeof(*udp_header);

    char srcv4_str[INET_ADDRSTRLEN], dstv4_str[INET_ADDRSTRLEN];
    dbglog(*self->log, "{}:{} -> {}:{}",
           inet_ntop(AF_INET, &ip_header->ip_src, srcv4_str, sizeof(srcv4_str)), ntohs(udp_header->uh_sport),
           inet_ntop(AF_INET, &ip_header->ip_dst, dstv4_str, sizeof(dstv4_str)), ntohs(udp_header->uh_dport));

    ag::Uint8View payload = {(uint8_t *) packet.bytes + header_length, packet.length - header_length};
    ag::dns_message_info info{
            .proto = ag::utils::TP_UDP,
            .peername = ag::SocketAddress{{(uint8_t *) &ip_header->ip_src, sizeof(ip_header->ip_src)},
                                           ntohs(udp_header->uh_sport)}};
    std::vector<uint8_t> response = self->proxy.handle_message(payload, &info);
    if (response.empty()) {
        return nil;
    }
    return create_response_packet(ip_header, udp_header, response);
}

- (NSData *)handleIPv6Packet:(NSData *)packet
{
    auto *ip_header = (struct iphdr6 *) packet.bytes;
    // @todo: handle tcp packets also
    if (ip_header->ip6_nh != IPPROTO_UDP) {
        return nil;
    }

    NSInteger ip_header_length = sizeof(*ip_header);
    auto *udp_header = (struct udphdr *) ((Byte *) packet.bytes + ip_header_length);
    NSInteger header_length = ip_header_length + sizeof(*udp_header);

    char srcv6_str[INET6_ADDRSTRLEN], dstv6_str[INET6_ADDRSTRLEN];
    dbglog(*self->log, "[{}]:{} -> [{}]:{}",
           inet_ntop(AF_INET6, &ip_header->ip6_src, srcv6_str, sizeof(srcv6_str)), ntohs(udp_header->uh_sport),
           inet_ntop(AF_INET6, &ip_header->ip6_dst, dstv6_str, sizeof(dstv6_str)), ntohs(udp_header->uh_dport));

    ag::Uint8View payload = {(uint8_t *) packet.bytes + header_length, packet.length - header_length};
    ag::dns_message_info info{
            .proto = ag::utils::TP_UDP,
            .peername = ag::SocketAddress{{(uint8_t *) &ip_header->ip6_src, sizeof(ip_header->ip6_src)},
                                           ntohs(udp_header->uh_sport)}};
    std::vector<uint8_t> response = self->proxy.handle_message(payload, &info);
    if (response.empty()) {
        return nil;
    }
    return create_response_packet_v6(ip_header, udp_header, response);
}

- (NSData *)handlePacket:(NSData *)packet
{
    auto *ip_header = (const struct iphdr *)packet.bytes;
    if (ip_header->ip_v == 4) {
        return [self handleIPv4Packet:packet];
    } else if (ip_header->ip_v == 6) {
        return [self handleIPv6Packet:packet];
    }
    dbglog(*self->log, "Wrong IP version: %u", ip_header->ip_v);
    return nil;
}

+ (BOOL) isValidRule: (NSString *) str
{
    return ag::dnsfilter::is_valid_rule([str UTF8String]);
}

+ (NSString *)libraryVersion {
    return convert_string(ag::dnsproxy::version());
}

@end

@implementation AGDnsStamp

- (instancetype) initWithNative: (const ag::server_stamp *) stamp
{
    self = [super init];
    if (self) {
        _proto = (AGStampProtoType) stamp->proto;
        _serverAddr = convert_string(stamp->server_addr_str);
        _providerName = convert_string(stamp->provider_name);
        _path = convert_string(stamp->path);
        if (!stamp->server_pk.empty()) {
            _serverPublicKey = [NSData dataWithBytes: stamp->server_pk.data() length: stamp->server_pk.size()];
        }
        if (!stamp->hashes.empty()) {
            NSMutableArray *hs = [NSMutableArray arrayWithCapacity: stamp->hashes.size()];
            for (const std::vector<uint8_t> &h : stamp->hashes) {
                [hs addObject: [NSData dataWithBytes: h.data() length: h.size()]];
            }
            _hashes = hs;
        }
        if (stamp->props & ag::DNSSEC) {
            _dnssec = YES;
        }
        if (stamp->props & ag::NO_LOG) {
            _noLog = YES;
        }
        if (stamp->props & ag::NO_FILTER) {
            _noFilter = YES;
        }
    }
    return self;
}

- (instancetype)initWithCoder:(NSCoder *)coder {
    self = [super init];
    if (self) {
        _proto = (AGStampProtoType) [coder decodeIntForKey:@"_proto"];
        _serverAddr = [coder decodeObjectForKey:@"_serverAddr"];
        _providerName = [coder decodeObjectForKey:@"_providerName"];
        _path = [coder decodeObjectForKey:@"_path"];
        _serverPublicKey = [coder decodeObjectForKey:@"_serverPublicKey"];
        _hashes = [coder decodeObjectForKey:@"_hashes"];
        _dnssec = [coder decodeBoolForKey:@"_dnssec"];
        _noLog = [coder decodeBoolForKey:@"_noLog"];
        _noFilter = [coder decodeBoolForKey:@"_noFilter"];
    }

    return self;
}

- (void)encodeWithCoder:(NSCoder *)coder {
    [coder encodeInt:self.proto forKey:@"_proto"];
    [coder encodeObject:self.serverAddr forKey:@"_serverAddr"];
    [coder encodeObject:self.providerName forKey:@"_providerName"];
    [coder encodeObject:self.path forKey:@"_path"];
    [coder encodeObject:self.serverPublicKey forKey:@"_serverPublicKey"];
    [coder encodeObject:self.hashes forKey:@"_hashes"];
    [coder encodeBool:self.dnssec forKey:@"_dnssec"];
    [coder encodeBool:self.noLog forKey:@"_noLog"];
    [coder encodeBool:self.noFilter forKey:@"_noFilter"];
}

- (instancetype)initWithString:(NSString *)stampStr
                         error:(NSError **)error {
    auto[stamp, stamp_error] = ag::server_stamp::from_string(stampStr.UTF8String);
    if (!stamp_error) {
        return [self initWithNative:&stamp];
    }
    if (error) {
        *error = [NSError errorWithDomain:AGDnsProxyErrorDomain
                                     code:AGDPE_PARSE_DNS_STAMP_ERROR
                                 userInfo:@{NSLocalizedDescriptionKey: convert_string(*stamp_error)}];
    }
    return nil;
}

+ (instancetype)stampWithString:(NSString *)stampStr
                          error:(NSError **)error {
    return [[self alloc] initWithString:stampStr error:error];
}

- (NSString *)prettyUrl {
    ag::server_stamp stamp = convert_stamp(self);
    return convert_string(stamp.pretty_url(false));
}

- (NSString *)prettierUrl {
    ag::server_stamp stamp = convert_stamp(self);
    return convert_string(stamp.pretty_url(true));
}

- (NSString *)stringValue {
    ag::server_stamp stamp = convert_stamp(self);
    return convert_string(stamp.str());
}

@end

@implementation AGDnsUtils

static auto dnsUtilsLogger = ag::Logger{"AGDnsUtils"};

static std::optional<std::string> verifyCertificate(ag::certificate_verification_event event) {
    return [AGDnsProxy verifyCertificate: &event log: dnsUtilsLogger];
}

+ (NSError *) testUpstream: (AGDnsUpstream *) opts
             ipv6Available: (BOOL) ipv6Available
                   offline: (BOOL) offline
{
    auto error = ag::test_upstream(convert_upstream(opts), ipv6Available, verifyCertificate, offline);
    if (error) {
        return [NSError errorWithDomain: AGDnsProxyErrorDomain
                                   code: AGDPE_TEST_UPSTREAM_ERROR
                               userInfo: @{NSLocalizedDescriptionKey: convert_string(*error)}];
    }
    return nil;
}

@end
