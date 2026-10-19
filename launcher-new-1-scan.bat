@echo off
chcp 936 >nul
title 新电脑 - 1 扫描旧机
echo.
echo  ============================================================
echo    步骤 1/7：连接旧电脑 + 扫描占用（只统计，不拷贝）
echo    前提：旧电脑已经跑过 launcher-old.bat
echo  ============================================================
echo.

powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\02-new-scan.ps1"
