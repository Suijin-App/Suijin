// Answers for suijin.app. The app's update feed is https://suijin.app/appcast.xml (SUFeedURL): a build keeps asking
// that address for as long as it is installed, so the address stays and only this redirect changes when releases
// move. Releases live on GitHub; the appcast is an asset of the latest release.
const REPOSITORY = "https://github.com/Suijin-App/Suijin";
const APPCAST = `${REPOSITORY}/releases/latest/download/appcast.xml`;

// Sparkle identifies itself as "Suijin/<version> Sparkle/<version>".
const SUIJIN_AGENT = /^Suijin\/(\d+(?:\.\d+){0,3})\b/;

// Counts one update check under its day and app version, for example "checks:2026-11-14:0.1.0". Each installed copy
// checks about once a day, so a day's count approximates the copies in use. Only the day and the version are kept:
// no address, no identifier, nothing about who asked. Requests that are not from Suijin's updater (browsers, bots)
// are counted together as "other". Concurrent requests may lose an increment; the figure is an estimate.
async function countCheck(request, env) {
  const version = SUIJIN_AGENT.exec(request.headers.get("User-Agent") ?? "")?.[1] ?? "other";
  const key = `checks:${new Date().toISOString().slice(0, 10)}:${version}`;
  const current = Number.parseInt((await env.CHECKS.get(key)) ?? "0", 10) || 0;
  // Kept for about 13 months, then dropped.
  await env.CHECKS.put(key, String(current + 1), { expirationTtl: 400 * 24 * 60 * 60 });
}

export default {
  fetch(request, env, context) {
    const url = new URL(request.url);
    if (url.pathname === "/appcast.xml") {
      // Counting never delays or fails the redirect.
      context.waitUntil(countCheck(request, env).catch(() => {}));
      // Temporary and uncached, so a new release is seen at the next check and the target can change later.
      return new Response(null, { status: 302, headers: { Location: APPCAST, "Cache-Control": "no-store" } });
    }
    // There is no website yet; everything else goes to the repository.
    return Response.redirect(REPOSITORY, 302);
  },
};
