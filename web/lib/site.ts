/** Where the site lives. `SITE_URL` replaces it for a copy hosted elsewhere. */
const SITE_URL = "https://www.mewo-on-fire.com";

/** Public URL of this site, for the install command and metadata. */
export function siteUrl(): string {
  if (process.env.SITE_URL) return process.env.SITE_URL.replace(/\/$/, "");
  if (process.env.NODE_ENV === "development") return "http://localhost:3000";
  return SITE_URL;
}

/** The one-line installer for macOS and Linux. */
export function installCommand(): string {
  return `curl -fsSL ${siteUrl()}/install.sh | sh`;
}
