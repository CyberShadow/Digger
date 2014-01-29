@echo off

call _clean.cmd

mkdir out
mkdir out\windows
mkdir out\windows\bin
mkdir out\windows\lib
mkdir out\import
mkdir out\import\phobos

sed "s#OUTDIR#%CD:\=/%/out#g" < sc.ini.tpl > out/windows/bin/sc.ini

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
