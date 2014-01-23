@echo off

if "%BRANCH%"=="" set BRANCH=master

if exist import rmdir /S /Q import
mkdir import
::call git checkout import

set PATH=C:\Soft\dm\bin;..\..\out\windows\bin;%WINDIR%\System32
set MAKEOPTS=

if exist doc rmdir /S /Q doc
::if exist import\core rmdir /S /Q import\core
if exist lib rmdir /S /Q lib
del *.obj

make -f win32.mak %* lib\druntime.lib lib\gcstub.obj                                                                                  %MAKEOPTS%
if not exist lib\druntime.lib exit 1

make -f win32.mak %* lib\druntime_debug.lib   "DFLAGS=-m32 -g -nofloat -w -d -Isrc -Iimport -property" DRUNTIME_BASE=druntime_debug   %MAKEOPTS%
if not exist lib\druntime_debug.lib exit 1

del *.obj
make -f win64.mak %* lib\druntime64.lib lib\gcstub64.obj                                                                              %MAKEOPTS%
if not exist lib\druntime64.lib exit 1

make -f win64.mak %* lib\druntime64_debug.lib "DFLAGS=-m64 -g -nofloat -w -d -Isrc -Iimport -property" DRUNTIME_BASE=druntime64_debug %MAKEOPTS%
if not exist lib\druntime64_debug.lib exit 1

make -f win32.mak %* import
if errorlevel 1 exit 1
if %BRANCH%==master make -f win32.mak %* copydir copy
if errorlevel 1 exit 1

::if exist lib\* copy /y lib\* ..\..\out\windows\lib\
rmdir /S /Q ..\..\out\import\druntime
mkdir ..\..\out\import\druntime
xcopy /Q /E /I /Y import ..\..\out\import\druntime

:: Cleanup

C:\cygwin\bin\rm -f errno_c.obj vc100.pdb

echo Druntime OK!
