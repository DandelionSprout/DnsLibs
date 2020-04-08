﻿using System.Collections.Generic;
using System.Net;
using Adguard.Dns.Helpers;
using Adguard.Dns.Utils;

namespace Adguard.Dns.Api.DnsProxyServer.Configs
{
    /// <summary>
    /// Upstream options.
    /// Managed mirror of <see cref="AGDnsApi.ag_upstream_options"/>
    /// </summary>
    public class UpstreamOptions
    {
        /// <summary>
        /// Server address, one of the following kinds:
        /// 8.8.8.8:53 -- plain DNS
        /// tcp://8.8.8.8:53 -- plain DNS over TCP
        /// tls://1.1.1.1 -- DNS-over-TLS
        /// https://dns.adguard.com/dns-query -- DNS-over-HTTPS
        /// sdns://... -- DNS stamp (see https://dnscrypt.info/stamps-specifications)
        /// </summary>
        [ManualMarshalStringToPtr]
        public string Address { get; set; }
        
        /// <summary>
        /// List of plain DNS servers to be used to resolve DOH/DOT hostnames (if any)
        /// </summary>
        public List<string> Bootstrap { get; set; }
        
        /// <summary>
        /// Default upstream timeout in milliseconds. Also, it is used as a timeout for bootstrap DNS requests.
        /// <code>timeout = 0</code>"/> means infinite timeout.
        /// </summary>
        public long TimeoutMs { get; set; }
        
        /// <summary>
        /// Resolver's IP address. In the case if it's specified, bootstrap DNS servers won't be used at all.
        /// </summary>
        public IPAddress ServerAddress { get; set; }

        #region Equals members

        public override bool Equals(object obj)
        {
            if (ReferenceEquals(null, obj))
            {
                return false;
            }

            if (ReferenceEquals(this, obj))
            {
                return true;
            }

            if (obj.GetType() != typeof(UpstreamOptions))
            {
                return false;
            }

            return Equals((UpstreamOptions)obj);
        }

        private bool Equals(UpstreamOptions other)
        {
            return Equals(Address, other.Address) && 
                   CollectionUtils.SequenceEqual(Bootstrap, other.Bootstrap) && 
                   TimeoutMs == other.TimeoutMs && 
                   Equals(ServerAddress, other.ServerAddress);
        }

        public override int GetHashCode()
        {
            unchecked
            {
                int hashCode = (Address != null ? Address.GetHashCode() : 0);
                hashCode = (hashCode * 397) ^ (Bootstrap != null ? Bootstrap.GetHashCode() : 0);
                hashCode = (hashCode * 397) ^ TimeoutMs.GetHashCode();
                hashCode = (hashCode * 397) ^ (ServerAddress != null ? ServerAddress.GetHashCode() : 0);
                return hashCode;
            }
        }

        #endregion
    }
}