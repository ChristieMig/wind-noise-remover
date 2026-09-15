/**
 * 让 Node 在证书被中间人拦截 / 缺根证书的环境里也能正常访问 HTTPS。
 *
 * 症状：报错 "unable to verify the first certificate"（或 UNABLE_TO_GET_ISSUER_CERT_LOCALLY）。
 * 原因：Node 只信任自带的 CA 列表，而某些环境（企业代理、抓包软件、安全软件）用的是
 *       系统证书库里的私有根证书，于是校验失败。
 * 做法：把系统 CA 和 Node 自带 CA 合并后设为默认信任列表。
 *       官方等价做法是启动时加 --use-system-ca，但那个参数在旧版 Node 上会直接报错，
 *       所以这里用 API 在运行时修复，不能用了就静默跳过（老版本 Node 请自行加 --use-system-ca）。
 *
 * 在入口脚本顶部 require 一次即可：
 *   require('./system-ca.js');   // 必须在发起 https 请求之前
 */
try {
  const tls = require('tls');
  if (typeof tls.getCACertificates === 'function' && typeof tls.setDefaultCACertificates === 'function') {
    const list = [];
    try { list.push(...tls.getCACertificates('default')); } catch { /* 忽略 */ }
    try { list.push(...tls.getCACertificates('system')); } catch { /* 忽略 */ }
    if (list.length) tls.setDefaultCACertificates(list);
  }
} catch {
  /* 老版本 Node 没有这些 API：忽略，必要时用 NODE_OPTIONS=--use-system-ca */
}
