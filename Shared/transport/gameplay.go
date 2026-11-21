// Gameplay sessions carry game packet IDs and exact payload bit counts.
// Reliability and ordering are transport metadata, never player identity.
package transport

import (
	"context"
	"encoding/binary"
	"errors"
	"io"
	"sync"
	"time"

	"github.com/quic-go/quic-go"
)

const (
	gameChannels = 5 // ePacketOrdering in Server/sdk/net/ns_common.h
	unsequenced  = 0xff
)

type GameplaySession struct {
	conn            *quic.Conn
	ordered         *quic.Stream
	writeMu         sync.Mutex
	readMu          sync.Mutex
	datagramWriteMu sync.Mutex
	datagramReadMu  sync.Mutex
	sent            [gameChannels]uint64
	received        [gameChannels]uint64
}

// OpenGameplay opens the single bidirectional ordered stream. Its preface also
// makes the stream visible to the server before the first application packet.
func OpenGameplay(ctx context.Context, conn *quic.Conn) (*GameplaySession, error) {
	stream, err := conn.OpenStreamSync(ctx)
	if err != nil {
		return nil, err
	}
	return handshakeGameplay(ctx, conn, stream, true)
}

// AcceptGameplay must only be called on a connection accepted by the mutual
// TLS listener. The returned session has no player privileges before game admission.
func AcceptGameplay(ctx context.Context, conn *quic.Conn) (*GameplaySession, error) {
	stream, err := conn.AcceptStream(ctx)
	if err != nil {
		return nil, err
	}
	return handshakeGameplay(ctx, conn, stream, false)
}

func handshakeGameplay(ctx context.Context, conn *quic.Conn, stream *quic.Stream, client bool) (*GameplaySession, error) {
	datagrams := conn.ConnectionState().SupportsDatagrams
	if stream.StreamID() != 0 || !datagrams.Local || !datagrams.Remote {
		conn.CloseWithError(1, "unsupported gameplay transport")
		return nil, errors.New("expected stream zero and QUIC datagrams")
	}
	if deadline, ok := ctx.Deadline(); ok {
		stream.SetDeadline(deadline)
	}
	// Context cancellation also interrupts a partial preface on an open stream.
	stopped := make(chan struct{})
	stop := context.AfterFunc(ctx, func() {
		stream.SetDeadline(time.Now())
		close(stopped)
	})
	defer func() {
		if !stop() {
			<-stopped
		}
		stream.SetDeadline(time.Time{})
	}()
	write := func() error {
		_, err := stream.Write([]byte("NGP1"))
		return err
	}
	read := func() error {
		var preface [4]byte
		if _, err := io.ReadFull(stream, preface[:]); err != nil {
			return err
		}
		if string(preface[:]) != "NGP1" {
			return errors.New("invalid gameplay preface")
		}
		return nil
	}
	first, second := read, write
	if client {
		first, second = write, read
	}
	err := first()
	if err == nil {
		err = second()
	}
	if err != nil {
		conn.CloseWithError(1, "gameplay handshake failed")
		return nil, err
	}
	return &GameplaySession{conn: conn, ordered: stream}, nil
}

func (s *GameplaySession) Close() error { return s.conn.CloseWithError(0, "") }

func (s *GameplaySession) SendOrdered(f Frame) error {
	wire, err := f.MarshalBinary()
	if err != nil {
		return err
	}
	s.writeMu.Lock()
	defer s.writeMu.Unlock()
	if _, err = s.ordered.Write(wire); err != nil {
		// A partial frame makes further writes on this stream ambiguous.
		s.conn.CloseWithError(1, "gameplay stream write failed")
	}
	return err
}

func (s *GameplaySession) ReadOrdered() (Frame, error) {
	s.readMu.Lock()
	defer s.readMu.Unlock()
	frame, err := ReadFrame(s.ordered)
	if err != nil {
		s.conn.CloseWithError(1, "gameplay stream ended")
	}
	return frame, err
}

// SendUpdate uses QUIC DATAGRAM. Unsequenced packets can arrive in any order.
// A sequenced packet supersedes earlier sequenced packets on its ordering channel.
func (s *GameplaySession) SendUpdate(f Frame, channel uint8, sequenced bool) error {
	if channel >= gameChannels {
		return errors.New("invalid game ordering channel")
	}
	wire, err := f.MarshalBinary()
	if err != nil {
		return err
	}
	if !sequenced {
		return s.conn.SendDatagram(append([]byte{unsequenced}, wire...))
	}
	s.datagramWriteMu.Lock()
	defer s.datagramWriteMu.Unlock()
	s.sent[channel]++
	header := [9]byte{channel}
	binary.BigEndian.PutUint64(header[1:], s.sent[channel])
	return s.conn.SendDatagram(append(header[:], wire...))
}

func (s *GameplaySession) ReadUpdate(ctx context.Context) (Frame, error) {
	s.datagramReadMu.Lock()
	defer s.datagramReadMu.Unlock()
	for {
		data, err := s.conn.ReceiveDatagram(ctx)
		if err != nil {
			return Frame{}, err
		}
		if len(data) == 0 {
			return Frame{}, errors.New("missing game datagram channel")
		}
		channel := data[0]
		if channel == unsequenced {
			return ParseDatagram(data[1:])
		}
		if channel >= gameChannels || len(data) < 9 {
			return Frame{}, errors.New("invalid sequenced game datagram")
		}
		frame, err := ParseDatagram(data[9:])
		if err != nil {
			return Frame{}, err
		}
		seq := binary.BigEndian.Uint64(data[1:9])
		if seq <= s.received[channel] {
			continue
		}
		s.received[channel] = seq
		return frame, nil
	}
}
