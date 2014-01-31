@echo off

call _clean.cmd

mkdir build
mkdir build\windows
mkdir build\windows\bin
mkdir build\windows\lib
mkdir build\import
mkdir build\import\phobos

sed "s#OUTDIR#%CD:\=/%/current#g" < sc.ini.tpl > build/windows/bin/sc.ini

cd repo

cd dmd\src
if errorlevel 1 exit /B %ERRORLEVEL%
cmd /C ..\..\..\_build-dmd.cmd
if errorlevel 1 exit /B %ERRORLEVEL%
cd ..\..

cd druntime
cmd /C ..\..\_build-druntime.cmd
if errorlevel 1 exit /B %ERRORLEVEL%
cd ..

cd phobos
cmd /C ..\..\_build-phobos.cmd
if errorlevel 1 exit /B %ERRORLEVEL%
cd ..

cd tools
cmd /C ..\..\_build-tools.cmd
if errorlevel 1 exit %ERRORLEVEL%
cd ..

echo D build complete!
