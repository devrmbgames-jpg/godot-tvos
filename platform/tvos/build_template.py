#!/usr/bin/env python3
"""Package tvOS static libraries and the Xcode project as a Godot export template.

Run on a Mac with Xcode. Device and simulator libraries are kept in separate
XCFramework slices, including when both contain arm64 machine code.
"""

import argparse
import filecmp
from pathlib import Path
import plistlib
import shutil
import subprocess
import tempfile
import zipfile


ROOT = Path(__file__).resolve().parents[2]
PROJECT_TEMPLATE = ROOT / "misc/dist/tvos_xcode"


def library_architectures(library):
    result = subprocess.run(
        ["xcrun", "lipo", str(library.resolve()), "-archs"], check=True, capture_output=True, text=True
    )
    architectures = result.stdout.split()
    if not architectures or len(architectures) != len(set(architectures)):
        raise ValueError("Invalid static-library architectures: " + str(library))
    return set(architectures)


def validate_framework(framework, expected_libraries):
    """Check Apple slice metadata and preserve the supplied device/simulator roles."""
    info = plistlib.loads((framework / "Info.plist").read_bytes())
    if not isinstance(info, dict):
        raise ValueError("Invalid XCFramework Info.plist: " + str(framework))
    libraries = info.get("AvailableLibraries")
    if info.get("CFBundlePackageType") != "XFWK" or not isinstance(libraries, list):
        raise ValueError("Invalid XCFramework Info.plist: " + str(framework))
    seen = set()
    for library in libraries:
        if not isinstance(library, dict) or library.get("SupportedPlatform") != "tvos":
            raise ValueError("XCFramework contains a non-tvOS slice: " + str(framework))
        variant = library.get("SupportedPlatformVariant")
        if variant not in (None, "simulator") or variant not in expected_libraries or variant in seen:
            raise ValueError("Unexpected or duplicate XCFramework platform variant: " + str(variant))
        seen.add(variant)
        original, expected_architectures = expected_libraries[variant]
        architectures = library.get("SupportedArchitectures")
        if (
            not isinstance(architectures, list)
            or not all(isinstance(arch, str) for arch in architectures)
            or len(architectures) != len(set(architectures))
            or set(architectures) != expected_architectures
        ):
            raise ValueError("XCFramework architectures do not match the supplied libraries: " + str(framework))
        identifier = library.get("LibraryIdentifier")
        relative = library.get("LibraryPath")
        for component in [identifier, relative]:
            if not isinstance(component, str) or not component or Path(component).is_absolute():
                raise ValueError("Invalid XCFramework library path: " + str(component))
        bundled = (framework / identifier / relative).resolve()
        try:
            bundled.relative_to(framework.resolve())
        except ValueError:
            raise ValueError("XCFramework library path escapes its bundle: " + str(bundled))
        if not bundled.is_file() or not filecmp.cmp(original, bundled, shallow=False):
            raise ValueError("XCFramework slice does not contain its supplied library: " + str(bundled))
    if seen != set(expected_libraries):
        raise ValueError("XCFramework is missing a required device or simulator slice: " + str(framework))


def create_framework(device, simulators, destination, scratch):
    device_architectures = library_architectures(device)
    if device_architectures != {"arm64"}:
        raise ValueError("The tvOS device library must contain exactly arm64: " + str(device))
    simulator_architectures = set()
    for simulator in simulators:
        architectures = library_architectures(simulator)
        if not architectures <= {"arm64", "x86_64"} or architectures & simulator_architectures:
            raise ValueError("Unsupported or duplicate simulator architectures: " + str(simulator))
        simulator_architectures.update(architectures)
    expected_libraries = {None: (device, device_architectures)}
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
        expected_libraries["simulator"] = (simulator_library, simulator_architectures)
    subprocess.run(command + ["-output", str(destination)], check=True)
    validate_framework(destination, expected_libraries)


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
    parser.add_argument("--frameworks-output", type=Path, help="Also copy the XCFrameworks into a new directory")
    smoke = parser.add_mutually_exclusive_group()
    smoke.add_argument("--smoke-project", type=Path, help="Also render one unsigned Xcode link-test project")
    smoke.add_argument(
        "--smoke-projects",
        type=Path,
        help="Render each configuration into a new directory's debug/ and release/ folders",
    )
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
    if output.exists() and not output.is_file():
        parser.error("Expected an output ZIP file: " + str(output))
    directories = {}
    for option in ["frameworks_output", "smoke_project", "smoke_projects"]:
        path = getattr(args, option)
        if path:
            path = path.resolve()
            if path.exists():
                parser.error("Output directory already exists: " + str(path))
            directories[option] = path
    destinations = [output, *directories.values()]
    for index, path in enumerate(destinations):
        for other in destinations[index + 1 :]:
            if path == other or path in other.parents or other in path.parents:
                parser.error("Output paths must not overlap: " + str(path) + " and " + str(other))
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
        prepared_directories = {}
        if args.frameworks_output:
            prepared = scratch / "frameworks"
            prepared.mkdir()
            for framework in frameworks.values():
                shutil.copytree(framework, prepared / framework.name)
            prepared_directories["frameworks_output"] = prepared
        if args.smoke_projects:
            prepared = scratch / "smoke-projects"
            for configuration, framework in frameworks.items():
                make_smoke_project(PROJECT_TEMPLATE, framework, prepared / configuration, configuration.title())
            prepared_directories["smoke_projects"] = prepared
        elif args.smoke_project:
            configuration = "debug" if "debug" in frameworks else "release"
            prepared = scratch / "smoke-project"
            make_smoke_project(PROJECT_TEMPLATE, frameworks[configuration], prepared, configuration.title())
            prepared_directories["smoke_project"] = prepared
        archive = scratch / "tvos.zip"
        with zipfile.ZipFile(archive, "w", zipfile.ZIP_DEFLATED, compresslevel=6) as package:
            for source in sorted(staging.rglob("*")):
                if source.is_file():
                    package.write(source, source.relative_to(scratch))
        # Publish only after every configuration and rendered project is valid.
        for option, prepared in prepared_directories.items():
            destination = directories[option]
            destination.parent.mkdir(parents=True, exist_ok=True)
            shutil.copytree(prepared, destination)
        archive.replace(output)
    print("Created " + str(output))
    for destination in directories.values():
        print("Created " + str(destination))


if __name__ == "__main__":
    main()
