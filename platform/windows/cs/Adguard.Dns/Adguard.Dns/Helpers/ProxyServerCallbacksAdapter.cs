using System;
using Adguard.Dns.Api.DnsProxyServer.Callbacks;
using Adguard.Dns.Api.DnsProxyServer.EventArgs;
using Adguard.Dns.DnsProxyServer;
using Adguard.Dns.Exceptions;
using AdGuard.Utils.Interop;

namespace Adguard.Dns.Helpers
{
    /// <summary>
    /// An adapter between the native callbacks and the managed callbacks for the <see cref="Adguard.Dns.DnsProxyServer"/>
    /// </summary>
    /// <see cref="AGDnsApi.AGDnsProxyServerCallbacks"/>
    internal class ProxyServerCallbacksAdapter
    {
        private readonly IDnsProxyServerCallbackConfiguration m_DnsServerCallbackConfiguration;
        private readonly ICertificateVerificationCallback m_CertificateVerificationCallback;
        private readonly IDnsProxyServer m_ProxyServer;

        /// <summary>
        /// Creates an instance of the adapter
        /// </summary>
        /// <param name="dnsServerCallbackConfiguration">An object implementing the callbacks interface
        /// (<seealso cref="IDnsProxyServerCallbackConfiguration"/>)</param>
        /// <param name="certificateVerificationCallback">An object implementing certificate verification interface
        /// (<seealso cref="ICertificateVerificationCallback"/>)</param>
        /// <param name="proxyServer">An instance of <see cref="IDnsProxyServer"/></param>
        internal ProxyServerCallbacksAdapter(
            IDnsProxyServerCallbackConfiguration dnsServerCallbackConfiguration,
            ICertificateVerificationCallback certificateVerificationCallback,
            IDnsProxyServer proxyServer)
        {
            m_DnsServerCallbackConfiguration = dnsServerCallbackConfiguration;
            m_CertificateVerificationCallback = certificateVerificationCallback;
            m_ProxyServer = proxyServer;

            // Initialize a native callbacks object
            DnsProxyServerCallbacks =
                new AGDnsApi.AGDnsProxyServerCallbacks
                {
                    ag_dns_request_processed_cb = AGCOnDnsRequestProcessed,
                    ag_certificate_verification_cb = AGCOnCertificationVerificationProcessed
                };
        }

        /// <summary>
        /// Native <see cref="AGDnsApi.AGDnsProxyServerCallbacks"/> object
        /// </summary>
        internal AGDnsApi.AGDnsProxyServerCallbacks DnsProxyServerCallbacks { get; private set; }

        /// <summary>
        /// <see cref="AGDnsApi.AGDnsProxyServerCallbacks.ag_dns_request_processed_cb"/> adapter
        /// </summary>
        /// <param name="pInfo">The pointer to an instance of
        /// <see cref="AGDnsApi.ag_dns_request_processed_event"/></param>
        private void AGCOnDnsRequestProcessed(IntPtr pInfo)
        {
            try
            {
                DnsRequestProcessedEventArgs args =
                    MarshalUtils.PtrToClass<DnsRequestProcessedEventArgs, AGDnsApi.ag_dns_request_processed_event>(
                        pInfo,
                        DnsApiConverter.FromNativeObject);
                m_DnsServerCallbackConfiguration.OnDnsRequestProcessed(m_ProxyServer, args);
            }
            catch (Exception ex)
            {
                DnsExceptionHandler.HandleManagedException(ex);
            }
        }

        /// <summary>
        /// <see cref="AGDnsApi.AGDnsProxyServerCallbacks.ag_certificate_verification_cb"/> adapter
        /// </summary>
        /// <param name="pInfo">The pointer to an instance of
        /// <see cref="AGDnsApi.ag_certificate_verification_event"/></param>
        /// <returns>Certificate verification result
        /// (<seealso cref="AGDnsApi.ag_certificate_verification_result"/>)</returns>
        private AGDnsApi.ag_certificate_verification_result AGCOnCertificationVerificationProcessed(IntPtr pInfo)
        {
            try
            {
                CertificateVerificationEventArgs args =
                    MarshalUtils.PtrToClass<CertificateVerificationEventArgs, AGDnsApi.ag_certificate_verification_event>(
                        pInfo,
                        DnsApiConverter.FromNativeObject);
                AGDnsApi.ag_certificate_verification_result certificateVerificationResult =
                    m_CertificateVerificationCallback.OnCertificateVerification(this, args);
                return certificateVerificationResult;
            }
            catch (Exception ex)
            {
                DnsExceptionHandler.HandleManagedException(ex);
                return AGDnsApi.ag_certificate_verification_result.AGCVR_ERROR_CERT_VERIFICATION;
            }
        }
    }
}