@echo off
chcp 936 >nul
title 新电脑 - 5 修快捷方式
echo.
echo  ============================================================
echo    步骤 5/7：修快捷方式 + 清图标缓存
echo    旧电脑拷来的 .lnk 指向旧用户目录，全部变白块
echo  ============================================================
echo.

powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\06-new-fix-shortcuts.ps1"
