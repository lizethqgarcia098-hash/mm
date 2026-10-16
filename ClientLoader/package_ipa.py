#!/usr/bin/env python3
"""Build an unsigned IPA copy with the ClientLoader dylib linked at launch."""

from __future__ import annotations

import argparse
import os
import shutil
import struct
import sys
import tempfile
import zipfile
from pathlib import Path

MH_MAGIC_64 = 0xFEEDFACF
MH_DYLIB = 6
CPU_TYPE_ARM64 = 0x0100000C
LC_LOAD_DYLIB = 0x0000000C
LC_SEGMENT_64 = 0x00000019
HEADER_SIZE = 32


class MachOError(ValueError):
    pass


def _read_macho_header(data: bytes) -> tuple[int, int, int, int]:
    if len(data) < HEADER_SIZE:
        raise MachOError("Mach-O file is shorter than its 64-bit header")
    magic, cpu_type, _, file_type, command_count, command_bytes, _, _ = struct.unpack_from(
        "<IiiIIIII", data
    )
    if magic != MH_MAGIC_64:
        raise MachOError("expected a little-endian 64-bit Mach-O file")
    if cpu_type != CPU_TYPE_ARM64:
        raise MachOError("expected an arm64 Mach-O file")
    if HEADER_SIZE + command_bytes > len(data):
        raise MachOError("Mach-O load-command table extends past end of file")
    return file_type, command_count, command_bytes, HEADER_SIZE + command_bytes


def _commands(data: bytes, command_count: int, command_bytes: int):
    offset = HEADER_SIZE
    limit = HEADER_SIZE + command_bytes
    for _ in range(command_count):
        if offset + 8 > limit:
            raise MachOError("truncated Mach-O load command")
        command, size = struct.unpack_from("<II", data, offset)
        if size < 8 or offset + size > limit:
            raise MachOError("invalid Mach-O load-command size")
        yield offset, command, size
        offset += size
    if offset != limit:
        raise MachOError("Mach-O load-command sizes do not match header")


def _first_section_offset(data: bytes, command_count: int, command_bytes: int) -> int:
    offsets: list[int] = []
    for offset, command, size in _commands(data, command_count, command_bytes):
        if command != LC_SEGMENT_64:
            continue
        if size < 72:
            raise MachOError("truncated LC_SEGMENT_64 command")
        section_count = struct.unpack_from("<I", data, offset + 64)[0]
        if 72 + section_count * 80 > size:
            raise MachOError("truncated Mach-O section table")
        for index in range(section_count):
            section_offset = offset + 72 + index * 80
            file_offset = struct.unpack_from("<I", data, section_offset + 48)[0]
            if file_offset:
                offsets.append(file_offset)
    if not offsets:
        raise MachOError("could not locate the first Mach-O section")
    return min(offsets)


def add_dylib_load_command(
    executable: Path, install_name: str = "@executable_path/Frameworks/ClientLoader.dylib"
) -> bool:
    """Add an LC_LOAD_DYLIB to a thin arm64 executable; return False if already present."""
    data = bytearray(executable.read_bytes())
    file_type, command_count, command_bytes, command_end = _read_macho_header(data)
    if file_type != 2:
        raise MachOError("target Mach-O is not an executable")
    encoded_name = install_name.encode("utf-8") + b"\0"
    command_size = (24 + len(encoded_name) + 7) & ~7

    for offset, command, size in _commands(data, command_count, command_bytes):
        if command == LC_LOAD_DYLIB:
            name_offset = struct.unpack_from("<I", data, offset + 8)[0]
            existing = bytes(data[offset + name_offset : offset + size]).split(b"\0", 1)[0]
            if existing.decode("utf-8", errors="replace") == install_name:
                return False

    first_section = _first_section_offset(data, command_count, command_bytes)
    if command_end + command_size > first_section:
        raise MachOError(
            f"not enough header padding for new load command "
            f"({first_section - command_end} bytes available, {command_size} required)"
        )

    load_command = struct.pack(
        "<IIIIII", LC_LOAD_DYLIB, command_size, 24, 0, 0x10000, 0x10000
    ) + encoded_name
    load_command += b"\0" * (command_size - len(load_command))
    data[command_end : command_end + command_size] = load_command
    struct.pack_into("<I", data, 16, command_count + 1)
    struct.pack_into("<I", data, 20, command_bytes + command_size)
    executable.write_bytes(data)
    return True


def validate_loader(loader: Path) -> None:
    data = loader.read_bytes()
    file_type, _, _, _ = _read_macho_header(data)
    if file_type != MH_DYLIB:
        raise MachOError("loader must be a linked arm64 dynamic library, not an object file")


def make_ipa(app_dir: Path, loader: Path, output: Path) -> None:
    app_dir = app_dir.resolve()
    loader = loader.resolve()
    output = output.resolve()
    if not app_dir.is_dir() or app_dir.suffix != ".app":
        raise ValueError("--app must name an expanded .app directory")
    if not (app_dir / "Info.plist").is_file():
        raise ValueError("the app directory is missing Info.plist")
    if not (app_dir / "minecraftpe").is_file():
        raise ValueError("expected the Minecraft executable at .app/minecraftpe")
    if not loader.is_file():
        raise ValueError("the loader dylib does not exist")
    if output.exists():
        raise ValueError(f"refusing to overwrite existing output: {output}")
    validate_loader(loader)
    output.parent.mkdir(parents=True, exist_ok=True)

    with tempfile.TemporaryDirectory(
        prefix="client-loader-ipa-", dir=output.parent
    ) as temporary:
        payload = Path(temporary) / "Payload"
        payload.mkdir()
        staged_app = payload / app_dir.name
        shutil.copytree(app_dir, staged_app, symlinks=True)
        frameworks = staged_app / "Frameworks"
        frameworks.mkdir(exist_ok=True)
        staged_loader = frameworks / "ClientLoader.dylib"
        shutil.copy2(loader, staged_loader)
        add_dylib_load_command(staged_app / "minecraftpe")

        staged_ipa = Path(temporary) / output.name
        with zipfile.ZipFile(staged_ipa, "w", compression=zipfile.ZIP_STORED) as archive:
            for directory, subdirectories, filenames in os.walk(payload):
                subdirectories.sort()
                filenames.sort()
                directory_path = Path(directory)
                for name in subdirectories:
                    item = directory_path / name
                    if item.is_symlink():
                        continue
                    relative = item.relative_to(Path(temporary)).as_posix() + "/"
                    archive.writestr(relative, b"")
                for name in filenames:
                    item = directory_path / name
                    if item.is_symlink():
                        info = zipfile.ZipInfo(item.relative_to(Path(temporary)).as_posix())
                        info.create_system = 3
                        info.external_attr = 0o120777 << 16
                        archive.writestr(info, os.readlink(item).encode())
                        continue
                    relative = item.relative_to(Path(temporary)).as_posix()
                    info = zipfile.ZipInfo.from_file(item, relative)
                    info.compress_type = zipfile.ZIP_STORED
                    with item.open("rb") as source, archive.open(info, "w") as target:
                        shutil.copyfileobj(source, target, length=1024 * 1024)
        os.replace(staged_ipa, output)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app", required=True, type=Path, help="expanded Minecraft .app directory")
    parser.add_argument("--loader", required=True, type=Path, help="built arm64 ClientLoader.dylib")
    parser.add_argument("--output", required=True, type=Path, help="new unsigned .ipa output path")
    args = parser.parse_args()
    try:
        make_ipa(args.app, args.loader, args.output)
    except (OSError, ValueError, MachOError, zipfile.BadZipFile) as error:
        print(f"package_ipa.py: {error}", file=sys.stderr)
        return 1
    print(f"Created unsigned IPA: {args.output}")
    print("Import it into eSign and re-sign the app before installation.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
