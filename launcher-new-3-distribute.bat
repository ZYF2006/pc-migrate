@echo off
chcp 936 >nul
title 新电脑 - 3 分发数据
echo.
echo  ============================================================
echo    步骤 3/7：把中转盘的数据分发到真正能用的位置
echo    会拷到 桌面 / 文档 / 下载 / 用户目录 等
echo  ============================================================
echo.

powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\04-new-distribute.ps1"
