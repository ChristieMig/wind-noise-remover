# 视频降风噪工具

给一段视频去掉风噪（风吹麦克风的"轰隆隆 + 噗噗沙沙"），**画面不动、只重编码音频**，所以又快又不掉画质。

支持三种降噪引擎，默认自动挑可用的最好的那个：

| 引擎 | 是什么 | 速度参考<sup>*</sup> | 效果 |
|---|---|---|---|
| `deepfilter` | [DeepFilterNet3](https://github.com/Rikorose/DeepFilterNet)（这类任务的开源 SOTA，Rust 写的独立程序） | 60s 视频 ≈ 24s | 最好，高频残留最少 |
| `rnnoise` | [RNNoise](https://github.com/xiph/rnnoise) 神经网络降噪（ffmpeg 的 `arnndn` 滤镜 + [GregorR 的模型](https://github.com/GregorR/rnnoise-models)） | 60s 视频 ≈ 10s | 很好，低频压得最狠 |
| `classic` | 纯传统 DSP：两级高通 + `afftdn` + `anlmdn`，不依赖任何模型 | 60s 视频 ≈ 12s | 一般，但**不挑内容**（音乐/环境音也能用） |

<sup>*</sup> 640×360 / 60 秒片源，含 PowerShell 启动耗时；画面是直接复制的，所以主要开销在音频处理。

## 安装

需要 **ffmpeg**；想要 `rnnoise` / `deepfilter` 引擎还需要对应的模型和程序。三者都可以用脚本自动装：

```powershell
git clone https://github.com/ChristieMig/wind-noise-remover.git
cd wind-noise-remover
powershell -ExecutionPolicy Bypass -File setup.ps1
```

`setup.ps1` 会把 ffmpeg、5 个 RNNoise 模型、DeepFilterNet 二进制按固定版本拉到 `tools\` 下（下载器自带断点续传 / 重试 / 镜像回退，网络差也能装完）。需要 Node.js 来跑下载器。

也可以自己装：

- ffmpeg：放进 `tools\ffmpeg\bin\ffmpeg.exe`，或装好后加进 PATH，或用 `-Ffmpeg` 指定路径
- RNNoise 模型：`.rnnn` 文件放进 `tools\models\`（命名随意，用 `-RnnoiseModel 名字` 指定）
- DeepFilterNet：`deep-filter.exe` 放进 `tools\deepfilternet\`

缺哪一样都不会报错，引擎会自动降级：`deepfilter` → `rnnoise` → `classic`。

## 快速开始

最简单：把视频文件**拖到 `降风噪.bat` 上**即可（可以一次拖多个）。

命令行（PowerShell）：

```powershell
.\reduce-wind-noise.ps1 "D:\videos\vlog.mp4"                      # 默认 medium + auto 引擎
.\reduce-wind-noise.ps1 "D:\videos\vlog.mp4" strong               # 风很大
.\reduce-wind-noise.ps1 "D:\videos\vlog.mp4" voice                # 人声/口播优先
.\reduce-wind-noise.ps1 .\*.mp4 -OutDir .\out -Preset strong      # 批量 + 指定输出目录
.\reduce-wind-noise.ps1 "a.mp4" "b.mp4" -Force                    # 多个文件、覆盖已有输出
.\reduce-wind-noise.ps1 "music.mp4" -Engine classic               # 音乐/无对白素材
.\reduce-wind-noise.ps1 "赛车.mp4" -Engine classic -Preset strong -Declip
```

Python 版（功能相同）：

```powershell
python reduce_wind_noise.py "D:\videos\vlog.mp4" --preset strong
python reduce_wind_noise.py *.mp4 --outdir out --engine deepfilter
```

输出默认是 `原文件名_nowind.mp4`（和源文件同目录）。

## 引擎怎么选

- **默认 `auto`**：有 DeepFilterNet 就用它，没有就用 rnnoise，都没有才退回 classic。
- **`deepfilter` / `rnnoise` 都是"人声优先"的语音降噪器**：它们会判断"这段是不是人声"，不是就压掉。采访、vlog、口播这类素材效果拔群；**纯音乐、纯环境音、没有人声的素材请用 `-Engine classic`**，否则会被当成噪声掐掉（下面有实测数据）。

## 无人声素材怎么处理（音乐 / 赛车 / 环境音）

这是最容易踩的坑，直接上实测数据。用一段**真实赛车跑圈素材**（64 秒、2688×1512、立体声 48kHz、严重风噪、无人声对白）测的：

| 方案 | 全带 | <100Hz | 100-300 | **300-1k** | **1-3k** | 3-8k |
|---|---|---|---|---|---|---|
| 原始 | −8.0 | −9.5 | −15.7 | **−18.9** | **−22.3** | −27.5 |
| `classic -Preset strong` | −16.0 | **−30.8** | −20.9 | **−20.0** | **−23.3** | −27.9 |
| `classic -Preset strong` + rnnoise mix=0.25 | −17.4 | −32.3 | −22.4 | −21.4 | −24.7 | −29.3 |
| `deepfilter -AttenLimit 12` | −25.9 | −36.0 | −29.5 | **−31.0** | **−34.9** | −39.6 |
| `deepfilter`（默认，不限制衰减） | −36.2 | −46.5 | −38.7 | **−41.4** | **−48.9** | −60.7 |

看 `300-1k` / `1-3k` 两列（引擎声所在）：

- **classic 只砍低频**（<100Hz −21dB），引擎频段只掉 **0.9 / 0.4dB** —— 风噪轰鸣没了，引擎声原样保留。
- **神经网络引擎会连内容一起砍**：默认设置下引擎频段掉 22–27dB，整条音轨几乎被掐没。即使把 `-AttenLimit` 调到 12（限制最多衰减 12dB），引擎频段仍然掉 12dB。

所以无人声素材的正确姿势是 `-Engine classic`：

```powershell
# 只压低频轰鸣，引擎/音乐原样保留
.\reduce-wind-noise.ps1 "赛车.mp4" -Engine classic -Preset strong -Declip
```

如果连宽带"沙沙"声也想压一点，再叠一个**部分强度**的神经网络——用 `-RnnoiseMix`（0=不处理，1=完全降噪）或 DFN 的 `-AttenLimit`（dB）控制"压多少"，以此保住内容：

```powershell
# 低频走 classic，宽带噪声只压 25% 强度
.\reduce-wind-noise.ps1 "赛车.mp4" -Engine rnnoise -RnnoiseMix 0.25 -Preset strong -Highpass 150

# DeepFilterNet 同理：最多只允许衰减 8dB
.\reduce-wind-noise.ps1 "赛车.mp4" -Engine deepfilter -AttenLimit 8
```

上面那段赛车素材用 `classic -Preset strong -Declip` 的实测结果：**低频轰鸣 −21.4dB，300Hz–3kHz 的引擎声只掉 0.4~0.9dB**，64 秒片子 14 秒处理完。

> `rnnoise` / `deepfilter` 也能给无人声素材用，但必须配 `-RnnoiseMix` / `-AttenLimit` 把强度降下来，否则就是把整条音轨当噪声处理。

### 削波检测

风把麦克风推过载时波形会被削平，这种素材加 `-Declip` 会明显更干净。工具会**自动检测并提示**：

```
输入电平已贴顶且动态很小（峰值 0.83dB，波峰因数 8.8dB），很可能过载削波，建议加 -Declip。
```

判据是"峰值贴顶 + 波峰因数 < 12dB"。之所以不用 ffmpeg 的 `flat factor`（平顶因子）：视频音轨通常是 AAC，解码会把削波平顶抹平，`flat factor` 直接变 0，看不出来。上面那段赛车素材就是这种情况（峰值 0.91dB、波峰因数 9.1dB）。

## 实测对比（客观数据）

测试素材：真实语音（DeepFilterNet 仓库的 freesound 录音）+ 真实噪声（低频轰鸣型 / 宽带型）+ 合成阵风，分别按 +3dB 和 0dB 信噪比混合，共 6 个混合信号 + 3 个纯噪声信号 + 1 个干净语音，即 10 个信号 × 15 个方案。评测脚本在 `test\eval_chains.ps1` 和 `test\eval_dfn.ps1`（跑完会生成 `test\eval_results.csv`、`test\eval_dfn.csv`，全程只用 ffmpeg 测量，不依赖 numpy）。

**表1：处理后与"干净语音"的频谱偏差（dB，越小越接近干净，这是最公平的指标）**

| 方案 | <100Hz | 100-300 | 300-3k | >5k | 平均 |
|---|---|---|---|---|---|
| （原始混合信号，未处理） | 14.1 | 2.0 | 0.6 | 1.2 | **4.5** |
| 高通80 + **DeepFilterNet** | 1.2 | 0.8 | 0.5 | 0.2 | **0.7** |
| 高通 + afftdn + **RNNoise(sh)** | 0.8 | 0.7 | 0.6 | 0.5 | **0.7** |
| 高通90 + **RNNoise(sh)** | 0.7 | 0.7 | 0.7 | 0.8 | **0.7** |
| **RNNoise(sh)** 单独 | 0.7 | 0.7 | 0.6 | 0.8 | **0.7** |
| **DeepFilterNet** 单独（无高通） | 2.0 | 0.6 | 0.5 | 0.2 | 0.8 |
| **只靠传统 DSP**：高通+afftdn+anlmdn | 2.5 | 1.2 | 0.5 | 1.2 | 1.3 |

**表2：噪声压制能力（对纯噪声信号，dB，越负压得越狠）**

| 方案 | <100Hz | 100-300 | 300-3k |
|---|---|---|---|
| 高通 + afftdn + RNNoise | −49.7 | −34.5 | −31.8 |
| 高通90 + RNNoise(sh) | −46.7 | −32.0 | −30.1 |
| 高通80 + DeepFilterNet | −42.6 | −29.5 | −31.6 |
| RNNoise(sh) 单独 | −35.0 | −29.7 | −28.7 |
| DeepFilterNet 单独 | −25.6 | −27.3 | −30.4 |
| 传统 DSP：高通+afftdn+anlmdn | −19.8 | −3.5 | −0.3 |

结论：

1. **传统 DSP 的短板非常明显**：只能压低频（<100Hz），100Hz 以上几乎没动（−3.5 / −0.3dB）；两个神经网络方案则是全频段 30dB 级别的压制。这正是"低频压得住、中高频沙沙声还在"的原因。
2. **DeepFilterNet 建议配一个高通**（80Hz×2）：单独用低频还剩 2.0dB 偏差，加上高通后降到 1.2dB。
3. **RNNoise 五个模型里 `sh`（somnolent-hogwash）最好**，`cb` / `mp` 明显更差，所以默认用 `sh`。
4. 表2 里神经网络的数字偏乐观（纯噪声输入时它们判定"没人声"直接静音），**以表1为准**。

> 客观指标只能反映"能量/频谱"层面的干净程度，反映不了"有没有音乐噪声、人声有没有塑料感"。建议拿一段自己的素材，把各方案的输出听一遍再定——`test\eval_out\` 里有现成的对比音频。

## 预设

| 预设 | classic 高通 | rnnoise/deepfilter 高通 | 适用 |
|---|---|---|---|
| `light` | 80Hz ×2 | 60Hz ×2 | 轻微风声、室内 |
| `medium`（默认） | 120Hz ×2 | 80Hz ×2 | 户外常见风噪 |
| `strong` | 150Hz ×2 | 100Hz ×2 | 大风、风直吹麦克风 |
| `voice` | 90Hz ×2 | 60Hz ×2 | 口播/采访，优先保人声 |
| `custom` | 自定义 | 自定义 | 配 `-Highpass` / `-NoiseReduction` |

走神经网络引擎时高通降到 60~100Hz：剩下的噪声交给模型处理，高通只负责先把低频"轰隆"削掉、减轻模型负担；压太低反而会把人声的胸腔共鸣削薄。

## 工作原理

画面用 `-c:v copy` 直接复制，音频分三条路：

**classic**：`adeclip`(可选) → `highpass ×2`(24dB/oct) → `afftdn=nr=..:tn=1`(频域降噪 + 噪声底跟踪) → `anlmdn`(非局部均值) → `lowpass`(可选) → `dynaudnorm`(可选)

**rnnoise**：`adeclip`(可选) → `highpass ×2` → `arnndn=model='...'`（可选 `:mix=` 控制强度）

**deepfilter**：三段式（它只吃音频）
1. `ffmpeg` 抽音频到 48kHz wav，顺便做前置处理（`adeclip` / `highpass ×2`）
2. `deep-filter -D -o <临时目录> <音频>`（`-D` 补偿 STFT/模型前瞻延迟，保证音画同步）
3. `ffmpeg` 把降噪后的音频合回原视频（画面仍 `-c:v copy`）

按 `-DryRun` / `--dry-run` 可以只打印命令不处理；`-ExtraFilters` / `--extra` 可以追加任意 ffmpeg 滤镜。

## 参数速查

| PowerShell | Python | 说明 |
|---|---|---|
| `-Preset` | `--preset` | light/medium/strong/voice/custom |
| `-Engine` | `--engine` | auto/deepfilter/rnnoise/classic |
| `-RnnoiseModel` | `--rnnoise-model` | RNNoise 模型名或路径，默认 `sh` |
| `-RnnoiseMix` | `--rnnoise-mix` | 0~1，RNNoise 降噪强度（默认 1=完全降噪），无人声素材调小 |
| `-AttenLimit` | `--atten-limit` | DeepFilterNet 衰减上限 dB（默认 100=不限制），无人声素材调小 |
| `-DeepFilter` | `--deepfilter` | 手动指定 deep-filter.exe |
| `-OutDir` | `--outdir` | 输出目录 |
| `-Suffix` | `--suffix` | 文件名后缀，默认 `_nowind` |
| `-Container` | `--container` | same/mp4/mkv/mov，默认 same |
| `-AudioBitrate` | `--bitrate` | 音频码率 kbps，默认 192 |
| `-Highpass` | `--highpass` | 覆盖高通频率（Hz） |
| `-NoiseReduction` | `--noise-reduction` | 覆盖降噪强度（仅 classic） |
| `-ExtraFilters` | `--extra` | 追加滤镜 |
| `-Declip` / `-Normalize` | `--declip` / `--normalize` | 削波修复 / 响度归一化 |
| `-Force` | `--force` | 覆盖已存在的输出 |
| `-DryRun` | `--dry-run` | 只打印命令 |
| `-Ffmpeg` | `--ffmpeg` | 指定 ffmpeg 路径 |

## 已知行为

- **采样率**：`rnnoise` 固定按 48kHz 处理（44.1kHz 输入会转成 48kHz 输出）；`deepfilter` 同理（强制抽成 48kHz）。功能正常，只是输出音频采样率会变。
- **多声道**：`deepfilter` 只支持单/双声道，>2 声道（如 5.1）会自动降为立体声并提示。
- **字幕**：mp4/mov 输出不带字幕轨（避免封装报错），mkv 会原样复制字幕。
- **长视频**：DFN 走临时 wav（48kHz 单声道约 5.5MB/分钟），处理完自动清理。
- **Windows 路径里的冒号**：ffmpeg 滤镜语法会把 `:` 当选项分隔符，所以模型路径需要转义，脚本已处理（`arnndn=model='E\:/...'`）。自己写 `-ExtraFilters` 时要注意。

## 目录结构

```
wind-noise-remover/
├─ 降风噪.bat                  拖拽/双击入口（把参数原样转发给 ps1）
├─ reduce-wind-noise.ps1       主程序（PowerShell）
├─ reduce_wind_noise.py        Python 版（功能一致，仅用标准库）
├─ setup.ps1                   依赖安装脚本
├─ tools/
│  ├─ fetch.js                 下载器（断点续传 + 重试 + GitHub 镜像回退）
│  ├─ system-ca.js             修复 Node 的证书信任链（详见"常见环境问题"）
│  ├─ gh-publish.js            把本仓库发布到 GitHub（不依赖 git）
│  ├─ ffmpeg/                  ← setup.ps1 生成（不入库）
│  ├─ models/                  ← setup.ps1 生成：sh(默认)/bd/lq/mp/cb
│  └─ deepfilternet/           ← setup.ps1 生成
└─ test/
   ├─ eval_chains.ps1          传统链 / RNNoise 方案评测
   └─ eval_dfn.ps1             DeepFilterNet 对比评测
```

## 常见环境问题

1. **Node 报 `unable to verify the first certificate`**
   企业代理、抓包软件或安全软件会替换 HTTPS 证书，而 Node 只信任自带的 CA 列表。
   `tools\system-ca.js` 已把系统证书库合并进信任列表并在两个脚本里自动加载，正常情况无需处理。
   如果你的 Node 较老（没有 `tls.setDefaultCACertificates`）且仍然失败，启动时加 `--use-system-ca`：
   ```powershell
   node --use-system-ca tools\fetch.js <url> <输出文件>
   ```

2. **找不到 ffmpeg**
   放到 `tools\ffmpeg\bin\ffmpeg.exe`，或用 `-Ffmpeg "C:\path\to\ffmpeg.exe"`，或装好加进 PATH。
   本工具需要 ffmpeg 带 `arnndn` / `afftdn` / `anlmdn` / `adeclip` 滤镜（gyan.dev 的 essentials 构建和大多数完整构建都有）。

3. **PowerShell 执行策略禁止运行脚本**
   `降风噪.bat` 内部已经用了 `-ExecutionPolicy Bypass`；手动跑请写全：
   ```powershell
   powershell -NoProfile -ExecutionPolicy Bypass -File .\reduce-wind-noise.ps1 "视频.mp4"
   ```

4. **下载 GitHub 很慢 / 经常断**
   `tools\fetch.js` 自带断点续传、重试和镜像回退（jsDelivr / ghproxy 等），断了下一次运行会从已下载的字节继续。DeepFilterNet 那 26MB 就是这么拉下来的。

## 维护注意（改代码前看）

- **`.ps1` 文件必须带 UTF-8 BOM**。Windows PowerShell 5.1 对没有 BOM 的脚本按系统 ANSI 代码页（中文系统是 GBK）解码，文件里的中文会变乱码并直接导致语法错误。编辑器另存时选 "UTF-8 with BOM"，或用：
  ```powershell
  $p = 'reduce-wind-noise.ps1'
  $c = Get-Content -LiteralPath $p -Raw -Encoding UTF8
  Set-Content -LiteralPath $p -Value $c -NoNewline -Encoding UTF8   # PS 5.1 的 -Encoding UTF8 会写 BOM
  ```
- **`.py` 文件不要加 BOM**（Python 源码有 BOM 虽然多数情况能跑，但工具链容易踩坑）。
- `降风噪.bat` 内容保持纯 ASCII：cmd 按 ANSI 读取批处理，中文字面量会乱码。
- 发布到 GitHub：`node tools\gh-publish.js --repo <仓库名> --token-file <token文件>`（见脚本头部说明）。

## 参考的开源项目

- [Rikorose/DeepFilterNet](https://github.com/Rikorose/DeepFilterNet) —— DeepFilterNet3，实时语音增强 SOTA，本工具用的是它的 Windows release 二进制
- [xiph/rnnoise](https://github.com/xiph/rnnoise) —— Mozilla/Xiph 的 RNNoise 神经网络降噪
- [GregorR/rnnoise-models](https://github.com/GregorR/rnnoise-models) —— 社区训练的 RNNoise 模型（`sh` / `bd` / `lq` / `mp` / `cb` 来自这里）
- [ffmpeg](https://ffmpeg.org/ffmpeg-filters.html) 的 `arnndn` / `afftdn` / `anlmdn` / `adeclip` / `highpass` 滤镜
- [kenders2000/MicWindNoiseGenerator](https://github.com/kenders2000/MicWindNoiseGenerator) —— 麦克风风噪生成器（合成阵风测试信号的思路来源）

## 常见问题

- **人声发闷 / 有金属感** → 换 `voice` 预设；用 classic 时也可以 `-Preset custom -NoiseReduction 10`。
- **风噪还剩很多** → `strong`；再不行 `-Preset custom -Highpass 180 -Declip`。
- **纯音乐/环境音被掐掉了** → 别用神经网络引擎，`-Engine classic`。
- **只想导出降噪后的音频** → 直接调 ffmpeg（classic 链）：
  ```powershell
  ffmpeg -i in.mp4 -vn -af "highpass=f=120,highpass=f=120,afftdn=nr=16:nf=-50:tn=1" -c:a aac -b:a 192k out.m4a
  ```
  或者先导出 wav 再喂给 DeepFilterNet：`deep-filter -D -o out_dir audio.wav`
- **一段视频里只有部分时间有风噪** → 目前是全片统一处理（安静段落也会被神经网络过一遍）；要更精细可以切片分别处理。
- **想换 RNNoise 模型** → 把 `.rnnn` 放进 `tools\models\`，然后 `-RnnoiseModel 文件名（不带扩展名）`。
- **视频画质会变吗** → 不会，画面流是 `-c:v copy` 直接复制的，只有音频被重新编码（默认 AAC 192k）。
