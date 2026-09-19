@echo off
rem BreakReminder Windows 版编译脚本 - 使用系统自带 .NET Framework 编译器
rem 无需安装任何环境 (Windows 10 / 11 直接可用)
setlocal
set CSC=%WINDIR%\Microsoft.NET\Framework64\v4.0.30319\csc.exe
if not exist "%CSC%" set CSC=%WINDIR%\Microsoft.NET\Framework\v4.0.30319\csc.exe
if not exist "%CSC%" (
  echo 未找到 .NET Framework 编译器, 请在 Windows 10/11 上运行本脚本
  pause
  exit /b 1
)
"%CSC%" /nologo /target:winexe /out:BreakReminder.exe /optimize+ /r:System.dll /r:System.Drawing.dll /r:System.Windows.Forms.dll Program.cs
if errorlevel 1 (
  echo.
  echo 编译失败
  pause
  exit /b 1
)
echo 编译完成: BreakReminder.exe 约 20 KB, 双击运行, 托盘出现图标
pause
