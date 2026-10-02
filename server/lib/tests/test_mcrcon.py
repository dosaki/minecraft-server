import socket
import struct
import threading

import pytest

from mcrcon import Rcon, RconError, RconAuthError, player_count


def _packet(req_id, kind, body):
    data = struct.pack("<ii", req_id, kind) + body.encode() + b"\x00\x00"
    return struct.pack("<i", len(data)) + data


def _read_packet(conn):
    length = struct.unpack("<i", conn.recv(4))[0]
    data = b""
    while len(data) < length:
        data += conn.recv(length - len(data))
    req_id, kind = struct.unpack("<ii", data[:8])
    return req_id, kind, data[8:-2].decode()


@pytest.fixture
def fake_server():
    """A one-connection RCON server. Password 'pw'; echoes 'ran: <cmd>'."""
    srv = socket.socket()
    srv.bind(("127.0.0.1", 0))
    srv.listen(1)

    def serve():
        conn, _ = srv.accept()
        with conn:
            req_id, kind, body = _read_packet(conn)
            assert kind == 3
            conn.sendall(_packet(req_id if body == "pw" else -1, 2, ""))
            if body != "pw":
                return
            while True:
                try:
                    req_id, kind, body = _read_packet(conn)
                except (struct.error, ConnectionError):
                    return
                reply = "There are 2 of a max of 20 players online: a, b" if body == "list" else f"ran: {body}"
                conn.sendall(_packet(req_id, 0, reply))

    threading.Thread(target=serve, daemon=True).start()
    yield srv.getsockname()[1]
    srv.close()


@pytest.fixture
def fake_server_closes_mid_handshake():
    """A server that accepts connection then immediately closes (simulates mid-handshake failure)."""
    srv = socket.socket()
    srv.bind(("127.0.0.1", 0))
    srv.listen(1)

    def serve():
        conn, _ = srv.accept()
        conn.close()  # Close immediately without responding

    threading.Thread(target=serve, daemon=True).start()
    yield srv.getsockname()[1]
    srv.close()


def test_command_round_trip(fake_server):
    with Rcon("127.0.0.1", fake_server, "pw") as rcon:
        assert rcon.command("say hi") == "ran: say hi"


def test_bad_password_raises(fake_server):
    with pytest.raises(RconAuthError, match="authentication"):
        with Rcon("127.0.0.1", fake_server, "wrong"):
            pass


def test_connection_refused_raises_oserror():
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        port = s.getsockname()[1]
    with pytest.raises(OSError):
        with Rcon("127.0.0.1", port, "pw", timeout=1):
            pass


def test_socket_closed_on_handshake_failure(fake_server_closes_mid_handshake, monkeypatch):
    """Verify that socket is closed when handshake fails (connection closed)."""
    import mcrcon as mcrcon_module

    # Capture the socket created by Rcon
    captured_socket = []
    original_create_connection = socket.create_connection

    def mock_create_connection(*args, **kwargs):
        sock = original_create_connection(*args, **kwargs)
        captured_socket.append(sock)
        return sock

    monkeypatch.setattr(mcrcon_module.socket, "create_connection", mock_create_connection)

    # Try to create RCON connection to a server that closes mid-handshake
    rcon = Rcon("127.0.0.1", fake_server_closes_mid_handshake, "pw")
    # Connection errors during handshake raise OSError (ConnectionResetError, etc)
    with pytest.raises((RconError, OSError)):
        with rcon:
            pass

    # Verify socket was captured and is now closed
    assert len(captured_socket) == 1, "Socket should be created once"
    sock = captured_socket[0]

    # Verify socket is closed: fileno() should return -1
    assert sock.fileno() == -1, "Socket should be closed (fileno() == -1)"


@pytest.mark.parametrize("text,expected", [
    ("There are 0 of a max of 20 players online: ", 0),
    ("There are 3 of a max of 20 players online: a, b, c", 3),
    ("§6There are §c1§6 of a max of §c20§6 players online:", 1),
])
def test_player_count(text, expected):
    assert player_count(text) == expected


def test_player_count_rejects_garbage():
    with pytest.raises(RconError):
        player_count("Unknown command")
