// Package transport provides the authenticated UDP transport shared by native
// Neon peers. The operator provisions the host certificate and client CA.
package transport

import (
	"context"
	"crypto/tls"
	"crypto/x509"
	"errors"
	"time"

	"github.com/quic-go/quic-go"
)

const protocol = "neon-game/1"

func settings() *quic.Config {
	return &quic.Config{
		EnableDatagrams:            true,
		MaxIncomingStreams:         8,
		MaxIncomingUniStreams:      -1,
		HandshakeIdleTimeout:       5 * time.Second,
		MaxIdleTimeout:             30 * time.Second,
		MaxConnectionReceiveWindow: 4 << 20,
		MaxStreamReceiveWindow:     1 << 20,
	}
}

// Listen binds exactly one UDP address. A peer must present a client
// certificate trusted by clientRoots before Accept returns its connection.
func Listen(addr string, host tls.Certificate, clientRoots *x509.CertPool) (*quic.Listener, error) {
	return ListenWithPolicy(addr, host, clientRoots, AdmissionPolicy{})
}

// ListenWithPolicy applies the owner’s policy during mutual TLS, before Accept.
// Client certificates must chain to the dedicated install CA for this listener.
func ListenWithPolicy(addr string, host tls.Certificate, clientRoots *x509.CertPool, policy AdmissionPolicy) (*quic.Listener, error) {
	if clientRoots == nil || len(host.Certificate) == 0 || host.PrivateKey == nil {
		return nil, errors.New("host key pair and an explicit client CA are required")
	}
	config := &tls.Config{
		MinVersion:   tls.VersionTLS13,
		NextProtos:   []string{protocol},
		Certificates: []tls.Certificate{host},
		ClientAuth:   tls.RequireAndVerifyClientCert,
		ClientCAs:    clientRoots,
	}
	if policy.MobileIntegrity {
		config.VerifyConnection = verifyDeviceIntegrity
	}
	return quic.ListenAddr(addr, config, settings())
}

// Dial verifies the server name against serverRoots. tls.Certificate supports
// opaque crypto.Signer keys, so callers can keep private keys outside Go.
func Dial(ctx context.Context, addr, serverName string, client tls.Certificate, serverRoots *x509.CertPool) (*quic.Conn, error) {
	if serverName == "" || serverRoots == nil || len(client.Certificate) == 0 || client.PrivateKey == nil {
		return nil, errors.New("server name, trusted roots and a client key pair are required")
	}
	return quic.DialAddr(ctx, addr, &tls.Config{
		MinVersion:   tls.VersionTLS13,
		NextProtos:   []string{protocol},
		Certificates: []tls.Certificate{client},
		RootCAs:      serverRoots,
		ServerName:   serverName,
	}, settings())
}
