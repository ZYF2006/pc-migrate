@echo off
chcp 936 >nul
title 新电脑 - 6 合并书签
echo.
echo  ============================================================
echo    步骤 6/7：合并浏览器书签
echo    把书签文件（.html 或 .json）追加进 Chrome/Edge/夸克
echo  ============================================================
echo.

powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\07-new-bookmarks.ps1"
