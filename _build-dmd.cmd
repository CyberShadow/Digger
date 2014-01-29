@echo off
set PATH=\dm\bin;%WINDIR%\System32;C:\Soft\Tools
set PATH=%PATH%;C:\Windows\Microsoft.NET\Framework64\v4.0.30319
call "C:\Program Files (x86)\Microsoft Visual Studio 10.0\VC\bin\vcvars32.bat"

set CONFIGURATION=Debug
if not defined CONFIGURATION set CONFIGURATION=Release

::set PLATFORM=Win32
if not defined PLATFORM set PLATFORM=x64

msbuild /p:Configuration=%CONFIGURATION% /p:Platform=%PLATFORM% dmd_msc_vs10.sln
if errorlevel 1 goto dmc

copy /y vcbuild\%PLATFORM%\%CONFIGURATION%\dmd_msc.exe dmd.exe
copy /y vcbuild\%PLATFORM%\%CONFIGURATION%\dmd_msc.pdb dmd.pdb
C:\cygwin\bin\touch dmd.exe

goto install

:dmc
:: MSVC build failed, try DMC
set PATH=\dm\bin;%WINDIR%\System32;C:\Soft\Tools

if exist dmd.exe del dmd.exe
if exist dmd.pdb del dmd.pdb
make -f win32.mak clean

make -f win32.mak
if errorlevel 1 exit 1
cv2pdb -C dmd.exe
if errorlevel 1 exit 1

:install
:: Install
copy /y dmd.exe ..\..\..\out\windows\bin
copy /y dmd.pdb ..\..\..\out\windows\bin
