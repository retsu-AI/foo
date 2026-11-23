"""Build the pinned shared native transport libraries into a fresh prefix."""

import argparse
import base64
import hashlib
import json
import os
from pathlib import Path
import platform
import shutil
import subprocess
import tarfile
import tempfile
from urllib.request import urlopen


ROOT = Path(__file__).resolve().parents[2]
SOURCES = ROOT / "nix" / "transport-sources.json"
CURL_PATCH = ROOT / "nix" / "transport-curl-no-keylog.patch"

OPENSSL_TARGETS = {
    ("Linux", "x86_64"): "linux-x86_64",
    ("Linux", "aarch64"): "linux-aarch64",
    ("Darwin", "arm64"): "darwin64-arm64-cc",
    ("Windows", "AMD64"): "VC-WIN64A",
}
HTTP_ONLY_DISABLE = """
    ALTSVC AWS BEARER_AUTH COOKIES DICT DIGEST_AUTH DOH FILE FTP
    GOPHER HSTS IMAP IPFS KERBEROS_AUTH LDAP LDAPS MIME MQTT NEGOTIATE_AUTH
    NETRC POP3 RTSP SMTP TELNET TFTP WEBSOCKETS
""".split()


def run(*args, cwd=None):
    subprocess.run(args, cwd=cwd, check=True)


def download(name, pin, workspace):
    archive = workspace / pin["url"].rsplit("/", 1)[1]
    with urlopen(pin["url"], timeout=60) as response, archive.open("wb") as out:
        shutil.copyfileobj(response, out)
    with archive.open("rb") as src:
        actual = base64.b64encode(hashlib.file_digest(src, "sha256").digest()).decode("ascii")
    if actual != pin["sha256"]:
        raise ValueError(f"SHA-256 mismatch for {archive.name}")
    with tarfile.open(archive) as src:
        src.extractall(workspace, filter="data")
    return workspace / f"{name}-{pin['version']}"


def cmake_install(source, prefix, jobs, *options):
    build = source.parent / f"{source.name}-build"
    run(
        "cmake", "-S", source, "-B", build, "-G", "Ninja",
        "-DCMAKE_BUILD_TYPE=Release",
        f"-DCMAKE_INSTALL_PREFIX={prefix}",
        "-DCMAKE_INSTALL_LIBDIR=lib",
        *options,
    )
    run("cmake", "--build", build, "--parallel", str(jobs))
    run("cmake", "--install", build)


def build_openssl(source, prefix, jobs, target, windows):
    run(
        "perl", "Configure", target, "shared",
        "no-apps", "no-docs", "no-engine", "no-module", "no-sslkeylog", "no-tests",
        f"--prefix={prefix}", f"--openssldir={prefix / 'ssl'}", "--libdir=lib",
        cwd=source,
    )
    make = ["nmake", "/nologo"] if windows else ["make", "-j", str(jobs)]
    run(*make, "install_sw", cwd=source)


def build_curl(source, prefix, jobs, system):
    run("git", "apply", CURL_PATCH, cwd=source)
    lib = prefix / "lib"
    windows = system == "Windows"
    lib_suffix = {"Linux": ".so", "Darwin": ".dylib", "Windows": ".lib"}[system]
    platform_options = {
        "Darwin": ["-DUSE_APPLE_SECTRUST=OFF", "-DUSE_APPLE_IDN=OFF"],
        "Windows": [
            "-DCURL_USE_SCHANNEL=OFF",
            "-DCURL_WINDOWS_SSPI=OFF",
            "-DCURL_DISABLE_CA_SEARCH=ON",
            "-DUSE_WIN32_IDN=OFF",
        ],
    }
    cmake_install(
        source, prefix, jobs,
        "-DBUILD_CURL_EXE=OFF",
        "-DBUILD_LIBCURL_DOCS=OFF",
        "-DBUILD_MISC_DOCS=OFF",
        "-DBUILD_EXAMPLES=OFF",
        "-DBUILD_TESTING=OFF",
        "-DBUILD_SHARED_LIBS=ON",
        "-DBUILD_STATIC_LIBS=OFF",
        "-DCURL_USE_PKGCONFIG=OFF",
        "-DCURL_USE_OPENSSL=ON",
        f"-DOPENSSL_INCLUDE_DIR={prefix / 'include'}",
        f"-DOPENSSL_SSL_LIBRARY={lib / ('libssl' + lib_suffix)}",
        f"-DOPENSSL_CRYPTO_LIBRARY={lib / ('libcrypto' + lib_suffix)}",
        "-DCURL_DISABLE_OPENSSL_AUTO_LOAD_CONFIG=ON",
        "-DENABLE_ARES=ON",
        "-DENABLE_THREADED_RESOLVER=OFF",
        f"-DCARES_INCLUDE_DIR={prefix / 'include'}",
        f"-DCARES_LIBRARY={lib / (('cares' if windows else 'libcares') + lib_suffix)}",
        "-DCURL_CA_BUNDLE=none",
        "-DCURL_CA_PATH=none",
        "-DCURL_CA_NATIVE=OFF",
        "-DCURL_CA_FALLBACK=OFF",
        "-DCURL_DISABLE_BASIC_AUTH=OFF",
        "-DCURL_ENABLE_NTLM=OFF",
        "-DCURL_ZLIB=OFF",
        "-DCURL_BROTLI=OFF",
        "-DCURL_ZSTD=OFF",
        "-DUSE_NGHTTP2=OFF",
        "-DUSE_NGTCP2=OFF",
        "-DUSE_QUICHE=OFF",
        "-DUSE_LIBIDN2=OFF",
        "-DCURL_USE_LIBPSL=OFF",
        "-DCURL_USE_LIBSSH2=OFF",
        "-DCURL_USE_LIBSSH=OFF",
        "-DCURL_USE_GSASL=OFF",
        "-DCURL_USE_GSSAPI=OFF",
        "-DENABLE_UNIX_SOCKETS=OFF",
        f"-DCMAKE_INSTALL_RPATH={lib}",
        *platform_options.get(system, []),
        *(f"-DCURL_DISABLE_{feature}=ON" for feature in HTTP_ONLY_DISABLE),
    )


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("prefix", type=Path)
    parser.add_argument("--jobs", type=int, default=os.cpu_count() or 1)
    args = parser.parse_args()
    system = platform.system()
    arch = platform.machine()
    if (system, arch) not in OPENSSL_TARGETS:
        parser.error(f"unsupported native target {system} {arch}")

    prefix = args.prefix.resolve()
    prefix.mkdir(parents=True)
    pins = json.loads(SOURCES.read_text(encoding="utf-8"))
    try:
        with tempfile.TemporaryDirectory(prefix="foo-transport-") as tmp:
            sources = {name: download(name, pin, Path(tmp)) for name, pin in pins.items()}
            build_openssl(sources["openssl"], prefix, args.jobs, OPENSSL_TARGETS[system, arch], system == "Windows")
            cmake_install(
                sources["c-ares"], prefix, args.jobs,
                "-DCARES_SHARED=ON", "-DCARES_STATIC=OFF", "-DCARES_BUILD_TOOLS=OFF",
            )
            build_curl(sources["curl"], prefix, args.jobs, system)
            notices = prefix / "share" / "foo-transport"
            notices.mkdir(parents=True)
            for name, pin in pins.items():
                shutil.copyfile(sources[name] / pin["notice"], notices / f"{name}.txt")
            shutil.copyfile(SOURCES, notices / SOURCES.name)
    except BaseException:
        shutil.rmtree(prefix)
        raise


if __name__ == "__main__":
    main()
