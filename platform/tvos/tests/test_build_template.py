"""Test packaging and slice validation with small, non-executable archive fixtures.

The macOS workflow separately creates real XCFrameworks and links every slice.
"""

from contextlib import redirect_stderr, redirect_stdout
import importlib.util
import io
from pathlib import Path
import plistlib
import shutil
import sys
import tempfile
import unittest
from unittest.mock import patch
import xml.etree.ElementTree as ET
import zipfile


ROOT = Path(__file__).resolve().parents[3]
spec = importlib.util.spec_from_file_location("tvos_build_template", ROOT / "platform/tvos/build_template.py")
packager = importlib.util.module_from_spec(spec)
spec.loader.exec_module(packager)


class TVOSTemplateTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="tvos-packager-test-")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.device = {}
        self.simulator = {}
        for configuration in ["debug", "release"]:
            self.device[configuration] = self.root / (configuration + ".device.a")
            self.simulator[configuration] = self.root / (configuration + ".simulator.a")
            self.device[configuration].write_bytes(b"!<arch>\n" + configuration.encode() + b" device")
            self.simulator[configuration].write_bytes(b"!<arch>\n" + configuration.encode() + b" simulator")

    def framework_fixture(self, destination, device, simulator=None):
        expected = {None: (device, {"arm64"})}
        if simulator:
            expected["simulator"] = (simulator, {"arm64", "x86_64"})
        libraries = []
        for variant, (source, architectures) in expected.items():
            identifier = "tvos-" + "_".join(sorted(architectures)) + ("-simulator" if variant else "")
            directory = destination / identifier
            directory.mkdir(parents=True)
            shutil.copyfile(source, directory / source.name)
            library = {
                "LibraryIdentifier": identifier,
                "LibraryPath": source.name,
                "SupportedArchitectures": sorted(architectures),
                "SupportedPlatform": "tvos",
            }
            if variant:
                library["SupportedPlatformVariant"] = variant
            libraries.append(library)
        (destination / "Info.plist").write_bytes(
            plistlib.dumps(
                {"CFBundlePackageType": "XFWK", "XCFrameworkFormatVersion": "1.0", "AvailableLibraries": libraries}
            )
        )
        return expected

    def fake_create_framework(self, device, simulators, destination, scratch):
        expected = self.framework_fixture(destination, device, simulators[0] if simulators else None)
        packager.validate_framework(destination, expected)

    def run_packager(self, *options, create=None):
        arguments = ["build_template.py", "--output", str(self.root / "tvos.zip")]
        for configuration in ["debug", "release"]:
            arguments += ["--" + configuration, str(self.device[configuration])]
            arguments += ["--" + configuration + "-simulator", str(self.simulator[configuration])]
        with patch.object(sys, "argv", arguments + list(options)):
            with patch.object(packager, "create_framework", side_effect=create or self.fake_create_framework):
                with redirect_stdout(io.StringIO()):
                    packager.main()

    def test_device_and_universal_simulator_metadata(self):
        framework = self.root / "valid.xcframework"
        expected = self.framework_fixture(framework, self.device["debug"], self.simulator["debug"])
        packager.validate_framework(framework, expected)
        info_path = framework / "Info.plist"
        valid = info_path.read_bytes()
        mutations = [
            lambda libraries: libraries[0].update(SupportedPlatform="ios"),
            lambda libraries: libraries[0].update(SupportedArchitectures=["x86_64"]),
            lambda libraries: libraries[1].update(SupportedArchitectures=["arm64"]),
            lambda libraries: libraries[1].update(SupportedPlatformVariant="maccatalyst"),
            lambda libraries: libraries[1].pop("SupportedPlatformVariant"),
            lambda libraries: libraries.pop(),
            lambda libraries: libraries[0].update(LibraryPath="../../debug.device.a"),
        ]
        for mutation in mutations:
            with self.subTest(mutation=mutation):
                info = plistlib.loads(valid)
                mutation(info["AvailableLibraries"])
                info_path.write_bytes(plistlib.dumps(info))
                with self.assertRaises(ValueError):
                    packager.validate_framework(framework, expected)
        info_path.write_bytes(valid)
        device_slice = framework / "tvos-arm64" / self.device["debug"].name
        shutil.copyfile(self.simulator["debug"], device_slice)
        with self.assertRaisesRegex(ValueError, "supplied library"):
            packager.validate_framework(framework, expected)

    def test_duplicate_simulator_architectures_rejected_before_merge(self):
        with patch.object(packager, "library_architectures", return_value={"arm64"}):
            with patch.object(packager.subprocess, "run") as native:
                with self.assertRaisesRegex(ValueError, "duplicate simulator"):
                    packager.create_framework(
                        self.device["debug"],
                        [self.simulator["debug"], self.simulator["release"]],
                        self.root / "invalid.xcframework",
                        self.root,
                    )
                native.assert_not_called()

    def test_standalone_frameworks_and_both_smoke_configurations(self):
        frameworks = self.root / "xcframeworks"
        projects = self.root / "smoke"
        self.run_packager("--frameworks-output", str(frameworks), "--smoke-projects", str(projects))
        with zipfile.ZipFile(self.root / "tvos.zip") as archive:
            for configuration in ["debug", "release"]:
                framework_name = "libgodot.tvos." + configuration + ".xcframework"
                framework = frameworks / framework_name
                self.assertTrue((framework / "Info.plist").is_file())
                relative = "tvos-arm64/" + self.device[configuration].name
                self.assertEqual(
                    archive.read("tvos/" + framework_name + "/" + relative), self.device[configuration].read_bytes()
                )
                project = projects / configuration
                self.assertEqual(
                    (project / "TVOSSmoke.xcframework" / relative).read_bytes(), self.device[configuration].read_bytes()
                )
                scheme = ET.parse(project / "TVOSSmoke.xcodeproj/xcshareddata/xcschemes/TVOSSmoke.xcscheme")
                self.assertEqual(
                    scheme.getroot().find("LaunchAction").attrib["buildConfiguration"], configuration.title()
                )

    def test_legacy_smoke_project_prefers_debug(self):
        project = self.root / "legacy-smoke"
        self.run_packager("--smoke-project", str(project))
        self.assertEqual(
            (project / "TVOSSmoke.xcframework/tvos-arm64" / self.device["debug"].name).read_bytes(),
            self.device["debug"].read_bytes(),
        )

    def test_smoke_flags_are_mutually_exclusive(self):
        with redirect_stderr(io.StringIO()):
            with self.assertRaises(SystemExit) as failure:
                self.run_packager(
                    "--smoke-project", str(self.root / "one"), "--smoke-projects", str(self.root / "many")
                )
        self.assertEqual(failure.exception.code, 2)

    def test_failed_second_configuration_publishes_nothing(self):
        output = self.root / "tvos.zip"
        output.write_bytes(b"previous valid export template")
        frameworks = self.root / "xcframeworks"
        projects = self.root / "smoke"

        def invalid_release(device, simulators, destination, scratch):
            expected = self.framework_fixture(destination, device, simulators[0])
            if device == self.device["release"]:
                info_path = destination / "Info.plist"
                info = plistlib.loads(info_path.read_bytes())
                info["AvailableLibraries"][1]["SupportedPlatform"] = "ios"
                info_path.write_bytes(plistlib.dumps(info))
            packager.validate_framework(destination, expected)

        with self.assertRaisesRegex(ValueError, "non-tvOS"):
            self.run_packager(
                "--frameworks-output", str(frameworks), "--smoke-projects", str(projects), create=invalid_release
            )
        self.assertEqual(output.read_bytes(), b"previous valid export template")
        self.assertFalse(frameworks.exists())
        self.assertFalse(projects.exists())


if __name__ == "__main__":
    unittest.main()
