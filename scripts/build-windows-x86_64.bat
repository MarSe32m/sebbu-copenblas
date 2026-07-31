@echo off
setlocal EnableExtensions

for %%I in ("%~dp0..") do set "REPOSITORY_ROOT=%%~fI"
pushd "%REPOSITORY_ROOT%"
if errorlevel 1 goto :failed
set "REPOSITORY_PUSHED=1"

rem Callers may override these values, including from GitHub Actions.
if not defined OPENBLAS_VERSION set "OPENBLAS_VERSION=v0.3.34"
if not defined BUILD_JOBS set "BUILD_JOBS=%NUMBER_OF_PROCESSORS%"
if not defined BUILD_JOBS set "BUILD_JOBS=1"
if not defined ARTIFACT_BUNDLE_DIR set "ARTIFACT_BUNDLE_DIR=%REPOSITORY_ROOT%\COpenBLAS.artifactbundle"

set "BUILD_DIRECTORY=build-x86_64-nofortran"

rem Locate a Visual Studio installation containing the x64 build tools.
set "VSWHERE=%ProgramFiles(x86)%\Microsoft Visual Studio\Installer\vswhere.exe"

if not exist "%VSWHERE%" (
    echo ERROR: vswhere.exe was not found. Install Visual Studio with C++ x64 tools.
    goto :failed
)

set "VS_INSTALL="
for /f "usebackq tokens=*" %%I in (`"%VSWHERE%" -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath`) do set "VS_INSTALL=%%I"

if not defined VS_INSTALL (
    echo ERROR: Visual Studio x64 build tools are not installed.
    goto :failed
)

set "VCVARSALL=%VS_INSTALL%\VC\Auxiliary\Build\vcvarsall.bat"

if not exist "%VCVARSALL%" (
    echo ERROR: vcvarsall.bat was not found at:
    echo        %VCVARSALL%
    goto :failed
)

rem Use x64-hosted tools targeting x64.
call "%VCVARSALL%" x64
if errorlevel 1 goto :failed

echo Host architecture:   %VSCMD_ARG_HOST_ARCH%
echo Target architecture: %VSCMD_ARG_TGT_ARCH%

if exist "OpenBLAS\.git" goto :verify_source

if exist "OpenBLAS" (
    echo ERROR: OpenBLAS exists but is not a Git repository.
    goto :failed
)

git clone --depth 1 --branch "%OPENBLAS_VERSION%" https://github.com/OpenMathLib/OpenBLAS.git
if errorlevel 1 goto :failed
goto :source_ready

:verify_source
set "CHECKED_OUT_TAG="
for /f "usebackq tokens=*" %%I in (`git -C OpenBLAS describe --tags --exact-match 2^>nul`) do set "CHECKED_OUT_TAG=%%I"

if /i not "%CHECKED_OUT_TAG%"=="%OPENBLAS_VERSION%" (
    echo ERROR: Existing OpenBLAS directory is not checked out at %OPENBLAS_VERSION%.
    goto :failed
)

echo Reusing existing OpenBLAS source at %OPENBLAS_VERSION%.

:source_ready
pushd OpenBLAS
if errorlevel 1 goto :failed
set "SOURCE_PUSHED=1"

set "INSTALL_DIRECTORY=%CD%\install-x86_64-nofortran"

cmake -S . -B "%BUILD_DIRECTORY%" -G Ninja ^
    "-DCMAKE_BUILD_TYPE=Release" ^
    "-DCMAKE_C_COMPILER=clang-cl" ^
    "-DCMAKE_LINKER=lld-link" ^
    "-DCMAKE_MSVC_RUNTIME_LIBRARY=MultiThreadedDLL" ^
    "-DCMAKE_INSTALL_LIBDIR=lib" ^
    "-DTARGET=GENERIC" ^
    "-DDYNAMIC_ARCH=ON" ^
    "-DDYNAMIC_OLDER=OFF" ^
    "-DCONSISTENT_FPCSR=ON" ^
    "-DBINARY=64" ^
    "-DINTERFACE64=OFF" ^
    "-DNOFORTRAN=1" ^
    "-DC_LAPACK=ON" ^
    "-DBUILD_WITHOUT_LAPACK=OFF" ^
    "-DBUILD_WITHOUT_LAPACKE=OFF" ^
    "-DBUILD_STATIC_LIBS=ON" ^
    "-DBUILD_SHARED_LIBS=OFF" ^
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

for %%I in ("%ARTIFACT_BUNDLE_DIR%\openblas-windows-x86_64") do set "OUT_DIR=%%~fI"

rem Verify the new installation before deleting any previous artifact.
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

if not exist "%REPOSITORY_ROOT%\OpenBLAS\LICENSE" (
    echo ERROR: OpenBLAS LICENSE was not found.
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

xcopy "%INSTALL_DIRECTORY%\include\openblas\*" "%OUT_DIR%\include\" /E /I /H /Y /Q >nul
if errorlevel 1 goto :failed

copy /Y "%INSTALL_DIRECTORY%\lib\openblas.lib" "%OUT_DIR%\lib\openblas.lib" >nul
if errorlevel 1 goto :failed

copy /Y "%REPOSITORY_ROOT%\OpenBLAS\LICENSE" "%OUT_DIR%\LICENSE-OpenBLAS.txt" >nul
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
    echo   header "include.h"
    echo   export *
    echo }
) > "%OUT_DIR%\include\module.modulemap"
if errorlevel 1 goto :failed

(
    echo openblas_version=%OPENBLAS_VERSION%
    echo target=GENERIC
    echo dynamic_arch=ON
    echo dynamic_older=OFF
    echo no_fortran=1
    echo build_jobs=%BUILD_JOBS%
) > "%OUT_DIR%\BUILD-INFO.txt"
if errorlevel 1 goto :failed

echo.
echo OpenBLAS x86-64 was installed to:
echo %INSTALL_DIRECTORY%
echo.
echo Artifact payload staged at:
echo %OUT_DIR%

popd
set "REPOSITORY_PUSHED="
exit /b 0

:failed
set "BUILD_EXIT_CODE=%ERRORLEVEL%"
if "%BUILD_EXIT_CODE%"=="0" set "BUILD_EXIT_CODE=1"
if defined SOURCE_PUSHED popd
if defined REPOSITORY_PUSHED popd
echo.
echo ERROR: OpenBLAS x86-64 build or packaging failed with exit code %BUILD_EXIT_CODE%.
exit /b %BUILD_EXIT_CODE%
