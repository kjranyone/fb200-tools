"""Mobile wire payloads against real C RPC + NOR store; no pedal access."""
import ctypes as ct
import itertools
import shutil
import struct
import subprocess
import zlib

import pytest
from test_nam_a2 import FW, ROOT, model
from test_nam_runtime import latest, staging

from fb200 import nam
from fb200.protocol import pack_frame


@pytest.fixture(scope="module")
def rpc(tmp_path_factory):
    if not shutil.which("cc"):
        pytest.skip("no C compiler")
    path = tmp_path_factory.mktemp("namrpc") / "rpc.so"
    subprocess.run(["cc", "-O2", "-Wall", "-Wextra", "-Werror", "-shared", "-fPIC",
                    "-I", str(FW / "src"),
                    *[str(FW / p) for p in ["tests/namstore_host.c", "tests/namrpc_host.c",
                      "src/namstore/namstore.c", "src/namstore/namrpc.c", "src/dsp/nam_a2.c",
                      "src/crc32.c"]], "-o", str(path)], check=True)
    lib = ct.CDLL(str(path))
    lib.namstore_record.restype = ct.POINTER(ct.c_ubyte)
    lib.namrpc_request.argtypes = [ct.c_uint8, ct.c_void_p, ct.c_uint32, ct.c_void_p, ct.c_uint32]
    return lib


class Client:
    ids = itertools.count(1)

    def __init__(self, lib):
        self.lib = lib

    def call(self, op, args=b"", *, source=2, status=0, request=None):
        p = request or bytes([1, op]) + struct.pack("<H", next(self.ids)) + args
        out = ct.create_string_buffer(128)
        n = self.lib.namrpc_request(source, p, len(p), out, 128)
        reply = out.raw[:n]
        assert reply[:4] == p[:4]
        assert reply[4] == status
        self.last_request = p
        return reply[5:]

    def begin(self, packet, slot=1, **kwargs):
        return self.call(2, struct.pack("<BHI", slot, len(packet), zlib.crc32(packet)), **kwargs)[:4]

    def upload(self, packet, slot=1):
        token = self.begin(packet, slot)
        for offset in range(0, len(packet), 64):
            chunk = packet[offset:offset+64]
            assert self.call(3, token + struct.pack("<H", offset) + chunk) == (
                token + struct.pack("<H", offset+len(chunk)))
        assert self.lib.fake_writes() == 0
        self.call(4, token)
        return token


@pytest.fixture
def client(rpc):
    rpc.fake_reset()
    rpc.fake_selection_reset()
    return Client(rpc)


def test_mobile_fixture_matches_python_packet_and_frame():
    import json
    directory = ROOT / "mobile/test/fixtures"
    document = json.loads((directory / "synthetic.nam").read_text())
    assert nam.pack(document, "synthetic") == (directory / "synthetic.fbnm").read_bytes()
    assert pack_frame(0xE0, bytes([1, 0, 0x34, 0x12])).hex() == "aa550500e00100341230c2"


def test_caps_list_transfer_select_save_delete_and_commit_retry(client):
    c = client
    assert c.call(0) == struct.pack("<IHBBHHB", 48000, 1871, 3, 64, 7548, 7 | 16, 0)
    state = c.call(1)
    assert len(state) == 91 and state[0] == 0 and state[1:3] == b"\x01\0"
    packet = nam.pack(model(), "phone")
    token = c.upload(packet)
    commit = c.last_request
    writes = c.lib.fake_writes()
    # Lost commit ACK: exact retry acknowledges without a second flash update.
    c.call(4, request=commit)
    assert c.lib.fake_writes() == writes
    assert latest(c.lib)[64:] == packet[64:]
    c.call(6, b"\x01\x01")
    saved = c.last_request
    c.call(6, request=saved)
    assert c.lib.fake_saved() == 1 and c.call(1)[0] == 1
    c.call(7, b"\x01")
    assert c.call(1)[0] == 0 and c.call(1)[2] == 0
    c.call(4, token, status=6)


def test_duplicate_chunk_source_offset_token_and_expiry(client):
    c = client
    packet = nam.pack(model())
    token = c.begin(packet)
    args = token + b"\0\0" + packet[:64]
    ack = c.call(3, args)
    retry = c.last_request
    assert c.call(3, request=retry) == ack
    assert c.call(3, args) == ack  # new id, identical old bytes
    c.call(3, args, source=1, status=6)
    c.call(3, b"\0\0\0\0" + args[4:], status=6)
    c.call(3, token + struct.pack("<H", 65) + b"x", status=1)
    c.call(3, token + b"\0\0" + b"x" * 64, status=1)
    c.call(3, token + struct.pack("<H", 64) + b"x" * 65, status=1)
    c.call(4, token, status=1)  # incomplete upload never commits
    c.begin(packet, status=2)
    c.call(6, b"\0\0", status=2)
    c.call(7, b"\x01", status=2)
    c.lib.fake_time(3001)
    c.lib.namrpc_task()
    c.call(3, args, status=6)
    assert c.lib.fake_writes() == 0
    token = c.begin(packet)
    c.call(5, token)
    assert not c.lib.namstore_active() and c.lib.fake_writes() == 0


def test_usb_console_and_ble_share_staging_lock(client):
    c = client
    packet = nam.pack(model())
    assert c.lib.namstore_begin(1, len(packet), zlib.crc32(packet)) == 0
    c.begin(packet, status=2)
    assert c.lib.namstore_console_active() == 1
    c.lib.fake_time(3001)
    c.lib.namstore_task()
    token = c.begin(packet)
    assert c.lib.namstore_begin(1, len(packet), zlib.crc32(packet)) != 0
    assert c.lib.namstore_console_active() == 0
    c.call(5, token)


@pytest.mark.parametrize("fault", ["crc", "header", "nan", "flash"])
def test_failed_mobile_upload_keeps_previous_model(client, fault):
    c = client
    original = nam.pack(model(), "previous")
    assert c.lib.namstore_write(1, staging(original)) == 0
    old = latest(c.lib)
    packet = bytearray(nam.pack(model(), "next"))
    if fault == "header":
        packet[60] ^= 1
    if fault == "nan":
        struct.pack_into("<I", packet, 64, 0x7fc00000)
        struct.pack_into("<I", packet, 16, zlib.crc32(packet[64:]))
        struct.pack_into("<I", packet, 60, zlib.crc32(packet[:60]))
    token = c.begin(packet)
    if fault == "crc":
        packet[-1] ^= 1
    for offset in range(0, len(packet), 64):
        c.call(3, token + struct.pack("<H", offset) + packet[offset:offset+64])
    if fault == "flash":
        c.lib.fake_cut(4097)
    c.call(4, token, status=4 if fault == "flash" else 3)
    assert latest(c.lib) == old


@pytest.mark.parametrize("op,args", [(0, b"x"), (1, b"x"), (2, b""),
    (6, b"\x04\0"), (6, b"\0\x02"), (7, b"\0"), (7, b"\x04")])
def test_invalid_arguments(client, op, args):
    client.call(op, args, status=1)
    assert client.lib.fake_writes() == 0


def slot_name(c, slot=1):
    state = c.call(1)
    off = 1 + (slot - 1) * 30 + 2   # [slot][used][name 24][crc 4] per slot
    return state[off:off + 24].split(b"\0")[0].decode()


def test_rename_rewrites_header_only_and_keeps_weights(client):
    c = client
    packet = nam.pack(model(), "oldname")
    c.upload(packet, 1)
    first_bank = c.lib.namstore_current(1)
    c.call(9, b"\x01" + b"newname".ljust(24, b"\0"))
    assert slot_name(c) == "newname"
    stored = latest(c.lib)
    assert stored[24:48].split(b"\0")[0] == b"newname"
    assert stored[64:] == packet[64:]          # weights untouched
    assert stored[16:20] == packet[16:20]      # payload CRC untouched
    assert c.lib.namstore_current(1) == 1 - first_bank   # alternate bank
    # Empty slot and empty/oversized/unprintable names are refused.
    c.call(9, b"\x02" + b"x".ljust(24, b"\0"), status=1)
    c.call(9, b"\x01" + b"\0" * 24, status=1)
    c.call(9, b"\x01" + b"x" * 24, status=1)
    c.call(9, b"\x01" + b"bad name".ljust(24, b"\0"), status=1)
    assert slot_name(c) == "newname"


def test_rename_retry_is_idempotent_and_keeps_previous_on_flash_cut(client):
    c = client
    original = nam.pack(model(), "previous")
    assert c.lib.namstore_write(1, staging(original)) == 0
    old = latest(c.lib)
    c.lib.fake_cut(4097)
    request = bytes([1, 9]) + struct.pack("<H", next(c.ids)) + b"\x01" + b"next".ljust(24, b"\0")
    c.call(9, request=request, status=4)
    assert latest(c.lib) == old
    # The cached failure replays without touching flash; the client recovers
    # by list/refresh and issuing a new request id.
    c.call(9, request=request, status=4)
    c.lib.fake_cut(-1)
    c.call(9, b"\x01" + b"next".ljust(24, b"\0"))
    assert slot_name(c) == "next" and latest(c.lib)[64:] == original[64:]


def test_rename_blocked_during_transfer(client):
    c = client
    packet = nam.pack(model(), "keep")
    c.upload(packet, 1)
    token = c.begin(nam.pack(model(), "other"), 2)
    c.call(9, b"\x01" + b"zzz".ljust(24, b"\0"), status=2)
    c.call(5, token)


def test_unsupported_and_capacity(client):
    client.call(8, status=5)
    p = bytes([2, 0]) + struct.pack("<H", next(client.ids))
    # Version reply always advertises the implemented version.
    out = ct.create_string_buffer(128)
    assert client.lib.namrpc_request(2, p, len(p), out, 128) == 5
    assert out.raw[:5] == bytes([1, 0]) + p[2:] + b"\x05"
    client.lib.fake_capacity(0x50dfff)
    client.call(0, status=4)
    assert client.lib.fake_writes() == 0
