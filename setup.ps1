<#
  一键拉取依赖（新机器上第一次使用时跑一次）

  本仓库只放源码，第三方二进制和模型不入库（体积大 + 版权归各自项目），
  这个脚本按固定版本/地址把它们拉到 tools\ 下。

  前提：Node.js（脚本用 Node 自带的 OpenSSL 下载，绕开 Windows schannel 的 TLS 问题）
        ffmpeg 只用来处理音视频，装完记得让脚本能找到它。

  用法:
    powershell -ExecutionPolicy Bypass -File setup.ps1
    powershell -ExecutionPolicy Bypass -File setup.ps1 -SkipDeepFilter   # 不要 DeepFilterNet
#>
param(
    [string]$Root = $PSScriptRoot,
    [switch]$SkipFfmpeg,
    [switch]$SkipDeepFilter,
    [switch]$AddToPath
)

$ErrorActionPreference = 'Stop'
$fetch = Join-Path $Root 'tools\fetch.js'
$tools = Join-Path $Root 'tools'

function Step($m) { Write-Host "==> $m" -ForegroundColor Cyan }
function Note($m) { Write-Host "    $m" -ForegroundColor DarkGray }

if (-not (Get-Command node -ErrorAction SilentlyContinue)) {
    Write-Host '需要 Node.js 才能下载（本脚本用 Node 的 OpenSSL 访问 HTTPS）。' -ForegroundColor Red
    Write-Host '装好 Node 后重跑即可。' -ForegroundColor Red
    exit 1
}

# ---------------------------------------------------------------- 1. ffmpeg
if (-not $SkipFfmpeg) {
    Step '下载 ffmpeg（gyan.dev essentials 静态构建）'
    $zip = Join-Path $tools 'ffmpeg.zip'
    & node $fetch 'https://www.gyan.dev/ffmpeg/builds/ffmpeg-release-essentials.zip' $zip
    if ($LASTEXITCODE -ne 0) { throw 'ffmpeg 下载失败' }
    $tmp = Join-Path $tools 'ffmpeg-extract'
    Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
    Expand-Archive -Path $zip -DestinationPath $tmp -Force
    $exe = Get-ChildItem $tmp -Recurse -Filter ffmpeg.exe | Select-Object -First 1
    if (-not $exe) { throw '压缩包里没找到 ffmpeg.exe' }
    $dst = Join-Path $tools 'ffmpeg'
    Remove-Item $dst -Recurse -Force -ErrorAction SilentlyContinue
    Move-Item (Split-Path $exe.FullName -Parent | Split-Path -Parent) $dst
    Remove-Item $zip, $tmp -Recurse -Force -ErrorAction SilentlyContinue
    Note ('ffmpeg -> ' + (Join-Path $dst 'bin\ffmpeg.exe'))
}

# ---------------------------------------------------------------- 2. RNNoise 模型
Step '下载 RNNoise 模型（GregorR/rnnoise-models）'
$models = Join-Path $tools 'models'
New-Item -ItemType Directory -Force -Path $models | Out-Null
$modelUrls = @{
    'sh.rnnn' = 'https://raw.githubusercontent.com/GregorR/rnnoise-models/master/somnolent-hogwash-2018-09-01/sh.rnnn'
    'bd.rnnn' = 'https://raw.githubusercontent.com/GregorR/rnnoise-models/master/beguiling-drafter-2018-08-30/bd.rnnn'
    'lq.rnnn' = 'https://raw.githubusercontent.com/GregorR/rnnoise-models/master/leavened-quisling-2018-08-31/lq.rnnn'
    'mp.rnnn' = 'https://raw.githubusercontent.com/GregorR/rnnoise-models/master/marathon-prescription-2018-08-29/mp.rnnn'
    'cb.rnnn' = 'https://raw.githubusercontent.com/GregorR/rnnoise-models/master/conjoined-burgers-2018-08-28/cb.rnnn'
}
foreach ($k in $modelUrls.Keys) {
    $out = Join-Path $models $k
    if ((Test-Path $out) -and (Get-Item $out).Length -gt 100000) { Note "$k 已存在，跳过"; continue }
    & node $fetch $modelUrls[$k] $out | Out-Null
    Note "$k $(if (Test-Path $out) { [math]::Round((Get-Item $out).Length / 1KB) + ' KB' } else { '失败' })"
}

# ---------------------------------------------------------------- 3. DeepFilterNet
if (-not $SkipDeepFilter) {
    Step '下载 DeepFilterNet 0.5.6（Windows 官方 release，约 26MB）'
    $dfnDir = Join-Path $tools 'deepfilternet'
    New-Item -ItemType Directory -Force -Path $dfnDir | Out-Null
    $dfn = Join-Path $dfnDir 'deep-filter.exe'
    if ((Test-Path $dfn) -and (Get-Item $dfn).Length -gt 20000000) { Note '已存在，跳过' }
    else {
        & node $fetch 'https://github.com/Rikorose/DeepFilterNet/releases/download/v0.5.6/deep-filter-0.5.6-x86_64-pc-windows-msvc.exe' $dfn
        if ($LASTEXITCODE -ne 0) { Write-Host '    DeepFilterNet 下载失败（不影响：会自动退回 rnnoise/classic）' -ForegroundColor Yellow }
    }
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

Write-Host ''
Write-Host '完成。自检：' -ForegroundColor Green
$ff = Join-Path $tools 'ffmpeg\bin\ffmpeg.exe'
if (Test-Path $ff) { Note ('ffmpeg    : ' + (& $ff -hide_banner -version 2>&1 | Select-Object -First 1)) }
$m = Get-ChildItem (Join-Path $tools 'models\*.rnnn') -ErrorAction SilentlyContinue
Note ('RNNoise   : ' + $(if ($m) { ($m.Name -join ', ') } else { '无' }))
$d = Join-Path $tools 'deepfilternet\deep-filter.exe'
Note ('DeepFilter: ' + $(if (Test-Path $d) { '已就绪' } else { '无（会退回 rnnoise/classic）' }))
Write-Host ''
Note 'DeepFilterNet 需要单独跑，它的 CLI 不依赖 Python；rnnoise 引擎只需要 ffmpeg + models。'
Note 'Python 版额外需要 Python 3.8+（可选，功能与 PowerShell 版一致）。'
