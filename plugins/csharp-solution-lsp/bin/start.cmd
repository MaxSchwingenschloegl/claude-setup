@echo off
rem Starts csharp-ls with one solution of the project root (%1, else the current folder), so
rem it never loads one from a worktree or a subfolder: the solution named on the first line of
rem .claude\csharp-ls-solution (a path relative to the root), else the only .sln or .slnx in the
rem root. A named solution that does not exist (a typo, a trailing space, a byte-order mark) is
rem reported and the root is searched instead; with no single solution csharp-ls starts without
rem --solution and the reason goes to stderr. A folder it cannot enter stops it: started
rem elsewhere it would pick a solution at random again. Paths stay out of ( ) blocks, where a
rem ")" in them would end the block. A double quote in the first line of the file stops the
rem script (cmd cannot take it apart); no solution name holds one.
setlocal
set "ROOT=%~1"
if not defined ROOT set "ROOT=%CD%"
cd /d "%ROOT%" || goto noroot
set "SLN="
if exist ".claude\csharp-ls-solution" set /p SLN=<".claude\csharp-ls-solution"
rem Trailing spaces pass the exist check (Windows ignores them) but not csharp-ls
:trim
if not defined SLN goto detect
if "%SLN:~-1%"==" " set "SLN=%SLN:~0,-1%"& goto trim
if exist "%SLN%" goto run
echo csharp-solution-lsp: the solution named in .claude\csharp-ls-solution does not exist (a typo, a trailing space or a byte-order mark?), looking in the project root instead 1>&2
set "SLN="
:detect
set COUNT=0
rem *.sln* also matches .sln.bak and, with 8.3 names, a .slnx twice under *.sln: count by the
rem extension. The name stays a loop variable, which cmd does not parse again (a call would).
for %%F in (*.sln*) do if /i "%%~xF"==".sln" (set /a COUNT+=1 & set "SLN=%%~nxF") else if /i "%%~xF"==".slnx" (set /a COUNT+=1 & set "SLN=%%~nxF")
if "%COUNT%"=="1" goto run
echo csharp-solution-lsp: %COUNT% solutions in the project root and no usable .claude\csharp-ls-solution, starting without --solution 1>&2
set "SLN="
:run
if defined SLN goto withsolution
csharp-ls
exit /b %errorlevel%
:withsolution
csharp-ls --solution "%SLN%"
exit /b %errorlevel%

:noroot
echo csharp-solution-lsp: cannot enter the project folder "%ROOT%", not starting csharp-ls 1>&2
exit /b 1
