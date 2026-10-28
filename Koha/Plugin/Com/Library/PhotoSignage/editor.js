(function () {
    "use strict";

    const bootNode = document.getElementById("signage-boot");
    let boot = {};
    try { boot = JSON.parse(bootNode ? bootNode.textContent : "{}"); } catch (error) { boot = {}; }
    const screens = Array.isArray(boot.screens) ? boot.screens : [];
    const templates = Array.isArray(boot.templates) ? boot.templates : [];
    const starters = Array.isArray(boot.starters) ? boot.starters : [];
    const media = Array.isArray(boot.media) ? boot.media : [];
    const state = {
        selectedKind: null,
        selectedId: null,
        selectedRegionId: null,
        layout: null,
        name: "",
        dirty: false,
        pointer: null
    };
    const $ = (selector, root) => (root || document).querySelector(selector);
    const byId = id => document.getElementById(id);
    const node = (tag, className, text) => {
        const element = document.createElement(tag);
        if (className) element.className = className;
        if (text !== undefined && text !== null) element.textContent = String(text);
        return element;
    };
    const clamp = (value, min, max) => Math.max(min, Math.min(max, Number(value) || 0));
    const clone = value => JSON.parse(JSON.stringify(value));
    const escapeId = value => String(value || "").replace(/[^a-zA-Z0-9-]/g, "").slice(0, 60);
    const idForRegion = () => "region-" + (window.crypto && crypto.randomUUID ? crypto.randomUUID().replace(/-/g, "").slice(0, 12) : Math.random().toString(36).slice(2, 14));
    const safeColor = value => /^#[0-9a-fA-F]{6}$/.test(value || "") ? value : "#ffffff";
    const regionTypes = [
        ["clock", "Clock"], ["text", "Text"], ["playlist", "Media playlist"],
        ["youtube", "YouTube"], ["vimeo", "Vimeo"], ["webpage", "Webpage"], ["code", "Custom code"]
    ];
    const regionLabel = type => (regionTypes.find(item => item[0] === type) || [type || "region", "Region"])[1];
    const defaultRegion = type => ({
        id: idForRegion(), type: type || "text", x: 8, y: 8, w: 35, h: 28, fit: "contain",
        interval_seconds: 12, font_size: 32, color: "#ffffff", background: "#27353a", text: "",
        timezone: "UTC", clock_format: "datetime", hour12: false, url: "", html: "", css: "", js: "", items: []
    });
    const fallbackLayout = () => ({ width: 1920, height: 1080, background: "#171b23", regions: [] });
    function normalizeLayout(layout) {
        const source = layout && typeof layout === "object" ? layout : fallbackLayout();
        return {
            width: clamp(source.width || 1920, 240, 4096),
            height: clamp(source.height || 1080, 240, 4096),
            background: safeColor(source.background || "#171b23"),
            regions: Array.isArray(source.regions) ? source.regions.slice(0, 24).map((input) => {
                const region = Object.assign(defaultRegion(input && input.type), input || {});
                region.id = escapeId(region.id) || idForRegion();
                region.type = regionTypes.some(item => item[0] === region.type) ? region.type : "text";
                ["x", "y", "w", "h"].forEach(key => { region[key] = clamp(region[key], 0, 100); });
                region.w = Math.max(1, region.w); region.h = Math.max(1, region.h);
                region.font_size = clamp(region.font_size || 32, 12, 180);
                region.interval_seconds = clamp(region.interval_seconds || 12, 1, 86400);
                region.items = Array.isArray(region.items) ? region.items.slice(0, 200).map(item => ({
                    id: String(item && item.id || ""),
                    duration_seconds: item && item.duration_seconds !== undefined ? item.duration_seconds : ""
                })) : [];
                region.fit = region.fit === "cover" ? "cover" : "contain";
                region.color = safeColor(region.color || "#ffffff");
                region.background = safeColor(region.background || "#27353a");
                region.text = String(region.text || "");
                region.url = String(region.url || "");
                region.html = String(region.html || "");
                region.css = String(region.css || "");
                region.js = String(region.js || "");
                region.timezone = String(region.timezone || "UTC");
                region.clock_format = ["datetime", "date", "time"].includes(region.clock_format) ? region.clock_format : "datetime";
                region.hour12 = Boolean(region.hour12);
                return region;
            }) : []
        };
    }

    function activeRecord() {
        if (state.selectedKind === "screen") return screens.find(item => String(item.id) === String(state.selectedId));
        if (state.selectedKind === "template") return templates.find(item => String(item.id) === String(state.selectedId));
        return null;
    }
    function markDirty() {
        state.dirty = true;
        const saveState = byId("save-state");
        if (saveState) saveState.textContent = "Unsaved changes";
    }
    function showNotice(message, kind) {
        const area = byId("notice-area");
        area.replaceChildren();
        if (!message) return;
        const alert = node("div", "alert " + (kind === "error" ? "alert-error" : "alert-success"), message);
        alert.setAttribute(kind === "error" ? "role" : "role", kind === "error" ? "alert" : "status");
        area.append(alert);
    }
    function maySwitch() {
        return !state.dirty || window.confirm("You have unsaved changes. Leave this layout without saving?");
    }
    function setSelection(kind, id) {
        if (!maySwitch()) return;
        state.selectedKind = kind;
        state.selectedId = id === null ? null : String(id);
        state.selectedRegionId = null;
        const record = activeRecord();
        state.layout = record ? normalizeLayout(record.draft || record.layout) : null;
        state.name = record ? String(record.name || "") : "";
        state.dirty = false;
        const saveState = byId("save-state");
        if (saveState) saveState.textContent = record ? "All changes are local until saved" : "All changes are local until saved";
        renderAll();
    }
    function appendHidden(form, name, value) {
        const input = document.createElement("input");
        input.type = "hidden"; input.name = name; input.value = value === undefined || value === null ? "" : String(value);
        form.append(input);
    }
    function submitAction(action, options) {
        const data = options || {};
        const form = document.createElement("form");
        form.method = "post";
        form.action = boot.run_url || window.location.href;
        form.acceptCharset = "UTF-8";
        form.hidden = true;
        // CGI.pm reads POST parameters from the body, not the URL query.
        // Koha's plugins/run.pl needs these before it can dispatch to tool().
        appendHidden(form, "class", "Koha::Plugin::Com::Library::PhotoSignage");
        appendHidden(form, "method", "tool");
        appendHidden(form, "view", "screens");
        appendHidden(form, "csrf_token", boot.csrf_token || "");
        appendHidden(form, "screen_action", action);
        ["id", "name", "template_id", "enabled"].forEach(key => {
            if (Object.prototype.hasOwnProperty.call(data, key)) appendHidden(form, key, data[key]);
        });
        if (data.layout) appendHidden(form, "layout_json", JSON.stringify(data.layout));
        document.body.append(form);
        state.dirty = false;
        if (byId("save-state")) byId("save-state").textContent = "Submitting to Koha…";
        form.submit();
    }
    function saveData(action) {
        if (!state.layout || state.selectedKind !== "screen") return false;
        return { id: state.selectedId, name: state.name.trim(), layout: state.layout };
    }
    function setLayoutValue(path, value) {
        const parts = path.split(".");
        let target = state.layout;
        for (let i = 0; i < parts.length - 1; i += 1) target = target[parts[i]];
        target[parts[parts.length - 1]] = value;
        markDirty();
        renderCanvas();
        renderStack();
    }
    function selectedRegion() {
        return state.layout && state.layout.regions.find(region => region.id === state.selectedRegionId);
    }
    function selectRegion(id) {
        state.selectedRegionId = id;
        renderCanvas();
        renderStack();
        renderInspector();
    }
    function addLabel(parent, text, forId) {
        const label = node("label", "", text);
        if (forId) label.htmlFor = forId;
        parent.append(label);
        return label;
    }
    function field(parent, labelText, options) {
        const config = options || {};
        const wrap = node("div", "form-field");
        const id = "field-" + Math.random().toString(36).slice(2, 9);
        addLabel(wrap, labelText, id);
        let control;
        if (config.kind === "select") {
            control = document.createElement("select");
            (config.options || []).forEach(option => {
                const entry = document.createElement("option");
                entry.value = option[0]; entry.textContent = option[1]; control.append(entry);
            });
            control.value = config.value === undefined ? "" : String(config.value);
            control.addEventListener("change", () => config.onChange(control.value));
        } else if (config.kind === "textarea") {
            control = document.createElement("textarea");
            control.rows = config.rows || 3;
            control.value = config.value === undefined ? "" : String(config.value);
            if (config.maxLength) control.maxLength = config.maxLength;
            control.addEventListener("input", () => config.onChange(control.value));
        } else {
            control = document.createElement("input");
            control.type = config.kind || "text";
            control.value = config.value === undefined ? "" : String(config.value);
            if (config.min !== undefined) control.min = String(config.min);
            if (config.max !== undefined) control.max = String(config.max);
            if (config.step !== undefined) control.step = String(config.step);
            if (config.placeholder) control.placeholder = config.placeholder;
            control.addEventListener(config.kind === "color" ? "input" : "change", () => config.onChange(config.kind === "number" ? Number(control.value) : control.value));
        }
        control.id = id;
        wrap.append(control);
        if (config.help) wrap.append(node("span", "help", config.help));
        parent.append(wrap);
        return control;
    }
    function section(parent, title) {
        const block = node("section", "inspector-section");
        block.append(node("h4", "inspector-section-title", title));
        parent.append(block);
        return block;
    }
    function setRegionProperty(region, key, value) {
        region[key] = value;
        markDirty();
        renderCanvas();
        renderStack();
    }
    function renderInspector() {
        const empty = byId("inspector-empty");
        const content = byId("inspector-content");
        const region = selectedRegion();
        empty.hidden = Boolean(region);
        content.hidden = !region;
        content.replaceChildren();
        if (!region) return;
        const head = node("div", "inspector-header");
        const headCopy = node("div");
        headCopy.append(node("h3", "", regionLabel(region.type)), node("p", "", "Region settings"));
        const close = node("button", "mini-action", "×");
        close.type = "button"; close.setAttribute("aria-label", "Close region settings");
        close.addEventListener("click", () => selectRegion(null));
        head.append(headCopy, close); content.append(head);

        const basics = section(content, "CONTENT");
        field(basics, "Region type", { kind: "select", value: region.type, options: regionTypes, onChange: value => {
            region.type = value; markDirty(); renderAll();
        }});
        field(basics, "Text / announcement", { kind: "textarea", value: region.text, maxLength: 5000, rows: 3, help: "Plain text only. This editor never runs region code.", onChange: value => { region.text = value; markDirty(); renderCanvas(); } });

        const placement = section(content, "POSITION & SIZE · PERCENT");
        const positionGrid = node("div", "position-grid");
        [["x","Left",100-region.w],["y","Top",100-region.h],["w","Width",100-region.x],["h","Height",100-region.y]].forEach(([key, label, max]) => {
            field(positionGrid, label, { kind: "number", min: key === "w" || key === "h" ? 1 : 0, max, step: 0.1, value: region[key], onChange: value => {
                region[key] = clamp(value, key === "w" || key === "h" ? 1 : 0, max); markDirty(); renderCanvas(); renderStack(); renderInspector();
            }});
        });
        placement.append(positionGrid);
        const visual = section(content, "APPEARANCE");
        const colors = node("div", "fields-two");
        field(colors, "Text colour", { kind: "color", value: safeColor(region.color), onChange: value => setRegionProperty(region, "color", value) });
        field(colors, "Fill colour", { kind: "color", value: safeColor(region.background), onChange: value => setRegionProperty(region, "background", value) });
        visual.append(colors);
        const visualRow = node("div", "fields-two");
        field(visualRow, "Font size", { kind: "number", min: 12, max: 180, value: region.font_size, onChange: value => setRegionProperty(region, "font_size", clamp(value, 12, 180)) });
        field(visualRow, "Media fit", { kind: "select", value: region.fit, options: [["contain","Contain"],["cover","Cover"]], onChange: value => setRegionProperty(region, "fit", value) });
        visual.append(visualRow);
        field(visual, "Advance interval (seconds)", { kind: "number", min: 1, max: 86400, value: region.interval_seconds, help: "Timed content advances within 1 second to 24 hours.", onChange: value => setRegionProperty(region, "interval_seconds", clamp(value, 1, 86400)) });

        if (region.type === "clock") {
            const config = section(content, "CLOCK");
            field(config, "Timezone (IANA)", { value: region.timezone, placeholder: "America/Chicago", help: "Use a valid IANA timezone name or UTC.", onChange: value => setRegionProperty(region, "timezone", value) });
            const clockRow = node("div", "fields-two");
            field(clockRow, "Display", { kind: "select", value: region.clock_format, options: [["datetime","Date & time"],["date","Date"],["time","Time"]], onChange: value => setRegionProperty(region, "clock_format", value) });
            field(clockRow, "Time style", { kind: "select", value: region.hour12 ? "12" : "24", options: [["24","24 hour"],["12","12 hour"]], onChange: value => setRegionProperty(region, "hour12", value === "12") });
            config.append(clockRow);
        }
        if (["youtube", "vimeo", "webpage"].includes(region.type)) {
            const provider = section(content, "EMBED SOURCE");
            field(provider, region.type === "webpage" ? "HTTPS page URL" : region.type + " video URL", { kind: "url", value: region.url, placeholder: "https://", help: "External providers may refuse embedding or require privacy/cookie consent. Use a publicly embeddable HTTPS address.", onChange: value => setRegionProperty(region, "url", value) });
            provider.append(node("span", "help", "Playback is subject to browser autoplay and third-party frame restrictions."));
        }
        if (region.type === "playlist") renderMediaFields(content, region);
        if (region.type === "code") {
            const code = section(content, "CUSTOM CODE");
            code.append(node("div", "code-warning", "Code stays opaque in this staff editor and is never executed here. The server's isolated public preview is the only place to inspect custom output. Keep code self-contained; network and staff access must remain unavailable."));
            field(code, "HTML", { kind: "textarea", value: region.html, rows: 4, onChange: value => setRegionProperty(region, "html", value) });
            field(code, "CSS", { kind: "textarea", value: region.css, rows: 4, onChange: value => setRegionProperty(region, "css", value) });
            field(code, "JavaScript", { kind: "textarea", value: region.js, rows: 4, onChange: value => setRegionProperty(region, "js", value) });
        }
        const actions = node("div", "inspector-buttons");
        const remove = node("button", "button button-danger", "Remove region");
        remove.type = "button"; remove.addEventListener("click", () => {
            state.layout.regions = state.layout.regions.filter(item => item.id !== region.id);
            state.selectedRegionId = null; markDirty(); renderAll();
        });
        actions.append(remove);
        content.append(actions);
    }
    function renderMediaFields(parent, region) {
        const playlist = section(parent, "PLAYLIST ORDER");
        playlist.append(node("span", "help", "Select any existing library media: images, video, PDF, text or provider links. Set an item duration when needed."));
        const entries = node("div", "media-entries");
        region.items.forEach((item, index) => {
            const row = node("div", "media-entry");
            const select = document.createElement("select");
            select.setAttribute("aria-label", "Playlist item " + (index + 1));
            const placeholder = document.createElement("option");
            placeholder.value = ""; placeholder.textContent = media.length ? "Choose media…" : "No media available";
            select.append(placeholder);
            media.forEach(asset => {
                const option = document.createElement("option");
                option.value = String(asset.id);
                const kind = String(asset.media_type || "media");
                option.textContent = (asset.caption || (kind.charAt(0).toUpperCase() + kind.slice(1))) + " · " + kind;
                select.append(option);
            });
            select.value = item.id;
            select.addEventListener("change", () => { item.id = select.value; markDirty(); });
            const duration = document.createElement("input");
            duration.type = "number"; duration.min = "1"; duration.max = "86400"; duration.step = "1";
            duration.placeholder = "Auto"; duration.value = item.duration_seconds === "" ? "" : String(item.duration_seconds);
            duration.setAttribute("aria-label", "Duration seconds for item " + (index + 1));
            duration.addEventListener("change", () => { item.duration_seconds = duration.value ? clamp(duration.value, 1, 86400) : ""; markDirty(); });
            const up = node("button", "move-item", "↑");
            up.type = "button"; up.disabled = index === 0; up.setAttribute("aria-label", "Move playlist item " + (index + 1) + " up");
            up.addEventListener("click", () => {
                if (index === 0) return;
                [region.items[index - 1], region.items[index]] = [region.items[index], region.items[index - 1]];
                markDirty(); renderInspector();
            });
            const down = node("button", "move-item", "↓");
            down.type = "button"; down.disabled = index === region.items.length - 1; down.setAttribute("aria-label", "Move playlist item " + (index + 1) + " down");
            down.addEventListener("click", () => {
                if (index === region.items.length - 1) return;
                [region.items[index + 1], region.items[index]] = [region.items[index], region.items[index + 1]];
                markDirty(); renderInspector();
            });
            const remove = node("button", "remove-item", "×");
            remove.type = "button"; remove.setAttribute("aria-label", "Remove playlist item " + (index + 1));
            remove.addEventListener("click", () => { region.items.splice(index, 1); markDirty(); renderInspector(); });
            row.append(select, duration, up, down, remove);
            entries.append(row);
        });
        playlist.append(entries);
        const controls = node("div", "media-entry-actions");
        const add = node("button", "button button-soft", "＋ Add media");
        add.type = "button"; add.disabled = region.items.length >= 200 || media.length === 0;
        add.addEventListener("click", () => { region.items.push({ id: "", duration_seconds: "" }); markDirty(); renderInspector(); });
        controls.append(add);
        if (media.length === 0) controls.append(node("span", "help", "Add library media from the slideshow page first."));
        playlist.append(controls);
    }
    function renderCanvas() {
        const frame = byId("canvas-frame");
        if (!state.layout) return;
        frame.replaceChildren();
        frame.style.backgroundColor = safeColor(state.layout.background);
        frame.style.aspectRatio = state.layout.width + " / " + state.layout.height;
        frame.setAttribute("aria-label", state.layout.width + " by " + state.layout.height + " screen preview");
        state.layout.regions.forEach((region, index) => {
            const block = node("div", "region-block" + (region.id === state.selectedRegionId ? " is-selected" : ""));
            block.style.left = region.x + "%"; block.style.top = region.y + "%";
            block.style.width = region.w + "%"; block.style.height = region.h + "%";
            block.style.backgroundColor = region.background;
            block.style.color = region.color;
            block.style.zIndex = String(index + 1);
            block.tabIndex = 0;
            block.setAttribute("role", "button");
            block.setAttribute("aria-label", regionLabel(region.type) + " region, left " + region.x + " percent, top " + region.y + " percent, width " + region.w + " percent, height " + region.h + " percent");
            block.addEventListener("click", event => { event.stopPropagation(); selectRegion(region.id); });
            block.addEventListener("keydown", event => { if (event.key === "Enter" || event.key === " ") { event.preventDefault(); selectRegion(region.id); } });
            block.addEventListener("pointerdown", event => beginMove(event, region));
            block.append(node("span", "preview-type", regionLabel(region.type).toUpperCase()));
            if (region.type === "clock") {
                block.append(node("span", "region-preview-text", region.clock_format === "date" ? "Monday, June 16" : region.clock_format === "time" ? "09:42 AM" : "09:42  ·  Monday"));
                block.append(node("span", "region-preview-sub", region.timezone || "UTC"));
            } else if (region.type === "playlist") {
                block.append(node("span", "region-preview-text", region.items.length ? "MEDIA ROTATION" : "Add media items"));
                block.append(node("span", "region-preview-sub", region.items.length + " playlist items"));
            } else if (region.type === "code") {
                block.append(node("span", "region-preview-text", "Custom output"));
                block.append(node("span", "region-preview-sub", "Sandboxed public preview"));
            } else if (region.type === "youtube" || region.type === "vimeo" || region.type === "webpage") {
                block.append(node("span", "region-preview-text", region.text || regionLabel(region.type)));
                block.append(node("span", "region-preview-sub", region.url ? "External frame" : "Add a secure URL"));
            } else {
                block.append(node("span", "region-preview-text", region.text || (region.type === "text" ? "Your message" : "Text region")));
            }
            const handle = node("span", "resize-handle");
            handle.setAttribute("aria-hidden", "true");
            handle.addEventListener("pointerdown", event => beginResize(event, region));
            block.append(handle);
            frame.append(block);
        });
    }
    function beginMove(event, region) {
        if (event.target.classList.contains("resize-handle")) return;
        event.preventDefault();
        selectRegion(region.id);
        state.pointer = { mode: "move", id: region.id, x: event.clientX, y: event.clientY, left: region.x, top: region.y };
        byId("canvas-frame").setPointerCapture(event.pointerId);
    }
    function beginResize(event, region) {
        event.preventDefault(); event.stopPropagation();
        selectRegion(region.id);
        state.pointer = { mode: "resize", id: region.id, x: event.clientX, y: event.clientY, width: region.w, height: region.h };
        byId("canvas-frame").setPointerCapture(event.pointerId);
    }
    function pointerMove(event) {
        if (!state.pointer || !state.layout) return;
        const region = state.layout.regions.find(item => item.id === state.pointer.id);
        const frame = byId("canvas-frame");
        if (!region || !frame.clientWidth || !frame.clientHeight) return;
        const dx = (event.clientX - state.pointer.x) / frame.clientWidth * 100;
        const dy = (event.clientY - state.pointer.y) / frame.clientHeight * 100;
        if (state.pointer.mode === "move") {
            region.x = clamp(state.pointer.left + dx, 0, 100 - region.w);
            region.y = clamp(state.pointer.top + dy, 0, 100 - region.h);
        } else {
            region.w = clamp(state.pointer.width + dx, 1, 100 - region.x);
            region.h = clamp(state.pointer.height + dy, 1, 100 - region.y);
        }
        ["x", "y", "w", "h"].forEach(key => { region[key] = Math.round(region[key] * 100) / 100; });
        markDirty(); renderCanvas(); renderStack();
    }
    function pointerUp() { state.pointer = null; }
    function renderStack() {
        const list = byId("region-list");
        list.replaceChildren();
        const regions = state.layout ? state.layout.regions : [];
        [...regions].reverse().forEach((region, visibleIndex) => {
            const index = regions.length - 1 - visibleIndex;
            const row = node("li", "region-row" + (region.id === state.selectedRegionId ? " is-selected" : ""));
            row.append(node("span", "layer-number", String(visibleIndex + 1).padStart(2, "0")));
            const select = node("button", "region-select");
            select.type = "button";
            select.append(node("strong", "", region.text.trim() || regionLabel(region.type)));
            select.append(node("small", "", regionLabel(region.type) + " · " + [region.x, region.y, region.w, region.h].map(value => Math.round(value) + "%").join(" / ")));
            select.addEventListener("click", () => selectRegion(region.id));
            const controls = node("span", "layer-controls");
            [["↑","Move layer up",visibleIndex === 0,1],["↓","Move layer down",visibleIndex === regions.length - 1,-1]].forEach(([label,title,disabled,step]) => {
                const button = node("button", "mini-action", label);
                button.type = "button"; button.disabled = disabled; button.title = title; button.setAttribute("aria-label", title);
                button.addEventListener("click", () => {
                    const next = index + step;
                    [regions[index], regions[next]] = [regions[next], regions[index]];
                    markDirty(); renderCanvas(); renderStack();
                });
                controls.append(button);
            });
            row.append(select, controls); list.append(row);
        });
        byId("region-count").textContent = regions.length + (regions.length === 1 ? " region" : " regions");
        byId("layer-count").textContent = String(regions.length).padStart(2, "0");
    }
    function renderScreenList() {
        const list = byId("screen-list"); list.replaceChildren();
        if (!screens.length) list.append(node("p", "empty-list", "No screens yet. Create one to start a layout."));
        screens.forEach(screen => {
            const button = node("button", "screen-entry");
            button.type = "button";
            button.setAttribute("aria-current", state.selectedKind === "screen" && String(state.selectedId) === String(screen.id) ? "true" : "false");
            const main = node("span", "entry-main");
            main.append(node("span", "entry-name", screen.name || "Untitled screen"));
            const visibility = screen.published ? (screen.enabled ? "PUBLISHED · ENABLED" : "PUBLISHED · DISABLED") : "NOT PUBLISHED";
            main.append(node("span", "entry-meta", visibility + " · REV " + (screen.revision || "—")));
            button.append(main);
            const marker = node("span", "entry-marker" + (screen.published && screen.enabled ? " enabled" : "") + (screen.published && !screen.enabled ? " published" : ""));
            marker.setAttribute("aria-label", screen.published ? (screen.enabled ? "Published and enabled" : "Published but disabled") : "Not published");
            button.append(marker);
            button.addEventListener("click", () => setSelection("screen", screen.id));
            list.append(button);
        });
    }
    function renderTemplateList() {
        const list = byId("template-list"); list.replaceChildren();
        if (!templates.length) list.append(node("p", "empty-list", "No saved templates yet."));
        templates.forEach(template => {
            const wrap = node("div");
            const button = node("button", "template-entry");
            button.type = "button";
            button.setAttribute("aria-current", state.selectedKind === "template" && String(state.selectedId) === String(template.id) ? "true" : "false");
            const title = node("span", "entry-main");
            title.append(node("span", "entry-name", template.name || "Untitled template"));
            title.append(node("span", "entry-meta", "TEMPLATE · " + ((template.layout && template.layout.regions || []).length) + " REGIONS"));
            button.append(title);
            button.addEventListener("click", () => setSelection("template", template.id));
            wrap.append(button);
            if (state.selectedKind === "template" && String(state.selectedId) === String(template.id)) {
                const toolbar = node("div", "template-toolbar");
                [["Edit template","template-save"],["Duplicate","template-duplicate"],["Delete","template-delete"]].forEach(([label, action]) => {
                    const control = node("button", "button " + (action === "template-delete" ? "button-danger" : "button-soft"), label);
                    control.type = "button";
                    control.addEventListener("click", () => {
                        if ((action === "template-delete" && !window.confirm("Delete this saved template? Existing screens will not be changed.")) || !maySwitch()) return;
                        if (action === "template-save") {
                            if (!maySubmit()) return;
                            submitAction(action, { id: template.id, name: state.name.trim(), layout: state.layout });
                        } else submitAction(action, { id: template.id });
                    });
                    toolbar.append(control);
                });
                wrap.append(toolbar);
            }
            list.append(wrap);
        });
    }
    function maySubmit() {
        if (!state.layout) return true;
        if (!state.name.trim()) { showNotice(state.selectedKind === "template" ? "Enter a name for this template before saving." : "Enter a name for this screen before saving.", "error"); byId("screen-name").focus(); return false; }
        if (state.layout.regions.length > 24) { showNotice("A screen can contain no more than 24 regions.", "error"); return false; }
        if (state.layout.width < 240 || state.layout.height < 240 || state.layout.width > 4096 || state.layout.height > 4096) { showNotice("Screen dimensions must be between 240 and 4,096 pixels.", "error"); return false; }
        for (const region of state.layout.regions) {
            if (["youtube", "vimeo", "webpage"].includes(region.type) && region.url && !/^https:\/\//i.test(region.url)) {
                showNotice("Embedded provider and webpage URLs must use HTTPS.", "error"); return false;
            }
            if (region.type === "clock") {
                try { new Intl.DateTimeFormat("en", { timeZone: region.timezone }).format(new Date()); }
                catch (error) { showNotice("Enter a valid IANA timezone name or UTC for each clock region.", "error"); return false; }
            }
            if (region.type === "playlist" && region.items.some(item => !media.some(asset => String(asset.id) === String(item.id)))) {
                showNotice("Choose a valid library media item for each playlist row, or remove the empty row.", "error"); return false;
            }
        }
        return true;
    }
    function renderAll() {
        renderScreenList(); renderTemplateList();
        const record = activeRecord();
        const hasRecord = Boolean(record && state.layout);
        byId("empty-selection").hidden = hasRecord;
        byId("editor-content").hidden = !hasRecord;
        if (!hasRecord) return;
        byId("screen-name").value = state.name;
        byId("screen-name").disabled = false;
        const isScreen = state.selectedKind === "screen";
        byId("selection-kind").textContent = isScreen ? (record.published ? "SCREEN / PUBLISHED REVISION" : "SCREEN / DRAFT") : "TEMPLATE / LAYOUT";
        byId("duplicate-screen").hidden = !isScreen;
        byId("delete-screen").hidden = !isScreen;
        byId("save-screen").textContent = isScreen ? "Save draft" : "Save template";
        byId("screen-status").replaceChildren();
        if (isScreen) {
            const status = node("span", "pill" + (record.published ? " is-published" : ""), record.published ? "PUBLISHED" : "DRAFT");
            const revision = node("span", "pill", "REVISION " + (record.revision || "—"));
            const enabled = record.published
                ? node("span", "pill" + (record.enabled ? " is-enabled" : ""), record.enabled ? "ENABLED" : "DISABLED")
                : node("span", "pill", "NOT PUBLIC");
            const explanation = record.published
                ? (record.enabled ? "This published revision is currently available on its public screen." : "This screen was published, then disabled. It is not currently shown publicly.")
                : "This layout has not been published. Saving keeps it private.";
            byId("screen-status").append(status, enabled, revision, node("span", "", explanation));
        } else {
            byId("screen-status").append(node("span", "pill", "TEMPLATE"), node("span", "", "Editing a reusable layout. Create a screen from this template to preview it."));
        }
        byId("screen-width").value = state.layout.width;
        byId("screen-height").value = state.layout.height;
        byId("canvas-dimensions").textContent = state.layout.width + " × " + state.layout.height;
        byId("screen-background").value = state.layout.background;
        byId("background-value").textContent = state.layout.background.toUpperCase();
        const ratio = state.layout.width / state.layout.height;
        document.querySelectorAll(".orientation-button").forEach(button => button.classList.toggle("is-active", button.dataset.orientation === (ratio >= 1 ? "landscape" : "portrait")));
        byId("screen-enabled").checked = Boolean(record.enabled);
        byId("screen-enabled").disabled = !isScreen || !record.published;
        byId("enabled-label").textContent = isScreen && record.published ? "Enabled on public screens" : "Publish to enable this screen";
        byId("publish-screen").hidden = !isScreen;
        byId("open-preview").hidden = !isScreen;
        byId("public-link-wrap").hidden = !isScreen || !record.public_url;
        if (isScreen && record.public_url) byId("public-link").value = resolveLink(record.public_url);
        byId("template-editor").hidden = true;
        renderCanvas(); renderStack(); renderInspector();
    }
    function resolveLink(value) {
        try { return new URL(value, window.location.href).href; } catch (error) { return String(value || ""); }
    }
    function createDialog(initialName) {
        const overlay = node("div", "dialog-backdrop");
        overlay.setAttribute("role", "presentation");
        const dialog = node("section", "create-dialog");
        dialog.setAttribute("role", "dialog"); dialog.setAttribute("aria-modal", "true"); dialog.setAttribute("aria-labelledby", "create-title");
        const close = node("button", "dialog-close", "×"); close.type = "button"; close.setAttribute("aria-label", "Close");
        close.addEventListener("click", () => overlay.remove());
        dialog.append(close, node("p", "eyebrow", "NEW PUBLIC DISPLAY"), node("h2", "", "Give this screen a name."), node("p", "dialog-copy", "Start with a blank layout, a saved template or a staff starter."));
        const form = node("form", "create-form");
        form.addEventListener("submit", event => {
            event.preventDefault();
            const name = nameInput.value.trim();
            if (!name) { nameInput.focus(); return; }
            overlay.remove();
            submitAction("create", { name, template_id: starterSelect.value });
        });
        const nameInput = document.createElement("input");
        nameInput.type = "text"; nameInput.name = "name"; nameInput.maxLength = 120; nameInput.required = true; nameInput.placeholder = "e.g. Welcome lobby";
        nameInput.value = initialName === undefined || initialName === null ? "" : String(initialName);
        nameInput.setAttribute("aria-label", "Screen name");
        form.append(nameInput);
        const starterSelect = document.createElement("select");
        starterSelect.setAttribute("aria-label", "Start from a layout");
        const blank = document.createElement("option"); blank.value = ""; blank.textContent = "Blank canvas"; starterSelect.append(blank);
        if (templates.length) {
            const group = document.createElement("optgroup"); group.label = "Your templates";
            templates.forEach(item => { const option = document.createElement("option"); option.value = item.id; option.textContent = item.name; group.append(option); });
            starterSelect.append(group);
        }
        if (starters.length) {
            const group = document.createElement("optgroup"); group.label = "Starter layouts";
            starters.forEach(item => { const option = document.createElement("option"); option.value = item.id; option.textContent = item.name; group.append(option); });
            starterSelect.append(group);
        }
        form.append(starterSelect);
        const actions = node("div", "dialog-actions");
        const cancel = node("button", "button button-soft", "Cancel"); cancel.type = "button"; cancel.addEventListener("click", () => overlay.remove());
        const submit = node("button", "button button-primary", "Create screen"); submit.type = "submit";
        actions.append(cancel, submit); form.append(actions); dialog.append(form); overlay.append(dialog);
        overlay.addEventListener("click", event => { if (event.target === overlay) overlay.remove(); });
        document.body.append(overlay); nameInput.focus();
    }
    function saveAsTemplate() {
        if (!state.layout || state.selectedKind !== "screen") {
            showNotice("Select a screen first, then save its layout as a reusable template.", "error");
            return;
        }
        const templateName = window.prompt("Name this reusable template:", state.name + " template");
        if (templateName === null || !templateName.trim()) return;
        if (!maySubmit()) return;
        submitAction("template_save", { id: "", name: templateName.trim(), layout: state.layout });
    }
    function bindEvents() {
        byId("new-screen").addEventListener("click", () => { if (maySwitch()) createDialog(); });
        byId("empty-create").addEventListener("click", () => { if (maySwitch()) createDialog(); });
        byId("new-template").addEventListener("click", saveAsTemplate);
        byId("screen-name").addEventListener("input", event => {
            state.name = event.target.value; markDirty();
        });
        byId("screen-width").addEventListener("change", event => {
            state.layout.width = clamp(event.target.value, 240, 4096);
            event.target.value = state.layout.width; markDirty(); renderAll();
        });
        byId("screen-height").addEventListener("change", event => {
            state.layout.height = clamp(event.target.value, 240, 4096);
            event.target.value = state.layout.height; markDirty(); renderAll();
        });
        byId("screen-background").addEventListener("input", event => {
            state.layout.background = event.target.value; byId("background-value").textContent = event.target.value.toUpperCase();
            markDirty(); renderCanvas();
        });
        document.querySelectorAll(".orientation-button").forEach(button => button.addEventListener("click", () => {
            if (button.dataset.orientation === "landscape" && state.layout.width < state.layout.height) [state.layout.width, state.layout.height] = [state.layout.height, state.layout.width];
            if (button.dataset.orientation === "portrait" && state.layout.width > state.layout.height) [state.layout.width, state.layout.height] = [state.layout.height, state.layout.width];
            markDirty(); renderAll();
        }));
        byId("add-region").addEventListener("click", () => {
            if (state.layout.regions.length >= 24) { showNotice("A screen can contain no more than 24 regions.", "error"); return; }
            const region = defaultRegion("text");
            region.x = 8 + (state.layout.regions.length % 5) * 4;
            region.y = 8 + (state.layout.regions.length % 5) * 4;
            state.layout.regions.push(region);
            state.selectedRegionId = region.id; markDirty(); renderAll();
        });
        byId("save-screen").addEventListener("click", () => {
            if (!maySubmit()) return;
            if (state.selectedKind === "screen") submitAction("save", saveData("save"));
            else submitAction("template_save", { id: state.selectedId, name: state.name.trim(), layout: state.layout });
        });
        byId("duplicate-screen").addEventListener("click", () => {
            if (state.selectedKind !== "screen") return;
            if (window.confirm("Create a separate screen using this screen's saved layout? Unsaved edits are not included.") && maySwitch()) submitAction("duplicate", { id: state.selectedId });
        });
        byId("delete-screen").addEventListener("click", () => {
            if (state.selectedKind !== "screen") return;
            if (window.confirm("Delete this screen and its saved layouts? This cannot be undone.") && maySwitch()) submitAction("delete", { id: state.selectedId });
        });
        byId("publish-screen").addEventListener("click", () => {
            if (!maySubmit()) return;
            if (window.confirm("Publish this screen to its public address? The current layout will become visible to anyone with the link.")) submitAction("publish", saveData("publish"));
        });
        byId("screen-enabled").addEventListener("change", event => {
            if (!state.selectedId || state.selectedKind !== "screen") return;
            if (state.dirty && !window.confirm("Discard unsaved layout edits and change the public enabled state?")) { renderAll(); return; }
            submitAction("toggle", { id: state.selectedId, enabled: event.target.checked ? "1" : "0" });
        });
        byId("open-preview").addEventListener("click", event => {
            const record = activeRecord();
            if (!record) return;
            if (state.dirty) {
                event.preventDefault();
                showNotice("Save this draft first, then open the authenticated preview. This editor uses normal Koha form submissions and does not silently send draft data in the background.", "error");
                return;
            }
            const base = String(boot.run_url || window.location.href);
            const separator = base.includes("?") ? "&" : "?";
            window.open(base + separator + "view=screen_preview&id=" + encodeURIComponent(state.selectedId), "_blank", "noopener");
        });
        byId("copy-public-link").addEventListener("click", async () => {
            const input = byId("public-link"), status = byId("copy-status");
            try { await navigator.clipboard.writeText(input.value); status.textContent = "Address copied."; }
            catch (error) {
                input.focus(); input.select();
                status.textContent = document.execCommand("copy") ? "Address copied." : "Address selected. Copy it with your keyboard shortcut.";
            }
        });
        document.addEventListener("pointermove", pointerMove);
        document.addEventListener("pointerup", pointerUp);
        window.addEventListener("beforeunload", event => {
            if (state.dirty) { event.preventDefault(); event.returnValue = ""; }
        });
    }

    bindEvents();
    if (boot.message) showNotice(boot.message, "success");
    if (boot.error) showNotice(boot.error, "error");
    const initialId = boot.selected_id !== undefined && boot.selected_id !== null ? String(boot.selected_id) : null;
    const initialTemplate = boot.selected_kind === "template" && initialId && templates.find(template => String(template.id) === initialId);
    const initial = initialId && screens.find(screen => String(screen.id) === initialId);
    if (initialTemplate) setSelection("template", initialTemplate.id);
    else if (initial) setSelection("screen", initial.id);
    else if (screens.length) setSelection("screen", screens[0].id);
    else renderAll();
    if (boot.error) {
        let restored = false;
        if (Object.prototype.hasOwnProperty.call(boot, "submitted_name") && boot.submitted_name !== null && state.layout) {
            state.name = String(boot.submitted_name);
            byId("screen-name").value = state.name;
            restored = true;
        }
        if (Object.prototype.hasOwnProperty.call(boot, "submitted_layout") && boot.submitted_layout !== null && state.layout) {
            let submittedLayout = boot.submitted_layout;
            if (typeof submittedLayout === "string") {
                try { submittedLayout = JSON.parse(submittedLayout); } catch (error) { submittedLayout = null; }
            }
            if (submittedLayout && typeof submittedLayout === "object") {
                state.layout = normalizeLayout(submittedLayout);
                restored = true;
            }
        }
        if (restored) {
            state.dirty = true;
            byId("save-state").textContent = "Restored unsaved submission";
            renderAll();
        } else if (Object.prototype.hasOwnProperty.call(boot, "submitted_name") && boot.submitted_name !== null && !state.layout) {
            createDialog(String(boot.submitted_name));
        }
    }
}());
