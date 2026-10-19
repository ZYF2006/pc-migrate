@echo off
chcp 936 >nul
title 新电脑 - 4 补拷AppData
echo.
echo  ============================================================
echo    步骤 4/7：补拷 AppData 精选（书签/密码/软件设置）
echo    只挑真配置，自动排除缓存垃圾
echo  ============================================================
echo.

powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\05-new-appdata.ps1"
