from __future__ import annotations

import ctypes
import os
import sys
import threading
import time
from pathlib import Path

runtime = Path(__file__).resolve().parent
sys.path.insert(0, str(runtime / "python_packages"))
import serial  # type: ignore  # noqa: E402


port_name = sys.argv[1] if len(sys.argv) > 1 else "COM3"
login_user = os.environ.get("FPGATTEN_LOGIN_USER", "FPGAteen")
login_password = os.environ.get("FPGATTEN_LOGIN_PASSWORD", "")

ctypes.windll.kernel32.SetConsoleTitleW(
    f"FPGAtten JTAG Console - {port_name} - Ctrl+] to close"
)

for marker_name in ("serial_console.ready", "serial_console.logged_in"):
    (runtime / marker_name).unlink(missing_ok=True)

uart = serial.Serial(
    port=port_name,
    baudrate=115200,
    bytesize=serial.EIGHTBITS,
    parity=serial.PARITY_NONE,
    stopbits=serial.STOPBITS_ONE,
    timeout=0.05,
    write_timeout=2,
    rtscts=False,
    dsrdtr=False,
)
(runtime / "serial_console.ready").write_text(
    f"pid={os.getpid()}\nport={port_name}\n", encoding="utf-8"
)

stop_event = threading.Event()
login_state = 0
recent_text = ""


def write_uart(data: bytes) -> None:
    try:
        uart.write(data)
        uart.flush()
    except serial.SerialException:
        stop_event.set()


def reader() -> None:
    global login_state, recent_text
    while not stop_event.is_set():
        try:
            data = uart.read(max(1, uart.in_waiting))
        except serial.SerialException as exc:
            print(f"\n[FPGAtten console disconnected: {exc}]", flush=True)
            stop_event.set()
            return
        if not data:
            continue
        text = data.decode("utf-8", errors="replace")
        sys.stdout.write(text)
        sys.stdout.flush()
        recent_text = (recent_text + text)[-2048:]
        lowered = recent_text.lower()
        if login_state == 0 and "login:" in lowered:
            write_uart(login_user.encode("utf-8") + b"\r")
            login_state = 1
            recent_text = ""
        elif login_state == 1 and "password:" in lowered:
            if login_password:
                write_uart(login_password.encode("utf-8") + b"\r")
                login_state = 2
                recent_text = ""
        elif login_state == 2 and f"{login_user.lower()}@fpgatten-z19p" in lowered:
            login_state = 3
            (runtime / "serial_console.logged_in").write_text(
                f"pid={os.getpid()}\nport={port_name}\n", encoding="utf-8"
            )
            sys.stdout.write(
                "\n[已进入 FPGAtten 控制台；现在可手动输入命令，Ctrl+] 关闭串口。]\n"
            )
            sys.stdout.flush()


print(
    f"[FPGAtten serial console: {port_name}, 115200 8-N-1. "
    "等待 JTAG 启动；Ctrl+] 关闭。]",
    flush=True,
)

reader_thread = threading.Thread(target=reader, daemon=True)
reader_thread.start()

try:
    import msvcrt

    arrow_sequences = {"H": b"\x1b[A", "P": b"\x1b[B", "M": b"\x1b[C", "K": b"\x1b[D"}
    while not stop_event.is_set():
        if not msvcrt.kbhit():
            time.sleep(0.02)
            continue
        try:
            character = msvcrt.getwch()
        except KeyboardInterrupt:
            write_uart(b"\x03")
            continue
        if character == "\x1d":
            break
        if character in ("\x00", "\xe0"):
            write_uart(arrow_sequences.get(msvcrt.getwch(), b""))
        elif character in ("\r", "\n"):
            write_uart(b"\r")
        elif character == "\x08":
            write_uart(b"\x7f")
        else:
            write_uart(character.encode("utf-8", errors="ignore"))
finally:
    stop_event.set()
    reader_thread.join(timeout=1)
    uart.close()
    (runtime / "serial_console.ready").unlink(missing_ok=True)
    print("\n[FPGAtten serial console closed.]", flush=True)
