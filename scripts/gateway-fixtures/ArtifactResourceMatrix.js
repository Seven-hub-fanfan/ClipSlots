// Executed by the real opaque iframe after SDK initialization. Results use the fixture observer,
// independently of the native bridge, so a native terminal error cannot hide later CSP evidence.
(() => {
  const violations = [];
  const nestedReports = [], nestedWindows = new Set();
  const nestedHTML = `<script>
    (async()=>{
      const r={tag:'srcdoc',ran:true};
      for(const[name,read]of Object.entries({parentDOM:()=>parent.document,topDOM:()=>top.document})){
        try{read();r[name]='accessible';}catch{r[name]='blocked';}
      }
      try{
        await window.webkit.messageHandlers.clipslots.postMessage({
          jsonrpc:'2.0',id:'nested',method:'ping',params:{},nonce:'no-authority',revision:'1'});
        r.native='accepted';
      }catch{r.native='denied';}
      parent.postMessage({matrixNested:r},'*');
    })();
  <\/script>`;
  addEventListener('securitypolicyviolation', e => violations.push({
    directive: e.effectiveDirective, blockedURI: e.blockedURI, disposition: e.disposition
  }));
  const pause = ms => new Promise(resolve => setTimeout(resolve, ms));
  const dataURL = (type, bytes) => `data:${type};base64,${bytes}`;
  const blobURL = (type, bytes) => URL.createObjectURL(new Blob(
    [Uint8Array.from(atob(bytes), c => c.charCodeAt(0))], {type}));
  async function element(kind, url) {
    const node = document.createElement(kind === 'style' ? 'link' : kind);
    if (kind === 'style') { node.rel = 'stylesheet'; node.href = url; }
    else if (kind === 'object') { node.data = url; node.type = 'image/png'; }
    else if (kind === 'iframe' && url === 'srcdoc') {
      node.srcdoc = nestedHTML;
    } else node.src = url;
    if (kind === 'audio' || kind === 'video') node.preload = 'auto';
    const result = await new Promise(resolve => {
      let settled = false;
      const done = outcome => {
        if (settled) return;
        settled = true; clearTimeout(timer);
        document.removeEventListener('securitypolicyviolation', blocked);
        resolve({outcome, width: node.naturalWidth ?? node.videoWidth ?? null,
          height: node.naturalHeight ?? node.videoHeight ?? null,
          duration: Number.isFinite(node.duration) ? node.duration : null,
          readyState: node.readyState ?? null});
      };
      const blocked = e => { if(e.disposition==='enforce') done('csp-blocked'); };
      const timer = setTimeout(() => done('timeout'), 1200);
      document.addEventListener('securitypolicyviolation', blocked);
      node.addEventListener(kind === 'audio' || kind === 'video' ? 'loadeddata' : 'load',
        () => done('loaded'), {once:true});
      node.addEventListener('error', () => done('error'), {once:true});
      document.body.appendChild(node);
      if (kind === 'iframe') nestedWindows.add(node.contentWindow);
      if (kind === 'audio' || kind === 'video') node.load();
    });
    if (url === 'srcdoc') {
      for (let i=0;i<50&&!nestedReports.some(r=>r.tag==='srcdoc');i++) await pause(10);
      result.nested=nestedReports.find(r=>r.tag==='srcdoc')??null;
    }
    node.remove();
    if (kind === 'audio' || kind === 'video') { node.pause(); node.removeAttribute('src'); node.load(); }
    return result;
  }
  async function run(config) {
    const img = 'https://files.tapnow.art', media = 'https://files.tapnow.media';
    const png = dataURL('image/png', config.png), wav = dataURL('audio/wav', config.wav);
    const blobPNG = blobURL('image/png', config.png), blobWAV = blobURL('audio/wav', config.wav);
    const blobMP4 = blobURL('video/mp4', config.mp4);
    const blobScript = blobURL('text/javascript', btoa('window.matrixExternalScriptExecuted=true'));
    const blobCSS = blobURL('text/css', btoa('#matrix-style{color:rgb(9,8,7)}'));
    const blobFrame = blobURL('text/html', btoa(nestedHTML.replace("'srcdoc'","'blob'")));
    const results = [];
    const add = async (name, expected, operation) => {
      const start = violations.length;
      let detail;
      try { detail = await operation(); } catch (e) { detail = {outcome:'exception', error:String(e)}; }
      await pause(20);
      results.push({name, expected, ...detail, violations:violations.slice(start)});
    };
    await add('inline-script', 'allowed', async () => {
      const s = document.createElement('script'); s.textContent = 'window.matrixInlineExecuted=true';
      document.body.appendChild(s); s.remove();
      return {outcome:window.matrixInlineExecuted ? 'executed' : 'missing'};
    });
    await add('inline-style', 'allowed', async () => {
      const p = document.createElement('p'); p.id='matrix-style'; p.style.color='rgb(1, 2, 3)';
      document.body.appendChild(p);
      return {outcome:getComputedStyle(p).color};
    });
    await add('data-image', 'allowed', () => element('img', png));
    await add('blob-image', 'allowed', () => element('img', blobPNG));
    await add('https-image', 'allowed', () => element('img', img+'/image.png?case=https-image'));
    await add('https-audio', 'allowed', () => element('audio', media+'/audio.wav?case=https-audio'));
    await add('https-video', 'allowed', () => element('video', media+'/video.mp4?case=https-video'));
    await add('blob-audio', 'allowed', () => element('audio', blobWAV));
    await add('blob-video', 'allowed', () => element('video', blobMP4));
    await add('data-font', 'allowed', async () => {
      const face = new FontFace('matrix-data', `url(${dataURL('font/ttf',config.font)})`);
      await face.load(); document.fonts.add(face); return {outcome:face.status};
    });
    const specs = [
      ['undeclared-image','img','https://denied.invalid/image.png'],
      ['suffix-host-image','img','https://files.tapnow.art.denied.invalid/image.png'],
      ['wrong-port-image','img',img+':444/image.png'],
      ['http-image','img','http://files.tapnow.art/image.png'],
      ['media-domain-image','img',media+'/image.png'],
      ['image-domain-audio','audio',img+'/audio.wav'],
      ['image-domain-video','video',img+'/video.mp4'],
      ['data-audio','audio',wav],
      ['https-script','script',img+'/script.js'],
      ['data-script','script','data:text/javascript,window.matrixExternalScriptExecuted=true'],
      ['blob-script','script',blobScript],
      ['https-style','style',img+'/style.css'],
      ['data-style','style','data:text/css,%23matrix-style%7Bcolor%3Argb(9%2C8%2C7)%7D'],
      ['blob-style','style',blobCSS],
      ['https-frame','iframe',img+'/frame.html'],
      ['srcdoc-frame','iframe','srcdoc'],
      ['data-frame','iframe',dataURL('text/html',btoa(nestedHTML.replace("'srcdoc'","'data'")))],
      ['blob-frame','iframe',blobFrame],
      ['https-object','object',img+'/image.png'],
      ['data-object','object',png],
      ['file-image','img','file:///fixture-denied.png'],
      ['redirect-image','img',img+'/redirect.png']
    ];
    for (const [name, kind, url] of specs) {
      const expected=name==='srcdoc-frame'?'inherited-sandbox':
        name==='file-image'?'host-blocked':'blocked';
      await add(name,expected,() => element(kind,url+(url.startsWith('https:')||url.startsWith('http:')?'?case='+name:'')));
    }
    for (const [name,url] of [
      ['https-fetch',img+'/data.json?case=https-fetch'],
      ['media-fetch',media+'/data.json?case=media-fetch'],
      ['data-fetch','data:application/json,%7B%7D'],
      ['blob-fetch',blobPNG]]) {
      await add(name,'blocked',async () => {
        try { await fetch(url); return {outcome:'unexpected-response'}; }
        catch { return {outcome:'rejected'}; }
      });
    }
    await add('xhr','blocked',() => new Promise(resolve => {
      const x = new XMLHttpRequest(); x.open('GET',img+'/data.json?case=xhr');
      x.onload=()=>resolve({outcome:'unexpected-response'}); x.onerror=()=>resolve({outcome:'rejected'});
      x.timeout=1000; x.ontimeout=()=>resolve({outcome:'timeout'}); x.send();
    }));
    await add('websocket','blocked',() => new Promise(resolve => {
      const socket = new WebSocket('wss://files.tapnow.art/socket?case=websocket');
      socket.onopen=()=>{socket.close();resolve({outcome:'unexpected-open'});};
      socket.onerror=()=>resolve({outcome:'rejected'});
      setTimeout(()=>{socket.close();resolve({outcome:'timeout'});},1000);
    }));
    await add('worker','blocked',async () => {
      try { const w=new Worker(blobScript); w.terminate(); return {outcome:'constructed'}; }
      catch { return {outcome:'rejected'}; }
    });
    await add('css-import','blocked',async () => {
      const s=document.createElement('style');
      s.textContent=`@import url('${img}/style.css?case=css-import');`;
      document.head.appendChild(s); await pause(100); s.remove(); return {outcome:'observed'};
    });
    await add('https-font','blocked',async () => {
      const face=new FontFace('matrix-remote',`url(${img}/font.ttf?case=https-font)`);
      try { await face.load(); return {outcome:face.status}; }
      catch { return {outcome:'rejected'}; }
    });
    await add('base-uri','blocked',async () => {
      const b=document.createElement('base'); b.href=img+'/base/';
      document.head.prepend(b); await pause(50);
      const result={outcome:'observed',baseURI:document.baseURI}; b.remove(); return result;
    });
    await add('form','sandbox-blocked',async () => {
      const f=document.createElement('form'); f.action=img+'/submit?case=form'; f.method='POST';
      document.body.appendChild(f); f.submit(); await pause(100); f.remove();
      return {outcome:'observed',location:location.href};
    });
    await add('remote-404','resource-error',() => element('img',img+'/missing.png?case=remote-404'));
    for (const url of [blobPNG,blobWAV,blobMP4,blobScript,blobCSS,blobFrame]) URL.revokeObjectURL(url);
    parent.postMessage({jsonrpc:'2.0',method:'fixture/resource-matrix',
      params:{results,externalScriptExecuted:window.matrixExternalScriptExecuted===true,
        nestedReports,style:getComputedStyle(document.getElementById('matrix-style')).color}},'*');
  }
  addEventListener('message',e=>{
    if(e.source!==parent || e.data?.method!=='fixture/resources') return;
    run(e.data.params).catch(error=>parent.postMessage({jsonrpc:'2.0',method:'fixture/resource-matrix',
      params:{error:String(error)}},'*'));
  });
  addEventListener('message',e=>{
    if(nestedWindows.has(e.source)&&e.data?.matrixNested) nestedReports.push(e.data.matrixNested);
  });
})();
