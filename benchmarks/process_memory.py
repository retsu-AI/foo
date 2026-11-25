"""Read resident memory for the production process alone."""

import ctypes
from pathlib import Path
import platform
import subprocess


def linux_status(pid):
    status = Path(f"/proc/{pid}/status").read_text()
    fields = dict(line.split(":", 1) for line in status.splitlines() if ":" in line)
    return {
        "rss_bytes": int(fields["VmRSS"].split()[0]) * 1024,
        "peak_rss_bytes": int(fields["VmHWM"].split()[0]) * 1024,
    }


def macos_status(pid):
    resident_kib = subprocess.check_output(["ps", "-o", "rss=", "-p", str(pid)], timeout=5)
    return {"rss_bytes": int(resident_kib) * 1024}


def windows_status(pid):
    from ctypes import wintypes as win

    class Counters(ctypes.Structure):
        _fields_ = [
            ("size", win.DWORD),
            ("page_faults", win.DWORD),
            ("peak_working_set", ctypes.c_size_t),
            ("working_set", ctypes.c_size_t),
            ("quota_peak_paged_pool", ctypes.c_size_t),
            ("quota_paged_pool", ctypes.c_size_t),
            ("quota_peak_non_paged_pool", ctypes.c_size_t),
            ("quota_non_paged_pool", ctypes.c_size_t),
            ("pagefile_usage", ctypes.c_size_t),
            ("peak_pagefile_usage", ctypes.c_size_t),
        ]

    kernel = ctypes.WinDLL("kernel32", use_last_error=True)
    open_process = kernel.OpenProcess
    open_process.argtypes = (win.DWORD, win.BOOL, win.DWORD)
    open_process.restype = win.HANDLE
    query = kernel.K32GetProcessMemoryInfo
    query.argtypes = (win.HANDLE, ctypes.POINTER(Counters), win.DWORD)
    query.restype = win.BOOL
    close = kernel.CloseHandle
    close.argtypes = (win.HANDLE,)
    close.restype = win.BOOL

    process = open_process(0x0400 | 0x0010, False, pid)
    if not process:
        raise ctypes.WinError(ctypes.get_last_error())
    try:
        counters = Counters()
        counters.size = ctypes.sizeof(counters)
        if not query(process, ctypes.byref(counters), counters.size):
            raise ctypes.WinError(ctypes.get_last_error())
        return {
            "rss_bytes": counters.working_set,
            "peak_rss_bytes": counters.peak_working_set,
        }
    finally:
        close(process)


def process_memory(pid):
    measure = {
        "Linux": linux_status,
        "Darwin": macos_status,
        "Windows": windows_status,
    }.get(platform.system())
    if measure is None:
        return {"unavailable": f"no resident-memory reader for {platform.system()}"}
    return measure(pid)
