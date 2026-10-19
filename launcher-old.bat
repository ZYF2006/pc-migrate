@echo off
chcp 936 >nul
title 旧电脑 - 开启共享
echo.
echo  ============================================================
echo    旧电脑迁移准备：建共享 + 统计占用
echo    需要管理员权限，会弹出 UAC 提示，请点「是」
echo  ============================================================
echo.

net session >nul 2>&1
if %errorlevel% neq 0 (
    echo  [!] 正在申请管理员权限...
    powershell -NoProfile -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
    exit /b
)

powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\01-old-share.ps1"
