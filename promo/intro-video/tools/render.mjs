// Deterministic frame renderer: drives index.html's renderAt(t) in headless Edge
// and pipes JPEG frames into ffmpeg.
//
//   node render.mjs --stills 1,4.5,10 --outdir ../stills
//   node render.mjs --video ../BooruPlus-intro.mp4 --fps 60 [--from 0 --to 48.6]
import { spawn } from 'node:child_process';
import { mkdirSync, writeFileSync } from 'node:fs';
import path from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';
import puppeteer from 'puppeteer-core';

const here = path.dirname(fileURLToPath(import.meta.url));
const args = Object.fromEntries(process.argv.slice(2).reduce((acc, a, i, arr) => {
  if (a.startsWith('--')) acc.push([a.slice(2), arr[i + 1] && !arr[i + 1].startsWith('--') ? arr[i + 1] : true]);
  return acc;
}, []));
const EDGE = process.env.EDGE_PATH || 'C:/Program Files (x86)/Microsoft/Edge/Application/msedge.exe';
const page_url = pathToFileURL(path.join(here, '..', 'index.html')).href + '?render=1';

const browser = await puppeteer.launch({
  executablePath: EDGE,
  headless: true,
  args: ['--allow-file-access-from-files', '--hide-scrollbars', '--force-color-profile=srgb', '--disable-gpu-vsync', '--mute-audio'],
  defaultViewport: { width: 1920, height: 1080, deviceScaleFactor: 1 },
});
const page = await browser.newPage();
page.on('console', m => console.log('[page]', m.text()));
let pageFailed = null;
page.on('pageerror', e => { console.error('[page error]', e.message); pageFailed ??= e; });
await page.goto(page_url, { waitUntil: 'networkidle0', timeout: 120000 });
await page.waitForFunction('window.READY === true', { timeout: 120000 });
const duration = await page.evaluate('window.DURATION');

async function frame(t, type = 'jpeg') {
  await page.evaluate(tt => window.renderAt(tt), t);
  return page.screenshot(type === 'png' ? { type: 'png' } : { type: 'jpeg', quality: 96, optimizeForSpeed: true });
}

if (args.stills) {
  const out = path.resolve(here, args.outdir || '../stills');
  mkdirSync(out, { recursive: true });
  for (const s of String(args.stills).split(',')) {
    const t = +s;
    writeFileSync(path.join(out, `t${t.toFixed(2).padStart(6, '0')}.png`), await frame(t, 'png'));
  }
  console.log('stills written to', out);
} else {
  const fps = +(args.fps || 60);
  const from = +(args.from || 0), to = +(args.to || duration);
  const outFile = path.resolve(here, args.video || '../BooruPlus-intro.mp4');
  const ff = spawn('ffmpeg', ['-y', '-f', 'image2pipe', '-framerate', String(fps), '-c:v', 'mjpeg', '-i', '-',
    // Browser JPEGs are full-range BT.601; deliver standard limited-range BT.709.
    '-vf', 'scale=in_range=full:out_range=tv:in_color_matrix=bt601:out_color_matrix=bt709,format=yuv420p',
    '-colorspace', 'bt709', '-color_primaries', 'bt709', '-color_trc', 'bt709', '-color_range', 'tv',
    '-c:v', 'libx264', '-preset', 'slow', '-crf', '15', '-movflags', '+faststart',
    '-r', String(fps), outFile], { stdio: ['pipe', 'inherit', 'inherit'] });
  let ffFailed = null;
  const ffDone = new Promise(r => ff.on('close', code => { if (code !== 0) ffFailed ??= new Error(`ffmpeg exited with ${code}`); r(); }));
  ff.on('error', e => { ffFailed ??= e; });
  ff.stdin.on('error', e => { ffFailed ??= e; });
  const total = Math.round((to - from) * fps);
  const t0 = Date.now();
  for (let i = 0; i < total && !ffFailed && !pageFailed; i++) {
    const buf = await frame(from + i / fps);
    if (!ff.stdin.write(buf)) await Promise.race([new Promise(r => ff.stdin.once('drain', r)), ffDone]);
    if (i % 120 === 0) console.log(`frame ${i}/${total}  ${((Date.now() - t0) / 1000).toFixed(0)}s`);
  }
  ff.stdin.end();
  await ffDone;
  if (ffFailed || pageFailed) { console.error('render failed:', (ffFailed || pageFailed).message); await browser.close(); process.exit(1); }
  console.log('video written to', outFile);
}
await browser.close();
