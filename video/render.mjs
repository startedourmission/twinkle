// 사용법: node render.mjs            → out/twinkle-intro.mp4 (1920x1080, 30fps)
//         node render.mjs shots 2 12.5 → out/shot-2.jpg, out/shot-12.5.jpg (확인용 정지 화면)
import { createRequire } from 'node:module';
import { spawn } from 'node:child_process';
import { mkdirSync } from 'node:fs';
import { fileURLToPath, pathToFileURL } from 'node:url';
import path from 'node:path';

// playwright는 전역 설치본을 씀 (없으면 npm i playwright)
const { chromium } = createRequire(import.meta.url)(process.env.PLAYWRIGHT_PATH || 'playwright');
const dir = path.dirname(fileURLToPath(import.meta.url));
const out = path.join(dir, 'out');
mkdirSync(out, { recursive: true });
const FPS = 30, WORKERS = 4;
const url = pathToFileURL(path.join(dir, 'index.html')).href + '?still';

const browser = await chromium.launch({ args: ['--allow-file-access-from-files'] });
const open = async () => {
  const page = await browser.newPage({ viewport: { width: 1920, height: 1080 }, deviceScaleFactor: 1 });
  await page.goto(url);
  await page.evaluate(() => document.fonts.ready);
  return page;
};

if (process.argv[2] === 'shots') {
  const page = await open();
  for (const t of process.argv.slice(3)) {
    await page.evaluate(t => frame(t), +t);
    await page.screenshot({ path: path.join(out, `shot-${t}.jpg`), quality: 85 });
  }
} else {
  const first = await open();
  const total = Math.round((await first.evaluate(() => DURATION)) * FPS);
  const frames = new Array(total);
  let next = 0, done = 0;
  const ff = spawn('ffmpeg', ['-y', '-loglevel', 'error', '-f', 'image2pipe', '-framerate', String(FPS), '-c:v', 'mjpeg', '-i', '-',
    '-c:v', 'libx264', '-preset', 'slow', '-crf', '17', '-pix_fmt', 'yuv420p', '-movflags', '+faststart', path.join(out, 'twinkle-intro.mp4')],
    { stdio: ['pipe', 'inherit', 'inherit'] });
  let written = 0;
  const flush = () => { while (written < total && frames[written]) { ff.stdin.write(frames[written]); frames[written] = null; written++; } };
  const work = async page => {
    while (next < total) {
      const i = next++;
      while (i - written > 200) await new Promise(r => setTimeout(r, 50)); // 메모리 보호
      await page.evaluate(t => frame(t), i / FPS);
      frames[i] = await page.screenshot({ type: 'jpeg', quality: 96 });
      flush();
      if (++done % 150 === 0) console.log(`${done}/${total}`);
    }
  };
  const pages = [first, ...await Promise.all(Array.from({ length: WORKERS - 1 }, open))];
  await Promise.all(pages.map(work));
  flush();
  ff.stdin.end();
  await new Promise(r => ff.on('close', r));
  console.log('완료: out/twinkle-intro.mp4');
}
await browser.close();
