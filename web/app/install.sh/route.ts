import { ASSETS, assetDownloadUrl } from "@/lib/release";

function script(body: string): Response {
  return new Response(body, {
    headers: {
      "Content-Type": "text/x-shellscript; charset=utf-8",
      "Cache-Control": "no-store",
    },
  });
}

/**
 * `curl -fsSL <site>/install.sh | sh`: the latest release's install.sh, set
 * up to download the archives from this site.
 */
export async function GET(request: Request) {
  const site = process.env.SITE_URL?.replace(/\/$/, "") ?? new URL(request.url).origin;
  const url = await assetDownloadUrl(ASSETS.installer);
  const res = url ? await fetch(url, { cache: "no-store" }).catch(() => null) : null;
  if (!res?.ok) {
    return script(
      'echo "mewo: no release has been published yet. Try again later." >&2\nexit 1\n',
    );
  }
  const text = await res.text();
  return script(
    text.replace("${MEWO_DOWNLOAD_URL:-}", `\${MEWO_DOWNLOAD_URL:-${site}/download}`),
  );
}
