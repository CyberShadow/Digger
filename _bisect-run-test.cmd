@echo off

echo ------------------------------- STARTING BUILD -------------------------------

cd /D %~dp0
cd repo
call git submodule update
cd ..

call build-all
if errorlevel 1 exit /B 125

set PATH=C:\Windows;C:\Windows\System32;C:\Soft\Tools
set PATH=%~dp0\out\windows\bin;%PATH%
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
