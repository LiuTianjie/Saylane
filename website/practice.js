'use strict';
(() => {
  // Mirrors TranslationDirection.voiceModes: A→A, A→B, B→A, B→B.
  const chinese='我想试试用英语表达自己的想法。';
  const english="I'd like to try expressing my ideas in English.";
  const modes=[
    {title:'中文听写',sourceLabel:'你说 · 中文',targetLabel:'输入框 · 中文',source:chinese,target:chinese},
    {title:'中译英',sourceLabel:'你说 · 中文',targetLabel:'输入框 · English',source:chinese,target:english},
    {title:'英译中',sourceLabel:'你说 · English',targetLabel:'输入框 · 中文',source:english,target:chinese},
    {title:'英文听写',sourceLabel:'你说 · English',targetLabel:'输入框 · English',source:english,target:english}
  ];
  let current=1;
  const buttons=[...document.querySelectorAll('[data-mode]')];
  const key=document.querySelector('#practice-key');
  const result=document.querySelector('#practice-target');
  const reduceMotion=matchMedia('(prefers-reduced-motion: reduce)');
  let animation;
  function select(index){
    current=index;const mode=modes[index];
    buttons.forEach((button,i)=>button.setAttribute('aria-pressed',String(i===index)));
    for(const [id,value] of Object.entries({
      'practice-mode-title':mode.title,'practice-source-label':mode.sourceLabel,
      'practice-target-label':mode.targetLabel,'practice-source':mode.source,
      'practice-target':mode.target
    })) document.getElementById(id).textContent=value;
    animation?.cancel();
    if(!reduceMotion.matches) animation=result.animate([{opacity:.25,transform:'translateY(5px)'},{opacity:1,transform:'translateY(0)'}],{duration:220,easing:'ease-out'});
  }
  buttons.forEach(button=>button.addEventListener('click',()=>select(Number(button.dataset.mode))));
  key.addEventListener('dblclick',()=>select((current+1)%modes.length));
  // Keyboard/assistive activation is a single click with detail=0.
  key.addEventListener('click',event=>{if(event.detail===0)select((current+1)%modes.length);});
  reduceMotion.addEventListener('change',()=>animation?.cancel());
})();
