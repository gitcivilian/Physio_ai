@echo off
echo Cleaning Gradle cache and build directories...
cd /d "%~dp0"

REM Clean Flutter build
call flutter clean

REM Clean Gradle build
call gradlew.bat clean

REM Remove Gradle cache (optional - uncomment if needed)
REM rmdir /s /q "%USERPROFILE%\.gradle\caches"

echo.
echo Clean completed! Now try: flutter run
pause

