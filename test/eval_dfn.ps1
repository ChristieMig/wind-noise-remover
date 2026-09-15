<#
  DeepFilterNet 对比评测：把它和已有的 ffmpeg / RNNoise 方案放在同一张表里比。

  输出两个指标：
    1) 噪声压制能力：对"只含噪声"的信号处理前后各频段电平变化（越负越好）
    2) 频谱偏差：混合信号处理后各频段电平 与 "干净语音" 的距离（越小越接近干净，最公平）
#>
param(
    [string]$Root = 'E:\kida\code',
    [switch]$Force
)

$ff = Join-Path $Root 'tools\ffmpeg\bin\ffmpeg.exe'
$dfn = Join-Path $Root 'tools\deepfilternet\deep-filter.exe'
$modelDir = (Join-Path $Root 'tools\models').Replace('\', '/')
$modelDirEsc = $modelDir -replace ':', '\:'
$inDir = Join-Path $Root 'test\eval_in'
$outRoot = Join-Path $Root 'test\eval_out'
$tmp = Join-Path $Root 'tools\tmp'
$baseCsv = Join-Path $Root 'test\eval_results.csv'
$dfnCsv = Join-Path $Root 'test\eval_dfn.csv'
New-Item -ItemType Directory -Force -Path $tmp, $outRoot | Out-Null

function RN($name) { "arnndn=model='$modelDirEsc/$name.rnnn'" }

# 'DFN'            = 只用 DeepFilterNet
# 'DFN_PRE:<滤镜>'  = 先跑滤镜做前置处理，再交给 DeepFilterNet
# 'DFN_POST:<滤镜>' = 先跑 DeepFilterNet，再用滤镜收尾
$chains = [ordered]@{
    'L_deepfilter'      = 'DFN'
    'M_高通80+deepfilter' = 'DFN_PRE:highpass=f=80:poles=2,highpass=f=80:poles=2'
    'N_deepfilter+高通80' = 'DFN_POST:highpass=f=80:poles=2,highpass=f=80:poles=2'
    'O_高通80+DFN+anlmdn' = 'DFN_POST:anlmdn=s=0.0003:p=0.002:r=0.006:m=11'
}

$bands = [ordered]@{
    '全带'    = 'anull'
    '<100Hz'  = 'lowpass=f=100'
    '100-300' = 'highpass=f=100,lowpass=f=300'
    '300-3k'  = 'highpass=f=300,lowpass=f=3000'
    '>5k'     = 'highpass=f=5000'
}

function Get-BandLevel($file, $af) {
    $o = & $ff -hide_banner -nostdin -i $file -vn -af "$af,volumedetect" -f null - 2>&1 | Out-String
    if ($o -match 'mean_volume:\s*([-\d.]+) dB') { return [double]$matches[1] }
    return [double]::NaN
}

$inputs = Get-ChildItem $inDir -Filter *.wav | Sort-Object Name

# ---------------------------------------------------------------- 处理
foreach ($cname in $chains.Keys) {
    $dir = Join-Path $outRoot $cname
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    foreach ($f in $inputs) {
        $out = Join-Path $dir $f.Name
        if ((Test-Path $out) -and -not $Force) { continue }
        $spec = $chains[$cname]
        $pre = ''; $post = ''
        if ($spec -like 'DFN_PRE:*') { $pre = $spec.Substring(8) }
        elseif ($spec -like 'DFN_POST:*') { $post = $spec.Substring(9) }

        $tmpPre = Join-Path $tmp ('dfnpre_' + $f.Name)
        $preArgs = @('-hide_banner', '-loglevel', 'error', '-y', '-i', $f.FullName, '-vn', '-ar', '48000', '-ac', '1')
        if ($pre) { $preArgs += @('-af', $pre) }
        $preArgs += @('-c:a', 'pcm_s16le', $tmpPre)
        & $ff @preArgs 2>$null

        $dfnOutDir = Join-Path $tmp ('dfnout_' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Force -Path $dfnOutDir | Out-Null
        & $dfn -D -o $dfnOutDir $tmpPre 2>$null | Out-Null
        $enh = Get-ChildItem $dfnOutDir -Filter *.wav -ErrorAction SilentlyContinue | Select-Object -First 1
        if (-not $enh) { Write-Warning "DFN 未产出: $cname / $($f.Name)"; continue }

        $postArgs = @('-hide_banner', '-loglevel', 'error', '-y', '-i', $enh.FullName, '-ar', '48000', '-ac', '1')
        if ($post) { $postArgs += @('-af', $post) }
        $postArgs += @('-c:a', 'pcm_s16le', $out)
        & $ff @postArgs 2>$null

        Remove-Item $tmpPre -Force -ErrorAction SilentlyContinue
        Remove-Item $dfnOutDir -Recurse -Force -ErrorAction SilentlyContinue
    }
    Write-Host "  处理完成: $cname" -ForegroundColor DarkGray
}

# ---------------------------------------------------------------- 测量
$rows = New-Object System.Collections.Generic.List[object]
foreach ($f in $inputs) {
    foreach ($b in $bands.Keys) {
        $rows.Add([pscustomobject]@{ Input = $f.BaseName; Chain = '(原始)'; Band = $b; Level = (Get-BandLevel $f.FullName $bands[$b]) })
    }
    foreach ($cname in $chains.Keys) {
        $p = Join-Path (Join-Path $outRoot $cname) $f.Name
        if (-not (Test-Path $p)) { continue }
        foreach ($b in $bands.Keys) {
            $rows.Add([pscustomobject]@{ Input = $f.BaseName; Chain = $cname; Band = $b; Level = (Get-BandLevel $p $bands[$b]) })
        }
    }
    Write-Host ("  测量完成: " + $f.BaseName) -ForegroundColor DarkGray
}
$rows | Export-Csv -LiteralPath $dfnCsv -NoTypeInformation -Encoding UTF8

# ---------------------------------------------------------------- 合并旧结果
$all = New-Object System.Collections.Generic.List[object]
if (Test-Path $baseCsv) {
    Get-Content $baseCsv -Encoding UTF8 | Select-Object -Skip 1 | ForEach-Object {
        $p = $_ -split '","'
        $p[0] = $p[0].TrimStart('"'); $p[-1] = $p[-1].TrimEnd('"')
        $all.Add([pscustomobject]@{ Input = $p[0]; Chain = $p[1]; Band = $p[2]; Level = [double]$p[3] })
    }
}
foreach ($r in $rows) { $all.Add([pscustomobject]@{ Input = $r.Input; Chain = $r.Chain; Band = $r.Band; Level = $r.Level }) }

$chainList = $all.Chain | Select-Object -Unique | Where-Object { $_ -ne '(原始)' } | Sort-Object
$noise = @('noise_low', 'noise_wide', 'noise_gust')
$mixInputs = @('mix_low_snr0', 'mix_low_snr3', 'mix_wide_snr0', 'mix_wide_snr3', 'mix_gust_snr0', 'mix_gust_snr3')
$cleanRef = @{}
$all | Where-Object { $_.Input -eq 'clean' -and $_.Chain -eq '(原始)' } | ForEach-Object { $cleanRef[$_.Band] = [double]$_.Level }

function Avg-Delta($chain, $inputs, $band) {
    $v = $all | Where-Object { $_.Chain -eq $chain -and $inputs -contains $_.Input -and $_.Band -eq $band } | ForEach-Object { [double]$_.Level }
    if ($v.Count -eq 0) { return [double]::NaN }
    $o = $all | Where-Object { $_.Chain -eq '(原始)' -and $inputs -contains $_.Input -and $_.Band -eq $band } | ForEach-Object { [double]$_.Level }
    return (($v | Measure-Object -Average).Average - ($o | Measure-Object -Average).Average)
}
function Avg-Dev($chain, $band) {
    $devs = foreach ($mi in $mixInputs) {
        $r = $all | Where-Object { $_.Chain -eq $chain -and $_.Input -eq $mi -and $_.Band -eq $band }
        if ($r) { [math]::Abs([double]$r.Level - $cleanRef[$band]) }
    }
    if (-not $devs) { return [double]::NaN }
    return ($devs | Measure-Object -Average).Average
}

Write-Host ''
Write-Host '=== 表1 噪声压制能力(越负越好) / 语音保真(0=完全没动) ===' -ForegroundColor White
$t1 = foreach ($c in $chainList) {
    [pscustomobject]@{
        方案 = $c
        '噪声<100' = ('{0:N1}' -f (Avg-Delta $c $noise '<100Hz'))
        '噪声100-300' = ('{0:N1}' -f (Avg-Delta $c $noise '100-300'))
        '噪声300-3k' = ('{0:N1}' -f (Avg-Delta $c $noise '300-3k'))
        '语音全带' = ('{0:N1}' -f (Avg-Delta $c @('clean') '全带'))
        '语音300-3k' = ('{0:N1}' -f (Avg-Delta $c @('clean') '300-3k'))
    }
}
$t1 | Sort-Object { [double]($_.'噪声<100') } | Format-Table -AutoSize | Out-String -Width 200 | Write-Host

Write-Host '=== 表2 处理后与"干净语音"的频谱偏差(dB, 越小越干净) ===' -ForegroundColor White
$t2 = foreach ($c in $chainList) {
    $b = @{}
    foreach ($band in @('<100Hz', '100-300', '300-3k', '>5k')) { $b[$band] = Avg-Dev $c $band }
    [pscustomobject]@{
        方案 = $c
        '<100Hz' = ('{0:N1}' -f $b['<100Hz'])
        '100-300' = ('{0:N1}' -f $b['100-300'])
        '300-3k' = ('{0:N1}' -f $b['300-3k'])
        '>5k' = ('{0:N1}' -f $b['>5k'])
        平均偏差 = ('{0:N1}' -f (($b['<100Hz'] + $b['100-300'] + $b['300-3k'] + $b['>5k']) / 4))
    }
}
$t2 | Sort-Object { [double]($_.平均偏差) } | Format-Table -AutoSize | Out-String -Width 200 | Write-Host
