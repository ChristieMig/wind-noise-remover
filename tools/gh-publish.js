#!/usr/bin/env node
/**
 * 把本工具发布到 GitHub（不依赖 git，直接调 REST API）
 *
 * 为什么不用 git：这台机器上没装 git，而且系统 schannel 的 TLS 是坏的，
 * 只有 Node 自带的 OpenSSL 能正常访问 GitHub。
 *
 * 用法:
 *   node tools/gh-publish.js --repo <仓库名> [选项]
 *
 * 选项:
 *   --repo <name>        仓库名（必填），不存在会自动创建
 *   --owner <user>       仓库归属，默认取 token 对应的账号
 *   --private            建成私有仓库（默认公开）
 *   --token-file <path>  从文件读 token（推荐，避免 token 出现在命令行历史里）
 *   --root <dir>         本地根目录，默认脚本所在目录的上一级
 *   --branch <name>      分支，默认 main
 *   --dry-run            只打印要上传哪些文件，不真的上传
 *   --desc <text>        仓库描述
 *
 * token 权限：classic token 勾 repo；fine-grained token 需要 Contents: Read and write
 *           + Administration: Read and write（建仓库用）
 */
const fs = require('fs');
const path = require('path');
const https = require('https');

// ---------------------------------------------------------------- 参数
const argv = process.argv.slice(2);
const opt = { private: false, branch: 'main', dryRun: false };
for (let i = 0; i < argv.length; i++) {
  const a = argv[i];
  if (a === '--repo') opt.repo = argv[++i];
  else if (a === '--owner') opt.owner = argv[++i];
  else if (a === '--private') opt.private = true;
  else if (a === '--token-file') opt.tokenFile = argv[++i];
  else if (a === '--root') opt.root = argv[++i];
  else if (a === '--branch') opt.branch = argv[++i];
  else if (a === '--desc') opt.desc = argv[++i];
  else if (a === '--dry-run') opt.dryRun = true;
  else if (a === '-h' || a === '--help') { console.log(fs.readFileSync(__filename, 'utf8').split('*/')[0]); process.exit(0); }
}
if (!opt.repo) { console.error('缺少 --repo <仓库名>'); process.exit(2); }

const root = path.resolve(opt.root || path.join(__dirname, '..'));
const scriptDir = path.join(root, 'tools');

// ---------------------------------------------------------------- 要上传的文件
// 只传源码和文档；二进制依赖(ffmpeg/DeepFilterNet/Python)、模型、测试素材、成片都不进仓库
const FILE_LIST = [
  'README.md',
  'reduce-wind-noise.ps1',
  'reduce_wind_noise.py',
  '降风噪.bat',
  'setup.ps1',
  '.gitignore',
  'tools/fetch.js',
  'tools/gh-publish.js',
  'test/eval_chains.ps1',
  'test/eval_dfn.ps1',
];

function readToken() {
  if (opt.tokenFile) {
    const p = path.resolve(opt.tokenFile);
    if (!fs.existsSync(p)) { console.error(`找不到 token 文件: ${p}`); process.exit(2); }
    return fs.readFileSync(p, 'utf8').trim();
  }
  if (process.env.GITHUB_TOKEN) return process.env.GITHUB_TOKEN.trim();
  console.error('没有 token。用 --token-file <文件> 或设置环境变量 GITHUB_TOKEN。');
  process.exit(2);
}

// ---------------------------------------------------------------- HTTP
function api(method, apiPath, token, body) {
  return new Promise((resolve, reject) => {
    const data = body ? JSON.stringify(body) : null;
    const req = https.request({
      host: 'api.github.com',
      path: apiPath,
      method,
      headers: {
        'User-Agent': 'wind-noise-remover-publisher',
        Accept: 'application/vnd.github+json',
        Authorization: `Bearer ${token}`,
        'X-GitHub-Api-Version': '2022-11-28',
        ...(data ? { 'Content-Type': 'application/json', 'Content-Length': Buffer.byteLength(data) } : {}),
      },
    }, (res) => {
      let d = '';
      res.on('data', (c) => (d += c));
      res.on('end', () => {
        let json = null;
        try { json = d ? JSON.parse(d) : null; } catch { /* 非 JSON */ }
        resolve({ status: res.statusCode, json, raw: d });
      });
    });
    req.on('error', reject);
    req.setTimeout(60000, () => req.destroy(new Error('请求超时')));
    if (data) req.write(data);
    req.end();
  });
}

(async () => {
  const token = readToken();

  // 1) 确认身份
  const me = await api('GET', '/user', token);
  if (me.status !== 200) {
    console.error(`token 无效或权限不足（HTTP ${me.status}）${me.json && me.json.message ? ': ' + me.json.message : ''}`);
    process.exit(1);
  }
  const owner = opt.owner || me.json.login;
  console.log(`账号: ${me.json.login}${owner !== me.json.login ? `（上传到 ${owner}）` : ''}`);
  console.log(`仓库: ${owner}/${opt.repo}  分支: ${opt.branch}  ${opt.private ? '私有' : '公开'}`);

  // 2) 没有就创建
  const explicitBranch = argv.includes('--branch');
  let branch = opt.branch;
  const repoResp = await api('GET', `/repos/${owner}/${opt.repo}`, token);
  if (repoResp.status === 404) {
    if (opt.dryRun) { console.log(`[DryRun] 会创建仓库 ${owner}/${opt.repo}`); }
    else {
      const createPath = owner === me.json.login ? '/user/repos' : `/orgs/${owner}/repos`;
      const cr = await api('POST', createPath, token, {
        name: opt.repo,
        description: opt.desc || '视频降风噪：画面不动，只重编码音频（DeepFilterNet / RNNoise / 传统 DSP 三种引擎）',
        private: opt.private,
        auto_init: true,   // 带一个初始 README，这样 main 分支一开始就存在
      });
      if (cr.status !== 201) {
        console.error(`创建仓库失败（HTTP ${cr.status}）${cr.json && cr.json.message ? ': ' + cr.json.message : ''}`);
        if (cr.status === 403) console.error('  → fine-grained token 需要 Administration: Read and write 权限');
        process.exit(1);
      }
      console.log(`已创建仓库: ${cr.json.html_url}`);
      if (!explicitBranch && cr.json.default_branch) branch = cr.json.default_branch;
    }
  } else if (repoResp.status === 200) {
    console.log('仓库已存在，将更新其中的文件');
    // 有些账号默认分支是 master，跟随仓库实际设置，避免上传到不存在的分支
    if (!explicitBranch && repoResp.json && repoResp.json.default_branch) branch = repoResp.json.default_branch;
  } else {
    console.error(`读取仓库失败（HTTP ${repoResp.status}）${repoResp.json && repoResp.json.message ? ': ' + repoResp.json.message : ''}`);
    process.exit(1);
  }
  console.log(`分支: ${branch}`);

  // 3) 逐个文件上传
  let ok = 0, skip = 0, fail = 0;
  for (const rel of FILE_LIST) {
    const abs = path.join(root, rel);
    if (!fs.existsSync(abs)) { console.log(`  跳过(本地没有): ${rel}`); skip++; continue; }
    const content = fs.readFileSync(abs);
    const encPath = rel.split('/').map(encodeURIComponent).join('/');
    if (opt.dryRun) { console.log(`  [DryRun] 上传 ${rel} (${content.length} 字节)`); continue; }

    // 已存在则要先拿 sha 才能更新
    let sha;
    const ex = await api('GET', `/repos/${owner}/${opt.repo}/contents/${encPath}?ref=${branch}`, token);
    if (ex.status === 200 && ex.json && ex.json.sha) sha = ex.json.sha;

    const body = {
      message: sha ? `更新 ${rel}` : `添加 ${rel}`,
      content: content.toString('base64'),
      branch: branch,
    };
    if (sha) body.sha = sha;

    const up = await api('PUT', `/repos/${owner}/${opt.repo}/contents/${encPath}`, token, body);
    if (up.status === 200 || up.status === 201) { console.log(`  ✓ ${rel}`); ok++; }
    else {
      console.error(`  ✗ ${rel} (HTTP ${up.status}) ${up.json && up.json.message ? up.json.message : ''}`);
      fail++;
    }
  }

  console.log(`\n完成: 成功 ${ok}，跳过 ${skip}，失败 ${fail}`);
  if (!opt.dryRun) console.log(`仓库地址: https://github.com/${owner}/${opt.repo}`);
  process.exit(fail ? 1 : 0);
})().catch((e) => { console.error('出错:', e.message); process.exit(1); });
