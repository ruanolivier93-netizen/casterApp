/// Lightweight ad/tracker blocker for the in-app WebView browser.
///
/// Caster-safe strategy:
///   1. **Subresource blocking** for known ad/tracker hosts.
///   2. **Explicit popup/redirect blocking** for hostile navigation targets.
///   3. **Cosmetic CSS hiding** for common ad containers.
///   4. **Video detection** remains always-on for extraction/casting.
///
/// Heavy DOM/event interception scripts are intentionally kept out of the live
/// browser pipeline because they are much more likely to break playback.
library;

class AdBlocker {
  AdBlocker._();

  // ══════════════════════════════════════════════════════════════════════════
  // Layer 1: Domain-level blocking
  // ══════════════════════════════════════════════════════════════════════════

  /// Returns `true` if a subresource URL should be blocked.
  ///
  /// This is intentionally narrower than navigation blocking: it is aimed at
  /// obvious ad/tracker assets and should avoid matching generic app routes.
  static bool shouldBlockSubresource(String url) {
    final uri = Uri.tryParse(url);
    if (uri == null) return false;

    // Never block actual video/media resources.
    if (_looksLikeMediaUrl(uri, url)) return false;

    final host = uri.host.toLowerCase();

    // Whitelist video CDNs and streaming platforms.
    if (_videoDomains.any((d) => host == d || host.endsWith('.$d'))) {
      return false;
    }

    // Layer 1: Domain match for known ad/tracker hosts.
    if (_blockedDomains.any((d) => host == d || host.endsWith('.$d'))) {
      return true;
    }

    // Layer 2: Narrow URL signature match for obvious ad-serving assets.
    final fullUrl = url.toLowerCase();
    if (_blockedPathPatterns.any((p) => fullUrl.contains(p))) {
      return true;
    }

    return false;
  }

  /// Returns `true` if a main-frame or popup navigation should be blocked.
  ///
  /// Navigation blocking is stricter than asset blocking because false
  /// positives here are much more damaging to a casting workflow.
  static bool shouldBlockNavigation(String url) {
    final uri = Uri.tryParse(url);
    if (uri == null) return false;

    if (_looksLikeMediaUrl(uri, url)) return false;

    final host = uri.host.toLowerCase();
    if (_videoDomains.any((d) => host == d || host.endsWith('.$d'))) {
      return false;
    }

    if (_unsafeNavigationHosts.any((d) => host == d || host.endsWith('.$d'))) {
      return true;
    }

    return isPopupOrRedirect(url);
  }

  /// Returns `true` when the page itself is likely to be a playback surface.
  ///
  /// On these pages we prefer the lightest viable blocker profile so that
  /// player bootstrapping, DRM/session code, and site-specific controls are
  /// less likely to break.
  static bool isPlaybackSensitiveUrl(String url) {
    final uri = Uri.tryParse(url);
    if (uri == null) return false;

    final host = uri.host.toLowerCase();
    if (_playbackSensitiveHosts.any((d) => host == d || host.endsWith('.$d'))) {
      return true;
    }

    final path = uri.path.toLowerCase();
    return path.contains('/watch') ||
        path.contains('/embed') ||
        path.contains('/player') ||
        path.contains('/live') ||
        path.contains('/video');
  }

  /// Returns `true` if the URL looks like a popup, redirect, or affiliate ad.
  /// Used for navigation-level blocking (complements [shouldBlock]).
  static bool isPopupOrRedirect(String url) {
    final lower = url.toLowerCase();
    const patterns = [
      // Affiliate / tracking query parameters
      'click_id=', 'aff_id=', 'offer_id=', 'aff_sub=',
      'clickid=', 'affid=', 'campaign_id=',
      // Banner / zone ad serving
      '?zoneid=', '&zoneid=', '?bannerid=', '&bannerid=',
      // Ad redirect URL parameters
      '?adurl=', '&adurl=', '?ad_url=', '&ad_url=',
      // Google ad click tracking
      '/aclk?', '/pagead/',
      // CPA / smartlink paths
      '/smartlink/', '/cpa/', '/cpl/', '/cpc/',
      // Popup / popunder techniques
      'popunder', 'clickunder', 'pop.js', 'popjs',
      // Scam landing page patterns
      '/lucky-visitor', '/claim-reward', '/spin-wheel', '/prize-winner',
      'congratulations-you', 'you-have-won',
      // URL shorteners used for ad redirects
      'linkvertise.com', 'shrinkme.io', 'cpmlink.net',
      'exe.io', 'fc.lc', 'za.gl',
    ];
    for (final p in patterns) {
      if (lower.contains(p)) return true;
    }
    return false;
  }

  static bool _looksLikeMediaUrl(Uri uri, String url) {
    final path = uri.path.toLowerCase();
    if (_videoExtensions.any((ext) => path.endsWith(ext))) return true;

    final lower = url.toLowerCase();
    if (lower.contains('mime=video%2f') ||
        lower.contains('mime=audio%2f') ||
        lower.contains('mime=video/') ||
        lower.contains('mime=audio/') ||
        lower.contains('contenttype=video') ||
        lower.contains('contenttype=audio') ||
        lower.contains('format=m3u8') ||
        lower.contains('format=mpd') ||
        lower.contains('manifest') ||
        lower.contains('playlist') ||
        lower.contains('videoplayback')) {
      return true;
    }

    return false;
  }

  static const _videoExtensions = [
    '.mp4', '.m4v', '.webm', '.mkv', '.avi', '.mov', '.flv', '.ts',
    '.3gp', '.wmv', '.ogv', '.m3u8', '.mpd', '.m4s', '.f4v',
  ];

  /// Domains that serve legitimate video content — never block these.
  static const _videoDomains = <String>[
    // YouTube / Google video
    'googlevideo.com', 'ytimg.com', 'youtube.com', 'youtu.be',
    'youtube-nocookie.com', 'yt3.ggpht.com',
    // Vimeo
    'vimeocdn.com', 'player.vimeo.com', 'vimeo.com',
    // Major CDNs
    'akamaihd.net', 'akamaized.net', 'cloudfront.net', 'fastly.net',
    'cdn77.org', 'cdnvideo.ru', 'limelight.com', 'llnwd.net',
    'edgecastcdn.net', 'azureedge.net', 'stackpathdns.com',
    'hwcdn.net', 'kxcdn.com', 'gcdn.co',
    // Video players & platforms
    'jwpcdn.com', 'jwplatform.com', 'jwplayer.com',
    'brightcovecdn.com', 'brightcove.com', 'bcove.video',
    'vidible.tv', 'vidazoo.com', 'connatix.com',
    'dailymotion.com', 'dmcdn.net',
    'twitch.tv', 'ttvnw.net', 'jtvnw.net',
    'streamable.com', 'bitmovin.com',
    'cdn.flowplayer.com', 'flowplayer.com',
    'mux.com', 'stream.mux.com',
    'cloudflarestream.com', 'videodelivery.net',
    // Social media video
    'fbcdn.net', 'fbvideo.com', 'cdninstagram.com',
    'pstatp.com', 'tiktokcdn.com', 'muscdn.com',
    'media.tumblr.com', 'redditvideo.com', 'redditmedia.com',
    'v.redd.it', 'preview.redd.it',
    // Misc video services
    'theoplayer.com', 'mediastream.pe', 'wistia.com',
    'wistia.net', 'vidyard.com', 'loom.com',
    'bunnycdn.com', 'b-cdn.net',
    // Streaming-site video hosts (used by bstsrs, lookmovie, etc.)
    'voe.sx', 'savefiles.com', 'streamtape.com',
    'streamtape.to', 'stape.fun', 'streamsb.net',
    'sbembed.com', 'embedsito.com', 'vidcloud.co',
  ];

  /// Expose blocked domains for use with InAppWebView ContentBlocker rules.
  static List<String> get blockedDomains => _blockedDomains;

  static const _playbackSensitiveHosts = <String>[
    'youtube.com',
    'youtu.be',
    'youtube-nocookie.com',
    'vimeo.com',
    'player.vimeo.com',
    'dailymotion.com',
    'twitch.tv',
    'streamable.com',
    'jwplayer.com',
    'jwplatform.com',
    'flowplayer.com',
    'theoplayer.com',
    'bitmovin.com',
    'mux.com',
    'cloudflarestream.com',
    'facebook.com',
    'fb.watch',
    'instagram.com',
    'tiktok.com',
    'reddit.com',
    'x.com',
    'twitter.com',
    'netflix.com',
    'primevideo.com',
    'amazon.com',
    'hulu.com',
    'disneyplus.com',
    'max.com',
    'hbomax.com',
    'paramountplus.com',
    'peacocktv.com',
    'showmax.com',
    'dstv.com',
    'sabc.co.za',
  ];

  static const _unsafeNavigationHosts = <String>[
    'doubleclick.net',
    'googlesyndication.com',
    'googleadservices.com',
    'amazon-adsystem.com',
    'adnxs.com',
    'adsrvr.org',
    'popads.net',
    'popcash.net',
    'propellerads.com',
    'juicyads.com',
    'exoclick.com',
    'hilltopads.com',
    'trafficjunky.com',
    'clickadu.com',
    'trafficstars.com',
    'adsterra.com',
    'a-ads.com',
    'adf.ly',
    'shorte.st',
    'sh.st',
    'bc.vc',
    'ouo.io',
    'clk.sh',
    'admaven.com',
    'richpush.com',
    'luluvdoo.com',
    'bysesayeveum.com',
    'clicksfly.com',
    'moneyclick.com',
    'shrink.pe',
    'wishonly.site',
    'linkvertise.com',
    'shrinkme.io',
    'cpmlink.net',
    'exe.io',
    'fc.lc',
    'za.gl',
  ];

  // ── Blocked domains (~250 entries) ────────────────────────────────────────
  static const _blockedDomains = <String>[
    // ── Google Ads / DFP / AdSense / Analytics ──
    'doubleclick.net', 'googlesyndication.com', 'googleadservices.com',
    'google-analytics.com', 'googletagmanager.com', 'googletagservices.com',
    'pagead2.googlesyndication.com', 'adservice.google.com',
    'tpc.googlesyndication.com', 'fundingchoicesmessages.google.com',
    'securepubads.g.doubleclick.net', 'ad.doubleclick.net',
    'stats.g.doubleclick.net', 'cm.g.doubleclick.net',
    'bid.g.doubleclick.net', 'googleads.g.doubleclick.net',
    'www.googleadservices.com', 'www.google-analytics.com',
    'ssl.google-analytics.com', 'analytics.google.com',

    // ── Facebook / Meta tracking ──
    'facebook.net', 'an.facebook.com', 'pixel.facebook.com',
    'connect.facebook.net',

    // ── Amazon ads ──
    'amazon-adsystem.com', 'aax.amazon-adsystem.com',
    'assoc-amazon.com', 'z-na.amazon-adsystem.com',

    // ── Twitter / X ──
    'ads-twitter.com', 'ads-api.twitter.com', 'analytics.twitter.com',
    't.co', 'static.ads-twitter.com',

    // ── Microsoft / Bing ──
    'bat.bing.com', 'ads.microsoft.com', 'c.bing.com',
    'clarity.ms', 'c.clarity.ms',

    // ── Major ad exchanges & SSPs ──
    'adnxs.com', 'adsrvr.org', 'adform.net', 'adform.com',
    'openx.net', 'pubmatic.com', 'casalemedia.com',
    'rubiconproject.com', 'indexww.com', 'indexexchange.com',
    'bidswitch.net', 'spotxchange.com', 'spotx.tv',
    'contextweb.com', 'lijit.com', 'sovrn.com',
    'sharethrough.com', 'smartadserver.com',
    'yieldmo.com', 'yieldlab.net', 'yieldlab.de',
    'triplelift.com', 'gumgum.com', '33across.com',
    'trustx.org', 'emxdgt.com', 'synacor.com',
    'unrulymedia.com', 'rhythmone.com', 'justpremium.com',
    'conversantmedia.com', 'media.net',

    // ── Header bidding / Prebid ──
    'prebid.org', 'prebid-server.rubiconproject.com',
    'hb.adscale.de', 'ib.adnxs.com', 'acdn.adnxs.com',

    // ── Ad networks — display ──
    'criteo.com', 'criteo.net', 'outbrain.com',
    'taboola.com', 'revcontent.com', 'mgid.com',
    'content-ad.net', 'contentad.net', 'nativo.net', 'nativo.com',
    'zedo.com', 'advertising.com', 'serving-sys.com',
    'yieldmanager.com', 'adtechus.com', 'adtech.de',

    // ── Mobile ad SDKs ──
    'admob.com', 'mopub.com', 'inmobi.com',
    'unity3d.com', 'unityads.unity3d.com',
    'applovin.com', 'vungle.com', 'ironsrc.com',
    'chartboost.com', 'adcolony.com',
    'startappservice.com', 'supersonic.com',
    'tapjoy.com', 'fyber.com',

    // ── Video ad networks (VAST/VPAID) ──
    'innovid.com', 'flashtalking.com', 'springserve.com',
    'extremereach.io', 'freewheel.com', 'freewheel.tv',
    'fwmrm.net', 'adaptv.advertising.com',
    'ads.stickyadstv.com', 'cdn.teads.tv', 'teads.tv',
    'a.teads.tv', 'vidoomy.com', 'seedtag.com',

    // ── Tracking / analytics ──
    'scorecardresearch.com', 'quantserve.com', 'quantcast.com',
    'segment.io', 'segment.com', 'cdn.segment.com',
    'mixpanel.com', 'hotjar.com', 'mouseflow.com',
    'fullstory.com', 'crazyegg.com', 'clicktale.com',
    'newrelic.com', 'nr-data.net', 'js-agent.newrelic.com',
    'omtrdc.net', 'demdex.net', 'everesttech.net',
    'bluekai.com', 'exelator.com', 'krxd.net',
    'turn.com', 'rlcdn.com', 'agkn.com',
    'mathtag.com', 'dotomi.com',
    'adsymptotic.com', 'adscience.nl',

    // ── Attribution & deep linking (tracking-heavy) ──
    'flurry.com', 'adjust.com', 'adjust.io',
    'branch.io', 'app.link', 'kochava.com',
    'appsflyer.com', 'singular.net', 'tenjin.io',

    // ── Fingerprinting / anti-fraud (tracking) ──
    'iovation.com', 'threatmetrix.com', 'deviceidentity.com',
    'sift.com', 'permutive.com', 'permutive.app',
    'id5-sync.com', 'liveintent.com', 'liveramp.com',
    'adsrvr.org', 'thetradedesk.com',

    // ── Pop-unders / redirects / malvertising ──
    'popads.net', 'popcash.net', 'propellerads.com',
    'juicyads.com', 'exoclick.com', 'hilltopads.com',
    'trafficjunky.com', 'clickadu.com', 'trafficstars.com',
    'adsterra.com', 'a-ads.com', 'adf.ly', 'shorte.st',
    'sh.st', 'bc.vc', 'ouo.io', 'clk.sh',
    'admaven.com', 'richpush.com', 'pushcrew.com',
    'pushwoosh.com', 'cleverpush.com',

    // ── Streaming-site ad redirectors ──
    'luluvdoo.com', 'bysesayeveum.com', 'clicksfly.com',
    'moneyclick.com', 'shrink.pe', 'doods.pro',
    'streamlare.com', 'doodstream.com', 'dood.so',
    'dood.la', 'dood.ws', 'dood.watch',
    'upstream.to', 'mixdrop.co', 'mixdrop.to',
    'filemoon.sx', 'filemoon.to', 'wishonly.site',

    // ── Consent / cookie tracking ──
    'cookielaw.org', 'cookiepro.com', 'trustarc.com',
    'consensu.org', 'cookiebot.com', 'consentmanager.net',
    'privacy-center.org', 'onetrust.com', 'osano.com',
    'iubenda.com', 'termly.io',

    // ── Social widgets (tracking) ──
    'addthis.com', 'addtoany.com', 'sharethis.com',
    'po.st', 'sumo.com', 'sumome.com',

    // ── Push notification spam ──
    'onesignal.com', 'pushassist.com', 'subscribemenot.com',
    'sendpulse.com', 'web-push.io',

    // ── Email / marketing automation ──
    'mkt.com', 'hubspot.com', 'hs-analytics.net',
    'hsforms.net', 'marketo.com', 'marketo.net',
    'pardot.com', 'eloqua.com',

    // ── A/B testing / optimization ──
    'optimizely.com', 'cdn.optimizely.com',
    'vwo.com', 'd5nxst8fruw4z.cloudfront.net',
    'abtasty.com', 'kameleoon.com',

    // ── Customer data platforms ──
    'mparticle.com', 'treasuredata.com', 'tealiumiq.com',
    'tealium.com', 'tags.tiqcdn.com',

    // ── More trackers ──
    'chartbeat.com', 'parsely.com', 'parse.ly',
    'sentry.io', 'bugsnag.com', 'loggly.com',
    'amplitude.com', 'cdn.amplitude.com',
    'heap.io', 'heapanalytics.com',
    'ir-na.amazon-adsystem.com',
    'c.amazon-adsystem.com',

    // ── Anti-adblock / ad recovery ──
    'pagefair.com', 'pagefair.net',
    'blockthrough.com', 'admiral.com',
    'getadmiral.com', 'uponit.com',
    'sourcepoint.com',
  ];

  // ══════════════════════════════════════════════════════════════════════════
  // Layer 2: URL path-pattern blocking
  // ══════════════════════════════════════════════════════════════════════════

  static const _blockedPathPatterns = <String>[
    '/adsense', '/dfp/', '/doubleclick/',
    '/preroll', '/midroll', '/postroll',
    '/vast/', '/vpaid/', '/vmap/',
    '/pagead/', '/afs/ads', '/adsid/',
    '.googlesyndication.com', 'googletag.js',
    'adsbygoogle.js', 'show_ads.js',
    '/prebid', '/header-bidding/',
    '/sponsor/', '/sponsored/',
    '/native-ad/', '/native_ad/',
    '.adsrvr.org', '/outbrain/',
    '/taboola/', '/mgid/',
    'amazon-adsystem', '/aax/',
    '/imp/', '/impression/',
  ];

  // ══════════════════════════════════════════════════════════════════════════
  // Layer 3: CSS element-hiding injection
  // ══════════════════════════════════════════════════════════════════════════

  static const cssRules = '''
/* ── RL Caster Ad Blocker v2 – CSS layer ───────────────────────── */

/* ── Generic ad containers ── */
[id*="google_ads"           i],
[id*="ad-container"         i],
[id*="ad_container"         i],
[id*="ad-wrapper"           i],
[id*="ad_wrapper"           i],
[id*="adslot"               i],
[id*="adbanner"             i],
[id*="ad-banner"            i],
[id*="ad-holder"            i],
[id*="ad-placement"         i],
[id*="ad-block"             i],
[id*="ad_block"             i],
[id*="ad-unit"              i],
[id*="sidebar-ad"           i],
[id*="footer-ad"            i],
[id*="top-ad"               i],
[id*="bottom-ad"            i],
[id*="leaderboard-ad"       i],
[class*="ad-container"      i],
[class*="ad_container"      i],
[class*="ad-wrapper"        i],
[class*="ad_wrapper"        i],
[class*="adslot"            i],
[class*="adbanner"          i],
[class*="ad-banner"         i],
[class*="ad-placement"      i],
[class*="ad-unit"           i],
[class*="ad_unit"           i],
[class*="ads-banner"        i],
[class*="ad-holder"         i],
[class*="ad-block"          i],
[class*="ad_block"          i],
[class*="sidebar-ad"        i],
[class*="footer-ad"         i],
[class*="google-ad"         i],
[class*="adBox"             i],
[class*="adbox"             i],
[class*="ad-box"            i],
[class*="ad_box"            i],

/* ── Specific networks ── */
[class*="sponsored-content" i],
[class*="sponsored_content" i],
[class*="sponsored-post"    i],
[class*="taboola"           i],
[class*="outbrain"          i],
[class*="mgid"              i],
[class*="revcontent"        i],
[class*="content-ad"        i],
[class*="nativo-ad"         i],
[class*="teads"             i],
[class*="seedtag"           i],
[data-ad],
[data-ad-slot],
[data-ad-unit],
[data-dfp],
[data-google-query-id],
div[aria-label="Ads"        i],
div[aria-label="Advertisement" i],
div[aria-label="Sponsored"  i],

/* ── Ad iframes ── */
iframe[src*="doubleclick"   ],
iframe[src*="googlesyndication"],
iframe[src*="adnxs"         ],
iframe[src*="amazon-adsystem"],
iframe[src*="ads."          ],
iframe[src*="/ads/"         ],
iframe[src*="adserver"      ],
iframe[id*="google_ads"     ],
iframe[id*="aswift"         ],

/* ── Ad elements ── */
ins.adsbygoogle,
amp-ad,
amp-embed,
amp-sticky-ad,
amp-auto-ads,

/* ── Cookie consent / GDPR banners ── */
[id*="cookie-banner"      i],
[id*="cookie_banner"      i],
[id*="cookie-consent"     i],
[id*="cookie_consent"     i],
[id*="gdpr"               i],
[id*="consent-banner"     i],
[id*="cookieNotice"       i],
[id*="cookie-notice"      i],
[id*="cookie-popup"       i],
[id*="cookie-modal"       i],
[id*="cookie-wall"        i],
[id*="privacy-banner"     i],
[class*="cookie-banner"   i],
[class*="cookie_banner"   i],
[class*="cookie-consent"  i],
[class*="cookie_consent"  i],
[class*="gdpr"            i],
[class*="consent-banner"  i],
[class*="CookieConsent"   i],
[class*="cc-window"       i],
[class*="cc-banner"       i],
[class*="cookie-notice"   i],
[class*="cookie-popup"    i],
[class*="cookie-wall"     i],
[class*="privacy-banner"  i],
[class*="cookieBar"       i],

/* ── Newsletter / subscribe popups ── */
[class*="newsletter-popup" i],
[class*="subscribe-modal"  i],
[class*="newsletter-modal" i],
[class*="email-popup"      i],
[class*="signup-popup"     i],
[class*="exit-intent"      i],
[id*="newsletter-popup"    i],
[id*="subscribe-modal"     i],
[id*="newsletter-modal"    i],
[id*="email-popup"         i],
[id*="exit-intent"         i],

/* ── Overlay / interstitial ads ── */
[class*="interstitial"     i],
[class*="overlay-ad"       i],
[class*="modal-ad"         i],
[class*="splash-ad"        i],
[class*="welcome-ad"       i],
[class*="paywall"          i],
[id*="interstitial"        i],
[id*="overlay-ad"          i],

/* ── Notification / push prompts ── */
[class*="push-notification" i],
[class*="web-push"          i],
[class*="notification-prompt" i],
[id*="push-notification"    i],
[id*="onesignal"            i],

/* ── Anti-adblock nag screens ── */
[class*="anti-adblock"     i],
[class*="adblock-notice"   i],
[class*="adblock-warning"  i],
[class*="adblock-modal"    i],
[class*="adblock-detected" i],
[class*="adb-overlay"      i],
[id*="anti-adblock"        i],
[id*="adblock-notice"      i],
[id*="adblock-warning"     i],
[id*="adblock-modal"       i],
[id*="adblock-detected"    i],

/* ── YouTube specific ── */
.ad-showing .video-ads,
.ytp-ad-module,
.ytp-ad-overlay-container,
.ytp-ad-text-overlay,
#player-ads,
#masthead-ad,
ytd-promoted-sparkles-web-renderer,
ytd-promoted-video-renderer,
ytd-display-ad-renderer,
ytd-companion-slot-renderer,
ytd-action-companion-ad-renderer,
ytd-in-feed-ad-layout-renderer,
ytd-ad-slot-renderer,
ytd-banner-promo-renderer,
tp-yt-paper-dialog.ytd-popup-container,
.ytd-merch-shelf-renderer,
.ytd-statement-banner-renderer,

/* ── Hide with extreme prejudice ── */
{ display: none !important;
  visibility: hidden !important;
  height: 0 !important;
  max-height: 0 !important;
  min-height: 0 !important;
  overflow: hidden !important;
  pointer-events: none !important;
  opacity: 0 !important;
  position: absolute !important;
  z-index: -9999 !important;
}

/* ── PROTECT actual video players — never hide ──
   Includes the <video> element AND any ancestor wrapper that contains
   one (via :has()). This prevents over-eager substring class matchers
   like [class*="ad-block"] or [class*="overlay-ad"] from hiding a player
   wrapper named e.g. "video-ad-block" or "player-overlay-adapter". */
video,
audio,
video *,
audio *,
[class*="video-player" i],
[class*="videoPlayer"  i],
[class*="video-js"     i],
[class*="vjs-"         i],
[class*="plyr"         i],
[class*="jw-video"     i],
[class*="jwplayer"     i],
[class*="html5-video"  i],
[class*="flowplayer"   i],
[class*="bitmovin"     i],
[class*="shaka-"       i],
[class*="theoplayer"   i],
[class*="mediaelement" i],
[class*="hls-player"   i],
[class*="dash-player"  i],
[class*="player-container" i],
[class*="media-player" i],
[class*="clappr"       i],
.html5-video-player,
.video-stream,
:has(> video),
:has(> audio),
[class*="player" i]:has(video),
[class*="video"  i]:has(video) {
  display: revert !important;
  visibility: visible !important;
  height: revert !important;
  max-height: revert !important;
  min-height: revert !important;
  overflow: revert !important;
  pointer-events: auto !important;
  opacity: 1 !important;
  position: revert !important;
  z-index: revert !important;
}
''';

  // Earlier aggressive JavaScript blocker layers were intentionally removed.
  // They were effective against some hostile sites, but too risky for a
  // casting-focused browser because DOM/event interception tends to break
  // legitimate players more often than it helps.

  // ══════════════════════════════════════════════════════════════════════════
  // Layer 4: Video detection script
  // ══════════════════════════════════════════════════════════════════════════

  static const videoDetectorScript = r'''
(function RLCasterVideoDetector() {
  "use strict";
  if (window.__rlVideoDetector) return;
  window.__rlVideoDetector = true;

  var sent = {};
  var VIDEO_RE = /\.(mp4|m3u8|webm|mkv|avi|mov|flv|mpd|m4v|f4v)(\?|#|$)/i;
  var VIDEO_MIME_RE = /^(video\/|application\/x-mpegurl|application\/vnd\.apple\.mpegurl|application\/dash\+xml)/i;

  /* ── Junk URL filter: skip ads, tracking, tiny segments, previews ── */
  var JUNK_RE = /doubleclick|googlesyndication|googleads|\/analytics|adnxs|facebook\.net|\/pixel|\/beacon|\/tracker|\/tracking|\/ads\/|\/ad\/|\/preroll|\/midroll|\/postroll|popads|popunder|\.gif(\?|$)|\.png(\?|$)|\.jpg(\?|$)|\.svg(\?|$)/i;
  /* Skip individual HLS/DASH segments (.ts, .m4s) — we want manifests only */
  var SEGMENT_RE = /\.(ts|m4s|aac)(\?|#|$)/i;

  function send(url, type) {
    if (!url || sent[url]) return;
    if (url.startsWith('blob:') || url.startsWith('data:')) return;
    if (url.length < 15 || url.length > 4000) return;
    var lower = url.toLowerCase();
    /* Skip junk / ad / tracking URLs */
    if (JUNK_RE.test(lower)) return;
    /* Skip individual segments — these are short chunks, not full videos */
    if (SEGMENT_RE.test(lower)) return;
    /* Skip very short query strings that indicate tracking pixels */
    if (lower.indexOf('/pixel') !== -1 || lower.indexOf('/beacon') !== -1) return;
    sent[url] = true;
    try { window.flutter_inappwebview.callHandler('VideoDetector', JSON.stringify({url: url, type: type})); } catch(_) {}
  }

  /* ── Layer 1: Intercept XMLHttpRequest ── */
  (function() {
    var origOpen = XMLHttpRequest.prototype.open;
    XMLHttpRequest.prototype.open = function(method, url) {
      try {
        var resolved = new URL(url, location.href).href;
        if (VIDEO_RE.test(resolved)) send(resolved, 'xhr');
      } catch(_) {}
      return origOpen.apply(this, arguments);
    };
    var origSend = XMLHttpRequest.prototype.send;
    XMLHttpRequest.prototype.send = function() {
      var xhr = this;
      xhr.addEventListener('load', function() {
        try {
          var ct = xhr.getResponseHeader('content-type') || '';
          if (VIDEO_MIME_RE.test(ct) && xhr.responseURL) send(xhr.responseURL, 'xhr');
        } catch(_) {}
      });
      return origSend.apply(this, arguments);
    };
  })();

  /* ── Layer 2: Intercept fetch() ── */
  (function() {
    var origFetch = window.fetch;
    if (!origFetch) return;
    window.fetch = function(input, init) {
      try {
        var url = typeof input === 'string' ? input : (input && input.url ? input.url : '');
        if (url) {
          var resolved = new URL(url, location.href).href;
          if (VIDEO_RE.test(resolved)) send(resolved, 'fetch');
        }
      } catch(_) {}
      return origFetch.apply(this, arguments).then(function(response) {
        try {
          var ct = response.headers.get('content-type') || '';
          if (VIDEO_MIME_RE.test(ct) && response.url) send(response.url, 'fetch');
        } catch(_) {}
        return response;
      });
    };
  })();

  /* ── Layer 3: DOM scanning ── */
  function scanDOM() {
    document.querySelectorAll('video').forEach(function(v) {
      if (v.src && !v.src.startsWith('blob:')) send(v.src, 'video');
      if (v.currentSrc && !v.currentSrc.startsWith('blob:')) send(v.currentSrc, 'video');
    });
    document.querySelectorAll('video source[src]').forEach(function(s) {
      if (!s.src.startsWith('blob:')) send(s.src, 'source');
    });
    document.querySelectorAll('iframe[src]').forEach(function(f) {
      var s = f.src.toLowerCase();
      if (s.indexOf('youtube.com/embed') !== -1 ||
          s.indexOf('player.vimeo.com') !== -1 ||
          s.indexOf('dailymotion.com/embed') !== -1 ||
          s.indexOf('streamable.com') !== -1 ||
          s.indexOf('facebook.com/plugins/video') !== -1 ||
          s.indexOf('twitch.tv/embed') !== -1 ||
          s.indexOf('wistia.com') !== -1 ||
          s.indexOf('vidyard.com') !== -1 ||
          s.indexOf('loom.com') !== -1) {
        send(f.src, 'embed');
      }
    });
    /* Only detect <a> links with video extensions — skip plain links */
    document.querySelectorAll('a[href]').forEach(function(a) {
      if (VIDEO_RE.test(a.href)) send(a.href, 'link');
    });
    document.querySelectorAll('meta[property="og:video"], meta[property="og:video:url"], meta[property="og:video:secure_url"], meta[name="twitter:player:stream"]')
      .forEach(function(m) {
        var c = m.getAttribute('content');
        if (c) send(c, 'meta');
      });
    document.querySelectorAll('[data-src], [data-video-url], [data-video-src], [data-stream-url], [data-hls], [data-dash], [data-video], [data-file], [data-mp4]')
      .forEach(function(el) {
        ['data-src', 'data-video-url', 'data-video-src', 'data-stream-url',
         'data-hls', 'data-dash', 'data-video', 'data-file', 'data-mp4'].forEach(function(attr) {
          var v = el.getAttribute(attr);
          if (v && VIDEO_RE.test(v)) {
            try { send(new URL(v, location.href).href, 'data-attr'); } catch(_) {}
          }
        });
      });
    document.querySelectorAll('script[type="application/ld+json"]').forEach(function(s) {
      try {
        var json = JSON.parse(s.textContent);
        var items = Array.isArray(json) ? json : [json];
        function processLD(item) {
          if (!item || typeof item !== 'object') return;
          if (item['@type'] === 'VideoObject') {
            if (item.contentUrl) send(item.contentUrl, 'json-ld');
            if (item.embedUrl) send(item.embedUrl, 'json-ld');
          }
          if (item['@graph'] && Array.isArray(item['@graph'])) {
            item['@graph'].forEach(processLD);
          }
        }
        items.forEach(processLD);
      } catch(_) {}
    });
  }

  /* ── Layer 4: PerformanceObserver ── */
  (function() {
    if (typeof PerformanceObserver === 'undefined') return;
    try {
      var po = new PerformanceObserver(function(list) {
        list.getEntries().forEach(function(entry) {
          var url = entry.name || '';
          if (VIDEO_RE.test(url)) send(url, 'resource');
          if (entry.initiatorType === 'video' || entry.initiatorType === 'media') {
            if (url && !url.startsWith('blob:') && !url.startsWith('data:')) {
              send(url, 'resource');
            }
          }
        });
      });
      po.observe({entryTypes: ['resource']});
    } catch(_) {}
    try {
      performance.getEntriesByType('resource').forEach(function(entry) {
        if (VIDEO_RE.test(entry.name)) send(entry.name, 'resource');
      });
    } catch(_) {}
  })();

  /* ── Layer 5: MutationObserver ── */
  scanDOM();
  setTimeout(scanDOM, 1500);
  setTimeout(scanDOM, 4000);
  setTimeout(scanDOM, 8000);

  if (typeof MutationObserver !== 'undefined' && (document.body || document.documentElement)) {
    var throttle = null;
    new MutationObserver(function(mutations) {
      var dominated = false;
      for (var i = 0; i < mutations.length; i++) {
        var m = mutations[i];
        if (m.type === 'attributes') { dominated = true; break; }
        for (var j = 0; j < m.addedNodes.length; j++) {
          if (m.addedNodes[j].nodeType === 1) { dominated = true; break; }
        }
        if (dominated) break;
      }
      if (!dominated) return;
      if (throttle) return;
      throttle = setTimeout(function() { throttle = null; scanDOM(); }, 400);
    }).observe(document.body || document.documentElement, {
      childList: true, subtree: true, attributes: true,
      attributeFilter: ['src', 'data-src', 'data-video-url', 'data-video', 'data-mp4']
    });
  }
})();
''';
}
