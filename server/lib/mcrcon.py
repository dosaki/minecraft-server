"""Minimal Source RCON client (as used by Minecraft) plus output parsing."""
import re
import socket
import struct

_LOGIN, _COMMAND = 3, 2
_PLAYERS = re.compile(r"There are (\d+)")
_COLOUR = re.compile("§.")


class RconError(Exception):
    pass


class Rcon:
    def __init__(self, host: str, port: int, password: str, timeout: float = 10):
        self._addr = (host, port)
        self._password = password
        self._timeout = timeout
        self._sock = None
        self._next_id = 0

    def __enter__(self):
        self._sock = socket.create_connection(self._addr, timeout=self._timeout)
        req_id = self._send(_LOGIN, self._password)
        resp_id, _, _ = self._recv()
        if resp_id == -1 or resp_id != req_id:
            self._sock.close()
            raise RconError("authentication failed")
        return self

    def __exit__(self, *exc):
        self._sock.close()

    def command(self, cmd: str) -> str:
        self._send(_COMMAND, cmd)
        _, _, body = self._recv()
        return body

    def _send(self, kind: int, body: str) -> int:
        self._next_id += 1
        data = struct.pack("<ii", self._next_id, kind) + body.encode("utf-8") + b"\x00\x00"
        self._sock.sendall(struct.pack("<i", len(data)) + data)
        return self._next_id

    def _recv(self):
        (length,) = struct.unpack("<i", self._read(4))
        data = self._read(length)
        req_id, kind = struct.unpack("<ii", data[:8])
        return req_id, kind, data[8:-2].decode("utf-8", "replace")

    def _read(self, n: int) -> bytes:
        buf = b""
        while len(buf) < n:
            chunk = self._sock.recv(n - len(buf))
            if not chunk:
                raise RconError("connection closed")
            buf += chunk
        return buf


def player_count(list_output: str) -> int:
    match = _PLAYERS.search(_COLOUR.sub("", list_output))
    if not match:
        raise RconError(f"unexpected list output: {list_output!r}")
    return int(match.group(1))
