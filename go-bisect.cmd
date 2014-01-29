@echo off

call go-bisect-conf.cmd

call :testrev GOOD "%GOOD%"
if errorlevel 125 echo GOOD revision %GOOD% is not buildable (test command returned status %ERRORLEVEL%) & exit 1
if errorlevel 1 echo GOOD revision %GOOD% is not correct (test command returned status %ERRORLEVEL%) & exit 1

call :testrev BAD "%BAD%"
if errorlevel 125 echo BAD revision %BAD% is not buildable (test command returned status %ERRORLEVEL%) & exit 1
if errorlevel 1 goto badok
echo BAD revision %BAD% is not correct (test command returned status %BAD%) & exit 1
:badok

cd repo

call git bisect reset
if errorlevel 1 exit 1
call git bisect start "%BAD%" "%GOOD%"
if errorlevel 1 exit 1
call git bisect run cmd /c "%CD%\..\_bisect-run-test.cmd %TESTER%"
if errorlevel 1 exit 1

goto :eof

:testrev
echo ########## Sanity-check, testing %1 revision %2 ...
cd repo
call git checkout %2
if errorlevel 1 exit /b 1
cd ..
cmd /C _bisect-run-test.cmd %TESTER%
