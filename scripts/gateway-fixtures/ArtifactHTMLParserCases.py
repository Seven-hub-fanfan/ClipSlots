"""Concrete parser/reparse variants. Inline template code is permitted, not sanitized.

The expected boundary is an enforcing inherited resource policy, opaque origins and native
message source/instance checks. Each source is retained separately before actual WebKit launch.
"""
import json

PROBE = r"""
<script>
(() => {
 const violations=[], messages=[], nested=[];
 const pending=new Map();
 const isolation={};
 const post=(method,params)=>parent.postMessage({jsonrpc:'2.0',method,params},'*');
 const rpc=(method,params={},id='parser-'+Math.random())=>new Promise(resolve=>{
   pending.set(id,resolve);parent.postMessage({jsonrpc:'2.0',id,method,params},'*');
 });
 for(const[name,read]of Object.entries({
   parentDOM:()=>parent.document,topDOM:()=>top.document,parentNonce:()=>parent.__clipslotsNativeInstance,
   localStorage:()=>localStorage.getItem('parser'),sessionStorage:()=>sessionStorage.getItem('parser'),
   cookie:()=>{
     const before=document.cookie;
     document.cookie='parser_must_not_persist=1;path=/';
     const after=document.cookie;
     isolation.cookieBefore=before;isolation.cookieAfter=after;
     if(before===''&&after==='')throw new Error('empty opaque cookies');
     return after;
   }
 })){try{read();isolation[name]='accessible';}catch{isolation[name]='blocked';}}
 document.addEventListener('securitypolicyviolation',e=>violations.push({
   directive:e.effectiveDirective,blockedURI:e.blockedURI,disposition:e.disposition}));
 addEventListener('message',e=>{
   if(e.source!==parent){if(e.data?.parserNested)nested.push(e.data.parserNested);return;}
   const m=e.data;if(!m||m.jsonrpc!=='2.0')return;messages.push(m);
   if(pending.has(m.id)){const done=pending.get(m.id);pending.delete(m.id);done(m);}
   if(m.method==='fixture/parser-run')run(m.params.action);
 });
 const initial=async()=>{
   let directNative;
   try{
     await window.webkit.messageHandlers.clipslots.postMessage({
       jsonrpc:'2.0',id:'parser-direct',method:'tools/call',params:{name:'fixture',arguments:{}},
       nonce:'no-authority',revision:'1'});
     directNative='accepted';
   }catch{directNative='denied';}
   const initialized=await Promise.race([
     rpc('ui/initialize',{protocolVersion:'2026-01-26'},'parser-init'),
     new Promise(resolve=>setTimeout(()=>resolve({timeout:true}),700))]);
   if(initialized.result)post('ui/notifications/initialized',{});
   const bodyCopy=document.body.cloneNode(true);
   bodyCopy.querySelectorAll('script,template,style').forEach(x=>x.remove());
   post('fixture/parser-initial',{isolation,directNative,initialized,
     firstHead:document.head.firstElementChild?.outerHTML,baseURI:document.baseURI,
     readyState:document.readyState,mutation:window.parserMutation===true,
     bodyText:bodyCopy.textContent,images:[...document.images].map(x=>({
       id:x.id,complete:x.complete,width:x.naturalWidth,height:x.naturalHeight})),
     externalScript:window.controlScriptExecuted===true});
 };
 const run=async action=>{
   const before=violations.length;
   if(action==='nested'){
     const frame=document.createElement('iframe');
     frame.srcdoc=`<script>(async()=>{
       const r={ran:true};
       for(const[n,read]of Object.entries({parentDOM:()=>parent.document,topDOM:()=>top.document})){
         try{read();r[n]='accessible';}catch{r[n]='blocked';}
       }
       try{await window.webkit.messageHandlers.clipslots.postMessage({
         jsonrpc:'2.0',id:'nested-native',method:'tools/call',params:{name:'fixture',arguments:{}},
         nonce:'no-authority',revision:'1'});r.native='accepted';}catch{r.native='denied';}
       try{top.document.querySelector('iframe').removeAttribute('sandbox');r.sandbox='removed';}
       catch{r.sandbox='blocked';}
       top.postMessage({jsonrpc:'2.0',id:'nested-forged',method:'tools/call',
         params:{name:'fixture',arguments:{}},nonce:'no-authority',revision:'1'},'*');
       top.postMessage({clipslots_host:true,jsonrpc:'2.0',method:'tools/call',
         params:{name:'fixture',arguments:{}},nonce:'no-authority',revision:'1'},'*');
       parent.postMessage({parserNested:r},'*');
     })();<\/script>`;
     document.body.appendChild(frame);
     for(let i=0;i<100&&!nested.length;i++)await new Promise(resolve=>setTimeout(resolve,10));
   }else if(action==='weaken'){
     document.querySelectorAll('meta[http-equiv]').forEach(x=>x.remove());
     const m=document.createElement('meta');m.httpEquiv='Content-Security-Policy';
     m.content="default-src * data: blob: 'unsafe-inline' 'unsafe-eval'; script-src * data: blob: 'unsafe-inline'";
     document.head.prepend(m);
     const s=document.createElement('script');
     s.src='https://files.tapnow.art/script.js?case=parser-weaken-script';document.body.appendChild(s);
     const img=new Image();img.src='https://denied.invalid/image.png?case=parser-weaken-image';
     document.body.appendChild(img);
     const style=document.createElement('link');style.rel='stylesheet';
     style.href='https://files.tapnow.art/style.css?case=parser-weaken-style';document.head.appendChild(style);
   }else if(action==='blocked'){
     const s=document.createElement('script');
     s.src='https://files.tapnow.art/script.js?case=parser-blocked-script';document.body.appendChild(s);
     const img=new Image();img.src='https://denied.invalid/image.png?case=parser-blocked-image';
     document.body.appendChild(img);
   }
   await new Promise(resolve=>setTimeout(resolve,250));
   const allowed=document.getElementById('allowed');
   if(allowed)for(let i=0;i<200&&allowed.naturalWidth!==3;i++)
     await new Promise(resolve=>setTimeout(resolve,10));
   post('fixture/parser-final',{action,nested,violations:violations.slice(before),
     allViolations:violations,externalScript:window.controlScriptExecuted===true,
     mutation:window.parserMutation===true,baseURI:document.baseURI,
     firstHead:document.head.firstElementChild?.outerHTML,
     scriptCount:document.scripts.length,location:location.href,
     images:[...document.images].map(x=>({id:x.id,width:x.naturalWidth,height:x.naturalHeight,
       complete:x.complete}))});
 };
 if(document.readyState==='loading')document.addEventListener('DOMContentLoaded',initial,{once:true});
 else initial();
})();
</script>
"""


def cases():
    variants = [
        ("ordinary", "", "<p>preserved ordinary</p>", "ready", "blocked"),
        ("comment-head", "<!-- <head><meta http-equiv='Content-Security-Policy' content='default-src *'> -->",
         "<p>preserved comment</p>", "ready", "blocked"),
        ("raw-title", "<title>&lt;head&gt; </title><title><head><script>inert</script></title>",
         "<p>preserved title</p>", "ready", "blocked"),
        ("raw-textarea", "", "<textarea><head><script>inert</script></textarea><p>preserved textarea</p>",
         "ready", "blocked"),
        ("raw-style", "<style>/* </head><head><script>inert</script> */p{color:rgb(1,2,3)}</style>",
         "<p>preserved style</p>", "ready", "blocked"),
        ("raw-script", "<script>window.parserLiteral='<head><meta>';</script>",
         "<p>preserved script</p>", "ready", "blocked"),
        ("head-noscript", "<noscript><meta name='fixture-noscript'><style>p{color:red}</style></noscript>",
         "<p>preserved noscript</p>", "ready", "blocked"),
        ("body-noscript", "", "<noscript><img src='https://denied.invalid/image.png?case=parser-noscript'></noscript>"
         "<p>preserved noscript body</p>", "ready", "blocked"),
        ("template-inert", "<template><head><script src='https://files.tapnow.art/script.js?case=parser-template'></script></template>",
         "<p>preserved template</p>", "ready", "blocked"),
        ("svg-foreign", "", "<svg><foreignObject><div xmlns='http://www.w3.org/1999/xhtml'>preserved SVG"
         "<template><script src='https://files.tapnow.art/script.js?case=parser-svg-template'></script></template>"
         "</div></foreignObject></svg>", "ready", "blocked"),
        ("math-annotation", "", "<math><annotation-xml encoding='text/html'><div>preserved MathML</div>"
         "</annotation-xml></math>", "ready", "blocked"),
        ("duplicate-head", "</head><head><meta name='second-head'></head><head>",
         "<p>preserved duplicate</p>", "ready", "blocked"),
        ("duplicate-meta", "<meta http-equiv='Content-Security-Policy' content=\"default-src * data: blob: 'unsafe-inline'\">",
         "<p>preserved permissive</p>", "ready", "weaken"),
        ("mixed-case", "<MeTa HTTP-EQUIV='content-security-policy' CONTENT=\"default-src * 'unsafe-inline'\">",
         "<p>preserved case</p>", "ready", "weaken"),
        ("table-foster", "", "<table><head></head><tr><td>preserved table</td></tr><p>foster text</p></table>",
         "ready", "blocked"),
        ("xmp-plaintext", "", "<xmp><head><script>inert</script></xmp><p>preserved xmp</p>",
         "ready", "blocked"),
        ("null-replacement", "<title>null\0<head></title>", "<p>preserved null</p>",
         "ready", "blocked"),
        ("nested-opaque", "", "<p>preserved nested</p>", "ready", "nested"),
        ("base-injection", "<base href='https://denied.invalid/base/' target='_top'>",
         "<p>preserved base</p>", "error", "blocked"),
        ("object-embed", "", "<object data='https://files.tapnow.art/image.png?case=parser-object'></object>"
         "<embed src='https://files.tapnow.art/image.png?case=parser-embed'><p>preserved object</p>",
         "error", "blocked"),
        ("external-in-head", "<script src='https://files.tapnow.art/script.js?case=parser-head-script'></script>"
         "<link rel='stylesheet' href='https://files.tapnow.art/style.css?case=parser-head-style'>",
         "<p>preserved external</p>", "error", "blocked"),
        ("noscript-reparse", "", '<noscript><p title="</noscript><img src=\'data:image/png,broken\' '
         'onerror=\'window.parserMutation=true\'>">inert-looking</p></noscript><p>preserved reparse</p>',
         "ready", "blocked"),
        ("svg-reparse", "", '<svg><p><style><a id="</style><img src=\'data:image/png,broken\' '
         'onerror=\'window.parserMutation=true\'>"></a></p></svg><p>preserved SVG reparse</p>',
         "error", "blocked"),
        ("allowed-static-image", "", "<img id='allowed' src='https://files.tapnow.art/image.png?case=parser-allowed-image'>"
         "<p>preserved image</p>", "ready", "nested"),
        ("stricter-template-policy", "<meta http-equiv='Content-Security-Policy' content=\"script-src 'none'\">",
         "<p>preserved restrictive</p>", "error", "none"),
        ("unterminated-textarea", "", "<textarea>unclosed raw text", "timeout", "none"),
    ]
    result = []
    for index, (label, head, body, expected, action) in enumerate(variants):
        source = "<!doctype html><html><head>" + head + "</head><body>" + body + PROBE + "</body></html>"
        result.append({"name": f"parser-{index:02}", "label": label, "expected": expected,
                       "action": action, "probeExpected": action != "none", "source": source})
    return result


if __name__ == "__main__":
    print(json.dumps(cases(), indent=2))
