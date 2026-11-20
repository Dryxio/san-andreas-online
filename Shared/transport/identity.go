package transport

import (
	"bytes"
	"context"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/x509"
	"encoding/pem"
	"errors"
	"fmt"
	"io"
	"net/http"
	"time"
)

const installCAURL = "https://identity.mta-neon.com/.well-known/neon-android-install-ca.pem"

// AndroidInstallRoots loads only the public CA for installs verified by Neon
// Identity. TLS validates the publisher independently of the connecting peer.
func AndroidInstallRoots(ctx context.Context) (*x509.CertPool, error) {
	client := &http.Client{
		Timeout:       5 * time.Second,
		CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse },
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, installCAURL, nil)
	if err != nil {
		return nil, err
	}
	res, err := client.Do(req)
	if err != nil {
		return nil, err
	}
	defer res.Body.Close()
	if res.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("Android install CA unavailable: HTTP %d", res.StatusCode)
	}
	return readInstallRoots(res.Body, time.Now())
}

func readInstallRoots(body io.Reader, now time.Time) (*x509.CertPool, error) {
	const maxSize = 16 << 10
	data, err := io.ReadAll(io.LimitReader(body, maxSize+1))
	if err != nil {
		return nil, err
	}
	if len(data) > maxSize {
		return nil, errors.New("Android install CA exceeds the response limit")
	}
	data = bytes.TrimSpace(data)
	if !bytes.HasPrefix(data, []byte("-----BEGIN CERTIFICATE-----")) {
		return nil, errors.New("invalid Android install CA response")
	}
	block, rest := pem.Decode(data)
	if block == nil || block.Type != "CERTIFICATE" || len(bytes.TrimSpace(rest)) != 0 {
		return nil, errors.New("expected one Android install CA certificate")
	}
	cert, err := x509.ParseCertificate(block.Bytes)
	if err != nil {
		return nil, err
	}
	key, ok := cert.PublicKey.(*ecdsa.PublicKey)
	if !ok || key.Curve != elliptic.P256() || !cert.BasicConstraintsValid || !cert.IsCA ||
		cert.KeyUsage&x509.KeyUsageCertSign == 0 || now.Before(cert.NotBefore) || !now.Before(cert.NotAfter) {
		return nil, errors.New("invalid Android install signing authority")
	}
	roots := x509.NewCertPool()
	roots.AddCert(cert)
	return roots, nil
}
