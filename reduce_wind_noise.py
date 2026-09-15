#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
视频降风噪（Python 版）—— 功能与 reduce-wind-noise.ps1 一致。

用 ffmpeg 对视频音轨做风噪抑制：画面直接复制（不重编码、无画质损失），只重编码音频。

降风噪处理链（针对风的两个特征：低频轰隆 + 宽带沙沙/噗噗声）：
  1. highpass ×2  两级高通(24dB/oct)，砍掉风的低频能量（风噪主要集中在 200Hz 以下）
  2. afftdn       频域降噪，tn=1 让噪声底自动跟踪（风忽大忽小，必须跟踪）
  3. anlmdn       非局部均值降噪，压掉残留宽带沙沙声
  4. 可选 adeclip 修复被风冲击削平的波形

用法：
  python reduce_wind_noise.py 视频.mp4
  python reduce_wind_noise.py 视频.mp4 --preset strong
  python reduce_wind_noise.py *.mp4 --outdir out --preset voice
  python reduce_wind_noise.py 视频.mp4 --preset custom --highpass 160 --noise-reduction 30 --declip
"""

import argparse
import json
import os
import shutil
import subprocess
import sys
import time

# ---------------------------------------------------------------- 控制台输出
def _init_console():
    """让中文在 Windows 控制台正常显示（把控制台代码页切到 UTF-8）。"""
    if os.name == "nt":
        try:
            import ctypes
            ctypes.windll.kernel32.SetConsoleOutputCP(65001)
        except Exception:
            pass
    try:
        sys.stdout.reconfigure(encoding="utf-8", errors="replace")
        sys.stderr.reconfigure(encoding="utf-8", errors="replace")
    except Exception:
        pass


def _vt_enabled():
    """只有真的在能解析 ANSI 的终端里才上色；重定向/管道时输出纯文本。"""
    if not sys.stdout.isatty():
        return False
    if os.name != "nt":
        return True
    try:
        import ctypes
        k = ctypes.windll.kernel32
        handle = k.GetStdHandle(-11)  # STD_OUTPUT_HANDLE
        mode = ctypes.c_uint32()
        if not k.GetConsoleMode(handle, ctypes.byref(mode)):
            return False
        return bool(k.SetConsoleMode(handle, mode.value | 0x0004))  # ENABLE_VIRTUAL_TERMINAL_PROCESSING
    except Exception:
        return False


_init_console()
USE_COLOR = _vt_enabled()


def _c(code, msg):
    return ("\033[%sm%s\033[0m" % (code, msg)) if USE_COLOR else msg


def step(msg):
    print(_c(36, "==> %s" % msg), flush=True)


def ok(msg):
    print("    " + _c(32, msg), flush=True)


def warn(msg):
    print("    " + _c(33, msg), flush=True)


def err(msg):
    print("    " + _c(31, msg), flush=True)


def dim(msg):
    print("    " + _c(90, msg), flush=True)


# ---------------------------------------------------------------- 找 ffmpeg
def resolve_ffmpeg(explicit=None, script_dir=None):
    script_dir = script_dir or os.path.dirname(os.path.abspath(__file__))
    candidates = []
    if explicit:
        candidates.append(explicit)
    # 1) 本工具自带的
    candidates.append(os.path.join(script_dir, "tools", "ffmpeg", "bin", "ffmpeg.exe"))
    candidates.append(os.path.join(script_dir, "ffmpeg", "bin", "ffmpeg.exe"))
    # 2) PATH 里的
    found = shutil.which("ffmpeg")
    if found:
        candidates.append(found)
    # 3) 系统里已知存在的（本机预装软件自带的构建）
    local = os.environ.get("LOCALAPPDATA", "")
    pf = os.environ.get("ProgramFiles", "")
    candidates += [
        os.path.join(local, "oopz", "ffmpeg.exe"),
        os.path.join(pf, "ffmpeg", "bin", "ffmpeg.exe"),
        r"E:\kida\JianyingPro\11.4.2.14459\ffmpeg.exe",
    ]
    for c in candidates:
        if c and os.path.isfile(c):
            return os.path.abspath(c)

    # 4) 常见目录里搜一下
    for root in [local, pf, os.environ.get("ProgramFiles(x86)", "")]:
        if not root or not os.path.isdir(root):
            continue
        for base, _dirs, files in os.walk(root):
            if base.count(os.sep) - root.count(os.sep) > 3:
                _dirs[:] = []
                continue
            if "ffmpeg.exe" in files:
                return os.path.join(base, "ffmpeg.exe")
    return None


def resolve_ffprobe(ffmpeg_path, script_dir=None):
    script_dir = script_dir or os.path.dirname(os.path.abspath(__file__))
    for p in (
        os.path.join(os.path.dirname(ffmpeg_path), "ffprobe.exe"),
        os.path.join(script_dir, "tools", "ffmpeg", "bin", "ffprobe.exe"),
    ):
        if os.path.isfile(p):
            return p
    return shutil.which("ffprobe")


def filter_path(p):
    """把 Windows 路径转成能塞进 ffmpeg 滤镜表达式里的形式（盘符冒号必须转义）。"""
    return p.replace("\\", "/").replace(":", "\\:")


def resolve_rnnoise_model(name_or_path, script_dir=None):
    """给模型名就从 tools/models 里找，给路径就直接用。"""
    if not name_or_path:
        return None
    script_dir = script_dir or os.path.dirname(os.path.abspath(__file__))
    if os.path.isfile(name_or_path):
        return os.path.abspath(name_or_path)
    for c in (
        os.path.join(script_dir, "tools", "models", name_or_path + ".rnnn"),
        os.path.join(script_dir, "tools", "models", name_or_path),
        os.path.join(script_dir, "models", name_or_path + ".rnnn"),
    ):
        if os.path.isfile(c):
            return os.path.abspath(c)
    return None


def resolve_deepfilter(explicit=None, script_dir=None):
    script_dir = script_dir or os.path.dirname(os.path.abspath(__file__))
    cands = []
    if explicit:
        cands.append(explicit)
    cands.append(os.path.join(script_dir, "tools", "deepfilternet", "deep-filter.exe"))
    cands.append(os.path.join(script_dir, "deep-filter.exe"))
    found = shutil.which("deep-filter")
    if found:
        cands.append(found)
    for c in cands:
        if c and os.path.isfile(c):
            return os.path.abspath(c)
    return None


# ---------------------------------------------------------------- 探测输入
def probe(path, ffmpeg_path, ffprobe_path=None):
    info = {"has_audio": False, "duration": 0.0, "acodec": "", "channels": 0, "sample_rate": 0}

    if ffprobe_path:
        try:
            out = subprocess.run(
                [ffprobe_path, "-v", "quiet", "-print_format", "json", "-show_format", "-show_streams", path],
                capture_output=True, text=True, encoding="utf-8", errors="replace",
            ).stdout
            obj = json.loads(out)
            info["duration"] = float(obj.get("format", {}).get("duration", 0) or 0)
            audio = next((s for s in obj.get("streams", []) if s.get("codec_type") == "audio"), None)
            if audio:
                info["has_audio"] = True
                info["acodec"] = audio.get("codec_name", "")
                info["channels"] = int(audio.get("channels", 0) or 0)
                info["sample_rate"] = int(audio.get("sample_rate", 0) or 0)
            if info["has_audio"] or info["duration"]:
                return info
        except Exception:
            pass

    # 没有 ffprobe 就解析 ffmpeg -i 的输出
    try:
        res = subprocess.run([ffmpeg_path, "-hide_banner", "-i", path],
                             capture_output=True, text=True, encoding="utf-8", errors="replace")
        text = (res.stderr or "") + (res.stdout or "")
        import re
        m = re.search(r"Duration:\s*(\d+):(\d+):(\d+\.\d+)", text)
        if m:
            info["duration"] = int(m.group(1)) * 3600 + int(m.group(2)) * 60 + float(m.group(3))
        m = re.search(r"Stream #\d+:\d+.*?: Audio: ([a-zA-Z0-9_]+).*?(\d+) Hz, (\w[\w(). ]*)", text)
        if m:
            info["has_audio"] = True
            info["acodec"] = m.group(1)
            info["sample_rate"] = int(m.group(2))
            layout = m.group(3)
            info["channels"] = {"mono": 1, "stereo": 2}.get(layout.strip(), 2)
    except Exception:
        pass
    return info


# ---------------------------------------------------------------- 滤镜链
PRESETS = {
    # 高通频率 / 降噪量 / 噪声底 / 增益平滑 / 低通 / anlmdn
    "light": dict(hp=80, nr=10, nf=-55, gs=0, lp=0, anlmdn=""),
    "medium": dict(hp=120, nr=16, nf=-50, gs=4, lp=0, anlmdn="s=0.0002:p=0.002:r=0.006:m=11"),
    "strong": dict(hp=150, nr=24, nf=-45, gs=8, lp=15000, anlmdn="s=0.0006:p=0.002:r=0.006:m=13"),
    "voice": dict(hp=90, nr=18, nf=-50, gs=6, lp=0, anlmdn="s=0.0004:p=0.002:r=0.008:m=13"),
    "custom": dict(hp=120, nr=16, nf=-50, gs=4, lp=0, anlmdn=""),
}


def build_filter(preset, highpass=0, noise_reduction=0, declip=False, normalize=False, extra="",
                 engine="classic", model_path=None, mix=1.0):
    cfg = dict(PRESETS[preset])

    # RNNoise 是"人声优先"的模型：它自己就会压掉大部分噪声，不需要再叠那么狠的传统降噪
    if engine == "rnnoise":
        cfg.update({
            "light": dict(hp=60, anlmdn=""),
            "medium": dict(hp=80, anlmdn=""),
            "strong": dict(hp=100, anlmdn="", lp=0),
            "voice": dict(hp=60, anlmdn=""),
            "custom": dict(hp=80),
        }[preset])

    if highpass and highpass > 0:
        cfg["hp"] = highpass
    if noise_reduction and noise_reduction > 0:
        cfg["nr"] = noise_reduction

    chain = []
    # 0) 削波修复
    if declip:
        chain.append("adeclip")
    # 1) 高通 ×2 = 24dB/oct
    if cfg["hp"] > 0:
        chain.append("highpass=f=%d:poles=2" % int(cfg["hp"]))
        chain.append("highpass=f=%d:poles=2" % int(cfg["hp"]))
    # 2) 核心降噪
    if engine == "rnnoise":
        # 模型路径里的冒号必须转义，否则会被 ffmpeg 滤镜语法当成选项分隔符
        # mix<1 时输出是"原声 + 降噪声"的混合，用于无人声素材保住内容
        rn = "arnndn=model='%s'" % filter_path(model_path)
        if mix < 1.0:
            rn += ":mix=%s" % mix
        chain.append(rn)
    else:
        # 频域降噪 + 噪声底跟踪（tn=1：风忽大忽小，必须跟踪）
        chain.append("afftdn=nr=%s:nf=%s:tn=1:gs=%s" % (cfg["nr"], cfg["nf"], cfg["gs"]))
    # 3) 非局部均值降噪
    if cfg["anlmdn"]:
        chain.append("anlmdn=%s" % cfg["anlmdn"])
    # 4) 低通
    if cfg["lp"] > 0:
        chain.append("lowpass=f=%d" % int(cfg["lp"]))
    # 5) 响度归一化
    if normalize:
        chain.append("dynaudnorm=f=250:g=5:p=0.9")
    # 6) 用户追加
    if extra:
        chain.append(extra.strip(","))
    return ",".join(chain)


# ---------------------------------------------------------------- 主流程
def main():
    ap = argparse.ArgumentParser(
        description="视频降风噪：只重编码音频，视频画面直接复制。",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="示例:\n"
               "  python reduce_wind_noise.py 视频.mp4\n"
               "  python reduce_wind_noise.py 视频.mp4 --preset strong\n"
               "  python reduce_wind_noise.py *.mp4 --outdir out --preset voice\n",
    )
    ap.add_argument("path", nargs="+", help="输入视频，可多个")
    ap.add_argument("--preset", choices=list(PRESETS), default="medium",
                    help="强度预设：light/medium/strong/voice/custom（默认 medium）")
    ap.add_argument("--outdir", default=None, help="输出目录，默认与源文件同目录")
    ap.add_argument("--suffix", default="_nowind", help="输出文件名后缀（默认 _nowind）")
    ap.add_argument("--container", choices=["same", "mp4", "mkv", "mov"], default="same",
                    help="输出封装格式（默认 same：与源文件相同）")
    ap.add_argument("--bitrate", type=int, default=192, help="音频码率 kbps（默认 192）")
    ap.add_argument("--highpass", type=float, default=0, help="覆盖预设的高通频率 Hz（70~180 常用）")
    ap.add_argument("--noise-reduction", type=float, default=0, help="覆盖预设的降噪强度（0.01~97）")
    ap.add_argument("--extra", default="", help='追加自定义滤镜，如 "loudnorm=I=-16:TP=-1.5"')
    ap.add_argument("--declip", action="store_true", help="先做削波修复（风的冲击常削平波形）")
    ap.add_argument("--normalize", action="store_true", help="结尾加动态响度归一化")
    ap.add_argument("--force", action="store_true", help="输出已存在时覆盖")
    ap.add_argument("--dry-run", action="store_true", help="只打印命令，不处理")
    ap.add_argument("--engine", choices=["auto", "deepfilter", "rnnoise", "classic"], default="auto",
                    help="降噪引擎：auto(默认，有 DeepFilterNet 就用它)/deepfilter/rnnoise/classic")
    ap.add_argument("--rnnoise-model", default="sh",
                    help="RNNoise 模型名或路径（tools/models 下有 sh/bd/lq/mp/cb，默认 sh）")
    ap.add_argument("--rnnoise-mix", type=float, default=1.0,
                    help="0~1，RNNoise 降噪强度（默认 1=完全降噪）；无人声素材调小可保住内容")
    ap.add_argument("--atten-limit", type=int, default=100,
                    help="DeepFilterNet 衰减上限 dB（默认 100=不限制）；无人声素材调小可保住内容")
    ap.add_argument("--deepfilter", default=None, help="手动指定 deep-filter.exe 路径")
    ap.add_argument("--ffmpeg", default=None, help="手动指定 ffmpeg 路径")
    args = ap.parse_args()

    script_dir = os.path.dirname(os.path.abspath(__file__))

    ffmpeg_path = resolve_ffmpeg(args.ffmpeg, script_dir)
    if not ffmpeg_path:
        err("找不到 ffmpeg.exe。")
        print("   解决办法（任选一个）：")
        print("     1) 把 ffmpeg.exe 放到 tools/ffmpeg/bin/ 下")
        print('     2) 用参数指定：--ffmpeg "C:\\path\\to\\ffmpeg.exe"')
        print("     3) 装完加入 PATH：winget install Gyan.FFmpeg")
        return 1
    ffprobe_path = resolve_ffprobe(ffmpeg_path, script_dir)

    model_path = resolve_rnnoise_model(args.rnnoise_model, script_dir)
    deepfilter_path = resolve_deepfilter(args.deepfilter, script_dir)

    engine = args.engine
    if engine == "auto":
        engine = "deepfilter" if deepfilter_path else ("rnnoise" if model_path else "classic")
    elif engine == "deepfilter" and not deepfilter_path:
        warn("找不到 deep-filter.exe，退回 %s。" % ("rnnoise" if model_path else "classic"))
        engine = "rnnoise" if model_path else "classic"
    elif engine == "rnnoise" and not model_path:
        warn("找不到 RNNoise 模型 '%s'，退回 classic。" % args.rnnoise_model)
        engine = "classic"

    files = []
    for p in args.path:
        if os.path.isfile(p):
            files.append(os.path.abspath(p))
        else:
            import glob
            hit = [os.path.abspath(f) for f in glob.glob(p) if os.path.isfile(f)]
            if hit:
                files.extend(hit)
            else:
                err("跳过（找不到文件）：%s" % p)
    if not files:
        err("没有可处理的视频文件。")
        return 1

    flt = build_filter(args.preset, args.highpass, args.noise_reduction,
                       args.declip, args.normalize, args.extra, engine, model_path, args.rnnoise_mix)

    # DeepFilterNet 走独立程序，这条链只是它的"前置处理"（削波修复 + 高通）
    dfn_pre = ""
    if engine == "deepfilter":
        pre = []
        if args.declip:
            pre.append("adeclip")
        hpf = {"light": 60, "medium": 80, "strong": 100, "voice": 60, "custom": 80}[args.preset]
        if args.highpass and args.highpass > 0:
            hpf = int(args.highpass)
        if hpf > 0:
            pre.append("highpass=f=%d:poles=2" % hpf)
            pre.append("highpass=f=%d:poles=2" % hpf)
        if args.normalize:
            pre.append("dynaudnorm=f=250:g=5:p=0.9")
        if args.extra:
            pre.append(args.extra.strip(","))
        dfn_pre = ",".join(pre)

    print()
    print("视频降风噪")
    dim("  ffmpeg : %s" % ffmpeg_path)
    dim("  预设   : %s" % args.preset)
    dim("  引擎   : %s%s" % (engine, "" if engine == args.engine else " (请求 %s)" % args.engine))
    if engine == "rnnoise":
        dim("  模型   : %s" % model_path)
    if engine == "deepfilter":
        dim("  DFN    : %s" % deepfilter_path)
        dim("  前置   : %s" % (dfn_pre or "(无)"))
    else:
        dim("  滤镜   : %s" % flt)
    dim("  待处理 : %d 个文件" % len(files))
    print()

    ok_count = fail_count = skip_count = dry_count = 0
    for index, in_file in enumerate(files, 1):
        name = os.path.basename(in_file)
        step("[%d/%d] %s" % (index, len(files), name))

        info = probe(in_file, ffmpeg_path, ffprobe_path)
        if not info["has_audio"]:
            err("这个文件没有音轨，跳过。")
            fail_count += 1
            continue

        ext = (os.path.splitext(in_file)[1].lstrip(".") if args.container == "same" else args.container) or "mp4"
        out_dir = args.outdir or os.path.dirname(in_file)
        if args.outdir:
            os.makedirs(args.outdir, exist_ok=True)
            out_dir = os.path.abspath(args.outdir)
        base = os.path.splitext(os.path.basename(in_file))[0]
        out_file = os.path.join(out_dir, "%s%s.%s" % (base, args.suffix, ext))

        if os.path.exists(out_file) and not args.force:
            warn("已存在，跳过（加 --force 可覆盖）：%s" % os.path.basename(out_file))
            skip_count += 1
            continue
        if os.path.abspath(out_file) == os.path.abspath(in_file):
            err("输出会和输入同名，请改 --suffix 或 --outdir。")
            fail_count += 1
            continue

        dur = time.strftime("%M:%S", time.gmtime(info["duration"]))
        dim("    音轨 %s / %dHz / %d声道，时长 %s" % (info["acodec"], info["sample_rate"], info["channels"], dur))

        cmd = [
            ffmpeg_path, "-hide_banner", "-nostdin", "-loglevel", "warning", "-stats", "-y",
            "-i", in_file,
            "-map", "0:v?", "-map", "0:a:0",
            "-c:v", "copy",
            "-af", flt,
            "-c:a", "aac", "-b:a", "%dk" % args.bitrate,
            "-map_metadata", "0",
        ]
        # 字幕：mkv 能装各种字幕，mp4/mov 就不带了，免得封装报错
        if ext == "mkv":
            cmd += ["-map", "0:s?", "-c:s", "copy"]
        if ext in ("mp4", "mov"):
            cmd += ["-movflags", "+faststart"]
        cmd.append(out_file)

        # DeepFilterNet 只吃音频，要先抽出来处理再合回视频，所以命令不一样
        dfn_cmds = None
        if engine == "deepfilter":
            ch = info["channels"] or 2
            if ch > 2:
                warn("音源是 %d 声道，DeepFilterNet 只支持单/双声道，已降为立体声。" % ch)
                ch = 2
            tmp = os.path.join(script_dir, "tools", "tmp")
            os.makedirs(tmp, exist_ok=True)
            pre_wav = os.path.join(tmp, "dfn_in_%s.wav" % os.getpid())
            dfn_dir = os.path.join(tmp, "dfn_%s" % os.getpid())

            extract = [ffmpeg_path, "-hide_banner", "-nostdin", "-loglevel", "warning", "-y",
                       "-i", in_file, "-vn", "-ar", "48000", "-ac", str(ch)]
            if dfn_pre:
                extract += ["-af", dfn_pre]
            extract += ["-c:a", "pcm_s16le", pre_wav]

            dfn = [deepfilter_path, "-D", "-o", dfn_dir]
            # -a 限制最大衰减量(dB)：无人声素材调小可保住内容
            if args.atten_limit < 100:
                dfn += ["-a", str(args.atten_limit)]
            dfn.append(pre_wav)

            mux = [ffmpeg_path, "-hide_banner", "-nostdin", "-loglevel", "warning", "-stats", "-y",
                   "-i", in_file, "-i", "(降噪后.wav)",
                   "-map", "0:v?", "-map", "1:a:0", "-c:v", "copy",
                   "-c:a", "aac", "-b:a", "%dk" % args.bitrate, "-map_metadata", "0"]
            if ext == "mkv":
                mux += ["-map", "0:s?", "-c:s", "copy"]
            if ext in ("mp4", "mov"):
                mux += ["-movflags", "+faststart"]
            mux.append(out_file)
            dfn_cmds = (extract, dfn, mux, pre_wav, dfn_dir)

        if args.dry_run:
            if dfn_cmds:
                extract, dfn, mux, _p, _d = dfn_cmds
                for tag, c in (("1) 抽音频+前置", extract), ("2) 神经网络降噪", dfn), ("3) 合回视频", mux)):
                    print("    " + _c(33, "[DryRun] %s: %s" % (
                        tag, " ".join('"%s"' % x if " " in x else x for x in c))))
            else:
                print("    " + _c(33, "[DryRun] %s" % " ".join(
                    '"%s"' % c if " " in c else c for c in cmd)))
            dry_count += 1
            continue

        t0 = time.time()
        if dfn_cmds:
            extract, dfn, mux, pre_wav, dfn_dir = dfn_cmds
            os.makedirs(dfn_dir, exist_ok=True)
            code = subprocess.run(extract).returncode
            enhanced = None
            if code == 0:
                code = subprocess.run(dfn).returncode
                if code == 0:
                    wavs = [os.path.join(dfn_dir, f) for f in os.listdir(dfn_dir) if f.lower().endswith(".wav")]
                    enhanced = wavs[0] if wavs else None
                    if enhanced is None:
                        code = 1
            if code == 0:
                mux[mux.index("(降噪后.wav)")] = enhanced
                code = subprocess.run(mux).returncode
            for p in (pre_wav,):
                try:
                    os.remove(p)
                except OSError:
                    pass
            shutil.rmtree(dfn_dir, ignore_errors=True)
        else:
            code = subprocess.run(cmd).returncode
        elapsed = time.time() - t0

        if code == 0 and os.path.exists(out_file):
            ok_count += 1
            ok("完成 -> %s" % out_file)
            dim("    %.1fMB -> %.1fMB，耗时 %.1fs" % (
                os.path.getsize(in_file) / 1048576,
                os.path.getsize(out_file) / 1048576, elapsed))
        else:
            fail_count += 1
            err("%s 处理失败（退出码 %s）" % (engine, code))

    print()
    if ok_count:
        print(_c(32, "成功 %d 个" % ok_count))
    if skip_count:
        print(_c(33, "跳过 %d 个（已存在）" % skip_count))
    if dry_count:
        print(_c(33, "预演 %d 个（未实际处理）" % dry_count))
    if fail_count:
        print(_c(31, "失败 %d 个" % fail_count))
    return 0 if (ok_count or skip_count or dry_count) else 1


if __name__ == "__main__":
    sys.exit(main())
