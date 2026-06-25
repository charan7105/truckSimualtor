# Deploy the setup site (Vercel + GitHub)

This `site/` folder is a self-contained static page (`index.html` + `downloads/`). No build step.

## Preview locally first
Double-click `site/index.html` — it opens in your browser exactly as it'll look live.

## Put it on Vercel (≈2 minutes)

### 1. Push to GitHub
If the project isn't on GitHub yet, create a repo and push it (run from the project root):
```
gh repo create matrack-sim-setup --private --source=. --remote=origin --push
```
…or create an empty repo on github.com and:
```
git remote add origin https://github.com/<you>/matrack-sim-setup.git
git push -u origin feature/vijay-disconnect-driveday
```

### 2. Import into Vercel
1. Go to **vercel.com → Add New… → Project**, and import the GitHub repo.
2. **Framework Preset:** *Other* (it's plain static — no build).
3. **Root Directory:** set to **`site`** (so Vercel serves this folder, not the whole repo).
4. Leave Build Command empty / Output Directory empty. Click **Deploy**.

You'll get a URL like `https://matrack-sim-setup.vercel.app`. Share that with the team.

### 3. Updates
Every `git push` to the connected branch → Vercel **auto-redeploys**. To change text or swap in the
Windows download, edit `site/`, commit, push — done.

## Swapping in the Windows download later
Once the dev builds `MatrackSim.exe`:
- Small enough? Drop it in `site/downloads/` and change the Windows step-1 button in `index.html` from the
  "coming soon" span to `<a class="dl" href="downloads/MatrackSim-win.exe" download>…</a>`.
- Larger file? Upload it to a **GitHub Release** and point the button at that release URL instead (keeps the repo small).

## Note on the Mac download
`downloads/MatrackTruckSim-mac.zip` is the unsigned universal `.app`. If you later notarize it with the
Matrack Apple Developer ID, replace this file with the notarized `.dmg`/zip and update the button.
