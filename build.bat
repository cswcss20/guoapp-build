@echo off
setlocal
cd /d "%~dp0"

echo [1/3] Refresh Flutter packages...
call flutter pub get
if errorlevel 1 goto :fail

echo [2/3] Build native core DLL...
call python scripts\build_native.py --platform windows
if errorlevel 1 goto :fail

echo [3/3] Build Windows app...
call flutter build windows --release
if errorlevel 1 goto :fail

echo.
echo Done. Run: build\windows\x64\runner\Release\duanju_app.exe
goto :end

:fail
echo.
echo Build FAILED. Check the error above.
exit /b 1

:end
