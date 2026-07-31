@echo off
setlocal EnableExtensions

rem Build settings
set "OPENBLAS_VERSION=v0.3.34"
set "BUILD_JOBS=16"
set "TARGET_TRIPLE=aarch64-pc-windows-msvc"
set "BUILD_DIRECTORY=build-arm64-nofortran"

rem Locate a Visual Studio installation containing the ARM64 build tools.
set "VSWHERE=%ProgramFiles(x86)%\Microsoft Visual Studio\Installer\vswhere.exe"

if not exist "%VSWHERE%" (
    echo ERROR: vswhere.exe was not found. Install Visual Studio 2026 with C++ tools.
    exit /b 1
)

set "VS_INSTALL="
for /f "usebackq tokens=*" %%I in (`"%VSWHERE%" -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.ARM64 -property installationPath`) do set "VS_INSTALL=%%I"

if not defined VS_INSTALL (
    echo ERROR: Visual Studio ARM64 build tools are not installed.
    exit /b 1
)

set "VCVARSALL=%VS_INSTALL%\VC\Auxiliary\Build\vcvarsall.bat"

if not exist "%VCVARSALL%" (
    echo ERROR: vcvarsall.bat was not found at:
    echo        %VCVARSALL%
    exit /b 1
)

rem Use x64-hosted tools targeting ARM64.
call "%VCVARSALL%" amd64_arm64
if errorlevel 1 goto :failed

echo Host architecture:   %VSCMD_ARG_HOST_ARCH%
echo Target architecture: %VSCMD_ARG_TGT_ARCH%

if exist "OpenBLAS\.git" goto :verify_source

if exist "OpenBLAS" (
    echo ERROR: OpenBLAS exists but is not a Git repository.
    exit /b 1
)

git clone --depth 1 --branch "%OPENBLAS_VERSION%" https://github.com/OpenMathLib/OpenBLAS.git
if errorlevel 1 goto :failed
goto :source_ready

:verify_source
set "CHECKED_OUT_TAG="
for /f "usebackq tokens=*" %%I in (`git -C OpenBLAS describe --tags --exact-match 2^>nul`) do set "CHECKED_OUT_TAG=%%I"

if /i not "%CHECKED_OUT_TAG%"=="%OPENBLAS_VERSION%" (
    echo ERROR: Existing OpenBLAS directory is not checked out at %OPENBLAS_VERSION%.
    exit /b 1
)

echo Reusing existing OpenBLAS source at %OPENBLAS_VERSION%.

:source_ready
pushd OpenBLAS
if errorlevel 1 goto :failed
set "SOURCE_PUSHED=1"

set "INSTALL_DIRECTORY=%CD%\install-arm64-nofortran"

cmake -S . -B "%BUILD_DIRECTORY%" -G Ninja ^
    "-DCMAKE_BUILD_TYPE=Release" ^
    "-DCMAKE_SYSTEM_NAME=Windows" ^
    "-DCMAKE_SYSTEM_PROCESSOR=ARM64" ^
    "-DCMAKE_C_COMPILER=clang-cl" ^
    "-DCMAKE_C_COMPILER_TARGET=%TARGET_TRIPLE%" ^
    "-DCMAKE_ASM_COMPILER_TARGET=%TARGET_TRIPLE%" ^
    "-DCMAKE_C_FLAGS=--target=%TARGET_TRIPLE%" ^
    "-DCMAKE_LINKER=lld-link" ^
    "-DCMAKE_MSVC_RUNTIME_LIBRARY=MultiThreadedDLL" ^
    "-DTARGET=ARMV8" ^
    "-DDYNAMIC_ARCH=OFF" ^
    "-DBINARY=64" ^
    "-DINTERFACE64=OFF" ^
    "-DNOFORTRAN=1" ^
    "-DC_LAPACK=ON" ^
    "-DBUILD_WITHOUT_LAPACK=OFF" ^
    "-DBUILD_WITHOUT_LAPACKE=OFF" ^
    "-DBUILD_STATIC_LIBS=ON" ^
    "-DBUILD_SHARED_LIBS=OFF" ^
    "-DCMAKE_SYSTEM_PROCESSOR=amd64" ^
    "-DBUILD_TESTING=OFF" ^
    "-DBUILD_BENCHMARKS=OFF" ^
    "-DUSE_OPENMP=OFF" ^
    "-DUSE_THREAD=ON" ^
    "-DNUM_THREADS=64" ^
    "-DCMAKE_INSTALL_PREFIX=%INSTALL_DIRECTORY%"
if errorlevel 1 goto :failed

cmake --build "%BUILD_DIRECTORY%" --parallel %BUILD_JOBS%
if errorlevel 1 goto :failed

cmake --install "%BUILD_DIRECTORY%"
if errorlevel 1 goto :failed

popd
set "SOURCE_PUSHED="

rem Stage the SwiftPM artifact bundle.
for %%I in ("%CD%\..\COpenBLAS.artifactbundle\openblas-windows-aarch64") do set "OUT_DIR=%%~fI"

rem Verify the new installation before deleting the previous artifact.
if not exist "%INSTALL_DIRECTORY%\include\openblas\cblas.h" (
    echo ERROR: Installed cblas.h was not found.
    goto :failed
)

if not exist "%INSTALL_DIRECTORY%\include\openblas\lapacke.h" (
    echo ERROR: Installed lapacke.h was not found.
    goto :failed
)

if not exist "%INSTALL_DIRECTORY%\lib\openblas.lib" (
    echo ERROR: Installed openblas.lib was not found.
    goto :failed
)

if exist "%OUT_DIR%" rmdir /s /q "%OUT_DIR%"
if exist "%OUT_DIR%" (
    echo ERROR: Could not remove artifact directory:
    echo        %OUT_DIR%
    goto :failed
)

mkdir "%OUT_DIR%\include"
if errorlevel 1 goto :failed

mkdir "%OUT_DIR%\lib"
if errorlevel 1 goto :failed

pushd OpenBLAS
if errorlevel 1 goto :failed
set "SOURCE_PUSHED=1"

xcopy "%INSTALL_DIRECTORY%\include\openblas\*" "%OUT_DIR%\include\" /E /I /H /Y /Q >nul
if errorlevel 1 goto :failed

copy /Y "%INSTALL_DIRECTORY%\lib\openblas.lib" "%OUT_DIR%\lib\openblas.lib" >nul
if errorlevel 1 goto :failed

if exist "%OUT_DIR%\include\lapacke_example_aux.h" (
    del /F /Q "%OUT_DIR%\include\lapacke_example_aux.h"
    if errorlevel 1 goto :failed
)

(
    echo #ifndef _COPENBLAS_INCLUDE_H_
    echo #define _COPENBLAS_INCLUDE_H_
    echo #include "cblas.h"
    echo #include "lapacke.h"
    echo #endif
) > "%OUT_DIR%\include\include.h"
if errorlevel 1 goto :failed

(
    echo module _COpenBLAS {
    echo     header "include.h"
    echo     export *
    echo }
) > "%OUT_DIR%\include\module.modulemap"
if errorlevel 1 goto :failed

popd
set "SOURCE_PUSHED="

echo.
echo OpenBLAS ARM64 was installed to:
echo %INSTALL_DIRECTORY%
echo.
echo Artifact bundle staged at:
echo %OUT_DIR%
exit /b 0

:failed
set "BUILD_EXIT_CODE=%ERRORLEVEL%"
if "%BUILD_EXIT_CODE%"=="0" set "BUILD_EXIT_CODE=1"
if defined SOURCE_PUSHED popd
echo.
echo ERROR: OpenBLAS ARM64 build failed with exit code %BUILD_EXIT_CODE%.
exit /b %BUILD_EXIT_CODE%
