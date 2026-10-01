# ccnotify download site

Next.js site where people download ccnotify: a landing page, the one-line
installer and the download links. The files themselves come from the latest
GitHub release, which `.github/workflows/release.yml` publishes when you push
a tag (`v0.1.0`, …).

| Path | What |
|---|---|
| `/` | Landing page: features, how it works, downloads per platform, FAQ |
| `/install.sh` | The release's `install.sh`, set up to download the archives from this site: `curl -fsSL <site>/install.sh \| sh` |
| `/download/macos`, `/download/linux`, `/download/android` | Redirect to the latest release's file (also accepts the full file names) |

## Run it

```sh
npm install
npm run dev        # http://localhost:3000
```

## Settings (environment variables)

| Variable | What |
|---|---|
| `GITHUB_REPO` | Repository with the releases. Default `xmustafa5/mewo-on-fire`. |
| `GITHUB_TOKEN` | Needed while the repository is private: a fine-grained token with read-only **Contents** access to it. The site then hands out GitHub's short-lived signed download URLs. Leave it unset for a public repository. |
| `SITE_URL` | Public URL of the site, used in the install command. On Vercel it defaults to the production domain. |

## Deploy on Vercel

1. Import the repository in Vercel and set **Root Directory** to `web`.
2. Add `GITHUB_TOKEN` (private repository) and, with your own domain, `SITE_URL`.
3. Deploy. The page picks up a new release within 5 minutes.

Any other Node.js host works too: `npm run build && npm start`.
