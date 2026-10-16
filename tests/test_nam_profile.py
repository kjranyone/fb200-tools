"""Compile-only 48 kHz clock and physical-RAM feasibility, never device I/O."""
import functools
import re
import shutil
import subprocess
import tempfile
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[1]
FW = ROOT / "firmware/audio"


@pytest.mark.parametrize("rate", [44100, 48000])
def test_clock_and_usb_config(rate, tmp_path):
    if not shutil.which("cc"):
        pytest.skip("host C compiler not installed")
    source = tmp_path / "clock.c"
    source.write_text('''#include "tusb_config.h"
#include "dsp/delay.h"
_Static_assert(AUDIO_FS == CFG_TUD_AUDIO_FUNC_1_MAX_SAMPLE_RATE, "USB rate");
_Static_assert(AUDIO_MCLK_HZ == 256u * AUDIO_FS, "MCLK");
_Static_assert(24000000ull * (AUDIO_PLL_LOOP * AUDIO_PLL_DENOM + AUDIO_PLL_NUM)
               == 64ull * AUDIO_MCLK_HZ * AUDIO_PLL_DENOM, "PLL4 divider");
_Static_assert(DELAY_FS_MAX == AUDIO_FS, "delay capacity");
_Static_assert(CFG_TUD_AUDIO_FUNC_1_EP_IN_SZ_MAX >= (AUDIO_FS+999)/1000*4, "USB packet");
int main(void) { return 0; }
''')
    subprocess.run(["cc", "-Werror", f"-DAUDIO_FS={rate}", "-I", str(FW / "src"),
                    "-c", str(source), "-o", str(tmp_path / "clock.o")], check=True)
    rejected = subprocess.run(["cc", "-DAUDIO_FS=96000", "-I", str(FW / "src"),
                               "-c", str(source), "-o", str(tmp_path / "bad.o")],
                              capture_output=True, check=False)
    assert rejected.returncode != 0
    assert b"AUDIO_FS must be" in rejected.stderr


@functools.cache
def probe_build(profile="nam-probe"):
    out = Path(tempfile.mkdtemp(prefix="nam_probe_"))
    subprocess.run(["make", f"BUILD={out}", f"PROFILE={profile}", "-j4", "build", "layout"],
                   cwd=FW, check=True)
    return out


@pytest.mark.skipif(any(shutil.which(t) is None for t in ("arm-none-eabi-gcc", "make", "curl")),
                    reason="ARM toolchain not installed")
def test_probe_reserves_real_ram():
    out = probe_build()
    layout = (out / "layout.txt").read_text()
    symbols = {name: int(address, 16) for address, name in
               re.findall(r"^([0-9a-f]+) \S+ (\S+)$", layout, re.MULTILINE)}
    nm = subprocess.run(["arm-none-eabi-nm", "-S", str(out / "fb200-app.elf")],
                        capture_output=True, text=True, check=True).stdout
    address, size = next((int(p[0], 16), int(p[1], 16)) for line in nm.splitlines()
                         if len(p := line.split()) == 4 and p[3] == "s_nam_reserve")
    assert size == 83976
    assert 0x20000000 <= address < address+size <= symbols["__dtcm_lo_end__"] <= 0x20018A00
    assert symbols["__itcm_bss_end__"] <= 0x20000
    assert symbols["__dtcm_hi_end__"] <= symbols["__stack_limit__"] == 0x20056000
    assert symbols["__ocram_end__"] <= 0x20208000
    assert "s_cab_tail" not in nm
    # The prototype is ARM-compiled, but is deliberately not live in the engine.
    assert " nam_a2_process" not in nm
    obj = out / "fb200-app/src/dsp/nam_a2.c.o"
    undefined = subprocess.run(["arm-none-eabi-nm", "-u", str(obj)], capture_output=True,
                               text=True, check=True).stdout
    assert all(line.split()[-1] in {"memcpy", "memset"} for line in undefined.splitlines())


@pytest.mark.skipif(any(shutil.which(t) is None for t in ("arm-none-eabi-gcc", "make", "curl")),
                    reason="ARM toolchain not installed")
def test_runtime_image_and_flash_busy_safety():
    out = probe_build("nam-runtime")
    elf = out / "fb200-app.elf"
    subprocess.run(["python3", str(ROOT / "firmware/tools/hot_path.py"), str(elf),
                    "--nam-runtime"], check=True)
    nm = subprocess.run(["arm-none-eabi-nm", "-S", str(elf)], capture_output=True,
                        text=True, check=True).stdout
    syms = {p[3]: (int(p[0], 16), int(p[1], 16)) for line in nm.splitlines()
            if len(p := line.split()) == 4}
    address, size = syms["s_nam"]
    assert size == 83976 and 0x20000000 <= address < address+size <= 0x20018A00
    address, size = syms["staging"]
    assert size == 8192 and 0x20200000 <= address < address+size <= 0x20208000
    assert "s_rev" not in syms  # restricted runtime profile frees reverb ITCM
    assert "nam_a2_process" in syms and syms["nam_a2_process"][0] < 0x20000
    # This profile must not silently weaken the stock image's required checks.
    result = subprocess.run(["python3", str(ROOT / "firmware/tools/hot_path.py"),
                             str(elf)], check=False, capture_output=True)
    assert result.returncode != 0 and b"lsio_" in result.stdout
