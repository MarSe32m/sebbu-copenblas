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
`DYNAMIC_ARCH=ON` and the AArch64 variants use the ARMv8 baseline. Windows
variants are built with `clang-cl` and use `MAX_STACK_ALLOC=2048` so small
Level-2 operations use stack-local workspaces instead of OpenBLAS's shared
workspace allocator.

Package versions follow Semantic Versioning independently of the bundled
OpenBLAS version. Currently the latest package version and OpenBLAS version
are in sync. However, in the future they might stray away from each other. 
Every release records both versions in its release notes and
`BUILD-METADATA.json`.

The package deliberately does not provide libraries for macOS, where
`Accelerate` should be used.
