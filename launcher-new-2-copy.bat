@echo off
chcp 936 >nul
title 新电脑 - 2 拷贝数据
echo.
echo  ============================================================
echo    步骤 2/7：拷贝数据到中转盘
echo    已拷过的文件会自动跳过，可随时 Ctrl+C 中断后重跑
echo  ============================================================
echo.

powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\03-new-copy.ps1"
