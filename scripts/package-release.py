#!/usr/bin/env python3
"""Create one multi-triple SwiftPM artifact bundle release archive."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import shutil
import sys
import zipfile
from dataclasses import asdict, dataclass
from pathlib import Path
from typing import Iterable


ARTIFACT_NAME = "_COpenBLAS"
BUNDLE_ROOT = "COpenBLAS.artifactbundle"
ARCHIVE_NAME = f"{BUNDLE_ROOT}.zip"
REPOSITORY = "MarSe32m/sebbu-copenblas"
FIXED_ZIP_TIME = (1980, 1, 1, 0, 0, 0)
DEFAULT_MANIFEST_TEMPLATE = Path(__file__).resolve().parents[1] / "info.json"


@dataclass(frozen=True)
class Variant:
    identifier: str
    payload_directory: str
    triple: str
    library_path: str


VARIANTS = (
    Variant(
        identifier="linux-x86_64-gnu",
        payload_directory="openblas-linux-x86_64-glibc2.34",
        triple="x86_64-unknown-linux-gnu",
        library_path="lib/libopenblas.a",
    ),
    Variant(
        identifier="linux-aarch64-gnu",
        payload_directory="openblas-linux-aarch64-glibc2.34",
        triple="aarch64-unknown-linux-gnu",
        library_path="lib/libopenblas.a",
    ),
    Variant(
        identifier="linux-x86_64-musl",
        payload_directory="openblas-linux-x86_64-musl1.2",
        triple="x86_64-swift-linux-musl",
        library_path="lib/libopenblas.a",
    ),
    Variant(
        identifier="linux-aarch64-musl",
        payload_directory="openblas-linux-aarch64-musl1.2",
        triple="aarch64-swift-linux-musl",
        library_path="lib/libopenblas.a",
    ),
    Variant(
        identifier="windows-x86_64",
        payload_directory="openblas-windows-x86_64",
        triple="x86_64-unknown-windows-msvc",
        library_path="lib/openblas.lib",
    ),
    Variant(
        identifier="windows-aarch64",
        payload_directory="openblas-windows-aarch64",
        triple="aarch64-unknown-windows-msvc",
        library_path="lib/openblas.lib",
    ),
)


def parse_arguments() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--package-version",
        required=True,
        help="sebbu-copenblas package version, for example 0.3.35",
    )
    parser.add_argument(
        "--openblas-version",
        required=True,
        help="Bundled OpenBLAS version without a leading v, for example 0.3.34",
    )
    parser.add_argument(
        "--payload-root",
        type=Path,
        required=True,
        help="Directory containing all six staged openblas-* payload directories",
    )
    parser.add_argument(
        "--dist-dir",
        type=Path,
        required=True,
        help="Output directory; its final path component must be release-assets",
    )
    parser.add_argument(
        "--package-manifest",
        type=Path,
        required=True,
        help="Input Package.swift to update",
    )
    parser.add_argument(
        "--output-package-manifest",
        type=Path,
        required=True,
        help="Destination for the release Package.swift",
    )
    parser.add_argument(
        "--artifact-manifest-template",
        type=Path,
        default=DEFAULT_MANIFEST_TEMPLATE,
        help=(
            "Template info.json containing all target variants; defaults to "
            "info.json in the repository root"
        ),
    )
    return parser.parse_args()


def fail(message: str) -> None:
    raise RuntimeError(message)


def validate_version(name: str, version: str) -> None:
    if not re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+", version):
        fail(
            f"{name} must contain exactly three numeric components, "
            "for example 0.3.34."
        )


def prepare_output_directory(path: Path, protected_paths: Iterable[Path]) -> Path:
    resolved = path.resolve()
    if resolved.name != "release-assets":
        fail("For safety, --dist-dir must end in 'release-assets'.")
    if resolved == Path(resolved.anchor):
        fail("Refusing to use a filesystem root as the output directory.")
    for protected_path in protected_paths:
        protected = protected_path.resolve()
        if resolved == protected or resolved in protected.parents:
            fail(
                f"Refusing to remove output directory {resolved} because it "
                f"contains protected input {protected}."
            )
    if resolved.exists():
        shutil.rmtree(resolved)
    resolved.mkdir(parents=True)
    return resolved


def validate_payload(payload_root: Path) -> Path:
    root = payload_root.resolve()
    if not root.is_dir():
        fail(f"Payload root does not exist: {root}")

    for variant in VARIANTS:
        variant_root = root / variant.payload_directory
        required_files = (
            variant_root / variant.library_path,
            variant_root / "include" / "cblas.h",
            variant_root / "include" / "lapacke.h",
            variant_root / "include" / "include.h",
            variant_root / "include" / "module.modulemap",
            variant_root / "LICENSE-OpenBLAS.txt",
        )
        for required_file in required_files:
            if not required_file.is_file():
                fail(
                    f"Missing required file for {variant.identifier}: "
                    f"{required_file}"
                )
    return root


def json_bytes(value: object) -> bytes:
    return (json.dumps(value, indent=2, sort_keys=True) + "\n").encode("utf-8")


def zip_info(name: str) -> zipfile.ZipInfo:
    info = zipfile.ZipInfo(name, date_time=FIXED_ZIP_TIME)
    info.compress_type = zipfile.ZIP_DEFLATED
    info.create_system = 3
    info.external_attr = 0o100644 << 16
    return info


def add_bytes(archive: zipfile.ZipFile, name: str, contents: bytes) -> None:
    archive.writestr(
        zip_info(name),
        contents,
        compress_type=zipfile.ZIP_DEFLATED,
        compresslevel=9,
    )


def add_file(archive: zipfile.ZipFile, name: str, source: Path) -> None:
    with source.open("rb") as input_stream:
        with archive.open(zip_info(name), mode="w", force_zip64=True) as output_stream:
            shutil.copyfileobj(input_stream, output_stream, length=1024 * 1024)


def payload_files(root: Path) -> Iterable[Path]:
    return sorted(path for path in root.rglob("*") if path.is_file())


def expected_manifest_variants() -> list[dict[str, object]]:
    return [
        {
            "path": f"{variant.payload_directory}/{variant.library_path}",
            "supportedTriples": [variant.triple],
            "staticLibraryMetadata": {
                "headerPaths": [f"{variant.payload_directory}/include"],
                "moduleMapPath": (
                    f"{variant.payload_directory}/include/module.modulemap"
                ),
            },
        }
        for variant in VARIANTS
    ]


def load_artifact_manifest(template_path: Path, version: str) -> dict[str, object]:
    resolved = template_path.resolve()
    if not resolved.is_file():
        fail(f"Artifact manifest template does not exist: {resolved}")

    try:
        manifest = json.loads(resolved.read_text(encoding="utf-8"))
    except json.JSONDecodeError as error:
        fail(f"Invalid JSON in artifact manifest template {resolved}: {error}")

    if not isinstance(manifest, dict) or manifest.get("schemaVersion") != "1.0":
        fail("Artifact manifest template must have schemaVersion '1.0'.")

    artifacts = manifest.get("artifacts")
    if not isinstance(artifacts, dict) or set(artifacts) != {ARTIFACT_NAME}:
        fail(f"Artifact manifest template must define only '{ARTIFACT_NAME}'.")

    artifact = artifacts[ARTIFACT_NAME]
    if not isinstance(artifact, dict) or artifact.get("type") != "staticLibrary":
        fail(f"Artifact '{ARTIFACT_NAME}' must have type 'staticLibrary'.")

    if artifact.get("variants") != expected_manifest_variants():
        fail(
            "Artifact manifest variants do not exactly match the six configured "
            "payloads and target triples."
        )

    # The checked-in info.json is a structural template. Its version is the only
    # field changed for a release.
    artifact["version"] = version
    return manifest


def create_archive(
    payload_root: Path,
    output_path: Path,
    manifest: dict[str, object],
) -> None:
    with zipfile.ZipFile(
        output_path,
        mode="w",
        compression=zipfile.ZIP_DEFLATED,
        compresslevel=9,
        allowZip64=True,
    ) as archive:
        add_bytes(
            archive,
            f"{BUNDLE_ROOT}/info.json",
            json_bytes(manifest),
        )
        for variant in VARIANTS:
            variant_root = payload_root / variant.payload_directory
            for source in payload_files(variant_root):
                relative = source.relative_to(variant_root).as_posix()
                add_file(
                    archive,
                    f"{BUNDLE_ROOT}/{variant.payload_directory}/{relative}",
                    source,
                )


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def find_matching_parenthesis(text: str, opening: int) -> int:
    depth = 0
    state = "normal"
    block_comment_depth = 0
    index = opening

    while index < len(text):
        char = text[index]
        following = text[index + 1] if index + 1 < len(text) else ""

        if state == "string":
            if char == "\\":
                index += 2
                continue
            if char == '"':
                state = "normal"
        elif state == "line_comment":
            if char == "\n":
                state = "normal"
        elif state == "block_comment":
            if char == "/" and following == "*":
                block_comment_depth += 1
                index += 2
                continue
            if char == "*" and following == "/":
                block_comment_depth -= 1
                index += 2
                if block_comment_depth == 0:
                    state = "normal"
                continue
        else:
            if char == '"':
                state = "string"
            elif char == "/" and following == "/":
                state = "line_comment"
                index += 2
                continue
            elif char == "/" and following == "*":
                state = "block_comment"
                block_comment_depth = 1
                index += 2
                continue
            elif char == "(":
                depth += 1
            elif char == ")":
                depth -= 1
                if depth == 0:
                    return index
        index += 1

    fail("Found an unterminated .binaryTarget(...) call in Package.swift.")
    raise AssertionError("unreachable")


def replace_binary_target(manifest: str, version: str, checksum: str) -> str:
    call_start = 0
    matches: list[tuple[int, int]] = []

    while True:
        call_start = manifest.find(".binaryTarget", call_start)
        if call_start == -1:
            break
        opening = manifest.find("(", call_start + len(".binaryTarget"))
        if opening == -1:
            break
        closing = find_matching_parenthesis(manifest, opening)
        body = manifest[opening + 1 : closing]
        if re.search(r'\bname\s*:\s*"_COpenBLAS"', body):
            matches.append((call_start, closing + 1))
        call_start = closing + 1

    if len(matches) != 1:
        fail(
            "Expected exactly one .binaryTarget named _COpenBLAS in Package.swift; "
            f"found {len(matches)}."
        )

    start, end = matches[0]
    line_start = manifest.rfind("\n", 0, start) + 1
    indent = manifest[line_start:start]
    if indent.strip():
        fail("Could not determine indentation for the _COpenBLAS binary target.")

    url = (
        f"https://github.com/{REPOSITORY}/releases/download/"
        f"{version}/{ARCHIVE_NAME}"
    )
    replacement = "\n".join(
        (
            ".binaryTarget(",
            f'{indent}    name: "_COpenBLAS",',
            f'{indent}    url: "{url}",',
            f'{indent}    checksum: "{checksum}"',
            f"{indent})",
        )
    )
    return manifest[:start] + replacement + manifest[end:]


def release_notes(package_version: str, openblas_version: str) -> str:
    rows = "\n".join(
        f"| `{variant.triple}` | `{variant.payload_directory}` |"
        for variant in VARIANTS
    )
    return f"""# COpenBLAS {package_version}

Prebuilt OpenBLAS `v{openblas_version}` static libraries for SwiftPM. All target
variants are contained in `{ARCHIVE_NAME}`.

| Swift target triple | Artifact-bundle variant |
| --- | --- |
{rows}

All variants are built with `NOFORTRAN=1`, `C_LAPACK=ON`, pthreads enabled,
OpenMP disabled, and `DYNAMIC_OLDER=OFF`. The x86-64 variants retain
`DYNAMIC_ARCH=ON` and the AArch64 variants use the ARMv8 baseline.
The Windows variants use `clang-cl` with `MAX_STACK_ALLOC=2048`, avoiding the
shared OpenBLAS workspace allocator for small Level-2 operations.

See `SHA256SUMS` and `BUILD-METADATA.json` for release verification details.
"""


def write_json(path: Path, value: object) -> None:
    path.write_bytes(json_bytes(value))


def main() -> int:
    arguments = parse_arguments()
    validate_version("Package version", arguments.package_version)
    validate_version("OpenBLAS version", arguments.openblas_version)

    payload_root = validate_payload(arguments.payload_root)
    manifest = load_artifact_manifest(
        arguments.artifact_manifest_template,
        arguments.package_version,
    )
    dist_dir = prepare_output_directory(
        arguments.dist_dir,
        protected_paths=(
            payload_root,
            arguments.package_manifest,
            arguments.artifact_manifest_template,
        ),
    )

    archive_path = dist_dir / ARCHIVE_NAME
    create_archive(
        payload_root,
        archive_path,
        manifest,
    )
    archive_checksum = sha256_file(archive_path)
    print(
        f"Created {archive_path.name} with {len(VARIANTS)} target variants"
    )

    metadata_path = dist_dir / "BUILD-METADATA.json"
    write_json(
        metadata_path,
        {
            "packageVersion": arguments.package_version,
            "openBLAS": {
                "repository": "https://github.com/OpenMathLib/OpenBLAS",
                "tag": f"v{arguments.openblas_version}",
            },
            "repository": f"https://github.com/{REPOSITORY}",
            "githubActions": {
                "repository": os.environ.get("GITHUB_REPOSITORY"),
                "runId": os.environ.get("GITHUB_RUN_ID"),
                "runAttempt": os.environ.get("GITHUB_RUN_ATTEMPT"),
                "sourceCommit": os.environ.get("GITHUB_SHA"),
            },
            "configuration": {
                "noFortran": True,
                "cLapack": True,
                "staticOnly": True,
                "openMP": False,
                "threading": True,
                "dynamicOlder": False,
                "windowsMaxStackAllocBytes": 2048,
            },
            "variants": [asdict(variant) for variant in VARIANTS],
            "archiveChecksums": {ARCHIVE_NAME: archive_checksum},
            "artifactBundle": {
                "fileName": ARCHIVE_NAME,
                "checksum": archive_checksum,
            },
        },
    )

    notes_path = dist_dir / "RELEASE_NOTES.md"
    notes_path.write_text(
        release_notes(arguments.package_version, arguments.openblas_version),
        encoding="utf-8",
    )

    checksummed_assets = sorted(
        [
            archive_path,
            metadata_path,
        ],
        key=lambda path: path.name,
    )
    sums_path = dist_dir / "SHA256SUMS"
    sums_path.write_text(
        "".join(f"{sha256_file(path)}  {path.name}\n" for path in checksummed_assets),
        encoding="utf-8",
    )

    source_manifest = arguments.package_manifest.read_text(encoding="utf-8")
    release_manifest = replace_binary_target(
        source_manifest,
        arguments.package_version,
        archive_checksum,
    )
    output_manifest = arguments.output_package_manifest.resolve()
    output_manifest.parent.mkdir(parents=True, exist_ok=True)
    output_manifest.write_text(release_manifest, encoding="utf-8")

    print(f"Artifact bundle checksum: {archive_checksum}")
    print(f"Wrote release manifest to {output_manifest}")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (OSError, RuntimeError, zipfile.BadZipFile) as error:
        print(f"ERROR: {error}", file=sys.stderr)
        sys.exit(1)
