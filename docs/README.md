# MediGemma Field — Live Demo Page (GitHub Pages source)

This folder is the source for the project's **Live Demo URL** (Kaggle requirement).

## Enable GitHub Pages

1. Push this folder to the `main` branch.
2. Go to: **Settings → Pages**
3. Under **Source**: select `Deploy from a branch`
4. Branch: `main`, folder: `/docs`
5. Save.
6. After ~30 seconds, the page will be live at:
   `https://<username>.github.io/medigemma_field/`

## Before final submission

Edit `index.html` and replace these placeholders:

| Placeholder | Replace with |
|---|---|
| `[YOUTUBE_VIDEO_ID]` | Actual YouTube video ID after upload |
| `[APK_RELEASE_URL]` | GitHub Release APK download URL |
| `[GITHUB_REPO_URL]` | `https://github.com/chyonek/medigemma_field` |

## Testing locally

```bash
cd docs
python -m http.server 8000
# Open http://localhost:8000
```

Or in VS Code: install "Live Server" extension → right-click `index.html` → Open with Live Server.

## Asset paths

All hero / icon images are in `docs/assets/`. Use relative paths:
```html
<img src="assets/app_icon.png" />
```
