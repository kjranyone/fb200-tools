"""NAM console transport: existing POSIX console, pyserial for native Windows."""
import sys

from fb200.console import Console
from fb200.errors import CommunicationError


class WindowsConsole(Console):
    def __init__(self, port=None):
        try:
            import serial
            from serial.tools import list_ports
        except ImportError as exc:
            raise CommunicationError('install Windows serial support: pip install "fb200-tools[nam]"') \
                from exc
        if port is None:
            ports = [p.device for p in list_ports.comports()
                     if (p.serial_number or "").startswith("AUDIO")]
            if len(ports) != 1:
                raise CommunicationError("specify the pedal's USB console port with --port COM5")
            port = ports[0]
        self.port, self.buf, self.echo = port, b"", None
        self._serial_errors = serial.SerialException
        try:
            self.serial = serial.Serial(port, 115200, timeout=0, write_timeout=10)
        except serial.SerialException as exc:
            raise CommunicationError(f"cannot open {port}: {exc}") from exc

    def write(self, data, timeout=10.0):
        try:
            self.serial.write_timeout = timeout
            if self.serial.write(data) != len(data):
                raise CommunicationError(f"short USB write on {self.port}")
        except self._serial_errors as exc:
            raise CommunicationError(f"USB write failed on {self.port}: {exc}") from exc

    def read_some(self):
        try:
            return self.serial.read(max(1, self.serial.in_waiting))
        except self._serial_errors as exc:
            raise CommunicationError(f"USB read failed on {self.port}: {exc}") from exc

    def close(self):
        self.serial.close()


def connect(port=None):
    return WindowsConsole(port) if sys.platform == "win32" else Console(port)
