/** Public URL of this site, for the install command and metadata. */
export function siteUrl(): string {
  if (process.env.SITE_URL) return process.env.SITE_URL.replace(/\/$/, "");
  if (process.env.VERCEL_PROJECT_PRODUCTION_URL) {
    return `https://${process.env.VERCEL_PROJECT_PRODUCTION_URL}`;
  }
  return "http://localhost:3000";
}

/** The one-line installer for macOS and Linux. */
export function installCommand(): string {
  return `curl -fsSL ${siteUrl()}/install.sh | sh`;
}
