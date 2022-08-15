#include <atomic>
#include <utility>

#include "common/coro.h"
#include "dns/net/aio_socket.h"
#include "dns/net/tcp_dns_buffer.h"

#define log_sock(s_, lvl_, fmt_, ...) lvl_##log((s_)->m_log, "[id={}] {}(): " fmt_, (s_)->m_id, __func__, ##__VA_ARGS__)

namespace ag::dns {

using namespace std::chrono;

static std::atomic_size_t next_id = {0};

AioSocket::AioSocket(SocketFactory::SocketPtr socket)
        : m_log(__func__)
        , m_id(next_id.fetch_add(1, std::memory_order_relaxed))
        , m_underlying_socket(std::move(socket)) {
}

AioSocket::~AioSocket() {
    // the underlying socket must be closed before the event loop
    m_underlying_socket.reset();
    if (auto handler = std::exchange(m_handler, nullptr)) {
        handler(std::exchange(m_pending_error, nullptr));
    }
}

void AioSocket::connect(AioSocket::ConnectParameters params, std::function<void(Error<SocketError>)> handler) {
    log_sock(this, trace, "{}", params.peer.str());

    if (m_handler != nullptr) {
        handler(make_error(SocketError::AE_IN_PROGRESS));
        return;
    }

    if (auto e = m_underlying_socket->connect(this->make_underlying_connect_parameters(params))) {
        handler(e);
        return;
    }

    m_handler = std::move(handler);
}

Error<SocketError> AioSocket::send(Uint8View data) {
    log_sock(this, trace, "{}", data.size());
    return m_underlying_socket->send(data);
}

Error<SocketError> AioSocket::send_dns_packet(Uint8View data) {
    log_sock(this, trace, "{}", data.size());
    return m_underlying_socket->send_dns_packet(data);
}

void AioSocket::receive(AioSocket::OnReadCallback on_read_handler, std::optional<Micros> timeout,
                        std::function<void(Error<SocketError>)> handler) {
    log_sock(this, trace, "...");

    if (m_handler != nullptr) {
        handler(make_error(SocketError::AE_IN_PROGRESS));
        return;
    }

    m_on_read_callback = on_read_handler;
    if (auto e = m_underlying_socket->set_callbacks(make_callbacks(true))) {
        handler(e);
        return;
    }

    if (timeout.has_value() && !m_underlying_socket->set_timeout(timeout.value())) {
        handler(make_error(SocketError::AE_SET_TIMEOUT_ERROR));
        return;
    }

    m_handler = std::move(handler);
}

coro::Task<AioSocket::ReceiveDnsPacketResult> AioSocket::receive_dns_packet(std::optional<microseconds> timeout) {

    struct ReadContext {
        utils::TransportProtocol protocol;
        TcpDnsBuffer tcp_buffer;
        Uint8Vector reply;
    };

    constexpr auto on_read = [](void *arg, Uint8View data) {
        auto *ctx = (ReadContext *) arg;
        bool done = false;
        switch (ctx->protocol) {
            case utils::TransportProtocol::TP_TCP:
                ctx->tcp_buffer.store(data);
                if (auto p = ctx->tcp_buffer.extract_packet(); p.has_value()) {
                    ctx->reply = std::move(p.value());
                    done = true;
                }
                break;
            case utils::TransportProtocol::TP_UDP:
                ctx->reply = {data.begin(), data.end()};
                done = true;
                break;
        }
        return !done;
    };

    ReadContext context = {m_underlying_socket->get_protocol()};
    struct OnReadCallback on_read_handler = {on_read, &context};

    if (auto err = co_await receive(on_read_handler, timeout)) {
        co_return err;
    }

    co_return std::move(context.reply);
}

Socket::ConnectParameters AioSocket::make_underlying_connect_parameters(ConnectParameters &params) const {
    return {
            params.loop,
            params.peer,
            make_callbacks(false),
            params.timeout,
    };
}

void AioSocket::on_connected(void *arg) {
    auto *self = (AioSocket *) arg;
    log_sock(self, trace, "...");
    if (auto handler = std::exchange(self->m_handler, nullptr)) {
        handler(std::exchange(self->m_pending_error, nullptr));
    }
}

void AioSocket::on_read(void *arg, Uint8View data) {
    auto *self = (AioSocket *) arg;
    log_sock(self, trace, "{}", data.size());
    if (!self->m_on_read_callback.func(self->m_on_read_callback.arg, data)) {
        if (auto err = self->m_underlying_socket->set_callbacks(self->make_callbacks(false))) {
            abort();
        };
        if (auto handler = std::exchange(self->m_handler, nullptr)) {
            handler(std::exchange(self->m_pending_error, nullptr));
        }
    }
}

void AioSocket::on_close(void *arg, Error<SocketError> error) {
    auto *self = (AioSocket *) arg;
    if (error) {
        log_sock(self, trace, "{}", error->str());
        self->m_pending_error = std::move(error);
    }
    if (auto handler = std::exchange(self->m_handler, nullptr)) {
        handler(std::exchange(self->m_pending_error, nullptr));
    }
}

Socket::Callbacks AioSocket::make_callbacks(bool want_read) const {
    return {on_connected, want_read ? on_read : nullptr, on_close, (void *) this};
}

} // namespace ag::dns
