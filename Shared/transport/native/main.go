// The native gameplay ABI is built with Go's c-shared build mode. Handles are
// local to this process. Only the transport creates them after mutual TLS.
package main

/*
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

// The callback signs a SHA-256 digest with the installation key. Return the
// number of bytes of ASN.1 DER ECDSA signature, or zero on failure.
typedef int (*NeonSignDigest)(uintptr_t key, const uint8_t *digest, uint8_t *der, int capacity);
static inline int neonSign(NeonSignDigest fn, uintptr_t key, const uint8_t *digest, uint8_t *der, int capacity) {
    return fn(key, digest, der, capacity);
}
*/
import "C"

import (
	"bytes"
	"context"
	"crypto"
	"crypto/ecdsa"
	"crypto/sha256"
	"crypto/tls"
	"crypto/x509"
	"errors"
	"io"
	"net"
	"net/netip"
	"os"
	"sync"
	"time"
	"unsafe"

	"github.com/Dryxio/san-andreas-online/Shared/transport"
	"github.com/quic-go/quic-go"
)

type listener struct {
	net    *quic.Listener
	ctx    context.Context
	cancel context.CancelFunc
}

type update struct {
	frame     transport.Frame
	channel   uint8
	sequenced bool
}

type peer struct {
	game        *transport.GameplaySession
	conn        *quic.Conn
	packets     chan transport.Frame
	outgoing    chan transport.Frame
	updates     chan update
	sendMu      sync.Mutex
	queuedBytes int
}

var handles = struct {
	sync.Mutex
	next      uint64
	listeners map[uint64]*listener
	peers     map[uint64]*peer
}{listeners: make(map[uint64]*listener), peers: make(map[uint64]*peer)}

func findPeer(id C.uint64_t) *peer {
	handles.Lock()
	defer handles.Unlock()
	return handles.peers[uint64(id)]
}

func registerPeer(c *quic.Conn, game *transport.GameplaySession) C.uint64_t {
	p := &peer{game: game, conn: c, packets: make(chan transport.Frame, 8), outgoing: make(chan transport.Frame, 256), updates: make(chan update, 64)}
	receive := func(next func() (transport.Frame, error)) {
		for {
			f, err := next()
			if err != nil {
				c.CloseWithError(1, "gameplay receive ended")
				return
			}
			select {
			case p.packets <- f:
			case <-c.Context().Done():
				return
			}
		}
	}
	go func() {
		for {
			select {
			case <-c.Context().Done():
				return
			case f := <-p.outgoing:
				if err := game.SendOrdered(f); err != nil {
					return
				}
				p.sendMu.Lock()
				p.queuedBytes -= len(f.Payload)
				p.sendMu.Unlock()
			}
		}
	}()
	go func() {
		for {
			select {
			case <-c.Context().Done():
				return
			case next := <-p.updates:
				err := game.SendUpdate(next.frame, next.channel, next.sequenced)
				var large *quic.DatagramTooLargeError
				if err != nil && !errors.As(err, &large) {
					c.CloseWithError(1, "gameplay datagram send failed")
					return
				}
			}
		}
	}()
	go receive(game.ReadOrdered)
	go receive(func() (transport.Frame, error) { return game.ReadUpdate(c.Context()) })
	handles.Lock()
	defer handles.Unlock()
	handles.next++
	handles.peers[handles.next] = p
	return C.uint64_t(handles.next)
}

func loadRoots(name string) (*x509.CertPool, error) {
	data, err := os.ReadFile(name)
	if err != nil {
		return nil, err
	}
	roots := x509.NewCertPool()
	if !roots.AppendCertsFromPEM(data) {
		return nil, errors.New("invalid certificate authority")
	}
	return roots, nil
}

func setError(out *C.char, size C.int, err error) {
	if out == nil || size <= 0 {
		return
	}
	buf := unsafe.Slice((*byte)(unsafe.Pointer(out)), int(size))
	n := copy(buf[:len(buf)-1], err.Error())
	buf[n] = 0
}

//export NeonGameListen
func NeonGameListen(address, certificate, key, clientCA, config *C.char, out *C.char, size C.int) C.uint64_t {
	host, err := tls.LoadX509KeyPair(C.GoString(certificate), C.GoString(key))
	if err != nil {
		setError(out, size, err)
		return 0
	}
	file, err := os.Open(C.GoString(config))
	if err != nil {
		setError(out, size, err)
		return 0
	}
	defer file.Close()
	policy, err := transport.ReadAdmissionPolicy(file)
	if err != nil {
		setError(out, size, err)
		return 0
	}
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	var roots *x509.CertPool
	if ca := C.GoString(clientCA); ca != "" {
		roots, err = loadRoots(ca)
	} else {
		roots, err = transport.AndroidInstallRoots(ctx)
	}
	if err != nil {
		setError(out, size, err)
		return 0
	}
	ln, err := transport.ListenWithPolicy(C.GoString(address), host, roots, policy)
	if err != nil {
		setError(out, size, err)
		return 0
	}
	lctx, stop := context.WithCancel(context.Background())
	handles.Lock()
	defer handles.Unlock()
	handles.next++
	handles.listeners[handles.next] = &listener{ln, lctx, stop}
	return C.uint64_t(handles.next)
}

//export NeonGameStopListen
func NeonGameStopListen(id C.uint64_t) {
	handles.Lock()
	l := handles.listeners[uint64(id)]
	delete(handles.listeners, uint64(id))
	handles.Unlock()
	if l != nil {
		l.cancel()
		l.net.Close()
	}
}

// NeonGameAccept blocks on a worker. An invalid gameplay stream is rejected
// and never yields a peer handle. StopListen interrupts pending accepts.
//
//export NeonGameAccept
func NeonGameAccept(id C.uint64_t) C.uint64_t {
	handles.Lock()
	l := handles.listeners[uint64(id)]
	handles.Unlock()
	if l == nil {
		return 0
	}
	for {
		c, err := l.net.Accept(l.ctx)
		if err != nil {
			return 0
		}
		ctx, cancel := context.WithTimeout(l.ctx, 3*time.Second)
		game, err := transport.AcceptGameplay(ctx, c)
		cancel()
		if err == nil {
			return registerPeer(c, game)
		}
		c.CloseWithError(1, "gameplay handshake failed")
	}
}

type nativeSigner struct {
	pub  *ecdsa.PublicKey
	key  C.uintptr_t
	sign C.NeonSignDigest
}

func (s nativeSigner) Public() crypto.PublicKey { return s.pub }
func (s nativeSigner) Sign(_ io.Reader, digest []byte, opts crypto.SignerOpts) ([]byte, error) {
	if len(digest) != 32 || opts.HashFunc() != crypto.SHA256 {
		return nil, errors.New("unsupported install key signature algorithm")
	}
	var sig [80]byte
	n := int(C.neonSign(s.sign, s.key, (*C.uint8_t)(&digest[0]), (*C.uint8_t)(&sig[0]), C.int(len(sig))))
	if n <= 0 || n > len(sig) {
		return nil, errors.New("install key signing failed")
	}
	return sig[:n], nil
}

// NeonGameDial uses the platform keystore callback and validates the server
// against system roots (or an explicitly provisioned host CA).
//
//export NeonGameDial
func NeonGameDial(address, name, serverCA *C.char, der *C.uint8_t, length C.int, key C.uintptr_t, sign C.NeonSignDigest, out *C.char, size C.int) C.uint64_t {
	if der == nil || length <= 0 || length > 65536 || sign == nil {
		setError(out, size, errors.New("missing install credential"))
		return 0
	}
	raw := C.GoBytes(unsafe.Pointer(der), length)
	leaf, err := x509.ParseCertificate(raw)
	if err != nil {
		setError(out, size, err)
		return 0
	}
	pub, ok := leaf.PublicKey.(*ecdsa.PublicKey)
	if !ok || pub.Params().Name != "P-256" {
		setError(out, size, errors.New("expected a P-256 install key"))
		return 0
	}
	pair := tls.Certificate{Certificate: [][]byte{raw}, Leaf: leaf, PrivateKey: nativeSigner{pub, key, sign}}
	var roots *x509.CertPool
	if file := C.GoString(serverCA); file != "" {
		roots, err = loadRoots(file)
	} else {
		roots, err = x509.SystemCertPool()
	}
	if err != nil {
		setError(out, size, err)
		return 0
	}
	ctx, cancel := context.WithTimeout(context.Background(), 8*time.Second)
	defer cancel()
	c, err := transport.Dial(ctx, C.GoString(address), C.GoString(name), pair, roots)
	if err != nil {
		setError(out, size, err)
		return 0
	}
	game, err := transport.OpenGameplay(ctx, c)
	if err != nil {
		c.CloseWithError(1, "gameplay handshake failed")
		setError(out, size, err)
		return 0
	}
	return registerPeer(c, game)
}

//export NeonGameClose
func NeonGameClose(id C.uint64_t) {
	handles.Lock()
	p := handles.peers[uint64(id)]
	delete(handles.peers, uint64(id))
	handles.Unlock()
	if p != nil {
		p.game.Close()
	}
}

// NeonGamePoll returns one complete frame (1), empty (0), or disconnected (-1).
// The caller supplies a reusable buffer at least 256 KiB in size.
//
//export NeonGamePoll
func NeonGamePoll(id C.uint64_t, kind *C.uint8_t, bits *C.uint32_t, buf *C.uint8_t, capacity C.int) C.int {
	p := findPeer(id)
	if p == nil || kind == nil || bits == nil || buf == nil || capacity < 256<<10 || p.conn.Context().Err() != nil {
		return -1
	}
	select {
	case f := <-p.packets:
		*kind = C.uint8_t(f.Kind)
		*bits = C.uint32_t(f.Bits)
		copy(unsafe.Slice((*byte)(unsafe.Pointer(buf)), len(f.Payload)), f.Payload)
		return 1
	default:
		return 0
	}
}

// NeonGameSend maps mode 0 to ordered delivery, 1 to an update and 2 to a
// sequenced update. Returns 1 for accepted, 0 for an unsent update, -1 on error.
//
//export NeonGameSend
func NeonGameSend(id C.uint64_t, kind C.uint8_t, bits C.uint32_t, buf *C.uint8_t, mode, channel C.uint8_t) C.int {
	p := findPeer(id)
	if p == nil || p.conn.Context().Err() != nil || bits > (256<<10)*8 || (bits != 0 && buf == nil) {
		return -1
	}
	f := transport.Frame{Kind: byte(kind), Bits: uint32(bits), Payload: unsafe.Slice((*byte)(unsafe.Pointer(buf)), (int(bits)+7)/8)}
	switch mode {
	case 0:
		p.sendMu.Lock()
		defer p.sendMu.Unlock()
		if p.queuedBytes+len(f.Payload) <= 2<<20 && len(p.outgoing) < cap(p.outgoing) {
			// The caller owns buf only for the duration of this call.
			f.Payload = bytes.Clone(f.Payload)
			p.queuedBytes += len(f.Payload)
			p.outgoing <- f
			return 1
		}
		p.conn.CloseWithError(1, "gameplay send queue full")
		return -1
	case 1, 2:
		if channel >= 5 || len(f.Payload) > 65527 {
			return 0
		}
		f.Payload = bytes.Clone(f.Payload)
		select {
		case p.updates <- update{f, uint8(channel), mode == 2}:
			return 1
		default:
			return 0
		}
	default:
		return -1
	}
}

// NeonGamePeerInfo reports the authenticated leaf key fingerprint and actual
// remote IPv4 address to the server's admission and ban checks.
//
//export NeonGamePeerInfo
func NeonGamePeerInfo(id C.uint64_t, ip, keyHash *C.uint8_t, port *C.uint16_t) C.int {
	p := findPeer(id)
	if p == nil || ip == nil || keyHash == nil || port == nil {
		return 0
	}
	chains := p.conn.ConnectionState().TLS.VerifiedChains
	if len(chains) == 0 || len(chains[0]) < 2 {
		return 0
	}
	addr, ok := p.conn.RemoteAddr().(*net.UDPAddr)
	if !ok {
		return 0
	}
	a, ok := netip.AddrFromSlice(addr.IP)
	if !ok || !a.Unmap().Is4() {
		return 0
	}
	v4 := a.Unmap().As4()
	copy(unsafe.Slice((*byte)(unsafe.Pointer(ip)), 4), v4[:])
	hash := sha256.Sum256(chains[0][0].RawSubjectPublicKeyInfo)
	copy(unsafe.Slice((*byte)(unsafe.Pointer(keyHash)), 32), hash[:])
	*port = C.uint16_t(addr.Port)
	return 1
}

func main() {}
