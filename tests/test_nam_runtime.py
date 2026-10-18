"""Real C model store + host importer on fake NOR/USB; never a pedal."""
import ctypes as ct
import json
import shutil
import struct
import subprocess
import sys
import zlib
from types import ModuleType, SimpleNamespace

import pytest
from test_nam_a2 import FW, State, init, model, render

from fb200 import cli, nam
from fb200.errors import CommunicationError

BASE, END = 0x400000, 0x500000   # 64 slots x two 8 KiB banks (namstore.h)


@pytest.fixture(scope="module")
def store(tmp_path_factory):
    if not shutil.which("cc"):
        pytest.skip("no C compiler")
    out = tmp_path_factory.mktemp("namstore") / ("store.dll" if sys.platform == "win32" else "store.so")
    subprocess.run(["cc", "-O2", "-Wall", "-Wextra", "-Werror", "-shared", "-fPIC",
                    "-I", str(FW / "src"), str(FW / "tests/namstore_host.c"),
                    str(FW / "src/namstore/namstore.c"), str(FW / "src/dsp/nam_a2.c"),
                    str(FW / "src/crc32.c"), "-o", str(out)], check=True)
    lib = ct.CDLL(str(out))
    lib.namstore_record.restype = ct.POINTER(ct.c_ubyte)
    lib.namstore_valid.argtypes = [ct.POINTER(ct.c_ubyte)]
    lib.namstore_write.argtypes = [ct.c_uint, ct.POINTER(ct.c_ubyte)]
    lib.fake_feed.argtypes = [ct.POINTER(ct.c_ubyte), ct.c_uint]
    lib.fake_flash.restype = ct.POINTER(ct.c_ubyte)
    lib.fake_log.restype = ct.c_char_p
    lib.nam_a2_init.argtypes = [ct.POINTER(State), ct.POINTER(ct.c_float), ct.c_size_t,
                               ct.c_uint, ct.c_uint]
    lib.nam_a2_process.argtypes = [ct.POINTER(State), ct.POINTER(ct.c_float), ct.c_uint]
    return lib


def staging(packet):
    return (ct.c_ubyte * 8192).from_buffer_copy(packet + b"\xff"*(8192-len(packet)))


def latest(store, slot=1):
    bank = store.namstore_current(slot)
    return ct.string_at(store.namstore_record(slot, bank), nam.PACKET) if bank >= 0 else None


def test_store_load_replace_and_delete(store):
    store.fake_reset()
    old = nam.pack(model(), "old")
    assert store.namstore_write(1, staging(old)) == 0
    assert latest(store)[64:] == old[64:]
    newer = model()
    newer["weights"][0] += 0.1
    new = nam.pack(newer, "new")
    assert store.namstore_write(1, staging(new)) == 0
    current = latest(store)
    assert current[64:] == new[64:] and struct.unpack_from("<I", current, 20)[0] == 2
    weights = struct.unpack_from("<1871f", current, 64)
    # Runtime-loaded stored bytes run through the actual inference kernel.
    signal = [0.4, -0.4] * 100
    assert (render(store, init(store, weights), signal) ==
            render(store, init(store, struct.unpack_from("<1871f", new, 64)), signal)).all()
    assert store.namstore_delete(1) == 0
    assert store.namstore_valid(staging(latest(store))) == 2
    assert store.namstore_write(1, staging(old)) == 0
    assert store.namstore_valid(staging(latest(store))) == 1
    # No writes outside the reserved 48 KiB gap.
    flash = ct.string_at(store.fake_flash(), 0x800000)
    assert flash[:BASE] == b"\xff"*BASE and flash[END:] == b"\xff"*(0x800000-END)


@pytest.mark.parametrize("cut", list(range(0, 12288, 256)) + [1, 4095, 4097, 8191, 8193, 12287])
def test_torn_update_preserves_previous_model(store, cut):
    store.fake_reset()
    old = nam.pack(model(), "old")
    assert store.namstore_write(1, staging(old)) == 0
    new_model = model()
    new_model["weights"][0] = 0.25
    new = nam.pack(new_model, "new")
    store.fake_cut(cut)
    assert store.namstore_write(1, staging(new)) < 0
    # Re-scan after simulated reboot without trusting any cached pointer/index.
    assert latest(store)[64:] == old[64:]


def reseal(packet):
    struct.pack_into("<I", packet, 16, zlib.crc32(packet[64:]))
    struct.pack_into("<I", packet, 60, zlib.crc32(packet[:60]))
    return packet


def test_bad_packets_and_boundaries(store):
    store.fake_reset()
    packet = nam.pack(model())
    for slot in (0, 65, 0xffffffff):
        assert store.namstore_write(slot, staging(packet)) < 0
        assert not store.namstore_record(slot, 0)
    store.fake_capacity(END-1)
    assert store.namstore_write(1, staging(packet)) < 0
    store.fake_capacity(0x800000)
    for offset, value in ((4, 2), (6, 8), (8, 0), (12, 0), (47, 65), (52, 1)):
        bad = bytearray(packet)
        bad[offset] = value
        reseal(bad)
        assert store.namstore_write(1, staging(bytes(bad))) < 0
    bad = bytearray(packet)
    struct.pack_into("<I", bad, 64, 0x7f800000)
    assert store.namstore_write(1, staging(bytes(reseal(bad)))) < 0
    bad = bytearray(packet)
    bad[-1] ^= 1
    assert store.namstore_write(1, staging(bytes(bad))) < 0
    assert store.fake_writes() == 0


@pytest.mark.parametrize("chunk", [1, 7, 64, 1024])
def test_usb_receive_and_timeout(store, chunk):
    store.fake_reset()
    packet = nam.pack(model(), "USB")
    assert store.namstore_begin(1, len(packet), zlib.crc32(packet)) == 0
    assert store.namstore_begin(2, len(packet), zlib.crc32(packet)) < 0
    assert store.namstore_delete(2) < 0
    store.fake_chunk(chunk)
    store.fake_feed(staging(packet), len(packet))
    for _ in range(len(packet)+1):
        store.namstore_task()
        if not store.namstore_active():
            break
    assert b"nam done ok slot 1" in store.fake_log()
    assert latest(store)[64:] == packet[64:]
    assert store.namstore_begin(2, len(packet), zlib.crc32(packet)) == 0
    store.fake_feed(staging(packet), 100)
    store.namstore_task()
    before = store.fake_writes()
    store.fake_feed(staging(packet), 0)  # disconnect: no more buffered USB bytes
    store.fake_time(3001)
    store.namstore_task()
    assert not store.namstore_active() and store.fake_writes() == before
    assert store.namstore_current(2) == -1


class Connection:
    def __init__(self, store):
        self.store = store
        self.data = b""
    def command(self, line, patterns, timeout):
        self.data = b""
        _, slot, size, crc = line.split()
        return b"nam ready\n" if self.store.namstore_begin(int(slot), int(size), int(crc, 0)) == 0 \
            else b"nam: refused\n"
    def write(self, raw):
        self.data += raw
    def expect(self, patterns, timeout):
        self.store.fake_feed(staging(self.data), len(self.data))
        while self.store.namstore_active():
            self.store.namstore_task()
        return self.store.fake_log()


def test_host_client_to_firmware_store(store):
    store.fake_reset()
    packet = nam.pack(model(), "From PC")
    con = Connection(store)
    nam.put(con, 3, packet)
    assert latest(store, 3)[24:48].split(b"\0")[0] == b"From_PC"
    bad = bytearray(packet)
    bad[-1] ^= 1
    with pytest.raises(CommunicationError):
        nam.put(con, 2, bytes(bad))
    assert store.namstore_current(2) == -1


def test_cli_rejects_model_before_connecting(monkeypatch, tmp_path):
    def fail(*args):
        pytest.fail("invalid model must not connect to USB")
    from fb200 import nam_console
    monkeypatch.setattr(nam_console, "connect", fail)
    file = tmp_path / "bad.nam"
    file.write_text(json.dumps({"architecture": "LSTM"}))
    assert cli.main(["nam", "put", "1", str(file)]) == 1


def test_model_slot_in_preset_tail(tmp_path):
    if not shutil.which("cc"):
        pytest.skip("no C compiler")
    source = tmp_path / "preset.c"
    source.write_text('''#include <assert.h>
#include <string.h>
#include "preset/preset.h"
_Static_assert(P_NAM_MARK >= P_EQ_DATA+24, "must not overlap EQ");
int main(void) {
    preset_t p={0};
    assert(preset_nam_slot(&p)==0);
    pset(&p,P_NAM_SLOT,3); assert(preset_nam_slot(&p)==0);
    pset(&p,P_NAM_MARK,NAM_MARK); assert(preset_nam_slot(&p)==3);
    pset(&p,P_NAM_SLOT,4); assert(preset_nam_slot(&p)==0);
    memset(&p,0xff,sizeof p); assert(preset_nam_slot(&p)==0);
}
''')
    exe = tmp_path / "preset"
    subprocess.run(["cc", "-Wall", "-Wextra", "-Werror", "-I", str(FW / "src"),
                    str(source), "-o", str(exe)], check=True)
    subprocess.run([str(exe)], check=True)


def test_windows_transport_without_device(monkeypatch):
    from fb200.nam_console import WindowsConsole
    class Port:
        in_waiting = 0
        closed = False
        raw = b""
        short = False
        def write(self, data):
            self.raw += b"nam use ok slot 1\r\n"
            return len(data)-1 if self.short else len(data)
        def read(self, n):
            out, self.raw = self.raw[:n], self.raw[n:]
            return out
        def close(self):
            self.closed = True
    port = Port()
    serial = ModuleType("serial")
    serial.SerialException = OSError
    serial.Serial = lambda *args, **kwargs: port
    tools = ModuleType("serial.tools")
    tools.list_ports = SimpleNamespace(comports=list)
    monkeypatch.setitem(sys.modules, "serial", serial)
    monkeypatch.setitem(sys.modules, "serial.tools", tools)
    with WindowsConsole("COM5") as con:
        nam.select(con, 1)
        port.short = True
        with pytest.raises(CommunicationError, match="short USB write"):
            con.write(b"test")
    assert port.closed


def test_nam_flash_range_and_audio_pump(tmp_path):
    if not shutil.which("cc"):
        pytest.skip("no C compiler")
    exe = tmp_path / "nam_rmw"
    subprocess.run(["cc", "-O2", "-Wall", "-Wextra", "-Werror", "-DNAM_RUNTIME",
                    "-I", str(FW / "src"), str(FW / "tests/nam_rmw_host.c"),
                    str(FW / "src/debug/flash_rmw.c"), "-o", str(exe)], check=True)
    subprocess.run([str(exe)], check=True)
