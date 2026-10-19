@echo off
chcp 936 >nul
title 新电脑 - 7 清理垃圾
echo.
echo  ============================================================
echo    步骤 7/7：清理迁移垃圾（默认只报告，不删除）
echo    看完报告后加 -Apply 才真正删除
echo  ============================================================
echo.

powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\08-new-cleanup.ps1"
