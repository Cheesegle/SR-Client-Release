@echo off
rem Build helper for Windows (requires Odin compiler in PATH).
rem
rem Usage:
rem   build.bat client            build the client      -> bin\sr_client.exe
rem                               (OpenGL and Vulkan; client, dev and check
rem                               recompile the SPIR-V first when the Vulkan
rem                               SDK's glslc is on PATH, else use the committed
rem                               src\client\spirv\*.spv)
rem   build.bat dev               developer client with debug tools (F3 window)
rem                                                     -> bin\sr_client_dev.exe
rem                               never packaged; releases use sr_client.exe
rem   build.bat browser           build browser helper and restore WebView2 loader
rem   build.bat server            build the server      -> bin\sr_server.exe
rem   build.bat tests             build + run the sim tests
rem   build.bat tests-vk          build + run the client tests on the Vulkan
rem                               backend with validation on (any validation
rem                               error fails the test that raised it)
rem   build.bat check             typecheck client + server without linking
rem   build.bat spirv             recompile the Vulkan shaders (needs glslc; the .spv files are committed)
rem   build.bat all               build client + server
rem   build.bat clean             remove built binaries
rem   build.bat (no args)         same as "all"
rem   build.bat client speed      build the client with -o:speed
rem   build.bat tests none        build and run tests with -o:none
rem   build.bat all speed minimal build client/server with separate levels
rem Optimization levels: none, minimal, size, speed, aggressive (default).

setlocal
set "BIN_DIR=bin"
set "ODIN=odin"
set "TARGET=%~1"
set "PROFILE=%~2"
set "SERVER_PROFILE=%~3"

if "%TARGET%"=="" set "TARGET=all"
if "%PROFILE%"=="" set "PROFILE=aggressive"
if "%SERVER_PROFILE%"=="" set "SERVER_PROFILE=%PROFILE%"

if /i "%TARGET%"=="help" goto usage
set "VALID_TARGET="
for %%T in (client dev browser server tests tests-vk check spirv all clean) do if /i "%TARGET%"=="%%T" (
    set "TARGET=%%T"
    set "VALID_TARGET=1"
)
if not defined VALID_TARGET goto bad_arguments
if not "%~4"=="" goto bad_arguments
if not "%TARGET%"=="all" if not "%~3"=="" goto bad_arguments
if "%TARGET%"=="spirv" if not "%~2"=="" goto bad_arguments
if "%TARGET%"=="check" if not "%~2"=="" goto bad_arguments
if "%TARGET%"=="clean" if not "%~2"=="" goto bad_arguments

call :validate_profile "%PROFILE%"
if errorlevel 1 exit /b 1
if "%TARGET%"=="all" call :validate_profile "%SERVER_PROFILE%"
if errorlevel 1 exit /b 1

where %ODIN% >nul 2>nul
if errorlevel 1 (
    echo Error: Odin compiler not found in PATH. Install it from https://odin-lang.org
    exit /b 1
)

if not exist "%BIN_DIR%" mkdir "%BIN_DIR%"

goto:%TARGET%

:clay
rem Build the Clay UI library from source (src\third_party\clay\clay.c).
if exist src\third_party\clay\windows\clay.lib exit /b 0
where cl >nul 2>nul
if errorlevel 1 (
    echo Error: cl.exe not found. Run this from the "x64 Native Tools Command Prompt for VS".
    exit /b 1
)
if not exist src\third_party\clay\windows mkdir src\third_party\clay\windows
pushd src\third_party\clay
cl /nologo /c /O2 /MT /Brepro /DCLAY_DISABLE_SIMD clay.c /Foclay.obj
if errorlevel 1 ( popd & exit /b 1 )
lib /nologo /OUT:windows\clay.lib clay.obj
set "CLAY_ERR=%errorlevel%"
del clay.obj
popd
exit /b %CLAY_ERR%

:browser
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tools\setup-webview2.ps1
if errorlevel 1 exit /b %errorlevel%
%ODIN% build src/browser_helper -out:%BIN_DIR%\sr_browser.exe -o:%PROFILE% -subsystem:windows -resource:installer\sr-client.rc
exit /b %errorlevel%

:client
call :clay
if errorlevel 1 exit /b %errorlevel%
call :spirv_optional
if errorlevel 1 exit /b %errorlevel%
call :browser
if errorlevel 1 exit /b %errorlevel%
%ODIN% build src/client -out:%BIN_DIR%\sr_client.exe -o:%PROFILE% -subsystem:windows -resource:installer\sr-client.rc
exit /b %errorlevel%

:spirv
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tools\build-spirv.ps1
exit /b %errorlevel%

:spirv_optional
rem Recompiles the committed SPIR-V when glslc is available, so it never goes
rem stale after a shader edit; without the Vulkan SDK the committed files are used.
where glslc >nul 2>nul
if errorlevel 1 (
    echo glslc not found; using the committed SPIR-V in src\client\spirv
    exit /b 0
)
goto spirv

:dev
rem Developer build: compiles in the debug tools (SR_DEV). It uses its own
rem file name so it can never be packaged or mistaken for a tester build.
call :clay
if errorlevel 1 exit /b %errorlevel%
call :spirv_optional
if errorlevel 1 exit /b %errorlevel%
call :browser
if errorlevel 1 exit /b %errorlevel%
%ODIN% build src/client -out:%BIN_DIR%\sr_client_dev.exe -o:%PROFILE% -define:SR_DEV=true -resource:installer\sr-client.rc
exit /b %errorlevel%

:server
%ODIN% build src/server -out:%BIN_DIR%\sr_server.exe -o:%PROFILE%
exit /b %errorlevel%

:tests
%ODIN% build src/tests -out:%BIN_DIR%\sr_tests.exe -o:%PROFILE%
if errorlevel 1 exit /b %errorlevel%
"%BIN_DIR%\sr_tests.exe"
if errorlevel 1 exit /b %errorlevel%
%ODIN% test src/browser_access -out:%BIN_DIR%\browser_access_tests.exe -o:none
exit /b %errorlevel%

:tests-vk
call :spirv
if errorlevel 1 exit /b %errorlevel%
set "SR_VK_VALIDATION=1"
set "VK_KHRONOS_VALIDATION_VALIDATE_SYNC=true"
%ODIN% build src/client -build-mode:test -o:none -define:SR_VULKAN=true -define:ODIN_TEST_THREADS=1 -out:%BIN_DIR%\client_tests_vk.exe
if errorlevel 1 exit /b %errorlevel%
"%BIN_DIR%\client_tests_vk.exe"
exit /b %errorlevel%

:check
%ODIN% check src/browser_helper
if errorlevel 1 exit /b %errorlevel%
call :spirv_optional
if errorlevel 1 exit /b %errorlevel%
%ODIN% check src/client
if errorlevel 1 exit /b %errorlevel%
%ODIN% check src/client -define:SR_DEV=true
if errorlevel 1 exit /b %errorlevel%
%ODIN% check src/server
exit /b %errorlevel%

:all
call :client
if errorlevel 1 exit /b %errorlevel%
set "PROFILE=%SERVER_PROFILE%"
call :server
exit /b %errorlevel%

:clean
if exist "%BIN_DIR%\sr_browser.exe" del "%BIN_DIR%\sr_browser.exe"
if exist "%BIN_DIR%\WebView2Loader.dll" del "%BIN_DIR%\WebView2Loader.dll"
if exist "%BIN_DIR%\WebView2-LICENSE.txt" del "%BIN_DIR%\WebView2-LICENSE.txt"
if exist "%BIN_DIR%\WebView2-NOTICE.txt" del "%BIN_DIR%\WebView2-NOTICE.txt"
if exist "%BIN_DIR%\sr_client.exe" del "%BIN_DIR%\sr_client.exe"
if exist "%BIN_DIR%\sr_client_dev.exe" del "%BIN_DIR%\sr_client_dev.exe"
if exist "%BIN_DIR%\sr_server.exe" del "%BIN_DIR%\sr_server.exe"
if exist "%BIN_DIR%\sr_tests.exe" del "%BIN_DIR%\sr_tests.exe"
echo Cleaned %BIN_DIR%\
exit /b 0

:validate_profile
for %%P in (none minimal size speed aggressive) do if "%~1"=="%%P" exit /b 0
echo Error: Unknown optimization level "%~1".
echo Levels: none, minimal, size, speed, aggressive.
exit /b 1

:bad_arguments
echo Error: Invalid target or arguments.
call :usage
exit /b 1

:usage
echo Usage: build.bat [client ^| dev ^| browser ^| server ^| tests ^| tests-vk ^| check ^| spirv] [level]
echo        build.bat all [client-level] [server-level]
echo        build.bat [check ^| clean ^| help]
echo Levels: none, minimal, size, speed, aggressive ^(default^).
echo With all, the server level defaults to the client level.
exit /b 0
