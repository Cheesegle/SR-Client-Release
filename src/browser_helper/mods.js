// SR Client: Krunker's own Mods window inside the helper. Installed before the
// official page's scripts. When the player presses "Load Mod", this records
// the mod's link so SR Client can load the same mod natively, then the helper
// window closes.
//
// Deliberately small (0.5's approach): only fetch and XMLHttpRequest are
// wrapped, as in 0.5, where the window closed on Load Mod. 0.6 - 0.14 also
// wrapped Blob, FileReader, Response, IndexedDB, Storage and Krunker's own
// functions; Krunker's page can refuse to load when its built-ins are
// replaced (0.14's Mods window stayed on the loading spinner), so none of
// that is done any more. The click listener below changes nothing on the
// page: it only reads the link off the Load Mod button that was clicked.
(() => {
    if (window !== window.top || location.origin !== 'https://krunker.io') return;
    if (window.__srMods) return;
    const state = window.__srMods = {state: 'WAIT_MODS', url: '', via: '', recent: [], clicks: []};
    const keep = (list, text, max) => { try { list.push(String(text).slice(0, 400)); if (list.length > max) list.shift(); } catch {} };
    // %LOCALAPPDATA%\SR-Client\mods-debug.txt (written by the helper): what
    // the page requested and what was clicked, so a missed mod can be traced.
    state.debug = () => JSON.stringify({state: state.state, via: state.via, url: state.url, clicks: state.clicks, recent: state.recent});
    const absolute = value => { try { return new URL(String(value), location.href); } catch { return null; } };
    const looksLikeMod = url => !!url && /^https?:$/.test(url.protocol) && /\.zip$/i.test(url.pathname);
    // The link goes to SR Client by WebView2's message channel (pushed, and
    // repeated until the window closes); the helper's polling stays as a backup.
    const post = () => { try { window.chrome.webview.postMessage(JSON.stringify({state: 'MOD', url: state.url})); } catch {} };
    const report = (url, via) => {
        if (state.url || !url || url.href.length > 4096) return;
        state.url = url.href;
        state.via = via;
        state.state = 'MOD';
        post();
        setInterval(post, 1000);
    };
    // A link that can be a mod: a zip, a Dropbox file or Krunker's mod storage.
    const modLike = text => /\.zip(\?|#|$)/i.test(text) || /dropbox\.com\//i.test(text) || /user-assets[^/]*\/md\d+/i.test(text);
    const fromText = (text, via) => {
        try {
            for (const link of String(text).match(/https?:\/\/[^\s'"`)<>]+/gi) || []) {
                if (modLike(link)) { report(absolute(link), via); return true; }
            }
        } catch {}
        return false;
    };

    const originalFetch = window.fetch;
    window.fetch = function(input, ...args) {
        const url = absolute(typeof input === 'string' || input instanceof URL ? input : input && input.url);
        if (url) keep(state.recent, url.href, 30);
        if (looksLikeMod(url)) report(url, 'fetch');
        const result = originalFetch.call(this, input, ...args);
        // Mod links without ".zip": report responses that are zip archives.
        Promise.resolve(result).then(response => {
            try {
                const type = (response.headers.get('content-type') || '').toLowerCase();
                if (type.includes('zip')) report(absolute(response.url), 'fetch-type');
            } catch {}
        }).catch(() => {});
        return result;
    };

    const originalOpen = XMLHttpRequest.prototype.open;
    XMLHttpRequest.prototype.open = function(method, url, ...rest) {
        const parsed = absolute(url);
        if (parsed) keep(state.recent, parsed.href, 30);
        if (looksLikeMod(parsed)) report(parsed, 'xhr');
        this.addEventListener('load', () => {
            try {
                const type = (this.getResponseHeader('content-type') || '').toLowerCase();
                if (type.includes('zip')) report(absolute(this.responseURL), 'xhr-type');
            } catch {}
        });
        return originalOpen.call(this, method, url, ...rest);
    };

    // The Load Mod button that was clicked: Krunker's mod buttons carry the
    // link in their onclick; "Load Mod" by URL reads the #modURL box.
    addEventListener('click', event => {
        try {
            const seen = [];
            let element = event.target;
            for (let depth = 0; element && depth < 8; depth++, element = element.parentElement) {
                const parts = [];
                for (const attribute of element.attributes || []) if (/^(onclick|href|data-)/i.test(attribute.name)) parts.push(attribute.name + '=' + attribute.value);
                if (!parts.length) continue;
                seen.push(element.tagName + ' ' + parts.join(' ').slice(0, 300));
                for (const part of parts) {
                    if (fromText(part, 'click')) break;
                    if (/loadModURL/i.test(part)) { const input = document.getElementById('modURL'); if (input) fromText(input.value, 'modURL'); }
                }
            }
            if (seen.length) keep(state.clicks, seen.join(' | '), 15);
        } catch {}
    }, true);

    // Open Krunker's Mods window (its palette button calls showWindow(4))
    // once the game UI exists. The player can also open it from the menu.
    // Krunker's own start-up can close it again, so it is reopened a few
    // times until the player clicks anything.
    let tries = 0, opened = 0, touched = false;
    addEventListener('pointerdown', () => { touched = true; }, true);
    const timer = setInterval(() => {
        tries += 1;
        if (touched || tries > 120 || opened >= 4) { clearInterval(timer); return; }
        if (typeof window.showWindow === 'function' && window.windows && tries % 4 === 0) {
            try { window.showWindow(4); opened += 1; } catch {}
        }
    }, 500);
})();
