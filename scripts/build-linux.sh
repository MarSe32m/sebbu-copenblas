#!/usr/bin/env bash
set -euo pipefail

readonly SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly REPOSITORY_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd)"

: "${OPENBLAS_VERSION:?Set OPENBLAS_VERSION to an upstream tag such as v0.3.35}"
: "${OPENBLAS_TARGET:?Set OPENBLAS_TARGET, for example GENERIC or ARMV8}"
: "${DYNAMIC_ARCH:?Set DYNAMIC_ARCH to ON or OFF}"
: "${ARTIFACT_VARIANT:?Set ARTIFACT_VARIANT to the output directory name}"
: "${ARTIFACT_BUNDLE_DIR:?Set ARTIFACT_BUNDLE_DIR to the payload root}"

if [[ ! "${OPENBLAS_VERSION}" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "ERROR: OPENBLAS_VERSION must look like v0.3.34." >&2
    exit 1
fi

if [[ "${DYNAMIC_ARCH}" != "ON" && "${DYNAMIC_ARCH}" != "OFF" ]]; then
    echo "ERROR: DYNAMIC_ARCH must be ON or OFF." >&2
    exit 1
fi

if [[ ! "${ARTIFACT_VARIANT}" =~ ^openblas-[a-z0-9._-]+$ ]]; then
    echo "ERROR: Refusing unsafe ARTIFACT_VARIANT '${ARTIFACT_VARIANT}'." >&2
    exit 1
fi

if [[ -n "${GLIBC_BASELINE:-}" &&
      ! "${GLIBC_BASELINE}" =~ ^[0-9]+\.[0-9]+$ ]]; then
    echo "ERROR: GLIBC_BASELINE must look like 2.26 when it is set." >&2
    exit 1
fi

DETECTED_GLIBC=""
if [[ -n "${GLIBC_BASELINE:-}" ]]; then
    DETECTED_GLIBC="$(getconf GNU_LIBC_VERSION 2>/dev/null || true)"
    if [[ "${DETECTED_GLIBC}" != "glibc ${GLIBC_BASELINE}" ]]; then
        echo "ERROR: Expected build container glibc ${GLIBC_BASELINE}, got '${DETECTED_GLIBC:-unknown}'." >&2
        exit 1
    fi
    if [[ "${ARTIFACT_VARIANT}" != *"-glibc${GLIBC_BASELINE}" ]]; then
        echo "ERROR: ARTIFACT_VARIANT must end in -glibc${GLIBC_BASELINE}." >&2
        exit 1
    fi
fi
readonly DETECTED_GLIBC

if [[ -z "${BUILD_JOBS:-}" ]]; then
    BUILD_JOBS="$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 1)"
fi

if [[ ! "${BUILD_JOBS}" =~ ^[1-9][0-9]*$ ]]; then
    echo "ERROR: BUILD_JOBS must be a positive integer." >&2
    exit 1
fi

if [[ -n "${CMAKE_COMMAND:-}" ]]; then
    readonly SELECTED_CMAKE_COMMAND="${CMAKE_COMMAND}"
elif command -v cmake >/dev/null 2>&1; then
    readonly SELECTED_CMAKE_COMMAND="cmake"
elif command -v cmake3 >/dev/null 2>&1; then
    readonly SELECTED_CMAKE_COMMAND="cmake3"
else
    echo "ERROR: Neither cmake nor cmake3 is available." >&2
    exit 1
fi

if ! command -v "${SELECTED_CMAKE_COMMAND}" >/dev/null 2>&1; then
    echo "ERROR: CMAKE_COMMAND '${SELECTED_CMAKE_COMMAND}' was not found." >&2
    exit 1
fi

if [[ -n "${CMAKE_GENERATOR:-}" ]]; then
    readonly SELECTED_CMAKE_GENERATOR="${CMAKE_GENERATOR}"
elif command -v ninja >/dev/null 2>&1; then
    readonly SELECTED_CMAKE_GENERATOR="Ninja"
else
    readonly SELECTED_CMAKE_GENERATOR="Unix Makefiles"
fi

readonly WORK_ROOT="${RUNNER_TEMP:-${REPOSITORY_ROOT}/.build}/openblas-${ARTIFACT_VARIANT}"
readonly SOURCE_DIRECTORY="${WORK_ROOT}/source"
readonly BUILD_DIRECTORY="${WORK_ROOT}/build"
readonly INSTALL_DIRECTORY="${WORK_ROOT}/install"
readonly OUT_DIRECTORY="${ARTIFACT_BUNDLE_DIR}/${ARTIFACT_VARIANT}"

rm -rf -- "${WORK_ROOT}"
mkdir -p -- "${WORK_ROOT}"

git clone \
    --depth 1 \
    --branch "${OPENBLAS_VERSION}" \
    https://github.com/OpenMathLib/OpenBLAS.git \
    "${SOURCE_DIRECTORY}"

"${SELECTED_CMAKE_COMMAND}" \
    -S "${SOURCE_DIRECTORY}" \
    -B "${BUILD_DIRECTORY}" \
    -G "${SELECTED_CMAKE_GENERATOR}" \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_INSTALL_PREFIX="${INSTALL_DIRECTORY}" \
    -DCMAKE_INSTALL_LIBDIR=lib \
    -DCMAKE_POSITION_INDEPENDENT_CODE=ON \
    -DTARGET="${OPENBLAS_TARGET}" \
    -DDYNAMIC_ARCH="${DYNAMIC_ARCH}" \
    -DDYNAMIC_OLDER=OFF \
    -DCONSISTENT_FPCSR=ON \
    -DBINARY=64 \
    -DINTERFACE64=OFF \
    -DNOFORTRAN=1 \
    -DC_LAPACK=ON \
    -DBUILD_WITHOUT_LAPACK=OFF \
    -DBUILD_WITHOUT_LAPACKE=OFF \
    -DBUILD_STATIC_LIBS=ON \
    -DBUILD_SHARED_LIBS=OFF \
    -DBUILD_TESTING=OFF \
    -DBUILD_BENCHMARKS=OFF \
    -DUSE_OPENMP=OFF \
    -DUSE_THREAD=ON \
    -DNUM_THREADS=512

"${SELECTED_CMAKE_COMMAND}" --build "${BUILD_DIRECTORY}" --parallel "${BUILD_JOBS}"
"${SELECTED_CMAKE_COMMAND}" --install "${BUILD_DIRECTORY}"

for required_file in \
    "${INSTALL_DIRECTORY}/include/openblas/cblas.h" \
    "${INSTALL_DIRECTORY}/include/openblas/lapacke.h" \
    "${INSTALL_DIRECTORY}/lib/libopenblas.a" \
    "${SOURCE_DIRECTORY}/LICENSE"
do
    if [[ ! -f "${required_file}" ]]; then
        echo "ERROR: Expected installed file was not found: ${required_file}" >&2
        exit 1
    fi
done

readonly SMOKE_TEST_BINARY="${WORK_ROOT}/smoke-openblas"
cc \
    -std=c11 \
    -O2 \
    -I"${INSTALL_DIRECTORY}/include/openblas" \
    "${SCRIPT_DIR}/smoke-openblas.c" \
    "${INSTALL_DIRECTORY}/lib/libopenblas.a" \
    -lm \
    -lpthread \
    -ldl \
    -o "${SMOKE_TEST_BINARY}"
"${SMOKE_TEST_BINARY}"

SMOKE_TEST_MAX_GLIBC=""
if [[ -n "${GLIBC_BASELINE:-}" ]]; then
    SMOKE_TEST_MAX_GLIBC="$(
        readelf --version-info "${SMOKE_TEST_BINARY}" |
            sed -n 's/.*Name: GLIBC_\([0-9][0-9.]*\).*/\1/p' |
            sort -Vu |
            tail -n 1
    )"
    if [[ -z "${SMOKE_TEST_MAX_GLIBC}" ]]; then
        echo "ERROR: Could not determine the smoke test's glibc requirements." >&2
        exit 1
    fi
    if [[ "$(printf '%s\n%s\n' "${GLIBC_BASELINE}" "${SMOKE_TEST_MAX_GLIBC}" | sort -V | tail -n 1)" != "${GLIBC_BASELINE}" ]]; then
        echo "ERROR: Smoke test requires glibc ${SMOKE_TEST_MAX_GLIBC}, newer than baseline ${GLIBC_BASELINE}." >&2
        exit 1
    fi
fi
readonly SMOKE_TEST_MAX_GLIBC

rm -rf -- "${OUT_DIRECTORY}"
mkdir -p -- "${OUT_DIRECTORY}/include" "${OUT_DIRECTORY}/lib"

cp -a -- "${INSTALL_DIRECTORY}/include/openblas/." "${OUT_DIRECTORY}/include/"
cp -- "${INSTALL_DIRECTORY}/lib/libopenblas.a" "${OUT_DIRECTORY}/lib/libopenblas.a"
cp -- "${SOURCE_DIRECTORY}/LICENSE" "${OUT_DIRECTORY}/LICENSE-OpenBLAS.txt"
rm -f -- "${OUT_DIRECTORY}/include/lapacke_example_aux.h"

{
    printf '%s\n' '#ifndef _COPENBLAS_INCLUDE_H_'
    printf '%s\n' '#define _COPENBLAS_INCLUDE_H_'
    printf '%s\n' '#include "cblas.h"'
    printf '%s\n' '#include "lapacke.h"'
    printf '%s\n' '#endif'
} > "${OUT_DIRECTORY}/include/include.h"

{
    printf '%s\n' 'module _COpenBLAS {'
    printf '%s\n' '  header "include.h"'
    printf '%s\n' '  export *'
    printf '%s\n' '}'
} > "${OUT_DIRECTORY}/include/module.modulemap"

{
    printf 'openblas_version=%s\n' "${OPENBLAS_VERSION}"
    printf 'target=%s\n' "${OPENBLAS_TARGET}"
    printf 'dynamic_arch=%s\n' "${DYNAMIC_ARCH}"
    printf 'dynamic_older=OFF\n'
    printf 'no_fortran=1\n'
    printf 'build_jobs=%s\n' "${BUILD_JOBS}"
    printf 'cmake_command=%s\n' "${SELECTED_CMAKE_COMMAND}"
    printf 'cmake_generator=%s\n' "${SELECTED_CMAKE_GENERATOR}"
    if [[ -n "${GLIBC_BASELINE:-}" ]]; then
        printf 'glibc_baseline=%s\n' "${GLIBC_BASELINE}"
        printf 'build_libc=%s\n' "${DETECTED_GLIBC}"
        printf 'smoke_test_max_glibc=%s\n' "${SMOKE_TEST_MAX_GLIBC}"
    fi
} > "${OUT_DIRECTORY}/BUILD-INFO.txt"

echo "Staged ${ARTIFACT_VARIANT} at ${OUT_DIRECTORY}"
