#!/usr/bin/env bash
set -euo pipefail

ARCH="${1:-}"

if [[ "$ARCH" != "x86_64" && "$ARCH" != "aarch64" && "$ARCH" != "all" ]]; then
  echo "Usage:"
  echo "  $0 x86_64"
  echo "  $0 aarch64"
  echo "  $0 all"
  exit 1
fi

# OpenBLAS 0.3.33 was released Apr 23, 2026.
# Override with:
#   OPENBLAS_VERSION=0.3.32 ./build-openblas-glibc.sh x86_64
OPENBLAS_VERSION="${OPENBLAS_VERSION:-0.3.33}"

# Compile-time maximum number of OpenBLAS worker threads.
# For 192 physical cores and 384 SMT threads, 512 gives headroom.
# Override with:
#   OPENBLAS_MAX_THREADS=384 ./build-openblas-glibc.sh x86_64
OPENBLAS_MAX_THREADS="${OPENBLAS_MAX_THREADS:-512}"

build_one_arch() {
  local arch="$1"

  local docker_platform=""
  local base_image=""
  local swift_triple=""
  local extra_openblas_flags=""
  local out_dir=""
  local image_name=""

  case "$arch" in
    x86_64)
      docker_platform="linux/amd64"
      base_image="quay.io/pypa/manylinux_2_34_x86_64:latest"
      swift_triple="x86_64-unknown-linux-gnu"
      extra_openblas_flags="DYNAMIC_OLDER=1"
      out_dir="${OUT_DIR:-$PWD/openblas-linux-x86_64-glibc2.34}"
      image_name="openblas-x86_64-glibc234-builder:${OPENBLAS_VERSION}"
      ;;
    aarch64)
      docker_platform="linux/arm64"
      base_image="quay.io/pypa/manylinux_2_34_aarch64:latest"
      swift_triple="aarch64-unknown-linux-gnu"
      extra_openblas_flags="TARGET=ARMV8"
      out_dir="${OUT_DIR:-$PWD/openblas-linux-aarch64-glibc2.34}"
      image_name="openblas-aarch64-glibc234-builder:${OPENBLAS_VERSION}"
      ;;
  esac

  rm -rf "$out_dir"
  mkdir -p "$out_dir"

  cat > Dockerfile.openblas-glibc <<'DOCKERFILE'
ARG BASE_IMAGE
FROM ${BASE_IMAGE}

ARG OPENBLAS_VERSION
ARG OPENBLAS_MAX_THREADS
ARG EXTRA_OPENBLAS_FLAGS

RUN yum -y install \
      git \
      make \
      gcc \
      perl \
      which \
      findutils \
      diffutils \
      tar \
      gzip \
      file \
      binutils \
    && yum clean all

WORKDIR /build

RUN git clone --depth 1 \
      --branch "v${OPENBLAS_VERSION}" \
      https://github.com/OpenMathLib/OpenBLAS.git

WORKDIR /build/OpenBLAS

# Important options:
#
# DYNAMIC_ARCH=1:
#   Build one library with runtime CPU dispatch.
#
# DYNAMIC_OLDER=1:
#   x86_64 only; include older x86_64 kernels as well.
#
# TARGET=ARMV8:
#   aarch64 only; generic ARMv8/AArch64 baseline, not a specific CPU.
#
# NUM_THREADS:
#   Compile-time maximum OpenBLAS worker threads.
#
# BIGNUMA=1:
#   Safer for very large HPC nodes / >256 logical CPUs.
#
# USE_THREAD=1 + USE_OPENMP=0:
#   Use OpenBLAS' pthread backend. Easier to vendor into Swift than OpenMP.
#
# NO_AFFINITY=1:
#   Let SLURM / the scheduler handle CPU binding.
#
# NOFORTRAN=1:
#   Avoid libgfortran/libquadmath dependencies. This still keeps BLAS,
#   CBLAS, LAPACK, and LAPACKE through OpenBLAS' C/f2c path.
#
# NO_SHARED=1:
#   Build static libopenblas.a only.
#
# Do not use -march=native.
RUN make -j"$(nproc)" \
      BINARY=64 \
      DYNAMIC_ARCH=1 \
      ${EXTRA_OPENBLAS_FLAGS} \
      USE_THREAD=1 \
      USE_OPENMP=0 \
      NUM_THREADS="${OPENBLAS_MAX_THREADS}" \
      BIGNUMA=1 \
      NO_AFFINITY=1 \
      NOFORTRAN=1 \
      NO_SHARED=1 \
      NO_STATIC=0 \
      CFLAGS="-O2 -fPIC" \
      FFLAGS="-O2 -fPIC" \
      FCFLAGS="-O2 -fPIC"

RUN make PREFIX=/opt/openblas NO_SHARED=1 install

RUN test -f /opt/openblas/lib/libopenblas.a
RUN test -f /opt/openblas/include/cblas.h
RUN test -f /opt/openblas/include/lapacke.h
RUN test -f /opt/openblas/include/openblas_config.h

# Your previous failure mode should not appear.
RUN ! nm -A /opt/openblas/lib/libopenblas.a | grep '__isoc23'

# Check that LAPACKE symbols exist.
RUN nm -A /opt/openblas/lib/libopenblas.a | grep ' LAPACKE_dgesv'

# Tiny CBLAS test.
RUN cat > /tmp/test_cblas.c <<'EOF'
#include <cblas.h>
#include <stdio.h>

int main(void) {
    double A[4] = {1.0, 2.0, 3.0, 4.0};
    double B[4] = {5.0, 6.0, 7.0, 8.0};
    double C[4] = {0.0, 0.0, 0.0, 0.0};

    cblas_dgemm(
        CblasRowMajor,
        CblasNoTrans,
        CblasNoTrans,
        2, 2, 2,
        1.0,
        A, 2,
        B, 2,
        0.0,
        C, 2
    );

    printf("%g %g %g %g\n", C[0], C[1], C[2], C[3]);
    return 0;
}
EOF

RUN gcc \
      -I/opt/openblas/include \
      /tmp/test_cblas.c \
      /opt/openblas/lib/libopenblas.a \
      -lm -lpthread -ldl \
      -o /tmp/test_cblas \
    && /tmp/test_cblas

# Tiny LAPACKE test.
RUN cat > /tmp/test_lapacke.c <<'EOF'
#include <lapacke.h>
#include <stdio.h>

int main(void) {
    lapack_int n = 2;
    lapack_int nrhs = 1;
    lapack_int lda = 2;
    lapack_int ldb = 1;
    lapack_int ipiv[2];

    double A[4] = {
        3.0, 1.0,
        1.0, 2.0
    };

    double b[2] = {
        9.0,
        8.0
    };

    lapack_int info = LAPACKE_dgesv(
        LAPACK_ROW_MAJOR,
        n,
        nrhs,
        A,
        lda,
        ipiv,
        b,
        ldb
    );

    printf("info=%d x=[%g, %g]\n", (int)info, b[0], b[1]);
    return info;
}
EOF

RUN gcc \
      -I/opt/openblas/include \
      /tmp/test_lapacke.c \
      /opt/openblas/lib/libopenblas.a \
      -lm -lpthread -ldl \
      -o /tmp/test_lapacke \
    && /tmp/test_lapacke

DOCKERFILE

  docker buildx build \
    --platform "$docker_platform" \
    --load \
    --build-arg BASE_IMAGE="$base_image" \
    --build-arg OPENBLAS_VERSION="$OPENBLAS_VERSION" \
    --build-arg OPENBLAS_MAX_THREADS="$OPENBLAS_MAX_THREADS" \
    --build-arg EXTRA_OPENBLAS_FLAGS="$extra_openblas_flags" \
    -t "$image_name" \
    -f Dockerfile.openblas-glibc .

  local container_id
  container_id="$(docker create "$image_name")"
  docker cp "$container_id:/opt/openblas/." "$out_dir"
  docker rm "$container_id" >/dev/null

  cat > "$out_dir/include/include.h" << 'EOF'
#include "cblas.h"
#include "lapacke.h"
EOF

  cat > "$out_dir/include/module.modulemap" <<'EOF'
module COpenBLAS {
  header "include.h"
  export *
}
EOF

  echo
  echo "Built OpenBLAS glibc:"
  echo "  arch:         $arch"
  echo "  Swift triple: $swift_triple"
  echo "  output:       $out_dir/lib/libopenblas.a"
  echo
  echo "Headers:"
  echo "  $out_dir/include"
  echo
  echo "Checking for bad glibc C23 symbols:"
  if nm -A "$out_dir/lib/libopenblas.a" | grep '__isoc23'; then
    echo "ERROR: found __isoc23 symbols"
    exit 1
  else
    echo "  OK: no __isoc23 symbols found"
  fi

  echo
  echo "Checking LAPACKE:"
  if nm -A "$out_dir/lib/libopenblas.a" | grep ' LAPACKE_dgesv' >/dev/null; then
    echo "  OK: LAPACKE_dgesv found"
  else
    echo "ERROR: LAPACKE_dgesv not found"
    exit 1
  fi

  echo
  echo "OpenBLAS config summary:"
  grep -E 'OPENBLAS_VERSION|MAX_CPU_NUMBER|DYNAMIC_ARCH|USE_THREAD|USE_OPENMP|BIGNUMA' \
    "$out_dir/include/openblas_config.h" || true

  echo
  echo "Done:"
  echo "  $out_dir"
}

if [[ "$ARCH" == "all" ]]; then
  build_one_arch x86_64
  build_one_arch aarch64
else
  build_one_arch "$ARCH"
fi