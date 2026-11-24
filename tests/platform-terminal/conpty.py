"""Drive a native Windows pseudoconsole over two synchronous pipes."""

import ctypes
from ctypes import wintypes as win
from pathlib import Path
import subprocess

kernel = ctypes.WinDLL("kernel32", use_last_error=True)
SIZE_T = ctypes.c_size_t
PVOID = ctypes.c_void_p
P_HANDLE = ctypes.POINTER(win.HANDLE)
P_DWORD = ctypes.POINTER(win.DWORD)
PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE = 0x00020016
EXTENDED_STARTUPINFO_PRESENT = 0x00080000
STARTF_USESTDHANDLES = 0x00000100
WAIT_TIMEOUT = 258
WAIT_OBJECT_0 = 0


class Coord(ctypes.Structure):
    _fields_ = [("X", win.SHORT), ("Y", win.SHORT)]


class StartupInfo(ctypes.Structure):
    _fields_ = [
        ("cb", win.DWORD), ("lpReserved", win.LPWSTR), ("lpDesktop", win.LPWSTR),
        ("lpTitle", win.LPWSTR), ("dwX", win.DWORD), ("dwY", win.DWORD),
        ("dwXSize", win.DWORD), ("dwYSize", win.DWORD), ("dwXCountChars", win.DWORD),
        ("dwYCountChars", win.DWORD), ("dwFillAttribute", win.DWORD),
        ("dwFlags", win.DWORD), ("wShowWindow", win.WORD), ("cbReserved2", win.WORD),
        ("lpReserved2", PVOID), ("hStdInput", win.HANDLE), ("hStdOutput", win.HANDLE),
        ("hStdError", win.HANDLE),
    ]


class StartupInfoEx(ctypes.Structure):
    _fields_ = [("startup", StartupInfo), ("attributes", PVOID)]


class ProcessInfo(ctypes.Structure):
    _fields_ = [
        ("process", win.HANDLE), ("thread", win.HANDLE),
        ("process_id", win.DWORD), ("thread_id", win.DWORD),
    ]


def bind(name, result, *arguments):
    function = getattr(kernel, name)
    function.restype = result
    function.argtypes = arguments
    return function


create_pipe = bind("CreatePipe", win.BOOL, P_HANDLE, P_HANDLE, PVOID, win.DWORD)
create_console = bind("CreatePseudoConsole", ctypes.c_long, Coord, win.HANDLE, win.HANDLE, win.DWORD, P_HANDLE)
resize_console = bind("ResizePseudoConsole", ctypes.c_long, win.HANDLE, Coord)
close_console = bind("ClosePseudoConsole", None, win.HANDLE)
init_attributes = bind("InitializeProcThreadAttributeList", win.BOOL, PVOID, win.DWORD, win.DWORD, ctypes.POINTER(SIZE_T))
update_attributes = bind("UpdateProcThreadAttribute", win.BOOL, PVOID, win.DWORD, SIZE_T, PVOID, SIZE_T, PVOID, PVOID)
delete_attributes = bind("DeleteProcThreadAttributeList", None, PVOID)
create_process = bind(
    "CreateProcessW", win.BOOL, win.LPCWSTR, win.LPWSTR, PVOID, PVOID,
    win.BOOL, win.DWORD, PVOID, win.LPCWSTR, ctypes.POINTER(StartupInfo), ctypes.POINTER(ProcessInfo),
)
close_handle = bind("CloseHandle", win.BOOL, win.HANDLE)
read_file = bind("ReadFile", win.BOOL, win.HANDLE, PVOID, win.DWORD, P_DWORD, PVOID)
write_file = bind("WriteFile", win.BOOL, win.HANDLE, PVOID, win.DWORD, P_DWORD, PVOID)
wait_for_object = bind("WaitForSingleObject", win.DWORD, win.HANDLE, win.DWORD)
get_exit = bind("GetExitCodeProcess", win.BOOL, win.HANDLE, P_DWORD)
terminate = bind("TerminateProcess", win.BOOL, win.HANDLE, win.UINT)


def check(ok):
    if not ok:
        raise ctypes.WinError(ctypes.get_last_error())


def check_hresult(result):
    if result != 0:
        raise OSError(f"pseudoconsole returned HRESULT 0x{result & 0xffffffff:08x}")


class ConPty:
    def __init__(self, arguments, columns, rows):
        self.console = win.HANDLE()
        self.input = win.HANDLE()
        self.output = win.HANDLE()
        self.process = None
        read_end = win.HANDLE()
        write_end = win.HANDLE()
        try:
            check(create_pipe(ctypes.byref(read_end), ctypes.byref(self.input), None, 0))
            check(create_pipe(ctypes.byref(self.output), ctypes.byref(write_end), None, 0))
            check_hresult(create_console(Coord(columns, rows), read_end, write_end, 0, ctypes.byref(self.console)))
            self.process = self.launch(arguments)
        except BaseException:
            if self.output:
                close_handle(self.output)
            if self.console:
                close_console(self.console)
            if self.input:
                close_handle(self.input)
            raise
        finally:
            if read_end:
                close_handle(read_end)
            if write_end:
                close_handle(write_end)

    def launch(self, arguments):
        storage_size = SIZE_T()
        init_attributes(None, 1, 0, ctypes.byref(storage_size))
        attributes = ctypes.create_string_buffer(storage_size.value)
        check(init_attributes(attributes, 1, 0, ctypes.byref(storage_size)))
        try:
            check(update_attributes(
                attributes, 0, PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE,
                self.console, ctypes.sizeof(self.console), None, None,
            ))
            info = StartupInfoEx()
            info.startup.cb = ctypes.sizeof(info)
            # Explicit null standard handles let ConPTY replace the runner's redirected handles.
            info.startup.dwFlags = STARTF_USESTDHANDLES
            info.attributes = ctypes.cast(attributes, PVOID)
            process = ProcessInfo()
            command = ctypes.create_unicode_buffer(subprocess.list2cmdline(list(map(str, arguments))))
            check(create_process(
                str(Path(arguments[0]).resolve()), command, None, None, False,
                EXTENDED_STARTUPINFO_PRESENT, None, None, ctypes.byref(info.startup), ctypes.byref(process),
            ))
            close_handle(process.thread)
            return process.process
        finally:
            delete_attributes(attributes)

    def read(self):
        buffer = ctypes.create_string_buffer(8192)
        read = win.DWORD()
        if not read_file(self.output, buffer, len(buffer), ctypes.byref(read), None):
            error = ctypes.get_last_error()
            if error in {6, 109, 232, 995}:
                return b""
            raise ctypes.WinError(error)
        return buffer.raw[:read.value]

    def send(self, data):
        written = win.DWORD()
        check(write_file(self.input, data, len(data), ctypes.byref(written), None))
        if written.value != len(data):
            raise OSError("partial pseudoconsole input write")

    def resize(self, columns, rows):
        check_hresult(resize_console(self.console, Coord(columns, rows)))

    def wait(self, timeout):
        result = wait_for_object(self.process, int(timeout * 1000))
        if result == WAIT_TIMEOUT:
            raise TimeoutError("pseudoconsole process did not exit")
        if result != WAIT_OBJECT_0:
            raise ctypes.WinError(ctypes.get_last_error())
        code = win.DWORD()
        check(get_exit(self.process, ctypes.byref(code)))
        return code.value

    def close(self):
        try:
            self.wait(0)
        except TimeoutError:
            check(terminate(self.process, 1))
            self.wait(5)
        close_handle(self.input)
        close_console(self.console)
        close_handle(self.process)

    def close_output(self):
        if self.output:
            close_handle(self.output)
            self.output = None
