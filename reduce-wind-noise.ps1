<#
.SYNOPSIS
    视频降风噪（简易工具）

.DESCRIPTION
    用 ffmpeg 对视频的音轨做风噪抑制：画面直接复制（不重编码、无画质损失），
    只重新编码音频，所以速度快。

    降风噪处理链（针对风的两个特征：低频轰隆 + 宽带沙沙/噗噗声）：
      1. highpass  高通滤波，砍掉风的低频能量（风噪主要集中在 200Hz 以下）
      2. afftdn    频域降噪，tn=1 让噪声底随声音自动跟踪（风是忽大忽小的，必须跟踪）
      3. anlmdn    非局部均值降噪，压掉残留的宽带沙沙声
      4. 可选 adeclip 修复被风冲击削平的波形

.PARAMETER Path
    输入视频，可以写多个、也支持通配符。最简单的用法是把视频文件拖到 降风噪.bat 上。

.PARAMETER Preset
    强度预设：
      light   轻微风噪（室内/轻微风声）
      medium  一般风噪（默认，户外常见情况）
      strong  严重风噪（大风、风直接吹麦克风）
      voice   人声/口播优先（保留人声清晰度）
      custom  自定义，需配合 -Highpass / -NoiseReduction 使用

.PARAMETER OutDir
    输出目录，默认与源文件同目录。

.PARAMETER Suffix
    输出文件名后缀，默认 "_nowind"。写成空字符串会覆盖源文件（危险）。

.PARAMETER Container
    输出封装格式：same(跟源文件相同) / mp4 / mkv / mov，默认 same。

.PARAMETER AudioBitrate
    音频码率 kbps，默认 192。

.PARAMETER Highpass
    覆盖预设的高通频率（Hz）。风噪大就调高，一般 70~180。

.PARAMETER NoiseReduction
    覆盖预设的降噪强度（0.01~97）。调高降噪更狠，但人声可能发闷、有金属感。

.PARAMETER Engine
    降噪引擎（实测差距很大，默认 auto 自动挑最好的）：
      auto       有 DeepFilterNet 就用它，否则用 rnnoise，都没有才退回 classic
      deepfilter DeepFilterNet3（GitHub 上这类任务的 SOTA，最干净，需要 tools\deepfilternet\deep-filter.exe）
      rnnoise    RNNoise 神经网络降噪（ffmpeg 的 arnndn 滤镜 + .rnnn 模型，实测比传统滤镜强很多）
      classic    纯传统 DSP：高通 + afftdn + anlmdn，不依赖任何模型
    注意：deepfilter / rnnoise 都是"人声优先"的语音降噪器，纯音乐或无对白的素材请用 classic。

.PARAMETER RnnoiseModel
    RNNoise 模型：给模型名（如 sh / bd / lq / mp / cb，对应 tools\models\<名>.rnnn）或完整路径。
    默认 sh（实测五个模型里综合最好）。

.PARAMETER DeepFilter
    手动指定 deep-filter.exe 路径。

.PARAMETER ExtraFilters
    追加自定义 ffmpeg 滤镜，例如 "loudnorm=I=-16:TP=-1.5:LRA=11"。

.PARAMETER Declip
    先做削波修复（风的冲击常把波形削平，开了会更干净，但慢一些）。

.PARAMETER Normalize
    结尾加动态响度归一化，让音量更稳定（安静段落的风噪也会被提起来，慎用）。

.PARAMETER Force
    输出文件已存在时覆盖。默认跳过。

.PARAMETER DryRun
    只打印将要执行的 ffmpeg 命令，不真正处理。

.PARAMETER Ffmpeg
    手动指定 ffmpeg.exe 路径。

.EXAMPLE
    .\reduce-wind-noise.ps1 "D:\videos\vlog.mp4"

.EXAMPLE
    .\reduce-wind-noise.ps1 .\*.mp4 -Preset strong -OutDir .\output

.EXAMPLE
    # 多个文件直接列在后面（不要写成 -Path a.mp4 b.mp4）
    .\reduce-wind-noise.ps1 .\a.mp4 .\b.mp4 -Preset strong

.EXAMPLE
    .\reduce-wind-noise.ps1 .\a.mp4 -Preset custom -Highpass 160 -NoiseReduction 30 -Declip
#>

[CmdletBinding()]
param(
    # ValueFromRemainingArguments: 允许 -Path a.mp4 b.mp4 这样一次传多个文件
    [Parameter(Mandatory = $true, Position = 0, ValueFromRemainingArguments = $true)]
    [string[]]$Path,

    [ValidateSet('light', 'medium', 'strong', 'voice', 'custom')]
    [string]$Preset = 'medium',

    [string]$OutDir,
    [string]$Suffix = '_nowind',

    [ValidateSet('same', 'mp4', 'mkv', 'mov')]
    [string]$Container = 'same',

    [int]$AudioBitrate = 192,

    [double]$Highpass = 0,
    [double]$NoiseReduction = 0,

    [ValidateSet('auto', 'deepfilter', 'rnnoise', 'classic')]
    [string]$Engine = 'auto',
    [string]$RnnoiseModel = 'sh',
    [string]$DeepFilter,

    # 无人声素材(音乐/赛车/环境音)的两个"部分降噪"旋钮：
    #   -RnnoiseMix    0=不处理，1=完全降噪。调小可以保住内容(引擎声/音乐)只去掉一部分噪声
    #   -AttenLimit    DeepFilterNet 的衰减上限(dB)，默认 100=不限制；调小同理
    [ValidateRange(0.0, 1.0)]
    [double]$RnnoiseMix = 1.0,
    [ValidateRange(0, 100)]
    [int]$AttenLimit = 100,

    [string]$ExtraFilters = '',
    [switch]$Declip,
    [switch]$Normalize,
    [switch]$Force,
    [switch]$DryRun,

    [string]$Ffmpeg
)

$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------- 预设词
# 方便把 .bat 拖拽进来的参数写成 "视频.mp4" strong —— 把混在文件列表里的预设词挑出来
if (-not $PSBoundParameters.ContainsKey('Preset')) {
    $knownPresets = @('light', 'medium', 'strong', 'voice', 'custom')
    $picked = @()
    foreach ($p in $Path) {
        if ($p -and ($knownPresets -contains $p.ToLower())) { $picked += $p.ToLower() }
    }
    if ($picked.Count -gt 0) {
        $Preset = $picked[-1]
        $Path = @($Path | Where-Object { $_ -and ($knownPresets -notcontains $_.ToLower()) })
    }
}

# ---------------------------------------------------------------- 输出小工具
function Write-Step($msg) { Write-Host "==> $msg" -ForegroundColor Cyan }
function Write-Ok($msg) { Write-Host "    $msg" -ForegroundColor Green }
function Write-Warn2($msg) { Write-Host "    $msg" -ForegroundColor Yellow }
function Write-Err($msg) { Write-Host "    $msg" -ForegroundColor Red }

# ---------------------------------------------------------------- 找 ffmpeg
function Resolve-FfmpegPath {
    param([string]$Explicit, [string]$ScriptDir)

    $candidates = New-Object System.Collections.Generic.List[string]
    if ($Explicit) { $candidates.Add($Explicit) }
    # 1) 本工具自带的
    $candidates.Add((Join-Path $ScriptDir 'tools\ffmpeg\bin\ffmpeg.exe'))
    $candidates.Add((Join-Path $ScriptDir 'ffmpeg\bin\ffmpeg.exe'))
    # 2) PATH 里的
    $cmd = Get-Command ffmpeg -ErrorAction SilentlyContinue
    if ($cmd) { $candidates.Add($cmd.Source) }
    # 3) 系统里已知存在的（本机预装软件自带的构建）
    $candidates.Add("$env:LOCALAPPDATA\oopz\ffmpeg.exe")
    $candidates.Add("$env:ProgramFiles\ffmpeg\bin\ffmpeg.exe")
    $candidates.Add("$env:LOCALAPPDATA\Microsoft\WinGet\Links\ffmpeg.exe")
    $candidates.Add('E:\kida\JianyingPro\11.4.2.14459\ffmpeg.exe')

    foreach ($c in $candidates) {
        if ($c -and (Test-Path -LiteralPath $c -PathType Leaf)) { return (Resolve-Path -LiteralPath $c).Path }
    }
    # 4) 全盘常见目录里搜一下
    foreach ($root in @("$env:LOCALAPPDATA", "$env:ProgramFiles", 'C:\Program Files (x86)')) {
        if (Test-Path $root) {
            $hit = Get-ChildItem -LiteralPath $root -Recurse -Depth 4 -Filter 'ffmpeg.exe' -File -ErrorAction SilentlyContinue |
                Select-Object -First 1
            if ($hit) { return $hit.FullName }
        }
    }
    return $null
}

function Resolve-FfprobePath {
    param([string]$FfmpegPath, [string]$ScriptDir)
    $dir = Split-Path $FfmpegPath -Parent
    foreach ($p in @((Join-Path $dir 'ffprobe.exe'), (Join-Path $ScriptDir 'tools\ffmpeg\bin\ffprobe.exe'))) {
        if (Test-Path -LiteralPath $p -PathType Leaf) { return (Resolve-Path -LiteralPath $p).Path }
    }
    $cmd = Get-Command ffprobe -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    return $null
}

# ---------------------------------------------------------------- 找模型/引擎
# RNNoise 模型：给名字就从 tools\models 里找，给路径就直接用
function Resolve-RnnoiseModel {
    param([string]$NameOrPath, [string]$ScriptDir)
    if (-not $NameOrPath) { return $null }
    if (Test-Path -LiteralPath $NameOrPath -PathType Leaf) { return (Resolve-Path -LiteralPath $NameOrPath).Path }
    $cands = @(
        (Join-Path $ScriptDir ("tools\models\{0}.rnnn" -f $NameOrPath)),
        (Join-Path $ScriptDir ("tools\models\{0}" -f $NameOrPath)),
        (Join-Path $ScriptDir ("models\{0}.rnnn" -f $NameOrPath))
    )
    foreach ($c in $cands) { if (Test-Path -LiteralPath $c -PathType Leaf) { return (Resolve-Path -LiteralPath $c).Path } }
    return $null
}

# 把 Windows 路径转成能塞进 ffmpeg 滤镜表达式里的形式：
# 反斜杠换成正斜杠，盘符的冒号必须转义，否则会被滤镜语法当成选项分隔符
function ConvertTo-FilterPath {
    param([string]$Path)
    return ($Path.Replace('\', '/') -replace ':', '\:')
}

function Resolve-DeepFilterPath {
    param([string]$Explicit, [string]$ScriptDir)
    $cands = New-Object System.Collections.Generic.List[string]
    if ($Explicit) { $cands.Add($Explicit) }
    $cands.Add((Join-Path $ScriptDir 'tools\deepfilternet\deep-filter.exe'))
    $cands.Add((Join-Path $ScriptDir 'deep-filter.exe'))
    $cmd = Get-Command deep-filter -ErrorAction SilentlyContinue
    if ($cmd) { $cands.Add($cmd.Source) }
    foreach ($c in $cands) { if ($c -and (Test-Path -LiteralPath $c -PathType Leaf)) { return (Resolve-Path -LiteralPath $c).Path } }
    return $null
}

# ---------------------------------------------------------------- 探测输入
function Get-MediaInfo {
    param([string]$File, [string]$FfmpegPath, [string]$FfprobePath)

    $info = [ordered]@{ HasAudio = $false; Duration = 0.0; AudioCodec = ''; Channels = 0; SampleRate = 0; VideoCodec = '' }

    if ($FfprobePath) {
        $prev = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
        try {
            $json = & $FfprobePath -v quiet -print_format json -show_format -show_streams -- $File 2>$null | Out-String
            $obj = $json | ConvertFrom-Json
            if ($obj.format.duration) { $info.Duration = [double]$obj.format.duration }
            $a = $obj.streams | Where-Object { $_.codec_type -eq 'audio' } | Select-Object -First 1
            $v = $obj.streams | Where-Object { $_.codec_type -eq 'video' } | Select-Object -First 1
            if ($a) {
                $info.HasAudio = $true
                $info.AudioCodec = $a.codec_name
                $info.Channels = [int]$a.channels
                $info.SampleRate = [int]$a.sample_rate
            }
            if ($v) { $info.VideoCodec = $v.codec_name }
        }
        catch { }
        finally { $ErrorActionPreference = $prev }
        if ($info.HasAudio -or $info.Duration -gt 0) { return $info }
    }

    # 没有 ffprobe 就解析 ffmpeg -i 的输出
    $prev = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    try {
        $text = (& $FfmpegPath -hide_banner -i $File 2>&1 | Out-String)
        if ($text -match 'Duration:\s*(\d+):(\d+):(\d+\.\d+)') {
            $info.Duration = [double]$matches[1] * 3600 + [double]$matches[2] * 60 + [double]$matches[3]
        }
        if ($text -match 'Stream #\d+:\d+.*?: Audio: ([a-zA-Z0-9_]+).*?(\d+) Hz, ([a-z0-9(). ]+?)[,\s]') {
            $info.HasAudio = $true
            $info.AudioCodec = $matches[1]
            $info.SampleRate = [int]$matches[2]
            $lay = $matches[3]
            $info.Channels = switch -Regex ($lay) {
                'mono' { 1; break }
                'stereo' { 2; break }
                '5\.1' { 6; break }
                '7\.1' { 8; break }
                default { 2 }
            }
        }
    }
    catch { }
    finally { $ErrorActionPreference = $prev }
    return $info
}

# ---------------------------------------------------------------- 削波检测
# 风把麦克风推过载时波形会被削平，这种素材加 -Declip 会明显更干净。
# 注意：视频音轨通常是 AAC，解码会把削波平顶抹掉（flat factor 变 0），
# 所以不能只看 flat factor，主要靠"峰值贴顶 + 波峰因数过小"判断（电平被压得很死）。
# 只看前 30 秒，够判断了，也不拖慢长视频。
function Test-Clipping {
    param([string]$File, [string]$FfmpegPath, [int]$Seconds = 30)
    $prev = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    try {
        $o = & $FfmpegPath -hide_banner -nostdin -t $Seconds -i $File -vn -af 'astats=measure_perchannel=none' -f null - 2>&1 | Out-String
    }
    finally { $ErrorActionPreference = $prev }
    $peak = $null; $rms = $null; $flat = $null
    if ($o -match 'Peak level dB:\s*([-\d.]+)') { $peak = [double]$matches[1] }
    if ($o -match 'RMS level dB:\s*([-\d.]+)') { $rms = [double]$matches[1] }
    if ($o -match 'Flat factor:\s*([-\d.]+)') { $flat = [double]$matches[1] }
    if ($null -eq $peak -or $null -eq $rms) { return [pscustomobject]@{ Clipped = $false; Peak = $peak; Flat = $flat; Crest = $null } }
    $crest = $peak - $rms
    # 判据：波形有平顶(flat factor 大 且 峰值贴顶)，或 峰值贴顶且动态被压死(波峰因数 < 12dB)
    # 视频音轨一般是 AAC，解码会把平顶抹掉，所以主要靠第二条
    $clipped = (($null -ne $flat) -and ($flat -gt 1.0) -and ($peak -gt -1.0)) -or (($peak -gt -1.0) -and ($crest -lt 12.0))
    return [pscustomobject]@{ Clipped = $clipped; Peak = $peak; Flat = $flat; Crest = $crest }
}

# ---------------------------------------------------------------- 滤镜链
function Get-WindNoiseFilter {
    param(
        [string]$Preset, [double]$HighpassOverride, [double]$NoiseReductionOverride,
        [switch]$Declip, [switch]$Normalize, [string]$Extra,
        [string]$Engine = 'classic', [string]$ModelPath, [double]$Mix = 1.0
    )

    # 预设参数：高通频率 / 降噪量 / 噪声底 / 增益平滑 / 低通 / anlmdn 参数
    # 高通级联两级(24dB/oct)：风噪集中在低频，滚降越陡，"轰隆"下去得越干净，而人声几乎不受影响
    $hp = 0.0; $nr = 0.0; $nf = -50.0; $gs = 0; $lp = 0.0; $anlmdn = ''
    switch ($Preset) {
        'light' { $hp = 80;  $nr = 10; $nf = -55; $gs = 0; $anlmdn = '' }
        'medium' { $hp = 120; $nr = 16; $nf = -50; $gs = 4; $anlmdn = 's=0.0002:p=0.002:r=0.006:m=11' }
        'strong' { $hp = 150; $nr = 24; $nf = -45; $gs = 8; $lp = 15000; $anlmdn = 's=0.0006:p=0.002:r=0.006:m=13' }
        'voice' { $hp = 90;  $nr = 18; $nf = -50; $gs = 6; $anlmdn = 's=0.0004:p=0.002:r=0.008:m=13' }
        'custom' { $hp = 120; $nr = 16; $nf = -50; $gs = 4 }
    }

    # RNNoise 是"人声优先"的模型：它会自己压制大部分噪声，所以不需要再叠那么狠的传统降噪
    if ($Engine -eq 'rnnoise') {
        switch ($Preset) {
            'light' { $hp = 60;  $anlmdn = '' }
            'medium' { $hp = 80;  $anlmdn = '' }
            'strong' { $hp = 100; $anlmdn = ''; $lp = 0 }
            'voice' { $hp = 60;  $anlmdn = '' }
            'custom' { $hp = 80 }
        }
    }

    if ($HighpassOverride -gt 0) { $hp = $HighpassOverride }
    if ($NoiseReductionOverride -gt 0) { $nr = $NoiseReductionOverride }

    $chain = New-Object System.Collections.Generic.List[string]

    # 0) 削波修复（风冲击麦克风常把波形削平，先修掉，后面降噪才不会把削波当噪声放大）
    if ($Declip) { $chain.Add('adeclip') }

    # 1) 高通：风噪的能量几乎都在低频，两级级联 = 24dB/oct，这一步对"轰隆隆"最有效
    if ($hp -gt 0) {
        $chain.Add(('highpass=f={0}:poles=2' -f [int]$hp))
        $chain.Add(('highpass=f={0}:poles=2' -f [int]$hp))
    }

    # 2) 核心降噪
    if ($Engine -eq 'rnnoise') {
        # RNNoise（arnndn 滤镜）：模型路径里的冒号必须转义，否则会被滤镜语法当成选项分隔符
        # mix<1 时输出是"原声 + 降噪声"的混合，用于无人声素材保住内容
        $rnArg = ("arnndn=model='{0}'" -f (ConvertTo-FilterPath $ModelPath))
        if ($Mix -lt 1.0) { $rnArg += ('{0}mix={1}' -f ':', $Mix) }
        $chain.Add($rnArg)
    }
    else {
        # 频域降噪：tn=1 自动跟踪噪声底，应对忽大忽小的风
        $chain.Add(('afftdn=nr={0}:nf={1}:tn=1:gs={2}' -f $nr, $nf, $gs))
    }

    # 3) 非局部均值降噪：压掉宽带"沙沙/噗噗"残留
    if ($anlmdn) { $chain.Add("anlmdn=$anlmdn") }

    # 4) 低通：顺手削掉一点高频嘶声
    if ($lp -gt 0) { $chain.Add(('lowpass=f={0}' -f [int]$lp)) }

    # 5) 可选：响度归一化
    if ($Normalize) { $chain.Add('dynaudnorm=f=250:g=5:p=0.9') }

    # 6) 用户自定义追加
    if ($Extra) { $chain.Add($Extra.Trim(',')) }

    return ($chain -join ',')
}

# ---------------------------------------------------------------- 主流程
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path

$ffmpegPath = Resolve-FfmpegPath -Explicit $Ffmpeg -ScriptDir $ScriptDir
if (-not $ffmpegPath) {
    Write-Err ' 找不到 ffmpeg.exe。'
    Write-Host '   解决办法（任选一个）：' -ForegroundColor Yellow
    Write-Host '     1) 把 ffmpeg.exe 放到 tools\ffmpeg\bin\ 下（和本脚本同一目录的 tools 文件夹）'
    Write-Host '     2) 用参数指定：-Ffmpeg "C:\path\to\ffmpeg.exe"'
    Write-Host '     3) 安装后加入 PATH：winget install Gyan.FFmpeg'
    exit 1
}
$ffprobePath = Resolve-FfprobePath -FfmpegPath $ffmpegPath -ScriptDir $ScriptDir

# 展开输入（支持通配符；也兼容 -Path "a.mp4,b.mp4" 这种逗号写法）
$rawInputs = New-Object System.Collections.Generic.List[string]
foreach ($p in $Path) {
    if ((Test-Path -LiteralPath $p -PathType Leaf) -or ($p -notmatch ',')) {
        $rawInputs.Add($p)
    }
    else {
        foreach ($piece in ($p -split ',')) {
            $t = $piece.Trim().Trim('"')
            if ($t) { $rawInputs.Add($t) }
        }
    }
}

$files = New-Object System.Collections.Generic.List[string]
foreach ($p in $rawInputs) {
    if (Test-Path -LiteralPath $p -PathType Leaf) {
        $files.Add((Resolve-Path -LiteralPath $p).Path)
    }
    else {
        $expanded = Get-ChildItem -Path $p -File -ErrorAction SilentlyContinue
        if ($expanded) { foreach ($f in $expanded) { $files.Add($f.FullName) } }
        else { Write-Err "跳过（找不到文件）：$p" }
    }
}
if ($files.Count -eq 0) { Write-Err '没有可处理的视频文件。'; exit 1 }

# ---------------------------------------------------------------- 选引擎
$modelPath = Resolve-RnnoiseModel -NameOrPath $RnnoiseModel -ScriptDir $ScriptDir
$deepFilterPath = Resolve-DeepFilterPath -Explicit $DeepFilter -ScriptDir $ScriptDir

$engineUsed = $Engine
switch ($Engine) {
    'auto' {
        if ($deepFilterPath) { $engineUsed = 'deepfilter' }
        elseif ($modelPath) { $engineUsed = 'rnnoise' }
        else { $engineUsed = 'classic' }
    }
    'deepfilter' {
        if (-not $deepFilterPath) {
            Write-Warn2 '找不到 deep-filter.exe，退回 rnnoise/classic。'
            $engineUsed = if ($modelPath) { 'rnnoise' } else { 'classic' }
        }
    }
    'rnnoise' {
        if (-not $modelPath) {
            Write-Warn2 ("找不到 RNNoise 模型 '{0}'，退回 classic。" -f $RnnoiseModel)
            $engineUsed = 'classic'
        }
    }
}

$filter = Get-WindNoiseFilter -Preset $Preset -HighpassOverride $Highpass -NoiseReductionOverride $NoiseReduction `
    -Declip:$Declip -Normalize:$Normalize -Extra $ExtraFilters `
    -Engine $engineUsed -ModelPath $modelPath -Mix $RnnoiseMix

# DeepFilterNet 需要单独的程序处理，这里只用 ffmpeg 链做"前置处理"（削波修复 + 高通）
$dfnPreFilter = ''
if ($engineUsed -eq 'deepfilter') {
    $pre = New-Object System.Collections.Generic.List[string]
    if ($Declip) { $pre.Add('adeclip') }
    $hpf = switch ($Preset) {
        'light' { 60 } 'medium' { 80 } 'strong' { 100 } 'voice' { 60 } 'custom' { 80 }
    }
    if ($Highpass -gt 0) { $hpf = [int]$Highpass }
    if ($hpf -gt 0) {
        $pre.Add(('highpass=f={0}:poles=2' -f $hpf))
        $pre.Add(('highpass=f={0}:poles=2' -f $hpf))
    }
    if ($Normalize) { $pre.Add('dynaudnorm=f=250:g=5:p=0.9') }
    if ($ExtraFilters) { $pre.Add($ExtraFilters.Trim(',')) }
    $dfnPreFilter = ($pre -join ',')
}

Write-Host ''
Write-Host '视频降风噪' -ForegroundColor White
Write-Host ("  ffmpeg : {0}" -f $ffmpegPath) -ForegroundColor DarkGray
Write-Host ("  预设   : {0}" -f $Preset) -ForegroundColor DarkGray
Write-Host ("  引擎   : {0}{1}" -f $engineUsed, $(if ($engineUsed -ne $Engine) { " (请求 $Engine)" } else { '' })) -ForegroundColor DarkGray
if ($engineUsed -eq 'rnnoise') { Write-Host ("  模型   : {0}" -f $modelPath) -ForegroundColor DarkGray }
if ($engineUsed -eq 'deepfilter') { Write-Host ("  DFN    : {0}" -f $deepFilterPath) -ForegroundColor DarkGray }
if ($engineUsed -eq 'deepfilter') {
    Write-Host ("  前置   : {0}" -f $(if ($dfnPreFilter) { $dfnPreFilter } else { '(无)' })) -ForegroundColor DarkGray
}
else {
    Write-Host ("  滤镜   : {0}" -f $filter) -ForegroundColor DarkGray
}
Write-Host ("  待处理 : {0} 个文件" -f $files.Count) -ForegroundColor DarkGray
Write-Host ''

$tmpDir = Join-Path $ScriptDir 'tools\tmp'
if (-not (Test-Path -LiteralPath $tmpDir)) { New-Item -ItemType Directory -Force -Path $tmpDir | Out-Null }

$okCount = 0; $failCount = 0; $skipCount = 0; $dryCount = 0
$total = $files.Count; $index = 0

foreach ($inFile in $files) {
    $index++
    $name = Split-Path $inFile -Leaf
    Write-Step "[$index/$total] $name"

    $info = Get-MediaInfo -File $inFile -FfmpegPath $ffmpegPath -FfprobePath $ffprobePath
    if (-not $info.HasAudio) {
        Write-Err '这个文件没有音轨，跳过。'
        $failCount++; continue
    }

    # 输出路径
    $ext = switch ($Container) {
        'same' { [System.IO.Path]::GetExtension($inFile).TrimStart('.') }
        default { $Container }
    }
    if ([string]::IsNullOrWhiteSpace($ext)) { $ext = 'mp4' }

    $dir = if ($OutDir) {
        if (-not (Test-Path -LiteralPath $OutDir)) { New-Item -ItemType Directory -Force -Path $OutDir | Out-Null }
        (Resolve-Path -LiteralPath $OutDir).Path
    }
    else { Split-Path $inFile -Parent }

    $base = [System.IO.Path]::GetFileNameWithoutExtension($inFile)
    $outFile = Join-Path $dir ("{0}{1}.{2}" -f $base, $Suffix, $ext)

    if ((Test-Path -LiteralPath $outFile) -and -not $Force) {
        Write-Warn2 ("已存在，跳过（加 -Force 可覆盖）：{0}" -f (Split-Path $outFile -Leaf))
        $skipCount++; continue
    }
    if ($outFile -eq $inFile) {
        Write-Err '输出会和输入同名，请改 -Suffix 或 -OutDir。'
        $failCount++; continue
    }

    Write-Host ("    音轨 {0} / {1}Hz / {2}声道，时长 {3:mm\:ss}" -f $info.AudioCodec, $info.SampleRate, $info.Channels, [TimeSpan]::FromSeconds($info.Duration)) -ForegroundColor DarkGray

    if (-not $Declip) {
        $clip = Test-Clipping -File $inFile -FfmpegPath $ffmpegPath
        if ($clip.Clipped) {
            Write-Warn2 ("输入电平已贴顶且动态很小（峰值 {0:N2}dB，波峰因数 {1:N1}dB），很可能过载削波，建议加 -Declip。" -f $clip.Peak, $clip.Crest)
        }
    }

    $ffArgs = @(
        '-hide_banner', '-nostdin', '-loglevel', 'warning', '-stats', '-y',
        '-i', $inFile,
        '-map', '0:v?', '-map', '0:a:0',
        '-c:v', 'copy',
        '-af', $filter,
        '-c:a', 'aac', '-b:a', ("{0}k" -f $AudioBitrate),
        '-map_metadata', '0'
    )
    # 字幕：mkv 能装各种字幕，mp4/mov 就不带了，免得封装报错
    if ($ext -eq 'mkv') { $ffArgs += @('-map', '0:s?', '-c:s', 'copy') }
    if ($ext -in @('mp4', 'mov')) { $ffArgs += @('-movflags', '+faststart') }
    $ffArgs += $outFile

    if ($DryRun) {
        if ($engineUsed -eq 'deepfilter') {
            $ch = if ($info.Channels -gt 0) { $info.Channels } else { 2 }
            $preTxt = if ($dfnPreFilter) { $dfnPreFilter } else { '(无)' }
            Write-Host ('    [DryRun] 1) 抽音频+前置: ' + $ffmpegPath + ' -i "' + $inFile + '" -vn -ar 48000 -ac ' + $ch + $(if ($dfnPreFilter) { ' -af "' + $dfnPreFilter + '"' } else { '' }) + ' <临时.wav>') -ForegroundColor DarkYellow
            Write-Host ('    [DryRun] 2) 神经网络降噪: ' + $deepFilterPath + ' -D -o <临时目录> <临时.wav>') -ForegroundColor DarkYellow
            Write-Host ('    [DryRun] 3) 合回视频: ' + $ffmpegPath + ' -i "' + $inFile + '" -i <降噪后.wav> -map 0:v? -map 1:a:0 -c:v copy -c:a aac -b:a ' + $AudioBitrate + 'k ' + ('"' + $outFile + '"')) -ForegroundColor DarkYellow
        }
        else {
            Write-Host ('    [DryRun] ' + $ffmpegPath + ' ' + (($ffArgs | ForEach-Object { if ($_ -match '\s') { '"' + $_ + '"' } else { $_ } }) -join ' ')) -ForegroundColor DarkYellow
        }
        $dryCount++
        continue
    }

    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $prev = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    $code = 1
    try {
        if ($engineUsed -eq 'deepfilter') {
            # ---- DeepFilterNet：只吃音频，所以先抽出来，处理完再合回视频 ----
            $preWav = Join-Path $tmpDir ('dfn_in_{0}.wav' -f [guid]::NewGuid().ToString('N'))
            $dfnDir = Join-Path $tmpDir ('dfn_{0}' -f [guid]::NewGuid().ToString('N'))
            New-Item -ItemType Directory -Force -Path $dfnDir | Out-Null
            $ch = if ($info.Channels -gt 0) { $info.Channels } else { 2 }
            # DeepFilterNet 只处理单/双声道，多声道先降到立体声（否则它会报错）
            if ($ch -gt 2) {
                Write-Warn2 ("音源是 {0} 声道，DeepFilterNet 只支持单/双声道，已降为立体声。" -f $ch)
                $ch = 2
            }

            # 1) 抽音频 + 前置处理（削波修复/高通），DFN 固定吃 48kHz
            $preArgs = @('-hide_banner', '-nostdin', '-loglevel', 'warning', '-y', '-i', $inFile, '-vn', '-ar', '48000', '-ac', "$ch")
            if ($dfnPreFilter) { $preArgs += @('-af', $dfnPreFilter) }
            $preArgs += @('-c:a', 'pcm_s16le', $preWav)
            & $ffmpegPath @preArgs
            $code = $LASTEXITCODE

            # 2) DeepFilterNet（-D 补偿 STFT/模型前瞻带来的延迟，保证音画同步）
            $enh = $null
            if ($code -eq 0) {
                $dfnArgs = @('-D', '-o', $dfnDir)
                # -a 限制最大衰减量(dB)：无人声素材调小可保住内容
                if ($AttenLimit -lt 100) { $dfnArgs += @('-a', "$AttenLimit") }
                $dfnArgs += $preWav
                & $deepFilterPath @dfnArgs
                $code = $LASTEXITCODE
                $enh = Get-ChildItem -LiteralPath $dfnDir -Filter '*.wav' -ErrorAction SilentlyContinue | Select-Object -First 1
                if (-not $enh) { $code = 1 }
            }

            # 3) 合回视频（画面依旧直接复制）
            if ($code -eq 0) {
                $muxArgs = @(
                    '-hide_banner', '-nostdin', '-loglevel', 'warning', '-stats', '-y',
                    '-i', $inFile, '-i', $enh.FullName,
                    '-map', '0:v?', '-map', '1:a:0',
                    '-c:v', 'copy',
                    '-c:a', 'aac', '-b:a', ("{0}k" -f $AudioBitrate),
                    '-map_metadata', '0'
                )
                if ($ext -eq 'mkv') { $muxArgs += @('-map', '0:s?', '-c:s', 'copy') }
                if ($ext -in @('mp4', 'mov')) { $muxArgs += @('-movflags', '+faststart') }
                $muxArgs += $outFile
                & $ffmpegPath @muxArgs
                $code = $LASTEXITCODE
            }

            Remove-Item -LiteralPath $preWav -Force -ErrorAction SilentlyContinue
            Remove-Item -LiteralPath $dfnDir -Recurse -Force -ErrorAction SilentlyContinue
        }
        else {
            & $ffmpegPath @ffArgs
            $code = $LASTEXITCODE
        }
    }
    finally { $ErrorActionPreference = $prev }
    $sw.Stop()

    if ($code -eq 0 -and (Test-Path -LiteralPath $outFile)) {
        $okCount++
        $inMB = (Get-Item -LiteralPath $inFile).Length / 1MB
        $outMB = (Get-Item -LiteralPath $outFile).Length / 1MB
        Write-Ok ("完成 -> {0}" -f $outFile)
        Write-Host ("    {0:N1}MB -> {1:N1}MB，耗时 {2:N1}s" -f $inMB, $outMB, $sw.Elapsed.TotalSeconds) -ForegroundColor DarkGray
    }
    else {
        $failCount++
        Write-Err ("{0} 处理失败（退出码 {1}）" -f $engineUsed, $code)
    }
}

Write-Host ''
if ($okCount) { Write-Host ("成功 {0} 个" -f $okCount) -ForegroundColor Green }
if ($skipCount) { Write-Host ("跳过 {0} 个（已存在）" -f $skipCount) -ForegroundColor Yellow }
if ($dryCount) { Write-Host ("预演 {0} 个（未实际处理）" -f $dryCount) -ForegroundColor Yellow }
if ($failCount) { Write-Host ("失败 {0} 个" -f $failCount) -ForegroundColor Red }
if ($okCount -eq 0 -and $skipCount -eq 0 -and $dryCount -eq 0) { exit 1 }
exit 0
