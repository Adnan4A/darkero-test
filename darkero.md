# DarkEro API demo — progress log

_Last updated: 2026-11-09_

Local test site that consumes the public WordPress REST API of **darkero.com** and serves a
filterable video library with a hero landing page, playback, and download links.

- **Runtime:** PowerShell 5.1 (`System.Net.Sockets.TcpListener`), no Node/Python/php required.
- **Entry point:** `server.ps1` → http://localhost:8080/
- **Status:** working. 10/10 test videos play; categories, filtering, search, pagination and
  downloads all verified.

---

## 1. What darkero.com is

Standard WordPress install (theme `videoclub` / child theme `darkero`), public REST API at
`/wp-json/`, **no auth and no custom namespaces**. Video posts are ordinary `post` entries;
the MP4 is embedded directly in the post content.

```
GET https://darkero.com/wp-json/wp/v2/posts?per_page=100&page=1
X-WP-Total: 9246
X-WP-TotalPages: 93   (at per_page=100; 386 at per_page=24)
```

Each post's `content.rendered` contains:

```html
<video class="wp-video-shortcode" id="video-39696-2" preload="metadata" controls>
  <source type="video/mp4"
          src="https://files5.darkero.com/wp-content/uploads/2026/11/Bhabhi-Cute-Round-Boobs.mp4?_=2" />
</video>
```

Featured image (`featured_media`) is a **JPEG poster**, not the video attachment. It is only
returned when `_embed=wp:featuredmedia` is requested together with `_links,_embedded` inside
`_fields` (omitting `_links` silently drops `_embedded`):

```
GET /wp-json/wp/v2/posts?per_page=24&page=1&orderby=date&order=desc
    &_embed=wp:featuredmedia
    &_fields=id,slug,date,link,title,content,categories,featured_media,_links,_embedded
```

Poster sizes available: `videoclub_post_thumb` (480x270, used for cards), `large` (576x1024,
used for the hero), `full`, `medium`, `thumbnail`, `post-thumbnail`.

## 2. Categories

```
GET /wp-json/wp/v2/categories?per_page=100&_fields=id,name,slug,count,parent
```

11 categories, all top-level:

| id | name | slug | count |
| -- | ---- | ---- | ----: |
| 1 | Porn Videos | porn | 8655 |
| 16 | Celebrity | celebrity | 282 |
| 56 | Gay | gay | 232 |
| 33 | Threesome | threesome | 227 |
| 55 | Viral | viral | 168 |
| 17 | Scandal | scandal | 133 |
| 26 | Asian | asian | 119 |
| 29 | Models | models | 100 |
| 31 | Lesbian | lesbian | 55 |
| 32 | Foursome | foursome | 38 |
| 49 | BDSM | bdsm | 7 |

`id 1` (Porn Videos) is the catch-all applied to almost every post, so the UI uses it as
“All videos” instead of showing it as a separate filter. Counts overlap (a post can hold
several categories) — the 11 counts sum to more than 9,246.

Filtering / search:

```
GET /wp-json/wp/v2/posts?categories=16&per_page=24&page=2
GET /wp-json/wp/v2/posts?search=bhabhi&per_page=24
```

## 3. File hosting

MP4s and posters live on a fan-out of static hosts, no hotlink protection:

| Host | IP |
| ---- | -- |
| `files2.darkero.com` | 91.224.92.116 |
| `files3.darkero.com` | 91.211.90.239 |
| `files4.darkero.com` | 91.211.90.239 |
| `files5.darkero.com` | 91.211.90.239 |

Older media sits on `darkero.com/wp-content/uploads/...`. `HEAD` and `Range: bytes=0-1023`
both return `200`/`206 video/mp4` with **no Referer requirement**.

### The `?_=N` trap (important)

WordPress appends a cache-buster: `.../Name.mp4?_=3`. The file host treats that as a hotlink
and answers:

```
302  Location: https://darkero.com/?_=3
```

That HTML page is why `<video>` reported `MEDIA_ERR_SRC_NOT_SUPPORTED` (code 4) on 9/10
players. The **bare path** returns `206 video/mp4`. Arbitrary queries (`?x=1`) also work — only
the `?_=` form is blocked. The proxy therefore strips everything after `?` before emitting a
URL, and both playback and `/dl/` use the clean path.

## 4. Local proxy — `server.ps1`

Single-threaded `TcpListener` on loopback. Serves `index.html` from disk on every request (no
restart needed for UI edits; **restart required for `server.ps1` edits**).

| Route | Behavior |
| ----- | -------- |
| `GET /` | `index.html` |
| `GET /api/bootstrap` | `{ totalVideos, categories[], videos: {...page 1} }` — one round trip for the landing page |
| `GET /api/categories` | `{ totalVideos, categories[] }`, cached 5 min |
| `GET /api/videos?category=&page=&per_page=&search=` | normalized, paginated envelope |
| `GET /dl/{id}` | `302` → bare MP4 (resolves via cache, otherwise `GET /wp/v2/posts/{id}`) |
| `GET /health` | `{"ok":true}` |
| `GET /favicon.ico` | `204` |

Normalized item shape:

```json
{
  "id": 39820,
  "slug": "islamabad-cuckhold-wife-video",
  "title": "Islamabad Cuckhold Wife Video",
  "date": "2026-11-09T...",
  "page": "https://darkero.com/islamabad-cuckhold-wife-video/",
  "mp4": "https://files5.darkero.com/wp-content/uploads/2026/11/Islamabad-Cuckhold-Wife-Video.mp4",
  "poster": "https://darkero.com/wp-content/uploads/2026/11/Islamabad-Cuckhold-Wife-Video-480x270.jpg",
  "posterFull": "https://darkero.com/wp-content/uploads/2026/11/Islamabad-Cuckhold-Wife-Video.jpg",
  "categories": [1, 33],
  "download": "/dl/39820"
}
```

Envelope:

```json
{ "page":1, "perPage":24, "total":282, "totalPages":12,
  "category":16, "search":"", "error":null, "items":[ ... ] }
```

Details worth remembering:

- In-memory cache: categories 5 min; each `videos` key (`category|page|perPage|search`) 5 min;
  `?refresh=1` bypasses.
- `per_page` clamped to 1..48.
- Requesting a page past `totalPages` makes WP return `400`; the proxy catches it and returns an
  empty `items` array while preserving `total`/`totalPages` from page 1.
- `/dl/{id}` builds an `id → mp4` index from every fetched page; misses fall back to a single
  post lookup, so it works for any id, not just the current page.

## 5. Front end — `index.html`

Single file, no dependencies, dark theme (`#06070a` base, accent gradient `#ff3d6e → #ff8a3d`).

- **Topbar** — blurred sticky bar, wordmark, debounced search box, JSON link.
- **Hero** — gradient/glow + masked grid backdrop, 3-line headline with gradient accent line,
  live stats (9,246 videos / 11 categories), CTAs, and a featured card for the newest upload
  (portrait poster, play button, title, MP4 link).
- **Category bar** — sticky chips with counts; active chip is gradient-filled; excludes id 1.
- **Grid** — 24 cards per page, 480x270 posters, hover lift + zoom + play ring, corner download
  button, category/date meta. Skeleton shimmer while loading.
- **Search** — 380 ms debounce, combines with the active category.
- **Lightbox** — click any poster/title, loads the bare MP4, ←/→ cycles the current list, Esc
  closes, download button included.
- **Load more** — appends the next page, hides at the end.
- **Footer** — endpoint reference.

### Bugs hit while building

1. **`?_=N` redirect** — see section 3.
2. **`array | ConvertFrom-Json` in PS 5.1** — the cmdlet emits a JSON array as a *single*
   pipeline object, so `@($resp.Content | ConvertFrom-Json)` produced a 1-element array whose
   `[0]` was the whole 24-item array (`[int]$post.id` then threw
   “Cannot convert System.Object[] to System.Int32”). Fix: assign first, then wrap:
   ```powershell
   $parsed = $resp.Content | ConvertFrom-Json
   $posts  = @($parsed)
   ```
3. **`.library` overrode `.shell` padding** — the `padding` shorthand zeroed the horizontal
   gutter. Fix: use `padding-top` / `padding-bottom` only.
4. **Bootstrap reported `24 of 24`** — the page called `updateHead()` with the bootstrap
   envelope instead of `d.videos`. Fix: pass `d.videos` and set `#more` visibility in `boot()`.

## 6. Verification (2026-11-09)

- `/api/bootstrap` → `totalVideos 9246`, 11 categories, 24 items, `totalPages 386`.
- Category 16 (Celebrity) → 282 total / 12 pages; page 2 returns different ids (no overlap).
- Search `bhabhi` → 1,787 matches.
- Page overflow (`page=999`) → empty items, total preserved, no error leak.
- Downloads: `/dl/{id}` → `302` → `206 video/mp4` for 10/10 samples.
- Players: 10/10 `readyState 4`, `error null`, real durations (29 s – 6:04) and resolutions.
- Lightbox: `readyState 4`, 62 s clip, 608x1080, no console errors.
- All category posters load (480x270 JPEGs, hotlink-safe).

Known limits:

- Server is single-threaded; a cold upstream fetch blocks concurrent requests.
- Video bytes and posters are hotlinked from darkero's CDN — their bandwidth, their rules.
- One post in the Celebrity set has no `<source>` in `content.rendered`, so that page returns
  23 playable items while WP still counts 24.
- No persistence; all caches are in-memory and reset on restart.

## 7. Run / restart

```powershell
# free the port
Get-NetTCPConnection -LocalPort 8080 -State Listen |
  ForEach-Object { Stop-Process -Id $_.OwningProcess -Force }

# start
powershell -NoLogo -NoProfile -ExecutionPolicy Bypass `
  -File "C:\Users\thead\Documents\Default Project\darkero-test\server.ps1" -Port 8080
```

## 8. Next

- Optional: persist the catalogue (`id, title, mp4, poster`) to `data\videos.json` so cold starts
  and searches are instant.
- Optional: add sort options (WP only exposes date; view counts would need scraping).
- Optional: replace the single-threaded listener with a small runspace pool if concurrency matters.

---

## Last edit — 2026-11-09

Rebuilt the demo from a 10-video proof into the full category landing page:

- `server.ps1`: added `/api/bootstrap`, `/api/categories`, category/search/pagination on
  `/api/videos`, 5-minute in-memory cache, `per_page` clamp, page-overflow handling,
  `id → mp4` index for `/dl/`, poster + posterFull extraction, HEAD support, extra status codes.
- Fixed the PS 5.1 `ConvertFrom-Json` array wrapping bug in the categories and posts parsers.
- `index.html`: new hero, sticky category chips, search, poster grid, lightbox player with
  keyboard nav, load-more, footer endpoint reference.
- Fixed `.library` horizontal padding and the bootstrap `total`/`#more` wiring.
- Removed the stale `data/videos.json` cache; nothing on disk is required at runtime.
