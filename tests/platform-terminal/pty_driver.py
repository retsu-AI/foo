"""A subprocess attached to a native Unix PTY or Windows pseudoconsole."""

import errno
import os
import platform
import subprocess
import threading
import time

if os.name == "nt":
    from conpty import ConPty
else:
    import fcntl
    import pty
    import select
    import signal
    import struct
    import termios

TIMEOUT = 10


class UnixPty:
    def __init__(self, arguments, columns, rows, environment=None, stderr_pipe=False):
        self.master, self.slave = pty.openpty()
        try:
            self.original = termios.tcgetattr(self.slave)
            self.resize(columns, rows)
            env = os.environ.copy()
            env["TERM"] = "xterm-256color"
            env.pop("NO_COLOR", None)
            env.update(environment or {})
            self.process = subprocess.Popen(
                arguments, stdin=self.slave, stdout=self.slave,
                stderr=subprocess.PIPE if stderr_pipe else self.slave,
                env=env, start_new_session=True,
            )
        except BaseException:
            os.close(self.slave)
            os.close(self.master)
            raise
        self.finished = threading.Event()

    def read(self):
        while True:
            ready, _, _ = select.select([self.master], [], [], 0.05)
            if ready:
                try:
                    return os.read(self.master, 8192)
                except OSError as error:
                    if error.errno != errno.EIO:
                        raise
                    return b""
            if self.finished.is_set():
                return b""

    def send(self, data):
        while data:
            data = data[os.write(self.master, data):]

    def resize(self, columns, rows):
        fcntl.ioctl(self.slave, termios.TIOCSWINSZ, struct.pack("HHHH", rows, columns, 0, 0))

    def wait(self, timeout):
        return self.process.wait(timeout=timeout)

    def terminate(self):
        self.process.send_signal(signal.SIGTERM)

    def disconnect(self):
        self.hangup()
        return self.wait(TIMEOUT)

    def fill_output(self):
        if os.get_blocking(self.slave):
            raise AssertionError("the native adapter left terminal output blocking")
        written = 0
        while written < 1024 * 1024:
            try:
                written += os.write(self.slave, b"x" * 4096)
            except BlockingIOError:
                return written
        raise AssertionError("PTY output did not reach backpressure")

    def hangup(self):
        if self.master is not None:
            os.close(self.master)
            self.master = None

    def mode_restored(self):
        return termios.tcgetattr(self.slave) == self.original

    def close(self):
        if self.process.poll() is None:
            self.process.kill()
            self.process.wait(timeout=TIMEOUT)
        self.finished.set()
        os.close(self.slave)
        if self.process.stderr is not None:
            self.process.stderr.close()

    def close_output(self):
        if self.master is not None:
            os.close(self.master)


class TerminalPeer:
    def __init__(self, arguments, columns=80, rows=18, environment=None, stderr_pipe=False):
        if os.name == "nt":
            self.device = ConPty(arguments, columns, rows)
        else:
            self.device = UnixPty(arguments, columns, rows, environment, stderr_pipe)
        self.condition = threading.Condition()
        self.data = bytearray()
        self.failure = None
        self.read_enabled = threading.Event()
        self.read_enabled.set()
        self.reader = threading.Thread(target=self.drain, daemon=True)
        self.reader.start()

    def drain(self):
        try:
            while True:
                self.read_enabled.wait()
                chunk = self.device.read()
                if not chunk:
                    return
                with self.condition:
                    self.data.extend(chunk)
                    self.condition.notify_all()
        except (OSError, ValueError, TypeError) as error:
            with self.condition:
                self.failure = error
                self.condition.notify_all()

    def mark(self):
        with self.condition:
            return len(self.data)

    def capture(self):
        with self.condition:
            return bytes(self.data)

    def expect(self, token, *, start=0, timeout=TIMEOUT):
        if isinstance(token, str):
            token = token.encode("utf-8")
        end = time.monotonic() + timeout
        with self.condition:
            while True:
                offset = self.data.find(token, start)
                if offset >= 0:
                    return offset
                if self.failure is not None:
                    raise self.failure
                remaining = end - time.monotonic()
                if remaining <= 0:
                    raise AssertionError(f"missing {token!r} on {platform.system()}. Last bytes: {self.data[-600:]!r}")
                self.condition.wait(remaining)

    def send(self, data):
        self.device.send(data.encode("utf-8") if isinstance(data, str) else data)

    def resize(self, columns, rows):
        self.device.resize(columns, rows)

    def wait(self, timeout=TIMEOUT):
        return self.device.wait(timeout)

    def disconnect(self):
        self.device.finished.set()
        self.reader.join(timeout=TIMEOUT)
        if self.reader.is_alive():
            raise TimeoutError("terminal output reader did not stop before hangup")
        return self.device.disconnect()

    def close(self):
        self.read_enabled.set()
        try:
            if os.name == "nt" and (self.failure is not None or not self.reader.is_alive()):
                self.device.close_output()
            self.device.close()
        finally:
            self.reader.join(timeout=TIMEOUT)
            self.device.close_output()
            if self.reader.is_alive():
                raise TimeoutError("terminal output reader did not finish")
        if self.failure is not None:
            raise self.failure
