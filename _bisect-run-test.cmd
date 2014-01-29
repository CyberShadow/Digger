@echo off

echo ------------------------------- STARTING BUILD -------------------------------

cd /D %~dp0
cd repo
call git submodule update
cd ..

call build-all
if errorlevel 1 exit /B 125

set PATH=C:\Windows;C:\Windows\System32;C:\Soft\Tools
set PATH=%~dp0\out\windows\bin;\dm\bin;%PATH%
set DFLAGS=
cd %~dp1
echo ################################ RUNNING TEST ################################

@echo on
@call %*
@echo off
set RESULT=%ERRORLEVEL%

echo ######################### TEST DONE WITH STATUS %RESULT% ############################

exit /b %RESULT%
