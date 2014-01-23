@echo off

set PATH=C:\Soft\dm\bin;..\..\out\windows\bin;C:\Soft\UnxUtils\usr\local\wbin;%WINDIR%\System32
set MAKEOPTS=DOC=doc DOCSRC=../dlang.org DIR=..\..\out

set MODEL=32
set MODELSUFFIX=
call :buildmodel

set MODEL=64
set MODELSUFFIX=64
call :buildmodel

::@echo ################ DOCUMENTATION ################
::make -f win32.mak html    %MAKEOPTS% %*
::if errorlevel 1 exit

@echo ################ INSTALLATION #################

::move ..\..\out\windows\lib\phobos.lib
::move ..\..\out\windows\lib\phobos64.lib

::make -f win32.mak install %MAKEOPTS% %*
::if errorlevel 1 exit

C:\cygwin\bin\cp -r etc std crc32.d ../../out/import/phobos/

:: Cleanup

C:\cygwin\bin\rm -f etc/c/zlib/zlib.lib etc/c/zlib/zlib64.lib etc/c/zlib/*.obj phobos.json

echo Phobos OK!

goto :eof

:::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::

:buildmodel

@echo ################### %MODEL%-BIT ####################

if exist *.obj del *.obj
if exist etc\c\zlib\*.obj del etc\c\zlib\*.obj

set CONFIGNAME=RELEASE
set CONFIGSUFFIX=
set CONFIGOPTS=
call :buildconfig

set CONFIGNAME=DEBUG
set CONFIGSUFFIX=_debug
set CONFIGOPTS="DFLAGS=-m%MODEL% -g -nofloat -d" "DRUNTIMELIB=$(DRUNTIME)\lib\druntime%MODELSUFFIX%%CONFIGSUFFIX%.lib"
call :buildconfig

goto :eof

:::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::

:buildconfig

@echo ---------------- %CONFIGNAME% BUILD ----------------
if exist *.lib del *.lib
make -f win%MODEL%.mak phobos%MODELSUFFIX%.lib %MAKEOPTS% %CONFIGOPTS% %*
if not exist phobos%MODELSUFFIX%.lib exit
if exist ..\..\out\windows\lib\phobos%MODELSUFFIX%%CONFIGSUFFIX%.lib del ..\..\out\windows\lib\phobos%MODELSUFFIX%%CONFIGSUFFIX%.lib
move phobos%MODELSUFFIX%.lib ..\..\out\windows\lib\phobos%MODELSUFFIX%%CONFIGSUFFIX%.lib

goto :eof
