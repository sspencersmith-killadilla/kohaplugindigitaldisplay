(function () {
    'use strict';
    const boot = JSON.parse(document.getElementById('screen-boot').textContent);
    const screen = document.getElementById('screen');
    const status = document.getElementById('screen-status');
    const clocks = [];
    let suspended = false;
    document.title = boot.name + (boot.preview ? ' — draft preview' : '');
    if (boot.preview) status.textContent = 'Private draft preview';
    function fit() {
        const scale = Math.min(window.innerWidth / boot.layout.width, window.innerHeight / boot.layout.height);
        screen.style.width = boot.layout.width + 'px';
        screen.style.height = boot.layout.height + 'px';
        screen.style.left = (window.innerWidth - boot.layout.width * scale) / 2 + 'px';
        screen.style.top = (window.innerHeight - boot.layout.height * scale) / 2 + 'px';
        screen.style.transform = 'scale(' + scale + ')';
    }
    screen.style.background = boot.layout.background;
    for (const region of boot.layout.regions) {
        const node = document.createElement('section');
        node.className = 'screen-region';
        node.setAttribute('aria-label', region.type + ' section');
        Object.assign(node.style, {
            left: region.x + '%', top: region.y + '%', width: region.w + '%', height: region.h + '%',
            background: region.background, color: region.color, fontSize: region.font_size + 'px'
        });
        screen.appendChild(node);
        if (region.type === 'text') {
            node.classList.add('screen-text');
            node.textContent = region.text;
        } else if (region.type === 'clock') {
            node.classList.add('screen-clock');
            clocks.push(() => {
                const options = { timeZone: region.timezone, hour12: region.hour12 };
                if (region.clock_format !== 'time') Object.assign(options, { weekday: 'long', year: 'numeric', month: 'long', day: 'numeric' });
                if (region.clock_format !== 'date') Object.assign(options, { hour: '2-digit', minute: '2-digit', second: '2-digit' });
                try { node.textContent = new Intl.DateTimeFormat(undefined, options).format(new Date()); }
                catch (_) { node.textContent = 'Invalid timezone: ' + region.timezone; }
            });
        } else {
            const frame = document.createElement('iframe');
            frame.title = region.type + ' section';
            frame.referrerPolicy = 'no-referrer';
            if (region.type === 'playlist') {
                // Generated only by the trusted player template, never staff code.
                frame.srcdoc = region.player_html;
                frame.allow = 'autoplay; fullscreen';
            } else if (region.type === 'code') {
                frame.setAttribute('sandbox', 'allow-scripts');
                // No same-origin, forms, popups, downloads, nested frames or external resources.
                // This policy precedes user content and cannot be relaxed by a later meta tag.
                const policy = "default-src 'none'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; img-src data:; connect-src 'none'; frame-src 'none'; media-src 'none'; object-src 'none'; base-uri 'none'; form-action 'none'";
                const snippet = '<!doctype html><meta charset="utf-8"><meta http-equiv="Content-Security-Policy" content="' + policy + '">' +
                    '<meta name="referrer" content="no-referrer"><style>html,body{margin:0;color:white;background:transparent}' +
                    region.css + '</style>' + region.html + '<script>' +
                    region.js.replace(/<\/script/gi, '<\\/script') + '<' + '/script>';
                // A second, non-user-controlled frame policy also blocks self-navigation
                // of the code document to HTTP(S), not just fetches and subresources.
                let binary = '';
                for (const byte of new TextEncoder().encode(snippet)) binary += String.fromCharCode(byte);
                const wrapperPolicy = policy.replace("frame-src 'none'", 'frame-src data:');
                frame.srcdoc = '<!doctype html><meta charset="utf-8"><meta http-equiv="Content-Security-Policy" content="' +
                    wrapperPolicy + '"><style>html,body,iframe{margin:0;width:100%;height:100%;border:0;overflow:hidden}</style>' +
                    '<iframe title="Isolated custom content" sandbox="allow-scripts" referrerpolicy="no-referrer" src="data:text/html;base64,' +
                    btoa(binary) + '"></iframe>';
            } else {
                // Opaque sandbox also protects against a remote site redirecting to Koha.
                frame.setAttribute('sandbox', region.type === 'youtube' || region.type === 'vimeo'
                    ? 'allow-scripts allow-same-origin' : 'allow-scripts');
                frame.allow = 'autoplay; fullscreen; picture-in-picture';
                frame.src = region.embed_url;
            }
            node.appendChild(frame);
        }
    }
    function updateClocks() { if (!suspended) clocks.forEach(update => update()); }
    updateClocks();
    setInterval(updateClocks, 1000);
    fit();
    window.addEventListener('resize', fit);
    document.getElementById('screen-fullscreen').addEventListener('click', () => {
        if (document.fullscreenElement) document.exitFullscreen().catch(() => {});
        else document.documentElement.requestFullscreen().catch(() => { status.textContent = 'Full screen is unavailable in this browser.'; });
    });
    let retry = 30000;
    async function checkRevision() {
        try {
            const controller = new AbortController();
            const timeout = setTimeout(() => controller.abort(), 10000);
            let response;
            try { response = await fetch(boot.revision_url, { cache: 'no-store', credentials: 'omit', signal: controller.signal }); }
            finally { clearTimeout(timeout); }
            if (response.status === 404) {
                suspended = true;
                // Removing frames stops downloaded media and custom code from continuing.
                screen.replaceChildren();
                status.textContent = 'This screen is no longer available.';
                retry = 30000;
            } else {
                if (!response.ok) throw new Error('Temporary screen check failure');
                const data = await response.json();
                if (!Number.isInteger(data.revision)) throw new Error('Unexpected screen response');
                if (suspended || data.revision !== boot.revision) { window.location.reload(); return; }
                status.textContent = '';
                retry = 30000;
            }
        } catch (_) {
            // A brief outage must not erase a functioning display.
            retry = Math.min(retry * 2, 300000);
            status.textContent = 'Update check unavailable; retrying automatically.';
        }
        setTimeout(checkRevision, retry);
    }
    if (boot.revision_url) setTimeout(checkRevision, retry);
}());
