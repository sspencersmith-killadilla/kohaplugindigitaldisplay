# Koha Photo Signage

An installable Koha plugin with staff-only visual screen design, reusable templates, a shared media library, and public full-screen digital signage. Version 2.0.2.

## Visual screens and templates

Open **Tools → Photo Signage → Manage screens and visual templates**. The original slideshow remains available, with the same URL, settings, uploads, and per-slide timing as before.

### Create and publish a screen

1. Choose **Create a screen**, enter a name, and select a blank, split, portrait, or saved template.
2. Set the screen dimensions/orientation and background. The public player preserves the designed aspect ratio, using bars rather than stretching the layout on differently shaped monitors.
3. Add sections, drag them around the canvas, and resize with the bottom-right handles. Accessible numeric position and size controls use percentages. Use the layer arrows to move sections in front of or behind one another.
4. Configure each section. The canvas shows safe placement previews; it does not execute snippets or load third-party embeds. **Save draft**, then use **Preview saved draft** for actual playback in a separate authenticated staff tab.
5. Choose **Publish screen** and confirm public access. Copy that screen's public address for a signage browser. No staff session is needed for viewing.

Screen addresses have this form:

```text
/api/v1/contrib/photosignage/screens/{screen-id}
```

Each screen has an immutable generated ID, so renaming it does not change its address. The copy control resolves it against this installation's configured public OPAC scheme, host, port, and prefix using the same rules as the original slideshow link. A draft already has its eventual address, but returns 404 until published.

**Save draft does not publish.** Published layouts, names, and selected media content are snapshots; editing a draft or shared text item does not change an existing display until that screen is republished. A published display checks its read-only revision address every 30 seconds and reloads on a published change. Temporary errors leave the current display running and retry with a bounded 60–300 second backoff. Disabling or deleting a screen returns 404 immediately for new requests; a running display stops its frames on its next successful availability check. Already received content cannot be revoked.

Duplicate a screen to create an independent, unpublished draft. Disable a published screen to remove public access without losing its layouts. Deleting a screen requires confirmation and removes that screen, not its shared media or other screens.

### Section types

- **Clock:** live date, time, or both, with an IANA timezone (for example `America/Chicago`) and 12/24-hour choice. It updates independently of other content.
- **Text:** plain text, font size, foreground and background colors.
- **Media playlist:** select any library items in a section-specific order. Images, text, PDFs, MP4s and existing provider/webpage slides are supported. Each section has its own fit and interval; each item can override its original duration. Blank item timing retains the item's original timing, or uses this section's default; an MP4 with no explicit limit plays to its end. Each playlist has independent pause/resume and fullscreen controls.
- **YouTube / Vimeo:** a provider video URL in its own section, running independently. Official provider embeds are muted and loop; browser/provider consent, privacy, network, and autoplay restrictions still apply.
- **Webpage:** a public HTTPS page in a sandboxed iframe. A site may refuse embedding or require browser permissions unavailable in the sandbox. There is no server-side fetch or bypass for those restrictions.
- **Custom code:** self-contained HTML, CSS, and browser JavaScript in an **opaque sandboxed frame**. The editor displays only its placement; use the saved authenticated preview to inspect its output.

Uploaded MP4s and PDFs can occupy an entire section by putting a single library item in a media playlist. A single MP4 loops. Multiple playlist regions advance independently, so a video does not restart when an adjacent slideshow changes slides.

### Reusable templates

Choose **Save screen as template**, give the layout a name, and use it when creating other screens. Templates can be edited, duplicated, and deleted in the studio. Each new screen receives an independent copy; later template edits never silently change other drafts or live displays. Templates are staff-only and cannot be opened publicly.

### Media privacy and dependencies

The original tool page is also the shared media library. By default, new items still enter the original public slideshow immediately, preserving existing behavior. To prepare content privately, select **Library only** when adding it. Library-only uploads are not publicly readable until an enabled, published screen references them.

The media list shows references from drafts, published screens, and templates. Deletion and disabling an original-slideshow item are refused while references remain, with the dependent names listed. Remove the relevant draft/template references and republish affected screens first. Disabling a screen alone retains its saved published references, so it is not a way to bypass dependency protection. A file remains public if the original slideshow or any enabled published screen still uses it.

### Custom-code safety and limits

Use snippets only from trusted staff. They run as browser code, never as Perl/PHP or server-side code. The frame does not grant same-origin access, form submissions, popups, downloads, nested user frames, or top-level navigation. Its restrictive content policy blocks external scripts, styles, images, media, connections, and object loads; inline CSS/JS and data images are allowed. A non-user-controlled outer wrapper permits only a data-URL child, additionally blocking that child's navigation to HTTP(S) pages. This prevents snippets from reading the Koha parent page, cookies, storage, or privileged plugin responses. Use the dedicated media/webpage/provider widgets for network content.

The sandbox is a browser security boundary, **not a CPU/memory quota**. Bad or infinite-loop JavaScript may still make a display unresponsive; review and preview code before publishing. The self-contained snippet policy does not make arbitrary untrusted code safe to accept from the public. Do not paste credentials or private information into snippets or any published region.

Limits are 50 screens, 50 templates, 24 sections per layout, 200 items per playlist, dimensions from 240–4096 pixels, and 12,000 characters each for snippet HTML/CSS/JS. Layout and published snapshot sizes are bounded; large combinations of text/code may require fewer sections. This is a rectangular signage editor, not a general nested web-page builder.

### Upgrade to 2.0.2

This version fixes screen-editor POST dispatch: the plugin class and method are now included in the form body, as Koha's CGI runner requires. Earlier visual-editor versions put them only in the URL, which could produce a server error for every create/save/publish action. The regression tests execute the actual editor form builder and pass its output through real CGI.pm, rather than assuming query parameters and POST fields are combined.

Back up the Koha database and upload directory together. Upload the new `PhotoSignage.kpz` over the existing plugin **without uninstalling**, keep it enabled, and restart all instance Plack/API workers (including the OPAC-facing API application). New screen and revision routes must be discovered, just like the original routes.

No existing playlist, setting, file, or URL is rewritten. Screen/template storage uses separate versioned plugin-data entries, initialized only by staff writes; merely visiting a public URL never runs installation or migration code. No new service, global Koha preference change, or core Koha code modification is required.

## Features

- Upload JPEG, PNG, GIF, or WebP images (12 MB maximum), MP4 videos (250 MB maximum), and PDFs (50 MB maximum).
- Add plain-text slides, YouTube or Vimeo videos, and public HTTPS pages that permit embedding.
- Caption, enable/disable, reorder, and remove slides in one playlist.
- Set the timed slide interval (3–600 seconds) and choose whole-image or fill-screen sizing.
- Give each slide its own optional display duration (1–86,400 seconds). Enter `240` for four minutes. Leave blank to use the default for timed slides or play an uploaded MP4 all the way to the end. An explicit MP4 duration is a maximum: advance at that time or when the video ends, whichever comes first. Pause/resume preserves the remaining display time.
- Play uploaded videos muted and advance when playback finishes; timed slides advance using the configured interval.
- Copy a stable public player link from the staff tool page. Signage browsers do not need a staff account, login, or session cookie.
- Use pause/resume and a full-screen control in the player.
- Keep uploaded media in Koha's configured `upload_path`; public read-only routes serve only enabled media, with byte-range support for video playback. Disabled media previews remain staff-only.

### External media limitations

- YouTube and Vimeo are displayed using their official embedded players. They use the individual slide duration, or the slideshow default if blank; their end time is not detected automatically. Set a four-minute provider slide to `240` seconds.
- Public webpages must use HTTPS and allow display in an iframe. Koha cannot override a remote site's Content Security Policy or `X-Frame-Options`; the player shows a reminder when displaying an external page and continues to the next slide on schedule.
- A PDF preview depends on the signage browser's built-in PDF support. The player also provides a link to open the PDF directly.
- Text slides are stored as plain text and rendered with HTML escaping. HTML/JavaScript is supported only in the isolated custom-code section, never in plain text/captions.
- Browser and Koha server upload limits may be lower than the plugin's per-file limits.

## Requirements

- Koha 22.11 or later with plugins enabled.
- A configured, writable Koha `upload_path`.
- Staff accounts with permission to access Koha plugins.
- A Koha server address reachable from the signage browser (HTTPS recommended). `OPACBaseURL` is optional, not required for playback.
- The catalogue must permit public access (`OpacPublic` enabled) and not be in maintenance mode (`OPACMaintenance` disabled). These policies are honored by the public routes.
- Koha's `/api/v1/contrib/photosignage/` routes must be reachable on the public catalogue host through the existing Koha API handler.

Before installation, your Koha administrator must enable plugins in `koha-conf.xml` (`enable_plugins` set to `1`). To upload through the staff interface, `plugins_restricted` must permit plugin uploads. Restart the Koha web server after changing Koha configuration.

## Install

1. In the Koha staff client, open **Administration → Manage plugins**.
2. Choose **Upload plugin**, select `PhotoSignage.kpz`, and install it.
3. Open **Tools → Photo Signage** (or the plugin entry under Tools).
4. After installation, have your administrator restart the instance's Plack/API workers so Koha discovers the new plugin API routes. Reload/restart Apache as appropriate for non-Plack CGI deployments or changed proxy configuration.
5. Open the plugin tool again. Add media, set the duration and image sizing, then choose **Open public slideshow** or **Copy link**.
6. On the signage workstation, use **Enter full screen** once; browsers require a user action before entering full-screen mode.

## Public link and access

The tool always shows **Open public slideshow** and a copyable full address. The stable player path on your Koha server is:

```text
/api/v1/contrib/photosignage/slideshow
```

Enabled images, videos, and PDFs use read-only media addresses under:

```text
/api/v1/contrib/photosignage/media/{slide-id}
```

The link follows Koha's OPAC address, not a library-specific hostname baked into the plugin:

1. When `OPACBaseURL` is valid, the tool uses it, preserving its HTTP/HTTPS scheme, hostname, port, and path prefix exactly.
2. If that preference is missing or invalid, set **Slideshow settings → OPAC address fallback** to this installation's full public catalogue address. Save settings, then copy the updated link. This is plugin-only configuration, not a global Koha preference change, and is ignored when a valid `OPACBaseURL` is available.
3. If neither address is available, the tool still provides a same-server link resolved by the browser. The notice explicitly says it is not a detected public catalogue address. Staff and public servers can have unrelated hostnames; the plugin never guesses by stripping “staff” from a hostname or trusting forwarded-host headers.

No setting is required for playback at a known public player address. You do not need to change `OPACBaseURL` to obtain a link. Use the public OPAC host when sharing the link; the signage browser must be able to reach its API routes. Configuring a hostname does not create a DNS record, publish a server, or bypass hosting-provider access restrictions.

The player loads uploaded media relative to its own page, on the actual playback host and path prefix, regardless of the preference. Use the canonical `/slideshow` address without a trailing slash; routers accepting a trailing slash redirect to the canonical address. The copy/open controls preserve a configured reverse-proxy prefix. Without JavaScript, the fallback Open link remains usable as a relative link.

**Anyone who can reach the public link can view enabled slides and download their enabled uploaded media.** New slides are enabled immediately. Do not add confidential information or material you cannot display publicly. Turning a slide off blocks subsequent public media requests, but cannot revoke content a visitor has already received; reload an already-open signage page to update its text, embeds, or playlist.

Only read-only `GET` operations are registered publicly; Mojolicious automatically handles `HEAD` requests through those same routes. Do not add explicit `head` operations: OpenAPI router versions used with Koha can attempt to call a nonexistent `Route->head` method and fail registration. Uploading, ordering, editing, deleting, and changing settings still use the original staff runner and its session, plugin permissions, and CSRF protection. Unknown, disabled, deleted, malformed, and non-file media IDs return 404. Public responses are marked no-store and noindex; these headers discourage caching/indexing but are not access controls.

Koha plugin API routes use the `contrib` namespace. These read-only operations intentionally omit `x-koha-authorization`; the core `/api/v1/public` preferences are not used to grant editing access or changed by this plugin. Private-catalogue and maintenance settings still block the plugin's public viewing routes, as does disabling the plugin or plugins globally.

If a reverse proxy restricts API access, the administrator must permit **only GET/HEAD** to this plugin's player/media paths on the public host and route them to Koha's existing API application. Do not remove authentication from the staff runner or open unrelated API endpoints. Standard Koha 22.11 Apache OPAC templates already route `/api` to Koha; custom hosting may differ. No core Koha source changes or separate web service are required.

### Upgrade from 1.0 or 1.1

1. Before upgrading, review currently enabled slides and turn off anything not intended for public display. Once the new routes are live, all enabled content is public.
2. Back up the Koha database and configured upload directory together.
3. Upload the updated `PhotoSignage.kpz` over the existing plugin using Koha's plugin management, retaining the same plugin class. Do not uninstall to upgrade.
4. Confirm the plugin is enabled and the catalogue permits public access. If you use `OPACBaseURL` to select a different public hostname, confirm it is correct; otherwise leave it unset. Restart the Plack/API workers and reload any changed web-server configuration.
5. Copy the new public link from the tool and test it in a private browser window without logging in. Update signage bookmarks. The previous staff runner URL still needs a staff login, then redirects to the new public address; it cannot become anonymous by changing its query parameters.

Existing playlists and files remain intact; no database migration or file relocation is needed.

### Upgrade from 1.2.0

Upload 1.2.1 over the existing plugin without uninstalling, and restart the Plack/API workers to load the updated code. Reopen the tool page and copy the displayed link. The previous blocking `OPACBaseURL` warning is removed; no global preference changes are needed.

### Upgrade to 1.2.2

Upload the current KPZ without uninstalling and restart the instance's Plack/API workers. The slideshow link automatically follows the installation's valid `OPACBaseURL`. If it is absent, save the full public catalogue address in the optional plugin-only fallback field. Existing playlists, files and playback settings remain intact; no library hostname is hardcoded in the package.

### Fix missing slideshow routes: upgrade to 1.2.3

Versions 1.2.0–1.2.2 declared explicit `HEAD` operations. With Mojolicious/OpenAPI combinations that do not provide `Route->head`, this can prevent the plugin's routes from registering. The previous local test harness manually mounted routes and did not detect that startup failure. Version 1.2.3 registers only `GET`, retaining automatic `HEAD` support, and the regression suite now mounts the declarations through the real OpenAPI plugin.

Upload 1.2.3 over the existing plugin, keep it enabled, and have the host restart **all Plack/API workers serving this Koha instance**, including the OPAC-facing API application. A browser refresh alone does not reload the server's route table. Existing playlists and uploads do not need to be recreated.

If the public path still returns a catalogue-styled “Page Not Found” after that restart, check the API worker startup log for plugin loading/route errors and confirm the public vhost forwards `/api` to the same instance. Compare the response from `/api/v1/libraries`: a JSON authentication/permission response establishes that the API is being reached, whereas the same HTML not-found page points toward hosting/proxy routing. Do not disable staff authentication to work around a missing route.

## Media storage and backups

The plugin stores uploaded media under `upload_path/plugin_data/photo-signage/` and stores playlist entries, captions, order, enabled state, and settings in Koha's `plugin_data` table. Existing photo-only playlists are read as image slides and continue to work after upgrading. Back up the Koha database and configured upload directory together. Uninstalling the plugin intentionally leaves uploaded files in place.

## Package

The uploadable Koha Plugin Zip is `PhotoSignage.kpz`. The source layout is also included beside this guide.

Rebuild it with `bash koha-plugin/package.sh` from the project root.

## Verification

Run `prove -v koha-plugin/t/public.t` on a Perl installation with Mojolicious, Mojolicious::Plugin::OpenAPI, and Template Toolkit available. The suite validates and registers the actual route declarations through OpenAPI, then uses real HTTP controller dispatch, HEAD/range streaming, and template rendering, with only Koha configuration/database/auth dependencies mocked. It checks anonymous viewing, denied public writes, hidden/deleted media denial, plugin/global catalogue policies, legacy photo data, and staff CSRF rejection without a session.

Run `node --test koha-plugin/t/*.test.cjs` to check the actual link/copy script, configured and same-server addresses, reverse-proxy prefixes, media URL resolution, independent playback timing, pause/resume, custom-code frame construction, and revision-polling failure behavior. The HTTP suite also covers rendering without a valid `OPACBaseURL`, legacy bookmark redirects, and canonical player paths.

The HTTP suite additionally checks multiple screen URLs, private drafts, published snapshots, templates and independent copies, media dependencies/privacy, revision reads, HEAD/range responses, validation failures, disabled/deleted screens, and staff CSRF rejection. On this workspace's Nix environment, use `bash koha-plugin/t/run-perl.sh koha-plugin/t/public.t` to select the interpreter matching installed XS modules.

For **local development only**, `bash koha-plugin/t/run-perl.sh koha-plugin/t/preview.pl daemon -l http://127.0.0.1:8765` serves a real Mojo/OpenAPI/template harness with **mocked** Koha data and authentication. Visit `http://127.0.0.1:8765/_test/login` to enter its test-only staff workspace. Storage is temporary, and this is not a Koha installation or production sign-in implementation. Never expose this harness publicly; it is excluded from the KPZ. Browser checks against it cannot certify actual Koha permissions, hosting/proxy setup, codecs, or third-party provider availability.

The route declarations follow Koha 22.11 and current plugin API routing/authentication conventions:
- https://github.com/Koha-Community/Koha/blob/22.11.x/Koha/REST/Plugin/PluginRoutes.pm
- https://github.com/Koha-Community/Koha/blob/22.11.x/Koha/REST/V1/Auth.pm
- https://github.com/Koha-Community/Koha/blob/main/Koha/REST/V1/Auth.pm

This repository does not include a live Koha database or deployed OPAC. The local tests do not certify your hosting proxy, plugin registration after restart, actual Koha staff permissions, browser codecs, or third-party embeds. Confirm those on your target Koha instance before using the signage screen.
