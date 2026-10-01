/**
 * Downloads come from the GitHub releases that .github/workflows/release.yml
 * publishes. With GITHUB_TOKEN set (a read-only token for the repository) the
 * repository can stay private: the site hands out GitHub's short-lived signed
 * URLs instead of the public release URLs.
 */
export const REPO = process.env.GITHUB_REPO ?? "xmustafa5/mewo-on-fire";

/** Release asset names, keyed by the short names /download/<key> accepts. */
export const ASSETS = {
  macos: "ccnotify-macos.tar.gz",
  linux: "ccnotify-linux-x86_64.tar.gz",
  android: "ccnotify-android.apk",
  installer: "install.sh",
} as const;

export type ReleaseAsset = { name: string; size: number; apiUrl: string };
export type Release = { tag: string; publishedAt: string; assets: ReleaseAsset[] };

type GitHubRelease = {
  tag_name: string;
  published_at: string;
  assets: { name: string; size: number; url: string }[];
};

function githubHeaders(accept = "application/vnd.github+json"): HeadersInit {
  const headers: Record<string, string> = {
    Accept: accept,
    "X-GitHub-Api-Version": "2022-11-28",
  };
  if (process.env.GITHUB_TOKEN) {
    headers.Authorization = `Bearer ${process.env.GITHUB_TOKEN}`;
  }
  return headers;
}

/**
 * The latest published release, cached for 5 minutes. Null when there is
 * none yet, or GitHub cannot be reached.
 */
export async function getLatestRelease(): Promise<Release | null> {
  try {
    const res = await fetch(`https://api.github.com/repos/${REPO}/releases/latest`, {
      headers: githubHeaders(),
      next: { revalidate: 300 },
    });
    if (!res.ok) return null;
    const data = (await res.json()) as GitHubRelease;
    return {
      tag: data.tag_name,
      publishedAt: data.published_at,
      assets: data.assets.map((a) => ({ name: a.name, size: a.size, apiUrl: a.url })),
    };
  } catch {
    return null;
  }
}

/**
 * A URL the browser (or curl) can download the asset of the latest release
 * from: the public release URL, or with a token the signed storage URL that
 * GitHub redirects to (valid for a few minutes). Null when it does not exist.
 */
export async function assetDownloadUrl(name: string): Promise<string | null> {
  if (!process.env.GITHUB_TOKEN) {
    return `https://github.com/${REPO}/releases/latest/download/${encodeURIComponent(name)}`;
  }
  const release = await getLatestRelease();
  const asset = release?.assets.find((a) => a.name === name);
  if (!asset) return null;
  try {
    const res = await fetch(asset.apiUrl, {
      headers: githubHeaders("application/octet-stream"),
      redirect: "manual",
      cache: "no-store",
    });
    return res.headers.get("location");
  } catch {
    return null;
  }
}
