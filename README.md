# DarkEro live library (local demo)

PowerShell-only local demo that reads the public WordPress REST API of **darkero.com** and
serves a filterable video library with search, categories, pagination and download links.

Everything runs on `System.Net.Sockets.TcpListener` — no Node, Python, PHP or database.

## Run

```powershell
# stop anything already on 8080
Get-NetTCPConnection -LocalPort 8080 -State Listen -ErrorAction SilentlyContinue |
  ForEach-Object { Stop-Process -Id $_.OwningProcess -Force }

powershell -NoLogo -NoProfile -ExecutionPolicy Bypass -File .\server.ps1 -Port 8080
```

Open http://localhost:8080/

## Files

| file | purpose |
| --- | --- |
| `server.ps1` | local HTTP server, upstream proxy, caching, poster/video handling |
| `index.html` | single-file front end (hero, filters, grid, lightbox, downloads) |
| `darkero.md` | full technical notes: endpoints, data shape, fixes, verification, restart |

## How it works

- Post listing comes from `/wp-json/wp/v2/posts` with `_embed=wp:featuredmedia`.
- MP4 sources are extracted from `content.rendered`; the `?_=N` suffix is stripped.
- Poster and video bytes are hotlinked from the darkero CDN; only metadata is proxied.
- `data/` is a runtime cache and is git-ignored.
