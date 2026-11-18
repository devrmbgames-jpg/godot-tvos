"""Export through a real Godot editor binary and inspect the produced project.

GODOT_BIN=/absolute/path/to/godot_server python -m unittest discover \
    -s platform/tvos/tests -p 'test_export_project.py'

The fixture libraries are deliberately not executable. These tests exercise
the C++ exporter and native-plugin integration; the macOS workflow separately
builds real libraries and links device/simulator applications with Xcode.
"""

import os
from pathlib import Path
import plistlib
import subprocess
import tempfile
import unittest
import xml.etree.ElementTree as ET
import zipfile


ROOT = Path(__file__).resolve().parents[3]
TEMPLATE = ROOT / "misc/dist/tvos_xcode"
GODOT = os.environ.get("GODOT_BIN")


@unittest.skipUnless(GODOT, "Set GODOT_BIN to an editor compiled from this branch.")
class TVOSExportTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="godot-tvos-export-")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.project = self.root / "project"
        self.project.mkdir()
        self.output = self.root / "export"
        self.output.mkdir()
        (self.project / "project.godot").write_text(
            'config_version=4\n[application]\nconfig/name="TVOS Export Test"\nrun/main_scene="res://main.tscn"\n'
            '[rendering]\nquality/driver/driver_name="GLES2"\nvram_compression/import_pvrtc=true\n'
        )
        (self.project / "main.tscn").write_text('[gd_scene format=2]\n\n[node name="Main" type="Node"]\n')
        self.template = self.root / "tvos.zip"
        self.make_template()
        self.write_preset()

    def write_preset(self, plugins=""):
        (self.project / "export_presets.cfg").write_text(
            '[preset.0]\nname="tvOS"\nplatform="tvOS"\nrunnable=true\n'
            'export_filter="all_resources"\ninclude_filter=""\nexclude_filter=""\n'
            "[preset.0.options]\n"
            'custom_template/debug="%s"\ncustom_template/release="%s"\n'
            'application/app_store_team_id="TESTTEAM01"\n'
            'application/name="Tom & Jerry"\n'
            'application/bundle_identifier="org.godotengine.test"\n'
            'application/short_version="1.0"\napplication/build_version="1"\n'
            'application/copyright="A & B"\n%s' % (self.template, self.template, plugins)
        )

    def make_template(self, legacy=False, omit_library=False):
        with zipfile.ZipFile(self.template, "w") as package:
            for path in TEMPLATE.rglob("*"):
                if not path.is_file():
                    continue
                relative = str(path.relative_to(TEMPLATE))
                text = path.read_text()
                if legacy and relative == "godot_tvos/Info.plist":
                    # A pre-UIScene custom template with only a first-generation remote.
                    text = plistlib.dumps(
                        {
                            "CFBundleName": "$name",
                            "GCSupportedGameControllers": [{"ProfileName": "MicroGamepad"}],
                        }
                    ).decode()
                if legacy and relative.endswith("project.pbxproj"):
                    text = text.replace(".xcframework", ".a").replace("wrapper.xcframework", "archive.ar")
                package.writestr("tvos/" + relative, text)
            if omit_library:
                return
            for target in ["debug", "release"]:
                prefix = "tvos/libgodot.tvos." + target
                if legacy:
                    package.writestr(prefix + ".fat.a", b"!<arch>\n" + target.encode())
                else:
                    package.writestr(
                        prefix + ".xcframework/Info.plist",
                        plistlib.dumps({"CFBundlePackageType": "XFWK", "XCFrameworkFormatVersion": "1.0"}),
                    )
                    package.writestr(prefix + ".xcframework/tvos-arm64/libgodot.a", b"!<arch>\n" + target.encode())

    def export(self, name="Game", debug=True, success=True, path=None):
        path = path or self.output / (name + ".xcodeproj")
        result = subprocess.run(
            [
                GODOT,
                "--no-window",
                "--path",
                str(self.project),
                "--export-debug" if debug else "--export",
                "tvOS",
                str(path),
            ],
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            timeout=90,
        )
        if success:
            self.assertEqual(result.returncode, 0, result.stdout)
            self.assertTrue(path.is_dir(), result.stdout)
        else:
            self.assertNotEqual(result.returncode, 0, result.stdout)
        return result

    def test_scene_manifest_and_xml_names(self):
        name = 'My.Game & "TV"'
        self.export(name)
        plist_path = self.output / name / "Info.plist"
        info = plistlib.loads(plist_path.read_bytes())
        self.assertEqual(info["CFBundleDisplayName"], "Tom & Jerry")
        self.assertEqual(info["NSHumanReadableCopyright"], "A & B")
        manifest = info["UIApplicationSceneManifest"]
        self.assertFalse(manifest["UIApplicationSupportsMultipleScenes"])
        scene = manifest["UISceneConfigurations"]["UIWindowSceneSessionRoleApplication"][0]
        self.assertEqual(scene["UISceneDelegateClassName"], "SceneDelegate")
        self.assertEqual(scene["UISceneClassName"], "UIWindowScene")
        profiles = {profile["ProfileName"] for profile in info["GCSupportedGameControllers"]}
        self.assertEqual(profiles, {"MicroGamepad", "DirectionalGamepad", "ExtendedGamepad"})
        self.assertTrue(info["GCSupportsMultipleMicroGamepads"])
        project = self.output / (name + ".xcodeproj")
        for xml in list(project.rglob("*.xcscheme")) + list(project.rglob("*.xcworkspacedata")):
            ET.parse(xml)
            self.assertNotRegex(xml.read_text(), r"\$[a-z_]+")
        scheme = ET.parse(next(project.rglob("*.xcscheme"))).getroot()
        self.assertEqual(scheme.find("LaunchAction").attrib["buildConfiguration"], "Debug")
        blueprint = scheme.find(".//BuildableReference").attrib["BlueprintIdentifier"]
        self.assertIn(blueprint + " /* ", (project / "project.pbxproj").read_text())
        self.assertTrue((self.output / (name + ".pck")).is_file())

    def test_release_selects_release_library(self):
        self.export(debug=False)
        library = self.output / "Game.xcframework/tvos-arm64/libgodot.a"
        self.assertTrue(library.read_bytes().endswith(b"release"))
        self.assertFalse((self.output / "libgodot.tvos.debug.xcframework").exists())
        scheme = ET.parse(self.output / "Game.xcodeproj/xcshareddata/xcschemes/Game.xcscheme").getroot()
        self.assertEqual(scheme.find("LaunchAction").attrib["buildConfiguration"], "Release")

    def test_legacy_template_is_upgraded(self):
        self.make_template(legacy=True)
        self.export()
        info = plistlib.loads((self.output / "Game/Info.plist").read_bytes())
        self.assertIn("UIApplicationSceneManifest", info)
        profiles = [profile["ProfileName"] for profile in info["GCSupportedGameControllers"]]
        self.assertEqual(profiles.count("DirectionalGamepad"), 1)
        self.assertTrue(info["GCSupportsMultipleMicroGamepads"])
        self.assertTrue((self.output / "Game.a").read_bytes().endswith(b"debug"))

    def test_native_plugin_uses_full_dotted_export_directory(self):
        plugin = self.project / "tvos/plugins"
        plugin.mkdir(parents=True)
        (plugin / "sample.a").write_bytes(b"!<arch>\nplugin")
        (plugin / "sample.gdatvp").write_text(
            '[config]\nname="Sample"\nbinary="sample.a"\n'
            'initialization="sample_initialize"\ndeinitialization="sample_deinitialize"\n'
            '[plist]\nSampleValue="A & B"\n'
        )
        self.write_preset("plugins/Sample=true\n")
        self.export("My.Game")
        self.assertTrue((self.output / "My.Game/tvos/plugins/sample.a").is_file())
        pbx = (self.output / "My.Game.xcodeproj/project.pbxproj").read_text()
        self.assertIn('path = "My.Game/tvos/plugins/sample.a"', pbx)
        code = (self.output / "My.Game/dummy.cpp").read_text()
        self.assertIn("sample_initialize();", code)
        info = plistlib.loads((self.output / "My.Game/Info.plist").read_bytes())
        self.assertEqual(info["SampleValue"], "A & B")

    def test_invalid_template_preserves_previous_export(self):
        previous = self.output / "Game"
        previous.mkdir()
        marker = previous / "keep.txt"
        marker.write_text("previous export")
        self.make_template(omit_library=True)
        self.export(success=False)
        self.assertEqual(marker.read_text(), "previous export")

    def test_export_does_not_erase_project_sources(self):
        previous = self.project / "assets"
        previous.mkdir()
        marker = previous / "keep.txt"
        marker.write_text("source asset")
        self.export(success=False, path=self.project / "assets.xcodeproj")
        self.assertEqual(marker.read_text(), "source asset")


if __name__ == "__main__":
    unittest.main()
