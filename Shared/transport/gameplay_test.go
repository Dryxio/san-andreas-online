package transport

import (
	"bytes"
	"context"
	"crypto/x509"
	"encoding/binary"
	"testing"
	"time"
)

func TestGameplayStreamAndUpdates(t *testing.T) {
	serverCA, installs := newAuthority(t), newAuthority(t)
	ln, err := Listen("127.0.0.1:0", serverCA.issue(t, x509.ExtKeyUsageServerAuth), installs.roots)
	if err != nil {
		t.Fatal(err)
	}
	defer ln.Close()
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	clientConn, err := Dial(ctx, ln.Addr().String(), "127.0.0.1", installs.issue(t, x509.ExtKeyUsageClientAuth), serverCA.roots)
	if err != nil {
		t.Fatal(err)
	}
	defer clientConn.CloseWithError(0, "")
	serverConn, err := ln.Accept(ctx)
	if err != nil {
		t.Fatal(err)
	}
	defer serverConn.CloseWithError(0, "")
	type result struct {
		session *GameplaySession
		err     error
	}
	opened := make(chan result, 1)
	go func() { s, e := OpenGameplay(ctx, clientConn); opened <- result{s, e} }()
	server, err := AcceptGameplay(ctx, serverConn)
	if err != nil {
		t.Fatal(err)
	}
	client := <-opened
	if client.err != nil {
		t.Fatal(client.err)
	}
	for _, ends := range [][2]*GameplaySession{{client.session, server}, {server, client.session}} {
		f := Frame{Kind: 21, Bits: 11, Payload: []byte{0xd3, 0xa0}}
		if err := ends[0].SendOrdered(f); err != nil {
			t.Fatal(err)
		}
		got, err := ends[1].ReadOrdered()
		if err != nil || got.Kind != f.Kind || got.Bits != f.Bits || !bytes.Equal(got.Payload, f.Payload) {
			t.Fatalf("ordered frame %v %v", got, err)
		}
		for _, sequenced := range []bool{true, false} {
			if err := ends[0].SendUpdate(f, 2, sequenced); err != nil {
				t.Fatal(err)
			}
			got, err = ends[1].ReadUpdate(ctx)
			if err != nil || got.Bits != 11 || !bytes.Equal(got.Payload, f.Payload) {
				t.Fatalf("update %v %v", got, err)
			}
		}
	}
	// A reordered stale datagram can never overwrite newer sync on that channel.
	wire, _ := (Frame{Kind: 20}).MarshalBinary()
	head := [9]byte{2}
	binary.BigEndian.PutUint64(head[1:], 1)
	if err := clientConn.SendDatagram(append(head[:], wire...)); err != nil {
		t.Fatal(err)
	}
	if err := client.session.SendUpdate(Frame{Kind: 22}, 2, true); err != nil {
		t.Fatal(err)
	}
	got, err := server.ReadUpdate(ctx)
	if err != nil || got.Kind != 22 {
		t.Fatalf("stale update delivered: %v %v", got, err)
	}
}

func TestGameplayReadyRequiresAcceptedCredential(t *testing.T) {
	serverCA, installs := newAuthority(t), newAuthority(t)
	ln, err := ListenWithPolicy("127.0.0.1:0", serverCA.issue(t, x509.ExtKeyUsageServerAuth), installs.roots, AdmissionPolicy{MobileIntegrity: true})
	if err != nil {
		t.Fatal(err)
	}
	defer ln.Close()
	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
	defer cancel()
	appOnly := installs.issue(t, x509.ExtKeyUsageClientAuth)
	conn, err := Dial(ctx, ln.Addr().String(), "127.0.0.1", appOnly, serverCA.roots)
	if err != nil {
		return
	}
	defer conn.CloseWithError(0, "")
	if _, err := OpenGameplay(ctx, conn); err == nil {
		t.Fatal("unapproved peer reported ready")
	}
}
