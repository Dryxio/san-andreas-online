package transport

import (
	"encoding/binary"
	"errors"
	"io"
)

// The length on the wire counts bits because some gameplay packets end in a
// partial byte. Framing is identical inside ordered streams and datagrams.
type Frame struct {
	Kind    byte
	Bits    uint32
	Payload []byte
}

const maxPayload = 256 << 10

func payloadSize(bits uint32) (int, error) {
	if bits > maxPayload*8 {
		return 0, errors.New("Neon frame exceeds the payload limit")
	}
	return int((bits + 7) / 8), nil
}

func (f Frame) MarshalBinary() ([]byte, error) {
	n, err := payloadSize(f.Bits)
	if err != nil {
		return nil, err
	}
	if len(f.Payload) != n {
		return nil, errors.New("Neon frame length does not match its payload")
	}
	buf := make([]byte, 5+n)
	buf[0] = f.Kind
	binary.BigEndian.PutUint32(buf[1:5], f.Bits)
	copy(buf[5:], f.Payload)
	return buf, nil
}

// ReadFrame reads exactly one message from an ordered stream.
func ReadFrame(r io.Reader) (Frame, error) {
	var header [5]byte
	if _, err := io.ReadFull(r, header[:]); err != nil {
		return Frame{}, err
	}
	bits := binary.BigEndian.Uint32(header[1:])
	n, err := payloadSize(bits)
	if err != nil {
		return Frame{}, err
	}
	data := make([]byte, n)
	if _, err := io.ReadFull(r, data); err != nil {
		return Frame{}, err
	}
	return Frame{Kind: header[0], Bits: bits, Payload: data}, nil
}

// ParseDatagram validates the whole message before returning a view into data.
func ParseDatagram(data []byte) (Frame, error) {
	if len(data) < 5 {
		return Frame{}, io.ErrUnexpectedEOF
	}
	bits := binary.BigEndian.Uint32(data[1:5])
	n, err := payloadSize(bits)
	if err != nil {
		return Frame{}, err
	}
	if len(data)-5 != n {
		return Frame{}, errors.New("invalid Neon datagram length")
	}
	return Frame{Kind: data[0], Bits: bits, Payload: data[5:]}, nil
}
