import Foundation
import ClipSlotsKit

/// Native transport supplies bytes; template execution retains the source proxy's opaque frame boundary.
enum AgentArtifactTemplateHTML {
    static func literal(_ value: JSONValue) throws -> String {
        try value.encodedText().replacingOccurrences(of: "<", with: "\\u003c")
            .replacingOccurrences(of: "\u{2028}", with: "\\u2028")
            .replacingOccurrences(of: "\u{2029}", with: "\\u2029")
    }

    static func document(template: AgentArtifactPageTemplate, nonce: UUID, revision: String) throws -> String {
        let html = try literal(.string(template.source))
        let innerPolicy = AgentArtifactPageResourceLoader.cspPolicy(template.csp)
        let policy = try literal(.string(innerPolicy))
        // srcdoc inherits the embedding document's policy. The outer frame must grant the same
        // declared image/media and data/blob ranges; a stricter outer default would silently deny
        // resources that the inner policy permits. Only the native frame may mount about:srcdoc.
        let outerPolicy = innerPolicy.replacingOccurrences(of: "frame-src 'none'", with: "frame-src about:")
            .replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "\"", with: "&quot;")
        let resource = try literal(template.resourceDescription)
        // No design-token or template style injection. The extra native monitor only reports terminal
        // resource errors and trusted presentation keys; persistence stays on the page RPC channel.
        let monitor = """
        (() => {
          let expanded = false, shortcuts = false;
          const fail = () => parent.postMessage({jsonrpc:'2.0',
            method:'ui/notifications/sandbox-resource-error',params:{message:'template resource blocked or failed'}},'*');
          addEventListener('securitypolicyviolation',e=>{if(e.disposition==='enforce') fail();});
          addEventListener('error',e=>{if(e.target && e.target!==window) fail();},true);
          addEventListener('message',e=>{
            if(e.source!==parent || !e.data || e.data.jsonrpc!=='2.0') return;
            if(e.data.method==='tapnow/presentationState') expanded=e.data.params?.expanded===true;
            if(e.data.method==='ui/notifications/host-context-changed')
              expanded=e.data.params?.displayMode==='fullscreen';
          });
          shortcuts=\(template.identity.name == "previs" ? "true" : "false");
          addEventListener('keydown',e=>{
            const editable=e.composedPath().some(n=>n instanceof Element &&
              (n.matches('input,textarea,select') || n.isContentEditable || n.getAttribute('role')==='textbox'));
            if(!e.isTrusted || e.defaultPrevented || editable || e.isComposing || e.keyCode===229 ||
              e.ctrlKey || e.metaKey || e.altKey || (e.key==='Enter'&&e.repeat) || !expanded ||
              (e.key!=='Escape'&&!shortcuts) ||
              !['Escape','ArrowLeft','ArrowRight','ArrowUp','ArrowDown','Enter',' '].includes(e.key)) return;
            e.preventDefault(); parent.postMessage({clipslots_control:'presentation_key',key:e.key},'*');
          });
        })();
        """
        let monitorLiteral = try literal(.string(monitor))
        return """
        <!doctype html><html><head><meta charset="utf-8">
        <meta name="color-scheme" content="light dark">
        <meta http-equiv="Content-Security-Policy" content="\(outerPolicy)">
        <style>html,body{margin:0;height:100%;width:100%;overflow:hidden;background:transparent}
        body{display:flex;flex-direction:column}iframe{width:100%;height:100%;border:0;background:transparent;flex-grow:1}</style>
        </head><body><script>
        (() => {
          'use strict';
          const nonce='\(nonce.uuidString)', revision=\(try literal(.string(revision)));
          const bridge=window.webkit.messageHandlers.clipslots;
          const inner=document.createElement('iframe');
          inner.setAttribute('sandbox','allow-scripts');
          Object.defineProperty(window,'__clipslotsNativeInstance',{value:nonce});
          let stopped=false;
          const forward = message => {
            if(!message || message.nonce!==nonce || message.revision!==revision || !inner.contentWindow) return;
            const data={};
            for(const key of Object.keys(message))
              if(!['nonce','revision','clipslots_host'].includes(key)) data[key]=message[key];
            inner.contentWindow.postMessage(data,'*');
          };
          addEventListener('message',event=>{
            const data=event.data;
            if(!data || typeof data!=='object') return;
            if(event.source===window && data.clipslots_host===true) {
              if(data.nonce!==nonce || data.revision!==revision) return;
              if(data.method==='ui/notifications/sandbox-resource-ready') return;
              if(data.method==='ui/notifications/sandbox-resource-error') stopped=true;
              forward(data); return;
            }
            if(event.source!==inner.contentWindow || stopped) return;
            if(data.clipslots_control==='presentation_key') {
              bridge.postMessage({presentation_key:data.key,instance:nonce,revision}).catch(()=>{}); return;
            }
            if(data.jsonrpc!=='2.0' || typeof data.method!=='string') return;
            bridge.postMessage({...data,nonce,revision}).then(response=>{
              if(response) forward(response);
            }).catch(()=>{});
          });
          inner.addEventListener('load',()=>{
            if(!inner.hasAttribute('srcdoc') || stopped) return;
            bridge.postMessage({resource_loaded:\(resource),instance:nonce,revision}).catch(()=>{});
          });
          // Parsing is inert. The enforcing meta precedes the actual document's first executable script,
          // even when comments, title or textarea contain deceptive head tags.
          const doc=new DOMParser().parseFromString(\(html),'text/html');
          const csp=doc.createElement('meta');
          csp.httpEquiv='Content-Security-Policy'; csp.content=\(policy);
          const scheme=doc.createElement('meta'); scheme.name='color-scheme'; scheme.content='light dark';
          const reporter=doc.createElement('script'); reporter.textContent=\(monitorLiteral);
          doc.head.insertBefore(reporter,doc.head.firstChild);
          doc.head.insertBefore(scheme,doc.head.firstChild);
          doc.head.insertBefore(csp,doc.head.firstChild);
          inner.srcdoc='<!doctype html>'+doc.documentElement.outerHTML;
          document.body.appendChild(inner);
        })();
        </script></body></html>
        """
    }

    static func contentRules(csp: JSONValue) throws -> String {
        var rules: [[String: Any]] = ["^https?:", "^file:", "^ftp:", "^wss?:"].map {
            ["trigger": ["url-filter": $0], "action": ["type": "block"]]
        }
        for (key, type) in [("imgDomains", "image"), ("mediaDomains", "media")] {
            for domain in csp[key]?.arrayValue ?? [] {
                guard let text = domain.stringValue,
                      text.range(of: #"^https://[a-z0-9.-]+(:[0-9]+)?$"#, options: .regularExpression)
                        == text.startIndex..<text.endIndex else { continue }
                // Resource URLs serialize an origin followed by '/'. WebKit's restricted regex
                // engine has no disjunction support; the slash also prevents suffix-host matches.
                rules.append(["trigger": ["url-filter": "^" + NSRegularExpression.escapedPattern(for: text) + "/",
                                            "resource-type": [type]],
                              "action": ["type": "ignore-previous-rules"]])
            }
        }
        return String(decoding: try JSONSerialization.data(withJSONObject: rules, options: [.sortedKeys]), as: UTF8.self)
    }
}
