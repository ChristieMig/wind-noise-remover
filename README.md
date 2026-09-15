# 视频降风噪工具

给一段视频去掉风噪（风吹麦克风的"轰隆隆 + 噗噗沙沙"），**画面不动、只重编码音频**，所以又快又不掉画质。

支持三种降噪引擎，默认自动挑最好的：

| 引擎 | 是什么 | 速度 | 效果 |
|---|---|---|---|
| `deepfilter` | [DeepFilterNet3](https://github.com/Rikorose/DeepFilterNet)（这类任务的开源 SOTA，Rust 写的独立程序） | 60s 视频 ≈ 24s | 最好，高频残留最少 |
| `rnnoise` | [RNNoise](https://github.com/xiph/rnnoise) 神经网络降噪（ffmpeg 的 `arnndn` 滤镜 + [GregorR 的模型](https://github.com/GregorR/rnnoise-models)） | 60s 视频 ≈ 10s | 很好，低频压得最狠 |
| `classic` | 纯传统 DSP：两级高通 + `afftdn` + `anlmdn`，不依赖模型 | 60s 视频 ≈ 12s | 一般，但**不挑内容**（音乐/环境音也能用） |

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
.\reduce-wind-noise.ps1 "a.mp4" -Engine deepfilter -RnnoiseModel sh
```

Python 版（功能相同）：

```powershell
python reduce_wind_noise.py "D:\videos\vlog.mp4" --preset strong
python reduce_wind_noise.py *.mp4 --outdir out --engine deepfilter
```

输出默认是 `原文件名_nowind.mp4`（和源文件同目录）。

## 引擎怎么选

- **默认 `auto`**：有 DeepFilterNet 就用它，没有就用 rnnoise，都没有才退回 classic。当前机器三者齐备，所以默认走 DeepFilterNet。
- **`deepfilter` / `rnnoise` 都是"人声优先"的语音降噪器**：它们会判断"这段是不是人声"，不是就压掉。采访、vlog、口播这类素材效果拔群；**纯音乐、纯环境音、没有人声的素材请用 `-Engine classic`**，否则会被当成噪声掐掉。
- 追求极致可以用 `-Engine classic` 的链和神经网络叠，但实测收益很小（见下表），一般没必要。

## 无人声素材怎么处理（音乐 / 赛车 / 环境音）

这是本工具最容易踩坑的地方，直接上实测数据。用一段**真实赛车跑圈素材**（64 秒、2688×1512、立体声 48kHz、严重风噪、无人声对白）测的：

| 方案 | 全带 | <100Hz | 100-300 | **300-1k** | **1-3k** | 3-8k |
|---|---|---|---|---|---|---|
| 原始 | −8.0 | −9.5 | −15.7 | **−18.9** | **−22.3** | −27.5 |
| `classic -Preset strong` | −16.0 | **−30.8** | −20.9 | **−20.0** | **−23.3** | −27.9 |
| `classic -Preset strong + rnnoise mix=0.25` | −17.4 | −32.3 | −22.4 | −21.4 | −24.7 | −29.3 |
| `deepfilter -AttenLimit 12` | −25.9 | −36.0 | −29.5 | **−31.0** | **−34.9** | −39.6 |
| `deepfilter`（默认，不限制衰减） | −36.2 | −46.5 | −38.7 | **−41.4** | **−48.9** | −60.7 |

看 `300-1k` / `1-3k` 两列（引擎声所在）：

- **classic 只砍低频**（<100Hz −21dB），引擎频段只掉 **0.9 / 0.4dB**，等于风噪轰鸣没了、引擎声原样保留。
- **神经网络引擎会连内容一起砍**：默认设置下引擎频段掉 22–27dB，整条音轨几乎被掐没。即使把 `-AttenLimit` 调到 12（限制最多衰减 12dB），引擎频段仍然掉 12dB。

**所以无人声素材的正确姿势是 `-Engine classic`：**

```powershell
# 推荐：只压低频轰鸣，引擎/音乐原样保留（本工具已用这条命令处理过那段赛车素材）
.\reduce-wind-noise.ps1 "赛车.mp4" -Engine classic -Preset strong -Declip
```

如果连宽带"沙沙"声也想压一点，再叠一个**部分强度**的神经网络——用 `-RnnoiseMix`（0=不处理，1=完全降噪）或 DFN 的 `-AttenLimit`（dB）来控制"压多少"，保住内容：

```powershell
# 低频走 classic，宽带噪声只压 25% 强度
.\reduce-wind-noise.ps1 "赛车.mp4" -Engine rnnoise -RnnoiseMix 0.25 -Preset strong -Highpass 150

# DeepFilterNet 同理：最多只允许衰减 8dB
.\reduce-wind-noise.ps1 "赛车.mp4" -Engine deepfilter -AttenLimit 8
```

实测这段赛车素材用 `classic -Preset strong -Declip` 的结果：**低频轰鸣 −21.4dB，300Hz–3kHz 的引擎声只掉 0.4~0.9dB**，64 秒片子 14 秒处理完（画面是直接复制的）。

> `rnnoise` / `deepfilter` 也可以给无人声素材用，但必须配 `-RnnoiseMix` / `-AttenLimit` 把强度降下来，否则就是把整条音轨当噪声处理。

### 削波检测

风把麦克风推过载时波形会被削平，这种素材加 `-Declip` 会明显更干净。工具会**自动检测并提示**：

```
输入电平已贴顶且动态很小（峰值 0.83dB，波峰因数 8.8dB），很可能过载削波，建议加 -Declip。
```

（判据是"峰值贴顶 + 波峰因数 < 12dB"；视频音轨一般是 AAC，解码会把削波平顶抹掉，所以不能只看 flat factor。上面那段赛车素材就是这种情况，峰值 0.91dB、波峰因数 9.1dB。）

## 实测对比（客观数据）

测试素材：真实语音（DeepFilterNet 仓库的 freesound 录音）+ 真实噪声（低频轰鸣型 / 宽带型）+ 合成阵风，分别按 +3dB 和 0dB 信噪比混合，共 6 个混合信号 + 3 个纯噪声信号 + 1 个干净语音，共 10 个信号 × 15 个方案。评测脚本在 `test\eval_chains.ps1` 和 `test\eval_dfn.ps1`，原始数据在 `test\eval_results.csv`、`test\eval_dfn.csv`。

**表1：处理后与"干净语音"的频谱偏差（dB，越小越接近干净，这是最公平的指标）**

| 方案 | <100Hz | 100-300 | 300-3k | >5k | 平均 |
|---|---|---|---|---|---|
| （原始混合信号，未处理） | 14.1 | 2.0 | 0.6 | 1.2 | **4.5** |
| 高通80 + **DeepFilterNet** | 1.2 | 0.8 | 0.5 | 0.2 | **0.7** |
| 高通 + afftdn + **RNNoise(sh)** | 0.8 | 0.7 | 0.6 | 0.5 | **0.7** |
| 高通90 + **RNNoise(sh)** | 0.7 | 0.7 | 0.7 | 0.8 | **0.7** |
| **RNNoise(sh)** 单独 | 0.7 | 0.7 | 0.6 | 0.8 | **0.7** |
| **DeepFilterNet** 单独（无高通） | 2.0 | 0.6 | 0.5 | 0.2 | 0.8 |
| **旧方案**：高通+afftdn+anlmdn | 2.5 | 1.2 | 0.5 | 1.2 | 1.3 |

**表2：噪声压制能力（对纯噪声信号，dB，越负压得越狠）**

| 方案 | <100Hz | 100-300 | 300-3k |
|---|---|---|---|
| 高通 + afftdn + RNNoise | −49.7 | −34.5 | −31.8 |
| 高通90 + RNNoise(sh) | −46.7 | −32.0 | −30.1 |
| 高通80 + DeepFilterNet | −42.6 | −29.5 | −31.6 |
| RNNoise(sh) 单独 | −35.0 | −29.7 | −28.7 |
| DeepFilterNet 单独 | −25.6 | −27.3 | −30.4 |
| 旧方案：高通+afftdn+anlmdn | −19.8 | −3.5 | −0.3 |

结论：
1. **传统方案的短板非常明显**：它只能压低频（<100Hz），100Hz 以上几乎没动（−3.5 / −0.3dB）；而两个神经网络方案全频段都有 30dB 级别的压制。这就是"低频压得住、中高频沙沙声还在"的原因。
2. **DeepFilterNet 需要配一个高通**（80Hz×2）：单独用它低频还剩 2.0dB 偏差，加上高通后降到 1.2dB。
3. **RNNoise 五个模型里的 `sh`（somnolent-hogwash）最好**，`cb`/`mp` 明显更差，所以默认用 `sh`。
4. 表2 里神经网络的数字偏乐观（纯噪声输入时它们会判定"没人声"直接静音），所以**以表1为准**。

> 注意：客观指标只能反映"能量/频谱"层面的干净程度，反映不了"有没有音乐噪声、人声有没有塑料感"。建议拿一段自己的素材，把 `test\eval_out\` 里各方案的输出听一遍再定。

## 预设

| 预设 | classic 高通 | rnnoise/deepfilter 高通 | 适用 |
|---|---|---|---|
| `light` | 80Hz ×2 | 60Hz ×2 | 轻微风声、室内 |
| `medium`（默认） | 120Hz ×2 | 80Hz ×2 | 户外常见风噪 |
| `strong` | 150Hz ×2 | 100Hz ×2 | 大风、风直吹麦克风 |
| `voice` | 90Hz ×2 | 60Hz ×2 | 口播/采访，优先保人声 |
| `custom` | 自定义 | 自定义 | 配 `-Highpass` / `-NoiseReduction` |

走神经网络引擎时高通降到 60~100Hz：因为剩下的噪声交给模型处理，高通只负责把低频"轰隆"先削掉、减轻模型负担，压太低反而会把人声胸腔共鸣削薄。

## 工作原理

画面用 `-c:v copy` 直接复制。音频分两条路：

**classic**：`adeclip`(可选) → `highpass ×2`(24dB/oct) → `afftdn=nr=..:tn=1`(频域降噪+噪声底跟踪) → `anlmdn`(非局部均值) → `lowpass`(可选) → `dynaudnorm`(可选)

**rnnoise**：`adeclip`(可选) → `highpass ×2` → `arnndn=model='...'`（RNNoise 模型）

**deepfilter**：三段式（因为它只吃音频）
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

## 已知行为（用之前先知道）

- **采样率**：`rnnoise` 内部固定按 48kHz 处理，44.1kHz 输入会被转成 48kHz 输出；`deepfilter` 同理（强制抽成 48kHz）。都正常，只是音频采样率会变。
- **多声道**：`deepfilter` 只支持单/双声道，>2 声道（如 5.1）会自动降为立体声并提示。
- **速度参考**（640×360 / 60 秒片源，含 PowerShell 启动和视频复制）：classic 12.4s、rnnoise 10.0s、deepfilter 23.6s。
- **长视频**：DFN 走临时 wav（48kHz 单声道约 5.5MB/分钟），处理完会清理。

## 文件清单

```
E:\kida\code\
├─ 降风噪.bat                  拖拽/双击入口（把参数原样转发给 ps1）
├─ reduce-wind-noise.ps1       主程序（PowerShell）
├─ reduce_wind_noise.py        Python 版（功能一致）
├─ tools\
│  ├─ ffmpeg\bin\ffmpeg.exe    ffmpeg（gyan essentials 2022-10-30 静态构建，含 arnndn/afftdn/anlmdn）
│  ├─ models\*.rnnn            RNNoise 模型 5 个：sh(默认最好)/bd/lq/mp/cb
│  ├─ deepfilternet\deep-filter.exe   DeepFilterNet 0.5.6（Windows 官方 release）
│  ├─ python\                  Python 3.12.7 + pip
│  ├─ fetch.js                 下载器（续传+重试+镜像回退，绕开本机 TLS 故障）
│  └─ tmp\                     临时目录
└─ test\
   ├─ 对比样本\                   ⭐ 真实素材的前后对比，可以直接播放试听
   │  ├─ 0_参考_干净语音.mp4
   │  ├─ 1_原始_真实语音+低频风噪.mp4
   │  ├─ 2_降噪_DeepFilterNet(默认).mp4
   │  └─ 3_降噪_classic传统方案.mp4
   ├─ eval_chains.ps1          传统链/RNNoise 方案评测
   ├─ eval_dfn.ps1             DeepFilterNet 对比评测
   ├─ eval_results.csv / eval_dfn.csv   评测原始数据
   ├─ eval_in\                 测试信号（干净语音/噪声/不同信噪比混合）
   ├─ eval_out\                各方案输出（可以直接试听对比）
   └─ 素材\                    下载的真实语音与噪声素材
```

**真实素材端到端验证**（`test\对比样本\` 里那组，视频走完整管线，与干净语音的频谱偏差）：

| 输出 | 全带 | <100Hz | 100-300 | 300-3k | >5k |
|---|---|---|---|---|---|
| 原始（真实语音 + 低频风噪） | 1.7 | **14.5** | 0.1 | 0.0 | 2.6 |
| **DeepFilterNet（默认）** | 0.3 | **0.6** | 0.3 | 0.3 | **0.3** |
| classic 传统方案 | 0.0 | 1.3 | 0.5 | 0.1 | 2.5 |

## 环境说明（本机踩过的坑）

1. **ffmpeg / Python / DeepFilterNet 都在 `tools\` 下，ffmpeg 和 python 已加入用户 PATH**（新开终端生效）。
2. **本机 HTTPS/TLS 是坏的**：schannel 报 `SEC_E_NO_CREDENTIALS`，`winget`、`Invoke-WebRequest`、`curl https://` 全挂。
   绕行：用纯 HTTP 镜像，或 `node tools\fetch.js <url> <out>`（Node 自带 OpenSSL）。**GitHub 连接经常被重置**，所以 `fetch.js` 做了断点续传 + 重试 + 镜像回退——下载 DeepFilterNet 那 26MB 就是这么磨下来的。
3. **pip 直连 PyPI 基本不可用**（超时/无响应），tuna、aliyun 镜像也不通，所以 numpy 最终没装成；评测脚本因此全部用 ffmpeg 做测量，不依赖 numpy。
4. **沙箱下 `tempfile` 会失败**：`mkdtemp()` 默认以 0o700 建目录，生成的受限 ACL 让后续写入被拒。已在 `tools\python\Lib\site-packages\sitecustomize.py` 打补丁。
5. **改 `reduce-wind-noise.ps1` / `test\*.ps1` 后必须保证文件带 UTF-8 BOM**，否则 PowerShell 5.1 按 GBK 解码，中文乱码并导致语法错误：

   ```powershell
   $p = 'E:\kida\code\reduce-wind-noise.ps1'
   $c = Get-Content -LiteralPath $p -Raw -Encoding UTF8
   Set-Content -LiteralPath $p -Value $c -NoNewline -Encoding UTF8
   ```
6. 本机 PowerShell 执行策略禁止直接运行 .ps1，`降风噪.bat` 里用了 `-ExecutionPolicy Bypass`；手动跑请用
   `powershell -NoProfile -ExecutionPolicy Bypass -File .\reduce-wind-noise.ps1 ...`。

## 参考的开源项目

- [Rikorose/DeepFilterNet](https://github.com/Rikorose/DeepFilterNet) —— DeepFilterNet3，实时语音增强 SOTA，本工具用的就是它的 Windows release 二进制
- [xiph/rnnoise](https://github.com/xiph/rnnoise) —— Mozilla/Xiph 的 RNNoise 神经网络降噪
- [GregorR/rnnoise-models](https://github.com/GregorR/rnnoise-models) —— 各种社区训练的 RNNoise 模型（`sh`/`bd`/`lq`/`mp`/`cb` 来自这里）
- [ffmpeg](https://ffmpeg.org/ffmpeg-filters.html) 的 `arnndn` / `afftdn` / `anlmdn` / `adeclip` / `highpass` 滤镜
- [kenders2000/MicWindNoiseGenerator](https://github.com/kenders2000/MicWindNoiseGenerator) —— 麦克风风噪生成器（本工具合成阵风测试信号的思路来源）

## 常见问题

- **人声发闷 / 有金属感** → 换 `voice` 预设，或用 classic 时 `-Preset custom -NoiseReduction 10`。
- **风噪还剩很多** → `strong`；再不行 `-Preset custom -Highpass 180 -Declip`。
- **只想导出降噪后的音频** → 直接调 ffmpeg（classic 链）：
  ```powershell
  ffmpeg -i in.mp4 -vn -af "highpass=f=120,highpass=f=120,afftdn=nr=16:nf=-50:tn=1" -c:a aac -b:a 192k out.m4a
  ```
  或先导出 wav 再喂给 DeepFilterNet：`deep-filter -D -o out_dir audio.wav`
- **一段视频里只有部分时间有风噪** → 目前是全片统一处理，安静段落也会被神经网络过一遍；要更精细可以切片分别处理。
- **想换 RNNoise 模型** → 把 `.rnnn` 放进 `tools\models\`，然后 `-RnnoiseModel 文件名（不带扩展名）`。
