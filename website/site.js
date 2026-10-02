'use strict';
// Everything below the hero: reveal on scroll, three small demos with preset
// text, and the download block filled in from the latest GitHub release.
(() => {
  const reduced = matchMedia('(prefers-reduced-motion: reduce)');
  const $ = id => document.getElementById(id);
  const wait = ms => new Promise(resolve => setTimeout(resolve, ms));

  // ----- Header and navigation -----
  const header = document.querySelector('.site-header');
  const onScroll = () => header.classList.toggle('scrolled', scrollY > 8);
  addEventListener('scroll', onScroll, {passive: true});
  onScroll();
  const links = new Map([...document.querySelectorAll('.nav-link[href^="#"]')].map(a => [a.getAttribute('href').slice(1), a]));
  const spy = new IntersectionObserver(entries => {
    for (const entry of entries) {
      if (!entry.isIntersecting) continue;
      links.forEach(a => a.classList.remove('current'));
      links.get(entry.target.id)?.classList.add('current');
    }
  }, {rootMargin: '-45% 0px -50% 0px'});
  links.forEach((_, id) => { const section = $(id); if (section) spy.observe(section); });

  // ----- Reveal on scroll -----
  const reveal = new IntersectionObserver(entries => {
    for (const entry of entries) {
      if (!entry.isIntersecting) continue;
      entry.target.classList.add('in');
      reveal.unobserve(entry.target);
    }
  }, {rootMargin: '0px 0px -8% 0px', threshold: .08});
  document.querySelectorAll('.reveal').forEach((element, index) => {
    // Neighbours in one row come in one after another.
    const siblings = [...element.parentElement.children].filter(child => child.classList.contains('reveal'));
    element.style.transitionDelay = `${Math.min(siblings.indexOf(element), 5) * 70}ms`;
    reveal.observe(element);
  });

  // A demo runs only while it is on screen and the page is showing; `run` gets
  // a function that says whether to go on. Returns a function that starts it over.
  function whileVisible(element, run) {
    let generation = 0, onScreen = false;
    const start = () => {
      generation += 1;
      const mine = generation;
      if (onScreen && !document.hidden) run(() => mine === generation);
    };
    new IntersectionObserver(entries => { onScreen = entries[0].isIntersecting; start(); }, {threshold: .35}).observe(element);
    document.addEventListener('visibilitychange', start);
    return start;
  }

  // ----- Dictation: live words, then the final text -----
  const live = '我想把周五的会改到下午三点然后在裙里通知一下大家';
  const final = [['我想把周五的会改到下午'], ['3', true], ['点'], ['，', true], ['然后在'], ['群', true], ['里通知一下大家'], ['。', true]];
  const text = $('dictation-text'), state = $('dictation-state'), dot = $('dictation-dot');
  function showFinal() {
    text.replaceChildren(...final.map(([piece, changed]) => {
      const span = document.createElement('span');
      span.textContent = piece;
      if (changed && !reduced.matches) span.className = 'changed';
      return span;
    }));
    state.textContent = '已写入输入框';
    dot.className = 'demo-dot done';
  }
  async function dictate(alive) {
    if (reduced.matches) { showFinal(); return; }
    while (alive()) {
      text.replaceChildren();
      state.textContent = '正在听 · 字随着声音出现';
      dot.className = 'demo-dot live';
      const span = document.createElement('span');
      span.className = 'live';
      text.append(span);
      await wait(500);
      // A few characters about every quarter of a second, the way the preview arrives.
      for (let shown = 0; shown < live.length && alive();) {
        shown = Math.min(live.length, shown + 2 + Math.floor(Math.random() * 3));
        span.textContent = live.slice(0, shown);
        await wait(260);
      }
      if (!alive()) return;
      state.textContent = '松手 · 本地模型写终稿';
      await wait(380);
      if (!alive()) return;
      showFinal();
      await wait(6500);
    }
  }
  const replay = whileVisible($('dictation-demo'), dictate);
  $('dictation-replay').addEventListener('click', replay);

  // ----- Translating what is on screen: select a region, read it in place -----
  const shot = $('shot'), tabs = [...document.querySelectorAll('#shot-tabs button')];
  const scenes = tabs.map(tab => tab.dataset.scene);
  const directions = {web: '英 → 中', app: '英 → 中', board: '日 → 中', video: '英 → 中'};
  let scene = 0;
  function showScene(index) {
    scene = index;
    // Back to the untouched picture at once, without the transitions running backwards.
    shot.classList.add('reset');
    shot.classList.remove('selecting', 'working', 'translated');
    shot.dataset.scene = scenes[index];
    $('shot-direction').textContent = directions[scenes[index]];
    tabs.forEach((tab, i) => tab.setAttribute('aria-pressed', String(i === index)));
    void shot.offsetWidth;
    shot.classList.remove('reset');
  }
  async function translateScreen(alive) {
    if (reduced.matches) { shot.classList.add('selecting', 'translated'); return; }
    while (alive()) {
      showScene(scene);
      await wait(700);
      if (!alive()) return;
      shot.classList.add('selecting');
      await wait(1150);
      if (!alive()) return;
      shot.classList.replace('selecting', 'working');
      await wait(520);
      if (!alive()) return;
      shot.classList.replace('working', 'translated');
      await wait(3400);
      if (!alive()) return;
      scene = (scene + 1) % scenes.length;
    }
  }
  const restartShot = whileVisible(shot, translateScreen);
  tabs.forEach((tab, index) => tab.addEventListener('click', () => { scene = index; restartShot(); }));

  // ----- Pinyin: a composition and its candidates -----
  const composing = $('pinyin-composing'), candidates = $('pinyin-candidates');
  const committed = composing.previousElementSibling;
  const stages = [
    ['san', ['三', '散', '伞', '山', '叁']],
    ['san dian', ['三点', '散点', '三', '散', '伞']],
    ['san dian kai', ['三点开', '三点', '散', '三', '伞']],
    ['san dian kai hui', ['三点开会', '三点', '散', '三', '伞']]
  ];
  function showCandidates(words) {
    candidates.replaceChildren(...words.map((word, index) => {
      const item = document.createElement('li'), number = document.createElement('i');
      if (index === 0) item.className = 'on';
      number.textContent = index + 1;
      item.append(number, word);
      return item;
    }));
  }
  async function type(alive) {
    if (reduced.matches) return;
    while (alive()) {
      committed.textContent = '今天下午';
      candidates.style.visibility = 'visible';
      for (const [letters, words] of stages) {
        const from = composing.textContent.length < letters.length && letters.startsWith(composing.textContent) ? composing.textContent.length : 0;
        for (let n = from + 1; n <= letters.length && alive(); n++) {
          composing.textContent = letters.slice(0, n);
          if (n === letters.length) showCandidates(words);
          await wait(letters[n - 1] === ' ' ? 60 : 110);
        }
        await wait(420);
      }
      if (!alive()) return;
      await wait(900);
      committed.textContent = '今天下午三点开会';
      composing.textContent = '';
      candidates.style.visibility = 'hidden';
      await wait(2600);
    }
  }
  whileVisible(candidates.parentElement, type);

  // ----- Download: the latest published release -----
  async function latestRelease() {
    const cached = sessionStorage.getItem('saylane-release');
    if (cached) return JSON.parse(cached);
    const response = await fetch('https://api.github.com/repos/LiuTianjie/Saylane/releases/latest', {headers: {Accept: 'application/vnd.github+json'}});
    if (!response.ok) throw new Error(String(response.status));
    const release = await response.json();
    const pkg = (release.assets || []).find(asset => asset.name.endsWith('.pkg'));
    const info = {tag: release.tag_name, page: release.html_url, url: pkg?.browser_download_url, size: pkg?.size};
    sessionStorage.setItem('saylane-release', JSON.stringify(info));
    return info;
  }
  latestRelease().then(info => {
    if (!/^v?\d/.test(info.tag || '')) return;
    $('release-version').textContent = info.tag.startsWith('v') ? info.tag : `v${info.tag}`;
    if (info.page) $('release-notes').href = info.page;
    // Only a file on GitHub's own release host becomes the button's target.
    if (info.url?.startsWith('https://github.com/LiuTianjie/Saylane/releases/download/')) $('download-button').href = info.url;
    if (info.size) {
      const size = $('release-size'), separator = document.createElement('span');
      separator.className = 'sep'; separator.textContent = '·';
      size.replaceChildren(separator, `${(info.size / 1048576).toFixed(1)} MB`);
    }
  }).catch(() => { /* The links already lead to the releases page. */ });
})();
