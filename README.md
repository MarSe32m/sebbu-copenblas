# sebbu-copenblas
# COpenBLAS

Prebuilt OpenBLAS static libraries for SwiftPM.

| Supported Swift target triples |
| --- |
| `x86_64-unknown-linux-gnu` | 
| `aarch64-unknown-linux-gnu` |
| `x86_64-swift-linux-musl` |
| `aarch64-swift-linux-musl` |
| `x86_64-unknown-windows-msvc` |
| `aarch64-unknown-windows-msvc` |

All variants are built with `NOFORTRAN=1`, `C_LAPACK=ON`, pthreads enabled,
OpenMP disabled, and `DYNAMIC_OLDER=OFF`. The x86-64 variants retain
`DYNAMIC_ARCH=ON`and the AArch64 variants use the ARMv8 baseline.

The package deliberately doesn't provide libraries for macOS since there ```Accelerate``` should be used.