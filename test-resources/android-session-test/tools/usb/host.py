"""Loopback-only ADB test link to one IPv4 game endpoint."""
import argparse
import ipaddress
import select
import socket
import struct


def read_exact(stream, size):
    data = bytearray()
    while len(data) < size:
        part = stream.recv(size - len(data))
        if not part:
            raise EOFError
        data.extend(part)
    return data


def forward(stream, endpoint):
    game = None
    try:
        while True:
            ready, _, _ = select.select([stream, game] if game else [stream], [], [])
            if stream in ready:
                length, = struct.unpack("!i", read_exact(stream, 4))
                if length == -1:
                    if game:
                        game.close()
                    game = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
                    game.connect(endpoint)
                    continue
                if not game or not 0 <= length <= 65507:
                    raise ValueError("Invalid UDP frame")
                game.send(read_exact(stream, length))
            if game in ready:
                data = game.recv(65507)
                stream.sendall(struct.pack("!i", len(data)) + data)
    finally:
        if game:
            game.close()


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("server", type=ipaddress.IPv4Address)
    parser.add_argument("port", type=int)
    args = parser.parse_args()
    if not 1 <= args.port <= 65535:
        parser.error("Game port must be between 1 and 65535")
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as listener:
        listener.bind(("127.0.0.1", 42673))
        listener.listen(1)
        while True:
            stream, _ = listener.accept()
            with stream:
                stream.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
                try:
                    forward(stream, (str(args.server), args.port))
                except (EOFError, OSError, ValueError):
                    pass
