@echo off

echo ------------------------------- BUILDING TOOLS -------------------------------
::if exist rdmd.exe del rdmd.exe
::dmd -g -debug rdmd.d
::call dbuildd rdmd.d
::if exist rdmd.exe copy /y rdmd.exe C:\Soft\dmd2d\windows\bin\

::if exist dman.exe del dman.exe
::dmd dman.d
::if exist dman.exe copy /y dman.exe C:\Soft\dmd2d\windows\bin\

::call dmake -f win32.mak DMD=dmd DOC=..\dlang.org PHOBOSDOC=..\dlang.org\phobos
::if errorlevel 1 exit

call dmake -f win32.mak DMD=dmd rdmd
if errorlevel 1 exit

copy /y generated\windows\32\rdmd.exe ..\..\build\windows\bin\

C:\cygwin\bin\rm -rf generated
