import struct
import tempfile
import unittest
import zipfile
from pathlib import Path

from package_ipa import (
    CPU_TYPE_ARM64,
    LC_LOAD_DYLIB,
    LC_SEGMENT_64,
    MH_DYLIB,
    MH_MAGIC_64,
    add_dylib_load_command,
    make_ipa,
)


def minimal_macho(file_type: int = 2) -> bytes:
    section_offset = 4096
    segment_size = 72 + 80
    header_size = 32
    command_size = segment_size
    data = bytearray(section_offset + 64)
    struct.pack_into(
        "<IiiIIIII",
        data,
        0,
        MH_MAGIC_64,
        CPU_TYPE_ARM64,
        0,
        file_type,
        1,
        command_size,
        0,
        0,
    )
    struct.pack_into("<II", data, header_size, LC_SEGMENT_64, segment_size)
    struct.pack_into("<I", data, header_size + 64, 1)
    struct.pack_into("<I", data, header_size + 72 + 48, section_offset)
    return bytes(data)


class AddDylibLoadCommandTests(unittest.TestCase):
    def test_adds_load_command_and_updates_header(self):
        with tempfile.TemporaryDirectory() as directory:
            executable = Path(directory) / "minecraftpe"
            executable.write_bytes(minimal_macho())

            self.assertTrue(add_dylib_load_command(executable))

            data = executable.read_bytes()
            _, _, _, file_type, command_count, command_bytes, _, _ = struct.unpack_from(
                "<IiiIIIII", data
            )
            self.assertEqual(file_type, 2)
            self.assertEqual(command_count, 2)
            command_offset = 32 + 152
            command, size, name_offset = struct.unpack_from("<III", data, command_offset)
            self.assertEqual(command, LC_LOAD_DYLIB)
            self.assertEqual(
                data[command_offset + name_offset : command_offset + size].split(b"\0", 1)[0],
                b"@executable_path/Frameworks/ClientLoader.dylib",
            )
            self.assertEqual(command_bytes, 152 + size)

    def test_is_idempotent(self):
        with tempfile.TemporaryDirectory() as directory:
            executable = Path(directory) / "minecraftpe"
            executable.write_bytes(minimal_macho())
            self.assertTrue(add_dylib_load_command(executable))
            modified = executable.read_bytes()
            self.assertFalse(add_dylib_load_command(executable))
            self.assertEqual(executable.read_bytes(), modified)

    def test_rejects_non_executable(self):
        with tempfile.TemporaryDirectory() as directory:
            executable = Path(directory) / "library"
            executable.write_bytes(minimal_macho(MH_DYLIB))
            with self.assertRaisesRegex(ValueError, "not an executable"):
                add_dylib_load_command(executable)

    def test_packages_copy_with_loader_and_link_command(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            app = root / "minecraftpe.app"
            app.mkdir()
            (app / "Frameworks").mkdir()
            (app / "Info.plist").write_text("plist placeholder")
            executable = app / "minecraftpe"
            executable.write_bytes(minimal_macho())
            original_executable = executable.read_bytes()
            loader = root / "ClientLoader.dylib"
            loader.write_bytes(minimal_macho(MH_DYLIB))
            output = root / "Minecraft-modified.ipa"

            make_ipa(app, loader, output)

            self.assertEqual(executable.read_bytes(), original_executable)
            with zipfile.ZipFile(output) as archive:
                packaged_executable = archive.read("Payload/minecraftpe.app/minecraftpe")
                self.assertIn(
                    "Payload/minecraftpe.app/Frameworks/ClientLoader.dylib",
                    archive.namelist(),
                )
            _, _, _, _, count, command_bytes, _, _ = struct.unpack_from(
                "<IiiIIIII", packaged_executable
            )
            self.assertEqual(count, 2)
            self.assertGreater(command_bytes, 152)


class ScriptDeliveryAssetTests(unittest.TestCase):
    def test_loader_scripts_match_3105_patch_payloads(self):
        project_root = Path(__file__).resolve().parents[1]
        scripts = ("client.js", "esp_test.js", "snapshot_contract_probe.js")
        for script in scripts:
            with self.subTest(script=script):
                loader_script = project_root / f"ClientLoader/scripts/{script}"
                patch_script = (
                    project_root
                    / "3105/Patches/Minecraft/Application/com.mojang.minecraftpe/"
                    f"Documents/ClientLoader/scripts/{script}"
                )
                self.assertTrue(loader_script.is_file())
                self.assertTrue(patch_script.is_file())
                self.assertEqual(loader_script.read_bytes(), patch_script.read_bytes())


if __name__ == "__main__":
    unittest.main()
