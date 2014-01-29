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

make -f win%DMODEL%.mak %* lib\druntime%DMODELSUFFIX%.lib lib\gcstub%DMODELSUFFIX%.obj %MAKEOPTS%
if not exist lib\druntime%DMODELSUFFIX%.lib exit 1

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
