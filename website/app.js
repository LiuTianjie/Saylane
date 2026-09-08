'use strict';
const sentences = [
  ['我正在把一个小小的想法变成现实。', "I'm turning a little idea into something real.", '小さなアイデアを形にしています。', 'Je donne vie à une petite idée.'],
  ['周末一起去喝杯咖啡吧。', "Let's grab a coffee this weekend.", '週末、一緒にコーヒーを飲みましょう。', 'On prend un café ce week-end ?'],
  ['我们可以一起把它做得更好。', 'We can make it even better, together.', '一緒にもっと良くしていきましょう。', 'Ensemble, nous pouvons faire encore mieux.'],
  ['很高兴认识你', 'So nice to meet you', 'お会いできて嬉しいです', 'Ravi de vous rencontrer'],
  ['让我们试试新的可能', "Let's try something new", '新しいことに挑戦しよう', 'Essayons quelque chose de nouveau'],
  ['今天的阳光真好', 'What a beautiful day', '今日はいい天気ですね', 'Quelle belle journée'],
  ['这个想法太棒了', 'I love that idea', '素晴らしいアイデアですね', "J’adore cette idée"],
  ['保持好奇，继续探索', 'Stay curious. Keep exploring.', '好奇心を持って探求しよう', 'Restons curieux'],
  ['谢谢你一直以来的支持', 'Thanks for always being there', 'いつも支えてくれてありがとう', 'Merci pour ton soutien'],
  ['好事情正在发生', 'Good things are happening', 'いいことが起きている', 'De belles choses arrivent'],
  ['准备好出发了吗', 'Ready when you are', '準備はできましたか', 'Prêt pour le départ ?'],
  ['我有一个新的灵感', 'I have a fresh idea', '新しいアイデアがあります', 'J’ai une nouvelle idée']
];
const reduced = matchMedia('(prefers-reduced-motion: reduce)');
const output = document.querySelector('#translated');
const language = document.querySelector('#language');
let languageIndex = 1, exampleIndex = 0, typingTimer, paused = reduced.matches;
function playExample() {
  clearTimeout(typingTimer);
  document.querySelector('#source-text').textContent = sentences[exampleIndex][0];
  const text = sentences[exampleIndex][languageIndex];
  if (reduced.matches) { output.textContent = text; return; }
  output.textContent = '';
  let index = 0;
  function type() { output.textContent = text.slice(0, ++index); if (index < text.length) typingTimer = setTimeout(type, 27); }
  typingTimer = setTimeout(type, 180);
}
document.querySelectorAll('[data-example]').forEach(button => button.addEventListener('click', () => {
  exampleIndex = Number(button.dataset.example);
  document.querySelectorAll('[data-example]').forEach(b => b.setAttribute('aria-pressed', String(b === button)));
  playExample();
}));
document.querySelector('#replay').addEventListener('click', playExample);
language.addEventListener('change', () => { languageIndex = {en:1,ja:2,fr:3}[language.value]; document.querySelector('.static-flow span:last-child').textContent = sentences[3][languageIndex]; playExample(); draw(); });
const canvas = document.querySelector('#flow');
const ctx = canvas.getContext('2d');
let width = 1000, height = 340, time = 0, last = 0, frame, visible = true;
const pointer = {x:-1000,y:-1000};
const stage = document.querySelector('.flow-stage');
const toggle = document.querySelector('#motion-toggle');
function updateToggle() { toggle.textContent = paused ? '播放动效 ▷' : '暂停动效 Ⅱ'; toggle.setAttribute('aria-pressed', String(paused)); }
function schedule() { cancelAnimationFrame(frame); last = 0; if (!paused && visible && !document.hidden) frame = requestAnimationFrame(tick); }
toggle.addEventListener('click', () => { paused = !paused; updateToggle(); schedule(); });
reduced.addEventListener('change', () => { paused = reduced.matches; updateToggle(); schedule(); playExample(); });
new ResizeObserver(() => { const box = stage.getBoundingClientRect(); width = box.width; height = box.height; const dpr = Math.min(devicePixelRatio || 1, 2); canvas.width = width*dpr; canvas.height = height*dpr; ctx.setTransform(dpr,0,0,dpr,0,0); draw(); }).observe(stage);
new IntersectionObserver(entries => { visible = entries[0].isIntersecting; schedule(); }).observe(stage);
document.addEventListener('visibilitychange', schedule);
stage.addEventListener('pointermove', e => {const box = stage.getBoundingClientRect();pointer.x=e.clientX-box.left;pointer.y=e.clientY-box.top;});
stage.addEventListener('pointerleave', () => {pointer.x=-1000;pointer.y=-1000;});
function path(t, lane, side) {
  const center = width/2, half = width/2, spread = height*.42;
  const x = center + side*(52 + (half-35)*t);
  const y = height/2 + lane*spread*Math.pow(t,.67);
  return {x,y};
}
function draw() {
  ctx.clearRect(0,0,width,height);
  const small = width<650;
  // The inward curve and exponential velocity create a gravitational lens.
  for(let line=0;line<19;line++) {
    const lane=(line-9)/9;
    [-1,1].forEach(side=> {
      ctx.beginPath();for(let n=0;n<=65;n++){const p=path(n/65,lane,side);n?ctx.lineTo(p.x,p.y):ctx.moveTo(p.x,p.y);}
      const grad=ctx.createLinearGradient(width/2,0,side<0?0:width,0);
      grad.addColorStop(0,'rgba(237,145,77,.33)');grad.addColorStop(.6,'rgba(201,173,129,.09)');grad.addColorStop(1,'rgba(201,173,129,0)');ctx.strokeStyle=grad;ctx.lineWidth=.7;ctx.stroke();
    });
  }
  const count=small?10:16;
  for(let i=0;i<count;i++) {
    const cycle=(time*.072+i/count)%1;
    const source=cycle<.5;
    const progress=source?cycle*2:(cycle-.5)*2;
    const distance=source?1-Math.pow(progress,2.6):Math.pow(progress,.48);
    const lane=((i*7)%count)/(count-1)*1.8-.9;
    const p=path(distance,lane,source?-1:1);
    const near=1-distance;
    const attract=Math.max(0,1-Math.hypot(pointer.x-p.x,pointer.y-p.y)/180);
    const x=p.x+(width/2-p.x)*attract*.1;
    const y=p.y+(height/2-p.y)*attract*.12;
    const alpha=Math.min(1,distance*4)*(distance>.9?(1-distance)*10:1);
    ctx.save();ctx.translate(x,y);ctx.scale(1-near*.52,1-near*.25);
    ctx.globalAlpha=alpha*(.62+(i%3)*.14);
    ctx.font=`${source?'400':'500'} ${small?11:15}px "DM Sans", "PingFang SC", sans-serif`;
    ctx.textAlign='center';ctx.textBaseline='middle';ctx.fillStyle=source?'#7c776d':'#b7784b';
    ctx.fillText(sentences[i%sentences.length][source?0:languageIndex],0,0);
    ctx.restore();
  }
  // Fast, fine particles visibly accelerate through the central translation core.
  for(let i=0;i<62;i++) {
    const p=(time*.16+i*.6180339)%1;
    const side=p<.5?-1:1;
    const d=side<0?1-Math.pow(p*2,2.8):Math.pow((p-.5)*2,.5);
    const lane=Math.sin(i*19.7)*.93;
    const point=path(d,lane,side);
    ctx.fillStyle=`rgba(225,145,76,${(1-d)*.38})`;
    ctx.beginPath();ctx.ellipse(point.x,point.y,1+(1-d)*3,.7,0,0,Math.PI*2);ctx.fill();
  }
}
function tick(now) { if(last) time+=Math.min((now-last)/1000,.05);last=now;draw();frame=requestAnimationFrame(tick); }
updateToggle();draw();schedule();
