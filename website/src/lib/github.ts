// The repository's star count, read once when the site is built. A failed lookup leaves the count out instead of
// failing the build or showing a made-up number.
export async function starCount(repository: string): Promise<number | null> {
  try {
    const response = await fetch(`https://api.github.com/repos/${repository}`, {
      headers: { Accept: "application/vnd.github+json", "User-Agent": "suijin-website-build" },
      signal: AbortSignal.timeout(8000),
    });
    if (!response.ok) return null;
    const count = (await response.json()).stargazers_count;
    return typeof count === "number" ? count : null;
  } catch {
    return null;
  }
}

/** 1234 → "1.2k", 87 → "87". */
export function compact(count: number): string {
  return count >= 1000 ? `${(count / 1000).toFixed(count >= 10000 ? 0 : 1)}k` : String(count);
}
