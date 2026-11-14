// Answers for suijin.app. The app's update feed is https://suijin.app/appcast.xml (SUFeedURL): a build keeps asking
// that address for as long as it is installed, so the address stays and only this redirect changes when releases
// move. Releases live on GitHub; the appcast is an asset of the latest release.
const REPOSITORY = "https://github.com/Suijin-App/Suijin";
const APPCAST = `${REPOSITORY}/releases/latest/download/appcast.xml`;

export default {
  fetch(request) {
    const url = new URL(request.url);
    if (url.pathname === "/appcast.xml") {
      // Temporary and uncached, so a new release is seen at the next check and the target can change later.
      return new Response(null, { status: 302, headers: { Location: APPCAST, "Cache-Control": "no-store" } });
    }
    // There is no website yet; everything else goes to the repository.
    return Response.redirect(REPOSITORY, 302);
  },
};
