@echo off
rem Usage: run-remote.cmd root@SERVER_IP [clients.txt] [out_dir] [native/amnezia/both]
rem Needs ssh.exe and tar.exe (built into Windows 10/11). The SSH password is asked once.
rem NOTE: keep this file ASCII-only, cmd.exe breaks on UTF-8 text.
setlocal
set "HOST=%~1"
set "LIST=%~2"
set "OUT=%~3"
set "FMT=%~4"
if "%HOST%"=="" goto usage
if "%LIST%"=="" set "LIST=clients.txt"
if "%OUT%"=="" set "OUT=awg-configs"
if "%FMT%"=="" set "FMT=native"
if /i not "%FMT%"=="native" if /i not "%FMT%"=="amnezia" if /i not "%FMT%"=="both" goto badfmt
cd /d "%~dp0"
if not exist "%LIST%" goto nolist
if not exist "%OUT%" mkdir "%OUT%"

rem Send [script + client list] to the server, run it there, receive a tar with the configs.
copy /y "%LIST%" "%TEMP%\awg-clients.txt" >nul
tar -cf - -C "%~dp0." gen-awg-configs.sh -C "%TEMP%" awg-clients.txt | ssh "%HOST%" "d=$(mktemp -d) && cd $d && tar xf - && bash gen-awg-configs.sh awg-clients.txt out %FMT% >&2; rc=$?; [ -d out ] && tar cf - -C out . ; cd /; rm -rf $d; exit $rc" > "%TEMP%\awg-out.tar"
if errorlevel 1 goto fail
tar -xf "%TEMP%\awg-out.tar" -C "%OUT%"
del "%TEMP%\awg-out.tar" "%TEMP%\awg-clients.txt"
echo Done. Configs saved to: %OUT%
exit /b 0

:usage
echo Usage: run-remote.cmd root@SERVER_IP [clients.txt] [out_dir] [native/amnezia/both]
exit /b 1
:badfmt
echo Format must be native, amnezia or both.
exit /b 1
:nolist
echo File not found: %LIST%
exit /b 1
:fail
echo Error while running on the server, see messages above.
del "%TEMP%\awg-out.tar" "%TEMP%\awg-clients.txt" 2>nul
exit /b 1
