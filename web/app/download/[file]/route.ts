import { ASSETS, assetDownloadUrl } from "@/lib/release";

const NAMES = new Set<string>(Object.values(ASSETS));

/**
 * /download/macos, /download/linux, /download/android, or an asset's full
 * name (what install.sh asks for): redirects to the latest release's file.
 */
export async function GET(_request: Request, ctx: RouteContext<"/download/[file]">) {
  const { file } = await ctx.params;
  const name = (ASSETS as Record<string, string>)[file] ?? (NAMES.has(file) ? file : null);
  if (!name) {
    return new Response("Not found\n", { status: 404 });
  }
  const url = await assetDownloadUrl(name);
  if (!url) {
    return new Response("This download is not available yet. Try again later.\n", {
      status: 404,
    });
  }
  // Signed URLs expire after a few minutes: never cache the redirect.
  return new Response(null, {
    status: 302,
    headers: { Location: url, "Cache-Control": "no-store" },
  });
}
