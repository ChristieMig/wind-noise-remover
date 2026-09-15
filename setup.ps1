<#
  视频降风噪工具 —— 依赖安装脚本（新机器上第一次使用时跑一次）

  本仓库只放源码。ffmpeg、DeepFilterNet、RNNoise 模型都是第三方产物（体积大、
  版权归各自项目），所以不入库，由这个脚本按固定版本/地址拉到 tools\ 下。

  依赖：Node.js（用它的 OpenSSL 下载，能绕开系统 TLS 栈故障 + 支持断点续传）
        可选：Python 3.8+（只有 Python 版主程序需要；PowerShell 版不需要）

  用法:
    powershell -ExecutionPolicy Bypass -File setup.ps1
    powershell -ExecutionPolicy Bypass -File setup.ps1 -SkipDeepFilter   # 不装 DeepFilterNet
    powershell -ExecutionPolicy Bypass -File setup.ps1 -AddToPath        # 顺便加入用户 PATH
#>
param(
    [string]$Root = $PSScriptRoot,
    [switch]$SkipFfmpeg,
    [switch]$SkipDeepFilter,
    [switch]$AddToPath
)

$ErrorActionPreference = 'Stop'
$tools = Join-Path $Root 'tools'
$fetch = Join-Path $tools 'fetch.js'

function Step($m) { Write-Host "==> $m" -ForegroundColor Cyan }
function Note($m) { Write-Host "    $m" -ForegroundColor DarkGray }
function Warn($m) { Write-Host "    $m" -ForegroundColor Yellow }

# ---------------------------------------------------------------- 前置检查
if (-not (Get-Command node -ErrorAction SilentlyContinue)) {
    Write-Host '需要 Node.js 才能下载依赖。装好 Node 后重跑本脚本。' -ForegroundColor Red
    Write-Host '（下载走 tools\fetch.js：支持断点续传、重试、GitHub 镜像回退，' -ForegroundColor Red
    Write-Host '  并会自动加载系统证书库修复证书链问题。）' -ForegroundColor Red
    exit 1
}
if (-not (Test-Path -LiteralPath $fetch)) { throw "找不到 $fetch" }

# 下载封装：失败时用 --use-system-ca 再试一次
# （system-ca.js 已在运行时修证书链；这个参数是给"仍失败"的环境兜底。
#   旧版 Node 不认识该参数会直接报错，所以只作为第二次尝试）
function Invoke-Fetch {
    param([string]$Url, [string]$Out, [switch]$Quiet)
    $nodeArgs = @($fetch, $Url, $Out)
    if ($Quiet) { & node @nodeArgs 2>$null | Out-Null } else { & node @nodeArgs }
    if ($LASTEXITCODE -eq 0) { return $true }
    Warn '第一次失败，改用 --use-system-ca 重试…'
    $nodeArgs = @('--use-system-ca') + $nodeArgs
    if ($Quiet) { & node @nodeArgs 2>$null | Out-Null } else { & node @nodeArgs }
    return ($LASTEXITCODE -eq 0)
}

# ---------------------------------------------------------------- 1. ffmpeg
if (-not $SkipFfmpeg) {
    Step '下载 ffmpeg（gyan.dev essentials 静态构建，含 arnndn/afftdn/anlmdn）'
    $zip = Join-Path $tools 'ffmpeg.zip'
    if (-not (Invoke-Fetch -Url 'https://www.gyan.dev/ffmpeg/builds/ffmpeg-release-essentials.zip' -Out $zip)) {
        throw 'ffmpeg 下载失败'
    }
    $tmp = Join-Path $tools 'ffmpeg-extract'
    Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
    Expand-Archive -Path $zip -DestinationPath $tmp -Force
    $exe = Get-ChildItem $tmp -Recurse -Filter ffmpeg.exe | Select-Object -First 1
    if (-not $exe) { throw '压缩包里没找到 ffmpeg.exe' }
    $dst = Join-Path $tools 'ffmpeg'
    Remove-Item $dst -Recurse -Force -ErrorAction SilentlyContinue
    Move-Item (Split-Path (Split-Path $exe.FullName -Parent) -Parent) $dst
    Remove-Item $zip -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
    Note ('ffmpeg -> ' + (Join-Path $dst 'bin\ffmpeg.exe'))
}

# ---------------------------------------------------------------- 2. RNNoise 模型
Step '下载 RNNoise 模型（GregorR/rnnoise-models，每个约 290KB）'
$models = Join-Path $tools 'models'
New-Item -ItemType Directory -Force -Path $models | Out-Null
$modelUrls = [ordered]@{
    'sh.rnnn' = 'https://raw.githubusercontent.com/GregorR/rnnoise-models/master/somnolent-hogwash-2018-09-01/sh.rnnn'
    'bd.rnnn' = 'https://raw.githubusercontent.com/GregorR/rnnoise-models/master/beguiling-drafter-2018-08-30/bd.rnnn'
    'lq.rnnn' = 'https://raw.githubusercontent.com/GregorR/rnnoise-models/master/leavened-quisling-2018-08-31/lq.rnnn'
    'mp.rnnn' = 'https://raw.githubusercontent.com/GregorR/rnnoise-models/master/marathon-prescription-2018-08-29/mp.rnnn'
    'cb.rnnn' = 'https://raw.githubusercontent.com/GregorR/rnnoise-models/master/conjoined-burgers-2018-08-28/cb.rnnn'
}
foreach ($k in $modelUrls.Keys) {
    $out = Join-Path $models $k
    if ((Test-Path $out) -and (Get-Item $out).Length -gt 100000) { Note "$k 已存在，跳过"; continue }
    if (Invoke-Fetch -Url $modelUrls[$k] -Out $out -Quiet) {
        Note ("{0} {1} KB" -f $k, [math]::Round((Get-Item $out).Length / 1KB))
    }
    else { Warn "$k 下载失败（rnnoise 引擎会退回 classic）" }
}

# ---------------------------------------------------------------- 3. DeepFilterNet
if (-not $SkipDeepFilter) {
    Step '下载 DeepFilterNet 0.5.6（Windows 官方 release，约 26MB）'
    $dfnDir = Join-Path $tools 'deepfilternet'
    New-Item -ItemType Directory -Force -Path $dfnDir | Out-Null
    $dfn = Join-Path $dfnDir 'deep-filter.exe'
    if ((Test-Path $dfn) -and (Get-Item $dfn).Length -gt 20000000) { Note '已存在，跳过' }
    elseif (Invoke-Fetch -Url 'https://github.com/Rikorose/DeepFilterNet/releases/download/v0.5.6/deep-filter-0.5.6-x86_64-pc-windows-msvc.exe' -Out $dfn) {
        Note ('deep-filter.exe ' + [math]::Round((Get-Item $dfn).Length / 1MB, 1) + ' MB')
    }
    else { Warn '下载失败，不影响使用：会自动退回 rnnoise / classic 引擎' }
}

# ---------------------------------------------------------------- 4. PATH
if ($AddToPath) {
    Step '把 tools 目录加入用户 PATH'
    $dirs = @((Join-Path $tools 'ffmpeg\bin'), (Join-Path $tools 'deepfilternet'))
    $old = [Environment]::GetEnvironmentVariable('Path', 'User')
    $kept = ($old -split ';' | Where-Object { $_ -and ($dirs -notcontains $_) })
    [Environment]::SetEnvironmentVariable('Path', (($dirs + $kept) -join ';'), 'User')
    Note '已写入用户 PATH（新开终端生效）'
}

# ---------------------------------------------------------------- 自检
Write-Host ''
Write-Host '安装完成，自检：' -ForegroundColor Green
$ff = Join-Path $tools 'ffmpeg\bin\ffmpeg.exe'
Note ('ffmpeg    : ' + $(if (Test-Path $ff) { (& $ff -hide_banner -version 2>&1 | Select-Object -First 1) } else { '未安装' }))
$m = Get-ChildItem (Join-Path $tools 'models\*.rnnn') -ErrorAction SilentlyContinue
Note ('RNNoise   : ' + $(if ($m) { ($m.Name -join ', ') } else { '未安装（rnnoise 引擎不可用）' }))
$d = Join-Path $tools 'deepfilternet\deep-filter.exe'
Note ('DeepFilter: ' + $(if (Test-Path $d) { '已就绪' } else { '未安装（会退回 rnnoise / classic）' }))
$py = Get-Command python -ErrorAction SilentlyContinue
Note ('Python    : ' + $(if ($py) { '可用（可选，仅 Python 版主程序需要）' } else { '未检测到（可选）' }))
Write-Host ''
Note '下一步：把视频拖到 降风噪.bat 上，或者'
Note '  powershell -ExecutionPolicy Bypass -File reduce-wind-noise.ps1 "视频.mp4"'
