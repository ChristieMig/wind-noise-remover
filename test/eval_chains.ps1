<#
  降风噪方案对比评测

  做法：对同一批测试信号分别跑不同的降噪链，测量各频段平均电平的变化。
  因为"风噪"和"人声"在频段上是分开的，所以不看主观听感也能客观比较：
    - 噪声信号(只含噪声)  处理前后 → 各频段残留多少  = 压制能力
    - 干净语音(只含人声)  处理前后 → 各频段掉了多少  = 人声保真
    - 混合信号            处理前后 → 综合效果

  用法: powershell -ExecutionPolicy Bypass -File eval_chains.ps1 [-Force]
#>
param(
    [string]$Root = 'E:\kida\code',
    [switch]$Force
)

$ff = Join-Path $Root 'tools\ffmpeg\bin\ffmpeg.exe'
$modelDir = (Join-Path $Root 'tools\models').Replace('\', '/')
$modelDirEsc = $modelDir -replace ':', '\:'
$inDir = Join-Path $Root 'test\eval_in'
$outRoot = Join-Path $Root 'test\eval_out'
$csv = Join-Path $Root 'test\eval_results.csv'

New-Item -ItemType Directory -Force -Path $inDir, $outRoot | Out-Null

function RN($name) { "arnndn=model='$modelDirEsc/$name.rnnn'" }

# ---------------------------------------------------------------- 候选降噪链
$chains = [ordered]@{
    'A_现方案-medium'   = 'highpass=f=120:poles=2,highpass=f=120:poles=2,afftdn=nr=16:nf=-50:tn=1:gs=4,anlmdn=s=0.0002:p=0.002:r=0.006:m=11'
    'B_只高通+afftdn'   = 'highpass=f=120:poles=2,highpass=f=120:poles=2,afftdn=nr=16:nf=-50:tn=1:gs=4'
    'C_rnnoise-sh'      = (RN 'sh')
    'D_rnnoise-mp'      = (RN 'mp')
    'E_rnnoise-cb'      = (RN 'cb')
    'F_rnnoise-bd'      = (RN 'bd')
    'G_rnnoise-lq'      = (RN 'lq')
    'H_高通90+rnnoise-sh' = "highpass=f=90:poles=2,highpass=f=90:poles=2," + (RN 'sh')
    'I_高通90+rnnoise-mp' = "highpass=f=90:poles=2,highpass=f=90:poles=2," + (RN 'mp')
    'J_高通+afftdn+rnnoise' = "highpass=f=90:poles=2,highpass=f=90:poles=2,afftdn=nr=12:nf=-50:tn=1:gs=4," + (RN 'sh')
    'K_rnnoise-sh+anlmdn' = (RN 'sh') + ',anlmdn=s=0.0003:p=0.002:r=0.006:m=11'
}

# ---------------------------------------------------------------- 测试信号
function New-TestSignals {
    $t = $inDir
    $src = Join-Path $Root 'test\素材'
    & $ff -hide_banner -loglevel error -y -i (Join-Path $src 'clean_speech.wav') -ac 1 -ar 48000 -c:a pcm_s16le (Join-Path $t 'clean.wav')
    & $ff -hide_banner -loglevel error -y -stream_loop -1 -i (Join-Path $src 'noise_b.wav') -t 10.6 -ac 1 -ar 48000 -c:a pcm_s16le (Join-Path $t 'noise_low.wav')
    & $ff -hide_banner -loglevel error -y -stream_loop -1 -i (Join-Path $src 'noise_a.wav') -t 10.6 -ac 1 -ar 48000 -c:a pcm_s16le (Join-Path $t 'noise_wide.wav')
    & $ff -hide_banner -loglevel error -y -f lavfi -i "anoisesrc=color=brown:sample_rate=48000:amplitude=0.9:duration=10.6" -af "lowpass=f=350,volume='0.35+0.35*sin(2*PI*t/2.5)':eval=frame,pan=mono|c0=c0" -c:a pcm_s16le (Join-Path $t 'noise_gust.wav')

    # 按 +3dB / 0dB 信噪比混合（用 astats 量 RMS 再算增益，避免手工估算）
    function Get-Rms($file) {
        $o = & $ff -hide_banner -nostdin -i $file -vn -af 'astats=measure_perchannel=none:measure_overall=RMS_level' -f null - 2>&1 | Out-String
        if ($o -match 'RMS level dB:\s*([-\d.]+)') { [double]$matches[1] } else { [double]::NaN }
    }
    $rc = Get-Rms (Join-Path $t 'clean.wav')
    foreach ($n in @('noise_low', 'noise_wide', 'noise_gust')) {
        $rn = Get-Rms (Join-Path $t "$n.wav")
        foreach ($snr in @(3, 0)) {
            $gain = $rc - $snr - $rn
            & $ff -hide_banner -loglevel error -y -i (Join-Path $t 'clean.wav') -i (Join-Path $t "$n.wav") `
                -filter_complex "[1:a]volume=${gain}dB[n];[0:a][n]amix=inputs=2:duration=first:normalize=0[m]" `
                -map '[m]' -c:a pcm_s16le (Join-Path $t "mix_$($n -replace 'noise_','')_snr$snr.wav")
        }
    }
    Write-Host ('测试信号已生成: ' + $inDir) -ForegroundColor Cyan
}

# ---------------------------------------------------------------- 频段测量
$bands = [ordered]@{
    '全带'     = 'anull'
    '<100Hz'   = 'lowpass=f=100'
    '100-300'  = 'highpass=f=100,lowpass=f=300'
    '300-3k'   = 'highpass=f=300,lowpass=f=3000'
    '>5k'      = 'highpass=f=5000'
}

function Get-BandLevel($file, $af) {
    $o = & $ff -hide_banner -nostdin -i $file -vn -af "$af,volumedetect" -f null - 2>&1 | Out-String
    if ($o -match 'mean_volume:\s*([-\d.]+) dB') { return [double]$matches[1] }
    return [double]::NaN
}

# ---------------------------------------------------------------- 主流程
if (-not (Test-Path (Join-Path $inDir 'clean.wav')) -or $Force) { New-TestSignals }

$inputs = Get-ChildItem $inDir -Filter *.wav | Sort-Object Name
Write-Host ("待测信号 {0} 个，候选方案 {1} 个" -f $inputs.Count, $chains.Count) -ForegroundColor Cyan

# 1) 处理
foreach ($cname in $chains.Keys) {
    $dir = Join-Path $outRoot $cname
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    foreach ($f in $inputs) {
        $out = Join-Path $dir $f.Name
        if ((Test-Path $out) -and -not $Force) { continue }
        & $ff -hide_banner -loglevel error -y -i $f.FullName -af $chains[$cname] -ar 48000 -ac 1 -c:a pcm_s16le $out 2>$null
    }
    Write-Host ("  处理完成: $cname") -ForegroundColor DarkGray
}

# 2) 测量
$rows = New-Object System.Collections.Generic.List[object]
foreach ($f in $inputs) {
    $orig = @{}
    foreach ($b in $bands.Keys) { $orig[$b] = Get-BandLevel $f.FullName $bands[$b] }
    foreach ($b in $bands.Keys) {
        $rows.Add([pscustomobject]@{ Input = $f.BaseName; Chain = '(原始)'; Band = $b; Level = $orig[$b]; Delta = 0.0 })
    }
    foreach ($cname in $chains.Keys) {
        $p = Join-Path (Join-Path $outRoot $cname) $f.Name
        if (-not (Test-Path $p)) { continue }
        foreach ($b in $bands.Keys) {
            $lv = Get-BandLevel $p $bands[$b]
            $rows.Add([pscustomobject]@{ Input = $f.BaseName; Chain = $cname; Band = $b; Level = $lv; Delta = ($lv - $orig[$b]) })
        }
    }
    Write-Host ("  测量完成: " + $f.BaseName) -ForegroundColor DarkGray
}

$rows | Export-Csv -LiteralPath $csv -NoTypeInformation -Encoding UTF8
Write-Host ("结果已写入: $csv") -ForegroundColor Green

# 3) 打印摘要
foreach ($f in $inputs) {
    Write-Host ''
    Write-Host ("=== " + $f.BaseName) -ForegroundColor White
    $sub = $rows | Where-Object { $_.Input -eq $f.BaseName }
    $tbl = foreach ($cname in (@('(原始)') + $chains.Keys)) {
        $r = $sub | Where-Object { $_.Chain -eq $cname }
        if (-not $r) { continue }
        $o = [ordered]@{ 方案 = $cname }
        foreach ($b in $bands.Keys) {
            $row = $r | Where-Object { $_.Band -eq $b }
            if ($cname -eq '(原始)') { $o[$b] = ('{0:N1}' -f $row.Level) }
            else { $o[$b] = ('{0:N1} ({1:+0.0;-0.0;0})' -f $row.Level, $row.Delta) }
        }
        [pscustomobject]$o
    }
    $tbl | Format-Table -AutoSize | Out-String -Width 200 | Write-Host
}
