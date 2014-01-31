@echo off

cd /D %~dp0

cd repo
for /f "usebackq tokens=*" %%a in (`git rev-parse HEAD`) do set COMMIT=%%a
set BUILDKEY=%COMMIT%-%DMODEL%
cd ..

if not exist cache\%BUILDKEY% call :build

if exist current rd current
if errorlevel 1 exit 1
mklink /J current cache\%BUILDKEY%
if errorlevel 1 exit 1

if exist current\unbuildable echo ***** Revision unbuildable, skipping & exit /B 125

set PATH=C:\Windows;C:\Windows\System32;C:\Soft\Tools
set PATH=%~dp0\current\windows\bin;%PATH%
if %DMODEL%==32 set PATH=%PATH%;\dm\bin
if %DMODEL%==64 call "C:\Program Files (x86)\Microsoft Visual Studio 10.0\VC\bin\amd64\vcvars64.bat"

set DFLAGS=
cd %~dp1
echo ################################ RUNNING TEST ################################

@echo on
@call %*
@echo off
set RESULT=%ERRORLEVEL%

echo ######################### TEST DONE WITH STATUS %RESULT% ############################

if %RESULT%==0 exit /B 0
exit /B 1
goto :eof


:build
echo ------------------------------- STARTING BUILD -------------------------------

cd /D %~dp0
cd repo
call git submodule update
cd ..

cmd /C build-all
if errorlevel 1 goto build_failed
ren build cache\%BUILDKEY%
goto :eof

:build_failed
mkdir cache\%BUILDKEY%
touch cache\%BUILDKEY%\unbuildable
goto :eof
