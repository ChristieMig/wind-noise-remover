#!/usr/bin/env node
/**
 * 简易 HTTP(S) 下载器（带断点续传 / 重试 / 镜像回退）
 *
 * 为什么需要它：本机系统 schannel 的 TLS 是坏的（SEC_E_NO_CREDENTIALS），
 * PowerShell / curl / winget 都上不了 HTTPS，但 Node 自带 OpenSSL 正常。
 * 另外访问 GitHub 时连接经常被重置，所以这里做三重保险：
 *   1) 断点续传：失败后从已下载的字节数继续（Range 请求）
 *   2) 重试：每个地址默认试 3 次，递增退避
 *   3) 镜像回退：raw.githubusercontent / github releases 自动尝试 jsDelivr 等镜像
 *
 * 用法:
 *   node fetch.js <url> <输出文件> [--retries 3] [--no-mirror]
 */
const fs = require('fs');
const https = require('https');
const http = require('http');

const UA = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) fetch.js';

// ---------------------------------------------------------------- 参数
const argv = process.argv.slice(2);
const positional = [];
let retries = 3;
let useMirror = true;
for (let i = 0; i < argv.length; i++) {
  const a = argv[i];
  if (a === '--retries') retries = Number(argv[++i]) || 3;
  else if (a === '--no-mirror') useMirror = false;
  else positional.push(a);
}
const [url, out] = positional;
if (!url || !out) {
  console.error('用法: node fetch.js <url> <输出文件> [--retries 3] [--no-mirror]');
  process.exit(2);
}

// ---------------------------------------------------------------- 镜像推导
function mirrorsFor(u) {
  const list = [];
  let m = u.match(/^https:\/\/raw\.githubusercontent\.com\/([^/]+)\/([^/]+)\/([^/]+)\/(.+)$/);
  if (m) {
    const [, owner, repo, ref, p] = m;
    list.push(`https://cdn.jsdelivr.net/gh/${owner}/${repo}@${ref}/${p}`);
    list.push(`https://raw.gitmirror.com/${owner}/${repo}/${ref}/${p}`);
    list.push(`https://ghproxy.net/${u}`);
    list.push(`https://ghfast.top/${u}`);
  }
  if (/^https:\/\/github\.com\/.+\/releases\/download\//.test(u)) {
    list.push(`https://ghproxy.net/${u}`);
    list.push(`https://ghfast.top/${u}`);
    list.push(`https://gh-proxy.com/${u}`);
  }
  if (/^https:\/\/github\.com\/([^/]+)\/([^/]+)\/raw\//.test(u)) {
    list.push(u.replace('https://github.com/', 'https://raw.gitmirror.com/').replace('/raw/', '/'));
  }
  return list;
}

// ---------------------------------------------------------------- 单次请求
function request(u, headers) {
  return new Promise((resolve, reject) => {
    const mod = u.startsWith('https:') ? https : http;
    const req = mod.get(u, { headers: { 'User-Agent': UA, ...headers } }, (res) => resolve({ res, req }));
    req.on('error', reject);
    req.setTimeout(60000, () => req.destroy(new Error('连接超时')));
  });
}

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const fmt = (mb) => `${mb.toFixed(1)} MB`;

/** 从 start 字节开始下载到 out（追加）。返回 {complete, size} */
async function downloadOnce(u, out, start) {
  const headers = start > 0 ? { Range: `bytes=${start}-` } : {};
  const { res } = await request(u, headers);
  const code = res.statusCode;

  if (code >= 300 && code < 400 && res.headers.location) {
    res.resume();
    return downloadOnce(new URL(res.headers.location, u).toString(), out, start);
  }
  if (code === 416) {  // 已经下完了
    res.resume();
    return { complete: true, size: start };
  }
  if (code !== 200 && code !== 206) {
    res.resume();
    throw new Error(`HTTP ${code}`);
  }

  const append = code === 206 && start > 0;
  if (!append && start > 0) start = 0;  // 服务器不支持续传，只能重来
  const len = res.headers['content-length'] ? Number(res.headers['content-length']) : 0;
  const total = len ? len + start : 0;

  await new Promise((resolve, reject) => {
    const ws = fs.createWriteStream(out, { flags: append ? 'a' : 'w' });
    let got = start;
    let lastPct = -1;
    res.on('data', (c) => {
      got += c.length;
      if (total) {
        const pct = Math.floor((got / total) * 100);
        if (pct !== lastPct && pct % 10 === 0) {
          lastPct = pct;
          process.stderr.write(`  ${pct}%\r`);
        }
      }
    });
    res.on('error', (e) => { ws.destroy(); reject(e); });
    ws.on('error', reject);
    ws.on('finish', () => ws.close(() => resolve()));
    res.pipe(ws);
  });

  const size = fs.statSync(out).size;
  const complete = total ? size >= total : true;  // 没有 content-length 时，连接正常结束即视为完成
  return { complete, size };
}

// ---------------------------------------------------------------- 主流程
(async () => {
  const targets = [url, ...(useMirror ? mirrorsFor(url) : [])];
  let lastErr = null;

  for (let t = 0; t < targets.length; t++) {
    const target = targets[t];
    const label = t === 0 ? '' : ` [镜像${t}: ${new URL(target).host}]`;

    for (let attempt = 1; attempt <= retries; attempt++) {
      const start = fs.existsSync(out) ? fs.statSync(out).size : 0;
      try {
        const r = await downloadOnce(target, out, start);
        if (r.complete) {
          if (t > 0 || attempt > 1) process.stderr.write('\n');
          console.log(`完成: ${out} (${fmt(r.size / 1048576)})`);
          process.exit(0);
        }
        process.stderr.write(`\n  未下完(${fmt(r.size / 1048576)})，续传重试 ${attempt}/${retries}${label}\n`);
        await sleep(500 * attempt);
      } catch (e) {
        lastErr = e;
        process.stderr.write(`\n  出错: ${e.message}，重试 ${attempt}/${retries}${label}\n`);
        await sleep(800 * attempt);
      }
    }
  }

  console.error(`下载失败: ${url}\n  最后错误: ${lastErr ? lastErr.message : '未知'}`);
  console.error(`  已下载部分保留在 ${out}，再次运行可续传`);
  process.exit(1);
})();
