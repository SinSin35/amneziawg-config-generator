@echo off
rem Usage: run-remote.cmd root@SERVER_IP [clients.txt] [out_dir] [native/amnezia/both] [NAME=VALUE ...]
rem Extra NAME=VALUE settings are passed to the script on the server.
rem Allowed names: SKIP_EXISTING, MTU, DNS, SERVER_IP, KEEPALIVE, CONTAINER
rem Values may contain only letters, digits and . _ : / , -   (no spaces).
rem A value with a comma must be quoted, because cmd splits arguments at commas: "DNS=1.1.1.1,1.0.0.1"
rem Example: run-remote.cmd root@1.2.3.4 clients.txt awg-configs both SKIP_EXISTING=1 MTU=1280
rem Needs ssh.exe and tar.exe (built into Windows 10/11). The SSH password is asked once.
rem NOTE: keep this file ASCII-only, cmd.exe breaks on UTF-8 text.
setlocal EnableExtensions
set "HOST=%~1"
set "LIST=%~2"
set "OUT=%~3"
set "FMT=%~4"
set "EXTRA="
if "%HOST%"=="" goto usage
if "%LIST%"=="" set "LIST=clients.txt"
if "%OUT%"=="" set "OUT=awg-configs"
if "%FMT%"=="" set "FMT=native"
if /i not "%FMT%"=="native" if /i not "%FMT%"=="amnezia" if /i not "%FMT%"=="both" goto badfmt
shift
shift
shift
shift

:parse
if "%~1"=="" goto parsed
set "TOK=%~1"
rem cmd treats = as an argument separator: NAME=VALUE may arrive as two arguments, glue them back
set TOK| findstr /r /c:"^TOK=[^=]*=" >nul
if errorlevel 1 (
  set "TOK=%~1=%~2"
  shift
)
set TOK| findstr /r /c:"^TOK=[A-Z_][A-Z_]*=[A-Za-z0-9._:/,-]*$" >nul
if errorlevel 1 goto badarg
set "NM="
for /f "tokens=1 delims==" %%a in ("%TOK%") do set "NM=%%a"
set "OKNAME="
for %%n in (SKIP_EXISTING MTU DNS SERVER_IP KEEPALIVE CONTAINER) do if /i "%NM%"=="%%n" set "OKNAME=1"
if not defined OKNAME goto badarg
set "EXTRA=%EXTRA% %TOK%"
shift
goto parse

:parsed
cd /d "%~dp0"
if not exist "%LIST%" goto nolist
if not exist "%OUT%" mkdir "%OUT%"

rem Send [script + client list] to the server, run it there, receive a tar with the configs.
copy /y "%LIST%" "%TEMP%\awg-clients.txt" >nul
tar -cf - -C "%~dp0." gen-awg-configs.sh -C "%TEMP%" awg-clients.txt | ssh "%HOST%" "d=$(mktemp -d) && cd $d && tar xf - && env%EXTRA% bash gen-awg-configs.sh awg-clients.txt out %FMT% >&2; rc=$?; [ -d out ] && tar cf - -C out . ; cd /; rm -rf $d; exit $rc" > "%TEMP%\awg-out.tar"
if errorlevel 1 goto fail
tar -xf "%TEMP%\awg-out.tar" -C "%OUT%"
del "%TEMP%\awg-out.tar" "%TEMP%\awg-clients.txt"
echo Done. Configs saved to: %OUT%
exit /b 0

:usage
echo Usage: run-remote.cmd root@SERVER_IP [clients.txt] [out_dir] [native/amnezia/both] [NAME=VALUE ...]
echo Allowed settings: SKIP_EXISTING, MTU, DNS, SERVER_IP, KEEPALIVE, CONTAINER
exit /b 1
:badfmt
echo Format must be native, amnezia or both.
exit /b 1
:badarg
echo Bad setting, see below (set TOK prints the value safely):
set TOK
echo Use NAME=VALUE with one of: SKIP_EXISTING, MTU, DNS, SERVER_IP, KEEPALIVE, CONTAINER
exit /b 1
:nolist
echo File not found: %LIST%
exit /b 1
:fail
echo Error while running on the server, see messages above.
del "%TEMP%\awg-out.tar" "%TEMP%\awg-clients.txt" 2>nul
exit /b 1
