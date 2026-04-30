#!/usr/bin/env bash
set -euo pipefail

ARCH="${1:-}"

if [[ "$ARCH" != "x86_64" && "$ARCH" != "aarch64" ]]; then
  echo "Usage:"
  echo "  $0 x86_64"
  echo "  $0 aarch64"
  exit 1
fi

OPENBLAS_VERSION="${OPENBLAS_VERSION:-0.3.33}"
OPENBLAS_MAX_THREADS="${OPENBLAS_MAX_THREADS:-512}"

case "$ARCH" in
  x86_64)
    DOCKER_PLATFORM="linux/amd64"
    BASE_IMAGE="quay.io/pypa/musllinux_1_2_x86_64:latest"
    SWIFT_TRIPLE="x86_64-unknown-linux-musl"
    EXTRA_OPENBLAS_FLAGS="DYNAMIC_OLDER=1"
    ;;
  aarch64)
    DOCKER_PLATFORM="linux/arm64"
    BASE_IMAGE="quay.io/pypa/musllinux_1_2_aarch64:latest"
    SWIFT_TRIPLE="aarch64-unknown-linux-musl"
    EXTRA_OPENBLAS_FLAGS="TARGET=ARMV8"
    ;;
esac

OUT_DIR="${OUT_DIR:-$PWD/openblas-linux-${ARCH}-musl1.2}"
IMAGE_NAME="openblas-${ARCH}-musl-builder:${OPENBLAS_VERSION}"

rm -rf "$OUT_DIR"
mkdir -p "$OUT_DIR"

cat > Dockerfile.openblas-musl <<'DOCKERFILE'
ARG BASE_IMAGE
FROM ${BASE_IMAGE}

ARG OPENBLAS_VERSION
ARG OPENBLAS_MAX_THREADS
ARG EXTRA_OPENBLAS_FLAGS

RUN apk add --no-cache \
      bash \
      git \
      make \
      gcc \
      musl-dev \
      linux-headers \
      perl \
      binutils \
      file \
      tar \
      gzip

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
#   x86_64 only; include older x86_64 kernels such as Atom, Bobcat,
#   Penryn, Opteron, etc.
#
# TARGET=ARMV8:
#   aarch64 only; generic ARMv8 baseline, not a specific CPU.
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
#   Avoid libgfortran/libquadmath dependencies. This still keeps CBLAS,
#   LAPACK, and LAPACKE through OpenBLAS' C/f2c path.
#
# NO_SHARED=1:
#   Build static libopenblas.a only.
#
# Do not use -march=native.
RUN make \
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

# Should not contain glibc/C23 symbols.
RUN ! nm -A /opt/openblas/lib/libopenblas.a | grep '__isoc23'
RUN ! readelf -Ws /opt/openblas/lib/libopenblas.a 2>/dev/null | grep 'GLIBC_'

# Check that LAPACKE exists.
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
      -lm -lpthread \
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
      -lm -lpthread \
      -o /tmp/test_lapacke \
    && /tmp/test_lapacke

DOCKERFILE

docker buildx build \
  --platform "$DOCKER_PLATFORM" \
  --load \
  --build-arg BASE_IMAGE="$BASE_IMAGE" \
  --build-arg OPENBLAS_VERSION="$OPENBLAS_VERSION" \
  --build-arg OPENBLAS_MAX_THREADS="$OPENBLAS_MAX_THREADS" \
  --build-arg EXTRA_OPENBLAS_FLAGS="$EXTRA_OPENBLAS_FLAGS" \
  -t "$IMAGE_NAME" \
  -f Dockerfile.openblas-musl .

container_id="$(docker create "$IMAGE_NAME")"
docker cp "$container_id:/opt/openblas/." "$OUT_DIR"
docker rm "$container_id" >/dev/null

cat > "$OUT_DIR/include/include.h" << 'EOF'
#include "cblas.h"
#include "lapacke.h"
EOF

cat > "$OUT_DIR/include/module.modulemap" <<'EOF'
module _COpenBLAS {
  header "include.h"
  export *
}
EOF

echo
echo "Built OpenBLAS musl:"
echo "  arch:         $ARCH"
echo "  Swift triple: $SWIFT_TRIPLE"
echo "  output:       $OUT_DIR/lib/libopenblas.a"
echo
echo "Headers:"
echo "  $OUT_DIR/include"
echo
echo "Checking for glibc/C23 leakage:"
if nm -A "$OUT_DIR/lib/libopenblas.a" | grep '__isoc23'; then
  echo "ERROR: found __isoc23 symbols"
  exit 1
fi

if readelf -Ws "$OUT_DIR/lib/libopenblas.a" 2>/dev/null | grep 'GLIBC_'; then
  echo "ERROR: found GLIBC versioned symbols"
  exit 1
fi

echo "  OK: no __isoc23 or GLIBC_ symbols found"
echo
echo "Checking LAPACKE:"
if nm -A "$OUT_DIR/lib/libopenblas.a" | grep ' LAPACKE_dgesv' >/dev/null; then
  echo "  OK: LAPACKE_dgesv found"
else
  echo "ERROR: LAPACKE_dgesv not found"
  exit 1
fi

echo
echo "OpenBLAS config summary:"
grep -E 'OPENBLAS_VERSION|MAX_CPU_NUMBER|DYNAMIC_ARCH|USE_THREAD|USE_OPENMP|BIGNUMA' \
  "$OUT_DIR/include/openblas_config.h" || true