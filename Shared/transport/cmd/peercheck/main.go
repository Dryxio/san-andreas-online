// Command peercheck verifies a native Neon UDP connection between two hosts.
// The listener serves a single authenticated peer and exits.
package main

import (
	"bytes"
	"context"
	"crypto/rand"
	"crypto/tls"
	"crypto/x509"
	"errors"
	"flag"
	"fmt"
	"net"
	"os"
	"time"

	"github.com/Dryxio/san-andreas-online/Shared/transport"
)

func run() error {
	serve := flag.Bool("listen", false, "listen for one peer")
	addr := flag.String("address", "", "UDP host:port")
	name := flag.String("server-name", "", "expected server certificate name (defaults to address host)")
	cert := flag.String("cert", "", "peer certificate chain PEM")
	key := flag.String("key", "", "peer private key PEM")
	ca := flag.String("ca", "", "CA PEM for the remote peer (listener default: Neon Identity Android install CA)")
	config := flag.String("config", "", "listener mtaserver.conf containing the mobile_integrity policy")
	flag.Parse()
	if *config != "" && !*serve {
		return errors.New("-config applies only to the listener")
	}
	host, _, err := net.SplitHostPort(*addr)
	if err != nil {
		return err
	}
	pair, err := tls.LoadX509KeyPair(*cert, *key)
	if err != nil {
		return err
	}
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	var roots *x509.CertPool
	if *serve && *ca == "" {
		roots, err = transport.AndroidInstallRoots(ctx)
		if err != nil {
			return err
		}
	} else {
		pem, err := os.ReadFile(*ca)
		if err != nil {
			return err
		}
		roots = x509.NewCertPool()
		if !roots.AppendCertsFromPEM(pem) {
			return errors.New("invalid CA file")
		}
	}
	deadline, _ := ctx.Deadline()
	if *serve {
		var policy transport.AdmissionPolicy
		if *config != "" {
			f, err := os.Open(*config)
			if err != nil {
				return err
			}
			defer f.Close()
			policy, err = transport.ReadAdmissionPolicy(f)
			if err != nil {
				return err
			}
		}
		l, err := transport.ListenWithPolicy(*addr, pair, roots, policy)
		if err != nil {
			return err
		}
		defer l.Close()
		fmt.Println("Listening on", l.Addr())
		c, err := l.Accept(ctx)
		if err != nil {
			return err
		}
		defer c.CloseWithError(0, "")
		s, err := c.AcceptStream(ctx)
		if err != nil {
			return err
		}
		s.SetDeadline(deadline)
		received, err := transport.ReadFrame(s)
		if err != nil {
			return err
		}
		if received.Kind != 1 || received.Bits != 256 {
			return errors.New("invalid check request")
		}
		received.Kind = 2
		response, err := received.MarshalBinary()
		if err != nil {
			return err
		}
		if err = c.SendDatagram(response); err != nil {
			return err
		}
		// Wait until the client confirms receipt before closing the connection.
		ack, err := transport.ReadFrame(s)
		if err != nil {
			return err
		}
		if ack.Kind != 3 || !bytes.Equal(ack.Payload, received.Payload) || ack.Bits != 256 {
			return errors.New("invalid acknowledgement")
		}
		if _, err = s.Write([]byte{4, 0, 0, 0, 0}); err != nil {
			return err
		}
		if err = s.Close(); err != nil {
			return err
		}
		select {
		case <-c.Context().Done():
			return nil
		case <-ctx.Done():
			return ctx.Err()
		}
	}
	if *name == "" {
		*name = host
	}
	c, err := transport.Dial(ctx, *addr, *name, pair, roots)
	if err != nil {
		return err
	}
	defer c.CloseWithError(0, "")
	s, err := c.OpenStreamSync(ctx)
	if err != nil {
		return err
	}
	s.SetDeadline(deadline)
	nonce := make([]byte, 32)
	if _, err = rand.Read(nonce); err != nil {
		return err
	}
	f := transport.Frame{Kind: 1, Bits: 256, Payload: nonce}
	write := func() error {
		b, err := f.MarshalBinary()
		if err != nil {
			return err
		}
		_, err = s.Write(b)
		return err
	}
	if err = write(); err != nil {
		return err
	}
	data, err := c.ReceiveDatagram(ctx)
	if err != nil {
		return err
	}
	reply, err := transport.ParseDatagram(data)
	if err != nil {
		return err
	}
	if reply.Kind != 2 || reply.Bits != 256 || !bytes.Equal(nonce, reply.Payload) {
		return errors.New("invalid check response")
	}
	f.Kind = 3
	if err = write(); err != nil {
		return err
	}
	ack, err := transport.ReadFrame(s)
	if err != nil {
		return err
	}
	if ack.Kind != 4 || ack.Bits != 0 {
		return errors.New("invalid completion frame")
	}
	return nil
}

func main() {
	if err := run(); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
	fmt.Println("Authenticated stream and datagram check passed.")
}
