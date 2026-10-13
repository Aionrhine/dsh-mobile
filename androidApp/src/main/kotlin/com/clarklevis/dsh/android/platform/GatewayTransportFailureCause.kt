package com.clarklevis.dsh.android.platform

import java.io.EOFException
import java.io.IOException
import java.net.SocketException
import java.net.SocketTimeoutException
import java.net.ProtocolException
import javax.net.ssl.SSLException

/** 仅记录固定错误类别，避免异常消息泄露地址、配对码或凭据。 */
internal enum class GatewayTransportFailureCause(val wireName: String) {
    PING_TIMEOUT("ping-timeout"),
    SOCKET_TIMEOUT("socket-timeout"),
    PEER_CLOSED("peer-closed"),
    PEER_CLOSING("peer-closing"),
    SOCKET_ERROR("socket-error"),
    TLS_ERROR("tls-error"),
    PROTOCOL_ERROR("protocol-error"),
    IO_ERROR("io-error"),
    OTHER("other");

    companion object {
        fun from(error: Throwable): GatewayTransportFailureCause = when (error) {
            is SocketTimeoutException -> if (error.message?.startsWith("sent ping but didn't receive pong within ") == true) {
                PING_TIMEOUT
            } else {
                SOCKET_TIMEOUT
            }
            is SSLException -> TLS_ERROR
            is EOFException -> PEER_CLOSED
            is ProtocolException -> PROTOCOL_ERROR
            is SocketException -> SOCKET_ERROR
            is IOException -> IO_ERROR
            else -> OTHER
        }
    }
}
