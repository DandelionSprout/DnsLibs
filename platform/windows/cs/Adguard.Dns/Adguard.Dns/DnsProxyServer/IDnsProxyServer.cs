using System;
using Adguard.Dns.Api.DnsProxyServer.Configs;

namespace Adguard.Dns.DnsProxyServer
{
    /// <summary>
    /// Interface for the proxy server
    /// </summary>
    internal interface IDnsProxyServer
    {
        /// <summary>
        /// Starts the DnsProxyServer
        /// </summary>
        /// <exception cref="InvalidOperationException">Thrown,
        /// if cannot starting the DnsProxyServer via native method</exception>
        void Start();

        /// <summary>
        /// Stops the DnsProxyServer.
        /// If it is not started yet, does nothing.
        /// </summary>
        /// <exception cref="InvalidOperationException">Thrown,
        /// if cannot closing the DnsProxyServer via native method</exception>
        void Stop();

        /// <summary>
        /// Gets the current DNS proxy settings as a <see cref="DnsProxySettings"/> object
        /// </summary>
        /// <returns>Current DNS proxy settings
        /// (<seealso cref="DnsProxySettings"/>)</returns>
        /// <exception cref="InvalidOperationException">Thrown,
        /// if cannot get the current dns proxy settings via native method</exception>
        DnsProxySettings GetCurrentDnsProxySettings();

        /// <summary>
        /// The DnsProxyServer status
        /// Determines, whether the current instance of the DnsProxyServer is started
        /// </summary>
        bool IsStarted { get; }
    }
}