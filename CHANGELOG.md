# Changelog

* [Feature] Changed the signature of `com.adguard.dnslibs.proxy.DnsProxy` constructor: now throws a
  `com.adguard.dnslibs.proxy.DnsProxyInitException` on failure, containing the same info as the native error.

* [Feature] Added an option to try HTTP/3 for DoH upstream connections.
  If enabled, HTTP/3 will be used for DoH if it's faster.
  See `DnsProxySettings::enable_http3`, `AGDnsProxyConfig.enableHttp3`,
  `com.adguard.dnslibs.proxy.DnsProxySettings#enableHttp3`, `ag_dnsproxy_settings::enable_http3`

* [Feature] Added an option to query upstreams in parallel. See 
  `DnsProxySettings::enable_parallel_upstream_queries` and the corresponding options in platform-specific adapters.
* [Feature] Added an option to change fallback behaviour. See
  `DnsProxySettings::enable_fallback_on_upstreams_failure` and the corresponding options in platform-specific adapters.
* [Feature] Added an option to change the behaviour when upstreams fail to yield a response. See
  `DnsProxySettings::enable_servfail_on_upstreams_failure` and the corresponding options in platform-specific adapters.

* [Feature] A non-standard `h3://` URL scheme can now be used to force a DoH upstream to use HTTP/3.

* [Feature] Now DnsProxy.init() return more informative error code with description.
  * [C API] See `DnsProxy.DnsProxyInitResult`
  * [Apple] See `AGDnsProxyError`
  * [Android] See `ag_dnsproxy_init_result`

## V2.0

* [Feature] Add an option to strip Encrypted Client Hello parameters from responses, effectively blocking ECH.
  * [C API] See `ag_dnsproxy_settings::block_ech`
  * [Apple] See `AGDnsProxyConfig.blockEch`
  * [Android] See `DnsProxySettings.setBlockEch()`.

* [Feature] DnsProxy now accepts a hostname as an address of the outbound proxy. In that case an application should also pass a list of the bootstrapping resolvers.

* [Feature] DnsProxy calls are now asynchronous. On iOS [handlePacket:completionHandler:] should be called instead of synchronous one.

* [Feature] The DoQ upstream now uses the port 853 by default (was 8853), conforms to RFC-9250, and doesn't support ALPNs other than "doq".
            ACHTUNG: Some changes might be required on the application side due to the default port change? 

## V1.7.28

* [Feature] Route resolver on Apple platforms is now can be enabled via `AGDnsProxySettings.enableRouteResolver`

## V1.7.0

* [Feature] In the settings returned by `dnsproxy::get_settings()`, listener settings now contain
  the actual port that each listener is listening on.

## V1.6
* [Feature] Add an ability to route DNS queries directly to a target host in case the configured
            proxy server is determined as unavailable. Mostly intended for Android.
    * [Android] See `OutboundProxySettings`
    * [C API] See `ag_outbound_proxy_settings`
* [Fix] Accept IPv6 availability parameter in upstream testing methods.
    * Note that the API has changed, see `com.adguard.dnslibs.proxy.DnsProxy#testUpstream`, `+[AGDnsUtils testUpstream:ipv6Available:]`, `ag_test_upstream`.
* [Feature] Split the blocking mode setting into separate settings for AdBlock-style and hosts-style rules.
    * Also remove the redundant `CUSTOM_ADDRESS` blocking mode: now if a custom blocking address is specified,
    it will simply be used where an all-zeroes address would have been used otherwise.
    * WARNING: the `DEFAULT` blocking mode has been removed. The default blocking mode for both rule types
    is now obtained with `ag::DnsProxySettings::get_default()`/`DnsProxySettings.getDefault()`
      /`AGDnsProxyConfig.getDefault()`/`ag_dnsproxy_settings_get_default()`
## V1.5
* [Feature] Fallback-only domains. See `fallbackDomains` or `fallback_domains` in respective adapters.
    * This is a list of domains (limited wildcards allowed) that will be forwarded directly to the fallback upstreams (if they exist).
    * There's also an option to automatically append DNS search domains to this list, see `detectSearchDomains` (Android and Apple only, Windows adapter handles search domains on its own).
  * WARNING: Note to application developers: you MUST get the default value of this field
    from `DnsProxySettings::get_default()`/`DnsProxySettings.getDefault()`/`AGDnsProxyConfig.getDefault()`
    as it contains important default for Wi-Fi calling, but we can't add them automatically, because the user must see the defaults in UI and be able to edit them.
  
* [Features] Retransmission handling: see `enableRetransmissionHandling` or `enable_retransmission_handling`.
    Mostly intended for iOS.
    If `enable_retransmission_handling` is true, retransmitted requests (defined as requests with the same id and sent from the same address that one of the requests that are currently being handled) will be handled only using fallback upstreams, and the answer to the original request will not be sent (to prevent possibly sending SERVFAIL, b/c iOS may mark the resolver as "bad" in this case and refuse to resolve anything from that point).
    Enabling this feature shouldn't break anything on Android and Windows, but it should not be enabled if there are otherwise no issues with retransmitted requests.
* [Feature] Add an ability to set up outbound proxy
    * [Android] see `OutboundProxySettings`
    * [Apple] see `AGOutboundProxySettings`
    * [C API] see `ag_outbound_proxy_settings`
* [Feature] DNS stamp API has been reworked in adapters: DNS stamps can now be
            dynamically edited and converted to various string representations.
* [Feature] DNSLibs indicate that upstream uses DNSSEC. Turn on `ag::DnsProxySettings::enable_dnssec_ok`
    and check `ag::DnsRequestProcessedEvent::dnssec` in callback.
* [Feature] DNS-over-QUIC default port changed. New port is 8853.
    Now an address like `quic://dns.adguard.com` is transformed into `quic://dns.adguard.com:8853`.
    So to force the use of the old port `784` specify it strictly - `quic://dns.adguard.com:784`.
* [Feature] Allow retrieving the library version
    * see `ag::dnsproxy::version()`
    * see `AGDnsProxy.libraryVersion` (Apple)
    * see `com.adguard.dnsproxy.DnsProxy.version()` (Android)
    * see `ag_dnsproxy_version()` (C API)
* [Feature] Add a "pretty URL" function for DNS stamps
    * see `ag::ServerStamp::pretty_url()`
    * see `AGDnsStamp.prettyUrl`, `AGDnsStamp.prettierUrl` (Apple)
    * see `com.adguard.dnsproxy.DnsStamp.getPrettyUrl()`,
          `com.adguard.dnsproxy.DnsStamp.getPrettierUrl()` (Android)
    * see `ag_dns_stamp::pretty_url`, `ag_dns_stamp::prettier_url` (C API)

## V1.4
* [Feature] API change: allow in-memory filters<p>
    see `ag::dnsfilter::FilterParams`
* [Feature] Optimistic DNS caching<p>
    see `ag::DnsProxySettings::optimistic_cache`
