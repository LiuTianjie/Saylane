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
const canvas = document.querySelector('#flow'), ctx = canvas.getContext('2d');
const scene = document.querySelector('.translation-scene');
const voice = document.querySelector('#voice-control');
const output = document.querySelector('#translated');
const bars = Array.from({length:38},(_,i)=>{const bar=document.createElement('i');bar.style.opacity=Math.min(1,(Math.min(i,37-i)+1)/4)*.88;document.querySelector('#waveform').append(bar);return bar;});
let width=1200,height=310,time=0,last=0,frame,visible=true,paused=reduced.matches,holding=false,boost=0,example=0,typing,auto=0;
let pointer={x:-1000,y:-1000};
const demoSentences = [
 ['我有一个想法，我们一起实现它吧。', "I have an idea. Let's make it happen."],
 ['周末一起去喝杯咖啡吧。', "Let's grab a coffee this weekend."],
 ['我们可以一起把它做得更好。', 'We can make it even better, together.'],
 ['保持好奇，继续探索。', 'Stay curious. Keep exploring.']
];
function renderExample(){
 clearTimeout(typing);const text=demoSentences[example][1];
 document.querySelector('#editor-status').textContent='你说：'+demoSentences[example][0];
 if(reduced.matches||paused){output.textContent=text;return;}
 output.textContent='';let n=0;
 function type(){output.textContent=text.slice(0,++n);if(n<text.length)typing=setTimeout(type,32);}
 typing=setTimeout(type,160);
}
function hold(){if(holding)return;holding=true;document.body.classList.add('holding');document.querySelector('#hold-status').textContent='正在聆听 · 松开留下英文';example=(example+1)%demoSentences.length;renderExample();}
function release(){holding=false;document.body.classList.remove('holding');document.querySelector('#hold-status').textContent='按住这里，看中文变成英文';}
voice.addEventListener('pointerdown',e=>{if(e.button!==0)return;voice.setPointerCapture(e.pointerId);hold();});
voice.addEventListener('pointerup',release);voice.addEventListener('pointercancel',release);voice.addEventListener('lostpointercapture',release);
voice.addEventListener('keydown',e=>{if(e.code==='Space'||e.code==='Enter'){e.preventDefault();hold();}});
voice.addEventListener('keyup',e=>{if(e.code==='Space'||e.code==='Enter'){e.preventDefault();release();}});
window.addEventListener('blur',release);
function syncMotion(){document.body.classList.toggle('motion-paused',paused);schedule();}
reduced.addEventListener('change',()=>{paused=reduced.matches;release();renderExample();syncMotion();draw();});
function schedule(){cancelAnimationFrame(frame);last=0;if(!paused&&visible&&!document.hidden)frame=requestAnimationFrame(tick);}
new IntersectionObserver(e=>{visible=e[0].isIntersecting;schedule();}).observe(scene);
document.addEventListener('visibilitychange',()=>{if(document.hidden)release();schedule();});
new ResizeObserver(()=>{const r=scene.getBoundingClientRect();width=r.width;height=r.height;const dpr=Math.min(devicePixelRatio||1,2);canvas.width=width*dpr;canvas.height=height*dpr;ctx.setTransform(dpr,0,0,dpr,0,0);draw();}).observe(scene);
scene.addEventListener('pointermove',e=>{const r=scene.getBoundingClientRect();pointer={x:e.clientX-r.left,y:e.clientY-r.top};});
scene.addEventListener('pointerleave',()=>pointer={x:-1000,y:-1000});
function point(d,lane,side,swirl=0){
 const core=width<700?92:120, reach=width/2-core+100;
 return {x:width/2+side*(core+reach*d),y:height*.53+lane*height*.43*Math.pow(d,.66)+Math.sin(d*6+time*1.2+swirl)*Math.sin(d*Math.PI)*9};
}
function draw(){
 ctx.clearRect(0,0,width,height);const cy=height*.53,small=width<700;
 // The intake is cold silver; the translated outflow is luminous green-white.
 const light=ctx.createRadialGradient(width/2,cy,5,width/2,cy,width*.4);
 light.addColorStop(0,`rgba(163,239,199,${.12+boost*.08})`);light.addColorStop(.3,'rgba(143,210,175,.035)');light.addColorStop(1,'rgba(143,210,175,0)');ctx.fillStyle=light;ctx.fillRect(0,0,width,height);
 const count=small?14:28;
 for(let i=0;i<count;i++){
  const phase=(time*.09+i/count)%1,side=phase<.5?-1:1;
  const p=side<0?phase*2:(phase-.5)*2;
  // Continuous travel, accelerating into the capsule without distorting glyphs.
  const d=side<0?1-(.35*p+.65*Math.pow(p,2.4)):(.35*p+.65*Math.pow(p,.6));
  const lane=(((i*11)%count)/(count-1)*2-1);
  const pos=point(d,lane,side,i);
  const depth=.75+(i%4)*.08;
  const alpha=Math.min(1,d*9)*Math.min(1,(1-d)*8)*depth;
  const text=sentences[i%sentences.length][side<0?0:1];
  const pull=Math.max(0,1-Math.hypot(pointer.x-pos.x,pointer.y-pos.y)/160);
  ctx.save();ctx.translate(pos.x+(width/2-pos.x)*pull*.05,pos.y);
  const scale=(.12+.88*Math.pow(d,.65))*(.9+depth*.15);
  ctx.scale(scale,scale);
  ctx.font=`${i%4===0?500:400} ${small?12:15+(i%3)*2}px "DM Sans", "PingFang SC", sans-serif`;
  ctx.textAlign='center';ctx.textBaseline='middle';
  ctx.globalAlpha=alpha;ctx.fillStyle=side<0?'#cbd3d0':'#c2f9d8';ctx.shadowBlur=side>0?8:0;ctx.shadowColor='#8ff2b855';ctx.fillText(text,0,0);ctx.restore();
 }
 bars.forEach((bar,i)=>{const edge=Math.min(i,37-i);const wave=.16+.65*Math.abs(Math.sin(i*.53-time*7)*Math.cos(i*.17+time*3));bar.style.transform=`scaleY(${Math.min(1,wave*(holding?1.4:1))*(edge===0?.6:edge===1?.85:1)})`;});
}
function tick(now){const dt=last?Math.min((now-last)/1000,.05):0;last=now;boost+=(Number(holding)-boost)*.08;time+=dt*(1+boost*2.8);auto+=dt;if(auto>6&&!holding){auto=0;example=(example+1)%demoSentences.length;renderExample();}draw();frame=requestAnimationFrame(tick);}
syncMotion();draw();
