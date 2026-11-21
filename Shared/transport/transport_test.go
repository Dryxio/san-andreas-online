package transport

import (
	"bytes"
	"context"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/tls"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/pem"
	"errors"
	"math/big"
	"net"
	"net/url"
	"strings"
	"testing"
	"time"

	"github.com/quic-go/quic-go"
)

type authority struct {
	cert  *x509.Certificate
	key   *ecdsa.PrivateKey
	roots *x509.CertPool
}

func makeKey(t *testing.T) *ecdsa.PrivateKey {
	t.Helper()
	key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	return key
}

func certTemplate(name string) *x509.Certificate {
	return &x509.Certificate{SerialNumber: big.NewInt(1), Subject: pkix.Name{CommonName: name}, NotBefore: time.Now().Add(-time.Hour), NotAfter: time.Now().Add(time.Hour)}
}

func newAuthority(t *testing.T) authority {
	t.Helper()
	key := makeKey(t)
	ca := certTemplate("test CA")
	ca.IsCA = true
	ca.BasicConstraintsValid = true
	ca.KeyUsage = x509.KeyUsageCertSign
	der, err := x509.CreateCertificate(rand.Reader, ca, ca, &key.PublicKey, key)
	if err != nil {
		t.Fatal(err)
	}
	cert, err := x509.ParseCertificate(der)
	if err != nil {
		t.Fatal(err)
	}
	roots := x509.NewCertPool()
	roots.AddCert(cert)
	return authority{cert, key, roots}
}

func TestPublishedInstallAuthority(t *testing.T) {
	ca := newAuthority(t)
	encode := func(der []byte) []byte { return pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: der}) }
	data := encode(ca.cert.Raw)
	now := time.Now()
	roots, err := readInstallRoots(bytes.NewReader(data), now)
	if err != nil {
		t.Fatal(err)
	}
	leaf, err := x509.ParseCertificate(ca.issue(t, x509.ExtKeyUsageClientAuth).Certificate[0])
	if err != nil {
		t.Fatal(err)
	}
	if _, err = leaf.Verify(x509.VerifyOptions{Roots: roots, KeyUsages: []x509.ExtKeyUsage{x509.ExtKeyUsageClientAuth}}); err != nil {
		t.Fatal(err)
	}
	for _, invalid := range [][]byte{encode(leaf.Raw), append(bytes.Clone(data), data...), []byte("missing"), bytes.Repeat([]byte{' '}, 16<<10+1)} {
		if _, err = readInstallRoots(bytes.NewReader(invalid), now); err == nil {
			t.Fatal("accepted invalid install CA response")
		}
	}
	if _, err = readInstallRoots(bytes.NewReader(data), ca.cert.NotAfter); err == nil {
		t.Fatal("accepted expired install CA")
	}
}

func (ca authority) issue(t *testing.T, usage x509.ExtKeyUsage, uris ...*url.URL) tls.Certificate {
	t.Helper()
	key := makeKey(t)
	leaf := certTemplate("peer")
	leaf.SerialNumber = big.NewInt(int64(usage) + 2)
	leaf.IPAddresses = []net.IP{net.ParseIP("127.0.0.1")}
	leaf.URIs = uris
	leaf.ExtKeyUsage = []x509.ExtKeyUsage{usage}
	leaf.KeyUsage = x509.KeyUsageDigitalSignature
	der, err := x509.CreateCertificate(rand.Reader, leaf, ca.cert, &key.PublicKey, ca.key)
	if err != nil {
		t.Fatal(err)
	}
	return tls.Certificate{Certificate: [][]byte{der}, PrivateKey: key}
}

func TestAuthenticatedUDP(t *testing.T) {
	ca := newAuthority(t)
	clientCA := newAuthority(t)
	ln, err := Listen("127.0.0.1:0", ca.issue(t, x509.ExtKeyUsageServerAuth), clientCA.roots)
	if err != nil {
		t.Fatal(err)
	}
	defer ln.Close()
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	client, err := Dial(ctx, ln.Addr().String(), "127.0.0.1", clientCA.issue(t, x509.ExtKeyUsageClientAuth), ca.roots)
	if err != nil {
		t.Fatal(err)
	}
	defer client.CloseWithError(0, "")
	server, err := ln.Accept(ctx)
	if err != nil {
		t.Fatal(err)
	}
	defer server.CloseWithError(0, "")
	if len(server.ConnectionState().TLS.VerifiedChains) == 0 {
		t.Fatal("missing verified client certificate")
	}
	wire, err := (Frame{Kind: 7, Bits: 9, Payload: []byte{0x81, 0x80}}).MarshalBinary()
	if err != nil {
		t.Fatal(err)
	}
	stream, err := client.OpenStreamSync(ctx)
	if err != nil {
		t.Fatal(err)
	}
	if _, err = stream.Write(wire); err != nil {
		t.Fatal(err)
	}
	if err = stream.Close(); err != nil {
		t.Fatal(err)
	}
	inbound, err := server.AcceptStream(ctx)
	if err != nil {
		t.Fatal(err)
	}
	deadline, _ := ctx.Deadline()
	inbound.SetReadDeadline(deadline)
	f, err := ReadFrame(inbound)
	if err != nil || f.Kind != 7 || f.Bits != 9 || !bytes.Equal(f.Payload, wire[5:]) {
		t.Fatalf("stream frame %v, %v", f, err)
	}
	if err = server.SendDatagram(wire); err != nil {
		t.Fatal(err)
	}
	response, err := client.ReceiveDatagram(ctx)
	if err != nil {
		t.Fatal(err)
	}
	f, err = ParseDatagram(response)
	if err != nil || f.Kind != 7 || f.Bits != 9 || !bytes.Equal(f.Payload, wire[5:]) {
		t.Fatalf("datagram frame %v, %v", f, err)
	}
}

func TestUntrustedClientCannotDeliver(t *testing.T) {
	ca := newAuthority(t)
	foreign := newAuthority(t)
	ln, err := Listen("127.0.0.1:0", ca.issue(t, x509.ExtKeyUsageServerAuth), ca.roots)
	if err != nil {
		t.Fatal(err)
	}
	defer ln.Close()
	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
	defer cancel()
	c, err := Dial(ctx, ln.Addr().String(), "127.0.0.1", foreign.issue(t, x509.ExtKeyUsageClientAuth), ca.roots)
	if err == nil {
		defer c.CloseWithError(0, "")
		select {
		case <-c.Context().Done():
			err = context.Cause(c.Context())
		case <-ctx.Done():
			t.Fatal("server did not reject the client")
		}
	}
	// A timeout can also prevent delivery. Require an explicit TLS rejection.
	var transportError *quic.TransportError
	if !errors.As(err, &transportError) || !transportError.ErrorCode.IsCryptoError() {
		t.Fatalf("expected a TLS rejection, got %v", err)
	}

	deadline, stop := context.WithTimeout(context.Background(), 100*time.Millisecond)
	defer stop()
	if peer, err := ln.Accept(deadline); err == nil {
		peer.CloseWithError(0, "")
		t.Fatal("accepted an untrusted peer")
	}
}

func TestFrameBounds(t *testing.T) {
	for _, bad := range [][]byte{{}, {1, 0, 0, 0, 1}, {1, 0, 0, 0, 0, 1}, {1, 255, 255, 255, 255}} {
		if _, err := ParseDatagram(bad); err == nil {
			t.Fatal("accepted invalid datagram")
		}
	}
	if _, err := ReadFrame(bytes.NewReader([]byte{1, 255, 255, 255, 255})); err == nil {
		t.Fatal("accepted oversized stream frame")
	}
	if _, err := (Frame{Bits: 1}).MarshalBinary(); err == nil {
		t.Fatal("accepted missing payload")
	}
}

func TestPortAlreadyOwned(t *testing.T) {
	classic, err := net.ListenPacket("udp4", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer classic.Close()
	ca := newAuthority(t)
	listener, err := Listen(classic.LocalAddr().String(), ca.issue(t, x509.ExtKeyUsageServerAuth), ca.roots)
	if err == nil {
		listener.Close()
		t.Fatal("accepted an occupied UDP endpoint")
	}
}

func TestWrongServerName(t *testing.T) {
	ca := newAuthority(t)
	listener, err := Listen("127.0.0.1:0", ca.issue(t, x509.ExtKeyUsageServerAuth), ca.roots)
	if err != nil {
		t.Fatal(err)
	}
	defer listener.Close()
	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
	defer cancel()
	c, err := Dial(ctx, listener.Addr().String(), "wrong.invalid", ca.issue(t, x509.ExtKeyUsageClientAuth), ca.roots)
	if err == nil {
		c.CloseWithError(0, "")
		t.Fatal("accepted a server certificate with the wrong identity")
	}
	var hostnameError x509.HostnameError
	if !errors.As(err, &hostnameError) {
		t.Fatalf("expected a certificate name mismatch, got %v", err)
	}
}

func TestMobileIntegrity(t *testing.T) {
	ca := newAuthority(t)
	foreign := newAuthority(t)
	host := ca.issue(t, x509.ExtKeyUsageServerAuth)
	claim, err := url.Parse(deviceIntegrityURI)
	if err != nil {
		t.Fatal(err)
	}
	marked := ca.issue(t, x509.ExtKeyUsageClientAuth, claim)
	unmarked := ca.issue(t, x509.ExtKeyUsageClientAuth)
	for _, tc := range []struct {
		name   string
		xml    string
		cert   tls.Certificate
		accept bool
	}{
		{"absent", "", unmarked, true},
		{"blank", "<mobile_integrity/>", unmarked, true},
		{"strict device", "<mobile_integrity>yes</mobile_integrity>", marked, true},
		{"strict app only", "<mobile_integrity>yes</mobile_integrity>", unmarked, false},
		{"strict unknown issuer", "<mobile_integrity>yes</mobile_integrity>", foreign.issue(t, x509.ExtKeyUsageClientAuth, claim), false},
	} {
		t.Run(tc.name, func(t *testing.T) {
			policy, err := ReadAdmissionPolicy(strings.NewReader("<config>" + tc.xml + "</config>"))
			if err != nil {
				t.Fatal(err)
			}
			l, err := ListenWithPolicy("127.0.0.1:0", host, ca.roots, policy)
			if err != nil {
				t.Fatal(err)
			}
			defer l.Close()
			ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
			defer cancel()
			c, err := Dial(ctx, l.Addr().String(), "127.0.0.1", tc.cert, ca.roots)
			if err == nil {
				defer c.CloseWithError(0, "")
			}
			if !tc.accept {
				if err == nil {
					select {
					case <-c.Context().Done():
						err = context.Cause(c.Context())
					case <-ctx.Done():
						t.Fatal(ctx.Err())
					}
				}
				var tlsErr *quic.TransportError
				if !errors.As(err, &tlsErr) || !tlsErr.ErrorCode.IsCryptoError() {
					t.Fatalf("expected TLS rejection, got %v", err)
				}
				return
			}
			if err != nil {
				t.Fatal(err)
			}
			server, err := l.Accept(ctx)
			if err != nil {
				t.Fatal(err)
			}
			defer server.CloseWithError(0, "")
			if err = c.SendDatagram([]byte("ping")); err != nil {
				t.Fatal(err)
			}
			got, err := server.ReceiveDatagram(ctx)
			if err != nil || string(got) != "ping" {
				t.Fatalf("datagram %q, %v", got, err)
			}
		})
	}
	for _, settings := range []string{"<mobile_integrity>yess</mobile_integrity>", "<mobile_integrity/><mobile_integrity>yes</mobile_integrity>", "<mobile_integrity><yes/></mobile_integrity>"} {
		if _, err := ReadAdmissionPolicy(strings.NewReader("<config>" + settings + "</config>")); err == nil {
			t.Fatal("accepted invalid mobile_integrity setting")
		}
	}
}
