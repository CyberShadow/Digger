:: Known bad (with regression) and good (w/o regression) commits
set BAD=c0d8903f374677d4b8e8f943b9fff411dc1adccf
set GOOD=a1bb3a9b7467ab3d629787c474506fca7fa14f74

:: Tester program.
:: _bisect-tester-compiles.bat is a helper that
:: will attempt to compile the given program.
set TESTER=%~dp0\_bisect-tester-compiles.bat -o- C:\Temp\test.d
