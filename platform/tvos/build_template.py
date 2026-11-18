#!/usr/bin/env python3
"""Package tvOS static libraries and the Xcode project as a Godot export template.

Run on a Mac with Xcode. Device and simulator libraries are kept in separate
XCFramework slices, including when both contain arm64 machine code.
"""

import argparse
from pathlib import Path
import plistlib
import shutil
import subprocess
import tempfile
import zipfile


ROOT = Path(__file__).resolve().parents[2]
PROJECT_TEMPLATE = ROOT / "misc/dist/tvos_xcode"


def create_framework(device, simulators, destination, scratch):
    command = ["xcrun", "xcodebuild", "-create-xcframework", "-library", str(device.resolve())]
    if simulators:
        if len(simulators) == 1:
            simulator_library = simulators[0].resolve()
        else:
            simulator_library = scratch / (destination.stem + ".simulator.a")
            subprocess.run(
                [
                    "xcrun",
                    "lipo",
                    "-create",
                    *[str(path.resolve()) for path in simulators],
                    "-output",
                    str(simulator_library),
                ],
                check=True,
            )
        command += ["-library", str(simulator_library)]
    subprocess.run(command + ["-output", str(destination)], check=True)


def make_smoke_project(template, framework, output, configuration):
    """Render a link-test project. Its empty PCK is not a playable application."""
    if output.exists():
        raise ValueError("Smoke project directory already exists: " + str(output))
    output.mkdir(parents=True)
    replacements = {
        "$binary": "TVOSSmoke",
        "$name": "Godot tvOS link test",
        "$bundle_identifier": "org.godotengine.tvos-smoke",
        "$team_id": "",
        "$short_version": "1.0",
        "$build_version": "1",
        "$copyright": "",
        "$default_build_config": configuration,
        "$cpp_code": "void godot_tvos_plugins_initialize() {}\nvoid godot_tvos_plugins_deinitialize() {}\n",
    }
    empty_fragments = [
        "additional_plist_content",
        "required_device_capabilities",
        "linker_flags",
        "modules_buildfile",
        "modules_fileref",
        "modules_buildphase",
        "modules_buildgrp",
        "additional_pbx_files",
        "additional_pbx_frameworks_build",
        "additional_pbx_frameworks_refs",
        "additional_pbx_resources_build",
        "additional_pbx_resources_refs",
        "pbx_embeded_frameworks",
    ]
    replacements.update({"$" + name: "" for name in empty_fragments})
    for source in sorted(template.rglob("*")):
        if not source.is_file():
            continue
        relative = str(source.relative_to(template)).replace("godot_tvos", "TVOSSmoke")
        target = output / relative
        target.parent.mkdir(parents=True, exist_ok=True)
        text = source.read_text()
        for key, value in replacements.items():
            text = text.replace(key, value)
        target.write_text(text)
    plistlib.loads((output / "TVOSSmoke/Info.plist").read_bytes())
    shutil.copytree(framework, output / "TVOSSmoke.xcframework")
    (output / "TVOSSmoke.pck").write_bytes(b"")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--debug", type=Path, help="Device release_debug (or debug) static library")
    parser.add_argument("--release", type=Path, help="Device release static library")
    parser.add_argument("--debug-simulator", type=Path, nargs="+", default=[], help="Debug simulator libraries")
    parser.add_argument("--release-simulator", type=Path, nargs="+", default=[], help="Release simulator libraries")
    parser.add_argument("--output", type=Path, default=ROOT / "bin/tvos.zip")
    parser.add_argument("--smoke-project", type=Path, help="Also render an unsigned Xcode link-test project")
    args = parser.parse_args()
    if not args.debug and not args.release:
        parser.error("Provide at least one of --debug or --release.")
    for target in ["debug", "release"]:
        device = getattr(args, target)
        simulators = getattr(args, target + "_simulator")
        if simulators and not device:
            parser.error("--" + target + "-simulator also requires --" + target)
        for path in ([device] if device else []) + simulators:
            if not path.is_file() or path.suffix != ".a":
                parser.error("Expected a static library: " + str(path))
    output = args.output.resolve()
    output.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="tvos-template-", dir=output.parent) as temporary:
        scratch = Path(temporary)
        staging = scratch / "tvos"
        shutil.copytree(PROJECT_TEMPLATE, staging)
        frameworks = {}
        for target in ["debug", "release"]:
            device = getattr(args, target)
            if device:
                framework = staging / ("libgodot.tvos." + target + ".xcframework")
                create_framework(device, getattr(args, target + "_simulator"), framework, scratch)
                frameworks[target] = framework
        archive = scratch / "tvos.zip"
        with zipfile.ZipFile(archive, "w", zipfile.ZIP_DEFLATED, compresslevel=6) as package:
            for source in sorted(staging.rglob("*")):
                if source.is_file():
                    package.write(source, source.relative_to(scratch))
        if args.smoke_project:
            configuration = "debug" if "debug" in frameworks else "release"
            make_smoke_project(
                PROJECT_TEMPLATE, frameworks[configuration], args.smoke_project.resolve(), configuration.title()
            )
        archive.replace(output)
    print("Created " + str(output))


if __name__ == "__main__":
    main()
