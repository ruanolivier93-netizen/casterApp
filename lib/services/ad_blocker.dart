/// State-of-the-art ad blocker for the in-app WebView browser.
///
/// Six-layer blocking:
///   1. **Domain filter** — blocks requests to 250+ known ad/tracking domains
///   2. **URL path-pattern filter** — blocks requests matching ad URL patterns
///   3. **CSS injection** — hides common ad containers via element hiding rules
///   4. **JS injection** — strips ad iframes, overlays, popups, sticky banners,
///      auto-skips YouTube ads, blocks window.open popups, intercepts WebSocket
///      ad connections, and neutralises anti-adblock scripts
///   5. **Consent auto-dismiss** — clicks "Accept All" buttons on cookie banners
///   6. **Video-detection script** — intercepts network requests and scans DOM
///      for video URLs, reporting them to Flutter via JavaScriptChannel
library;

class AdBlocker {
  AdBlocker._();

  // ══════════════════════════════════════════════════════════════════════════
  // Layer 1: Domain-level blocking
  // ══════════════════════════════════════════════════════════════════════════

  /// Returns `true` if the URL should be **blocked**.
  static bool shouldBlock(String url) {
    final uri = Uri.tryParse(url);
    if (uri == null) return false;

    // Never block actual video/media resources.
    final path = uri.path.toLowerCase();
    if (_videoExtensions.any((ext) => path.endsWith(ext))) return false;

    final host = uri.host.toLowerCase();

    // Whitelist video CDNs and streaming platforms.
    if (_videoDomains.any((d) => host == d || host.endsWith('.$d'))) {
      return false;
    }

    // Layer 1: Domain match
    if (_blockedDomains.any((d) => host == d || host.endsWith('.$d'))) {
      return true;
    }

    // Layer 2: URL path pattern match
    final fullUrl = url.toLowerCase();
    if (_blockedPathPatterns.any((p) => fullUrl.contains(p))) {
      return true;
    }

    return false;
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
    '/ads/', '/ad/', '/adserver', '/advert', '/admanager',
    '/adsense', '/dfp/', '/doubleclick/',
    '/banner/', '/banners/', '/popup/',
    '/preroll', '/midroll', '/postroll',
    '/vast/', '/vpaid/', '/vmap/',
    '/tracker/', '/tracking/', '/pixel/',
    '/beacon/', '/analytics/', '/telemetry/',
    '/pagead/', '/afs/ads', '/adsid/',
    '.googlesyndication.com', 'googletag.js',
    'adsbygoogle.js', 'show_ads.js',
    '/prebid', '/header-bidding/',
    '_ad.js', '-ad.js', '/ad.js',
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

/* ── PROTECT actual video players — never hide ── */
video,
video *,
[class*="video-player"] video,
[class*="videoPlayer"] video,
[class*="video-js"] video,
[class*="plyr"] video,
[class*="jw-video"] video,
[class*="html5-video"] video,
.html5-video-player video,
.video-stream {
  display: revert !important;
  visibility: visible !important;
  height: revert !important;
  max-height: revert !important;
  overflow: revert !important;
  pointer-events: auto !important;
  opacity: 1 !important;
  position: revert !important;
  z-index: revert !important;
}
''';

  // ══════════════════════════════════════════════════════════════════════════
  // Layer 4: JS ad-removal + anti-adblock + popup block + YouTube ad skip
  // ══════════════════════════════════════════════════════════════════════════

  static const jsScript = r'''
(function RLCasterAdBlockerV2() {
  "use strict";
  if (window.__rlAdBlockV2) return;
  window.__rlAdBlockV2 = true;

  /* ══ Config ══ */
  var AD_SEL = [
    'ins.adsbygoogle',
    'amp-ad', 'amp-embed', 'amp-sticky-ad', 'amp-auto-ads',
    'iframe[src*="doubleclick"]',
    'iframe[src*="googlesyndication"]',
    'iframe[src*="adnxs"]',
    'iframe[src*="amazon-adsystem"]',
    'iframe[src*="ads."]',
    'iframe[src*="/ads/"]',
    'iframe[src*="adserver"]',
    'iframe[id*="google_ads"]',
    'iframe[id*="aswift"]',
    'div[id*="google_ads"]',
    'div[id*="ad-container"]', 'div[id*="ad_container"]',
    'div[id*="ad-wrapper"]', 'div[id*="ad_wrapper"]',
    'div[id*="ad-holder"]', 'div[id*="ad-block"]',
    'div[id*="ad-unit"]', 'div[id*="adslot"]',
    'div[class*="ad-container"]', 'div[class*="ad_container"]',
    'div[class*="ad-wrapper"]', 'div[class*="ad_wrapper"]',
    'div[class*="ad-placement"]', 'div[class*="ad-unit"]',
    'div[class*="ad_unit"]', 'div[class*="ad-holder"]',
    'div[class*="ad-block"]', 'div[class*="ad_block"]',
    'div[class*="adBox"]', 'div[class*="adbox"]',
    'div[class*="sponsored-content"]', 'div[class*="sponsored_content"]',
    'div[class*="taboola"]', 'div[class*="outbrain"]',
    'div[class*="mgid"]', 'div[class*="revcontent"]',
    'div[class*="teads"]', 'div[class*="seedtag"]',
    '[data-ad]', '[data-ad-slot]', '[data-ad-unit]', '[data-dfp]',
    '[data-google-query-id]',
  ].join(',');

  var CONSENT_SEL = [
    '[class*="cookie-banner"]', '[class*="cookie_banner"]',
    '[class*="cookie-consent"]', '[class*="cookie_consent"]',
    '[class*="CookieConsent"]', '[class*="cc-window"]',
    '[class*="cc-banner"]', '[class*="gdpr"]',
    '[class*="consent-banner"]', '[class*="cookie-notice"]',
    '[class*="cookie-popup"]', '[class*="cookie-wall"]',
    '[class*="privacy-banner"]', '[class*="cookieBar"]',
    '[id*="cookie-banner"]', '[id*="cookie_banner"]',
    '[id*="cookie-consent"]', '[id*="cookie_consent"]',
    '[id*="gdpr"]', '[id*="consent-banner"]',
    '[id*="cookieNotice"]', '[id*="cookie-notice"]',
    '[id*="cookie-popup"]', '[id*="cookie-modal"]',
    '[id*="cookie-wall"]', '[id*="privacy-banner"]',
  ].join(',');

  var ANTI_AB_SEL = [
    '[class*="anti-adblock"]', '[class*="adblock-notice"]',
    '[class*="adblock-warning"]', '[class*="adblock-modal"]',
    '[class*="adblock-detected"]', '[class*="adb-overlay"]',
    '[id*="anti-adblock"]', '[id*="adblock-notice"]',
    '[id*="adblock-warning"]', '[id*="adblock-modal"]',
    '[id*="adblock-detected"]',
  ].join(',');

  var ACCEPT_TEXTS = [
    'accept all', 'accept cookies', 'i agree', 'agree', 'allow all',
    'allow cookies', 'ok', 'got it', 'continue', 'dismiss',
    'i understand', 'accept & continue', 'accept and continue',
    'close', 'agree and close', 'agree & close', 'consent',
    'yes, i agree', 'allow all cookies', 'enable all',
    'confirm', 'accept all cookies', 'i accept',
    'alle akzeptieren', 'tout accepter', 'aceptar todo',
    'akkoord', 'accetta tutti',
  ];

  /* ══ Check if element is a video player ══ */
  function isVideoPlayer(el) {
    if (!el || !el.tagName) return false;
    var tag = el.tagName.toLowerCase();
    if (tag === 'video' || tag === 'audio') return true;
    if (el.querySelector && (el.querySelector('video') || el.querySelector('audio'))) return true;
    var cls = (el.className || '').toString().toLowerCase();
    var id = (el.id || '').toLowerCase();
    var hints = ['video-player', 'videoplayer', 'video-js', 'vjs-', 'plyr',
      'jw-', 'jwplayer', 'html5-video', 'flowplayer', 'mediaelement', 'mejs',
      'bitmovin', 'shaka-', 'hls-player', 'dash-player', 'player-container',
      'media-player', 'clappr', 'videojs', 'theoplayer', 'html5-video-player',
      'video-stream', 'ytp-'];
    for (var i = 0; i < hints.length; i++) {
      if (cls.indexOf(hints[i]) !== -1 || id.indexOf(hints[i]) !== -1) return true;
    }
    return false;
  }

  /* ══ Core nuke — remove ad elements ══ */
  function nuke() {
    document.querySelectorAll(AD_SEL).forEach(function(el) {
      if (isVideoPlayer(el)) return;
      if (el.closest && el.closest('video, [class*="video-player"], [class*="video-js"], [class*="plyr"], .html5-video-player')) return;
      el.remove();
    });

    /* Remove fixed/sticky overlays that block content */
    document.querySelectorAll('div, section, aside, span').forEach(function(el) {
      var s;
      try { s = getComputedStyle(el); } catch(_) { return; }
      if (s.position !== 'fixed' && s.position !== 'sticky') return;
      var tag = el.tagName.toLowerCase();
      if (tag === 'header' || tag === 'nav') return;
      if (isVideoPlayer(el)) return;

      var r = el.getBoundingClientRect();
      var z = parseInt(s.zIndex, 10) || 0;

      /* Full-screen overlays (modals, interstitials) */
      if (r.width > window.innerWidth * 0.75 && r.height > window.innerHeight * 0.6 && z > 500) {
        el.remove();
        return;
      }
      /* Bottom sticky banners */
      if (r.height < 150 && r.bottom >= window.innerHeight - 5 && z > 5) {
        el.remove();
        return;
      }
      /* Top sticky banners (not nav) */
      if (r.height < 120 && r.top <= 5 && z > 5) {
        var cls = (el.className || '').toLowerCase();
        var id = (el.id || '').toLowerCase();
        if (cls.indexOf('ad') !== -1 || id.indexOf('ad') !== -1 ||
            cls.indexOf('banner') !== -1 || id.indexOf('banner') !== -1 ||
            cls.indexOf('promo') !== -1) {
          el.remove();
          return;
        }
      }
    });

    /* Re-enable scrolling if a modal locked it */
    ['body', 'html'].forEach(function(sel) {
      var el = sel === 'body' ? document.body : document.documentElement;
      if (!el) return;
      try {
        var s = getComputedStyle(el);
        if (s.overflow === 'hidden' || s.overflowY === 'hidden') {
          el.style.setProperty('overflow', 'auto', 'important');
          el.style.setProperty('overflow-y', 'auto', 'important');
        }
      } catch(_) {}
    });
  }

  /* ══ Anti-adblock countermeasures ══ */
  function dismissAntiAdblock() {
    document.querySelectorAll(ANTI_AB_SEL).forEach(function(el) {
      if (isVideoPlayer(el)) return;
      el.remove();
    });
    /* Remove overlay that might be left behind */
    document.querySelectorAll('[class*="modal-backdrop"], [class*="overlay"]').forEach(function(el) {
      if (isVideoPlayer(el)) return;
      var s;
      try { s = getComputedStyle(el); } catch(_) { return; }
      if (s.position === 'fixed' && parseFloat(s.opacity) < 0.8 && parseInt(s.zIndex, 10) > 500) {
        el.remove();
      }
    });
  }

  /* ══ Cookie consent auto-dismiss ══ */
  function tryDismissConsent() {
    /* Try clicking accept/dismiss buttons */
    var selectors = 'button, a[role="button"], [class*="accept"], [class*="agree"], [class*="dismiss"], [class*="close"], [class*="allow"], [class*="consent"], input[type="submit"]';
    var buttons = document.querySelectorAll(selectors);
    for (var i = 0; i < buttons.length; i++) {
      var txt = (buttons[i].textContent || '').trim().toLowerCase();
      if (txt.length > 40) continue; /* Skip non-button text */
      for (var j = 0; j < ACCEPT_TEXTS.length; j++) {
        if (txt === ACCEPT_TEXTS[j] || txt.indexOf(ACCEPT_TEXTS[j]) !== -1) {
          try { buttons[i].click(); return; } catch(_) {}
        }
      }
    }
    /* Also try aria-label matches */
    var ariaButtons = document.querySelectorAll('[aria-label]');
    for (var k = 0; k < ariaButtons.length; k++) {
      var label = (ariaButtons[k].getAttribute('aria-label') || '').toLowerCase();
      for (var l = 0; l < ACCEPT_TEXTS.length; l++) {
        if (label.indexOf(ACCEPT_TEXTS[l]) !== -1) {
          try { ariaButtons[k].click(); return; } catch(_) {}
        }
      }
    }
    /* Fallback: just remove consent banners */
    document.querySelectorAll(CONSENT_SEL).forEach(function(el) { el.remove(); });
  }

  /* ══ YouTube-specific ad handling ══ */
  function handleYouTubeAds() {
    if (location.hostname.indexOf('youtube') === -1) return;

    /* Skip ad button */
    var skipBtn = document.querySelector('.ytp-ad-skip-button, .ytp-ad-skip-button-modern, .ytp-skip-ad-button, [class*="skip-button"]');
    if (skipBtn) { try { skipBtn.click(); } catch(_) {} }

    /* Skip overlay close button */
    var closeOv = document.querySelector('.ytp-ad-overlay-close-button, .ytp-ad-overlay-close-container');
    if (closeOv) { try { closeOv.click(); } catch(_) {} }

    /* If video ad is playing, try to skip past it */
    var adShowing = document.querySelector('.ad-showing');
    if (adShowing) {
      var vid = document.querySelector('video');
      if (vid && vid.duration && isFinite(vid.duration) && vid.duration < 120) {
        vid.currentTime = vid.duration;
      }
    }

    /* Remove promoted content */
    document.querySelectorAll('ytd-promoted-sparkles-web-renderer, ytd-promoted-video-renderer, ytd-display-ad-renderer, ytd-companion-slot-renderer, ytd-action-companion-ad-renderer, ytd-in-feed-ad-layout-renderer, ytd-ad-slot-renderer, ytd-banner-promo-renderer, ytd-merch-shelf-renderer, #player-ads, #masthead-ad').forEach(function(el) { el.remove(); });
  }

  /* ══ Redirect window.open to new tab (block if ad) ══ */
  window.open = function(url) {
    if (url) {
      try {
        var resolved = new URL(url, location.href).href;
        if (!isAdRedirect(resolved)) {
          try { NewTab.postMessage(resolved); } catch(_) {}
        }
      } catch(_) {}
    }
    return null;
  };

  /* ══ Ad-redirect URL detection (shared helper) ══ */
  var AD_REDIR_PATTERNS = [
    'doubleclick', 'googlesyndication', 'googleads', 'adnxs', 'adsrvr',
    'popads', 'popcash', 'propellerads', 'clickadu', 'exoclick',
    'trafficjunky', 'juicyads', 'hilltopads', 'trafficstars',
    'adsterra', 'admaven', 'richpush', 'outbrain', 'taboola',
    'mgid', 'revcontent', 'criteo', 'pubmatic', 'adform',
    'amazon-adsystem', 'serving-sys', 'flashtalking',
    'popunder', 'clicktrack', 'clickunder',
    'linkvertise', 'shrinkme', 'cpmlink',
    'adf.ly', 'ouo.io', 'bc.vc', 'sh.st', 'shorte.st', 'clk.sh',
    '/aclk?', '/pagead/', 'click_id=', 'aff_id=', 'offer_id=',
    'aff_sub=', '?zoneid=', '&zoneid=', '?bannerid=', '&bannerid=',
    '?adurl=', '&adurl=', '/smartlink/', '/cpa/', '/cpl/',
    'popunder', 'clickunder',
  ];
  function isAdRedirect(url) {
    if (!url) return false;
    var lower = url.toLowerCase();
    for (var i = 0; i < AD_REDIR_PATTERNS.length; i++) {
      if (lower.indexOf(AD_REDIR_PATTERNS[i]) !== -1) return true;
    }
    return false;
  }

  /* ══ Abort ad-related property reads (scriptlet-style) ══ */
  (function() {
    var props = ['__ads', '_ads', 'adsbygoogle', 'adBlockDetected',
      'adblockDetected', 'blockAdBlock', 'canRunAds', 'isAdBlockActive',
      'google_ad_status', 'fuckAdBlock', 'sniffAdBlock'];
    props.forEach(function(prop) {
      try {
        if (prop === 'adsbygoogle') {
          /* Keep adsbygoogle as empty array to prevent errors */
          window.adsbygoogle = window.adsbygoogle || [];
          Object.defineProperty(window, 'adsbygoogle', {
            value: [], writable: false, configurable: false
          });
        } else if (prop === 'canRunAds' || prop === 'google_ad_status') {
          Object.defineProperty(window, prop, {
            get: function() { return true; },
            set: function() {},
            configurable: false
          });
        } else {
          Object.defineProperty(window, prop, {
            get: function() { return undefined; },
            set: function() {},
            configurable: false
          });
        }
      } catch(_) {}
    });
  })();

  /* ══ Intercept ad-related WebSocket connections ══ */
  (function() {
    var OrigWS = window.WebSocket;
    if (!OrigWS) return;
    var adWsPatterns = ['doubleclick', 'googlesyndication', 'googleads',
      'adnxs', 'adsrvr', 'pubmatic', 'criteo', 'outbrain', 'taboola'];
    window.WebSocket = function(url, protocols) {
      var urlLower = (url || '').toLowerCase();
      for (var i = 0; i < adWsPatterns.length; i++) {
        if (urlLower.indexOf(adWsPatterns[i]) !== -1) {
          /* Return a dummy that does nothing */
          return { send: function(){}, close: function(){},
            addEventListener: function(){}, removeEventListener: function(){},
            readyState: 3, CLOSED: 3 };
        }
      }
      if (protocols) return new OrigWS(url, protocols);
      return new OrigWS(url);
    };
    window.WebSocket.prototype = OrigWS.prototype;
    window.WebSocket.CONNECTING = 0;
    window.WebSocket.OPEN = 1;
    window.WebSocket.CLOSING = 2;
    window.WebSocket.CLOSED = 3;
  })();

  /* ══ Neutralise common anti-adblock check scripts ══ */
  (function() {
    /* Fake the ad element so "check if ads loaded" scripts pass */
    var fakeAd = document.createElement('div');
    fakeAd.id = 'ad_banner';
    fakeAd.className = 'adsbygoogle';
    fakeAd.style.cssText = 'position:absolute;left:-9999px;width:1px;height:1px;overflow:hidden;';
    fakeAd.innerHTML = '&nbsp;';
    (document.body || document.documentElement).appendChild(fakeAd);

    /* Override offsetHeight check — ad blockers set it to 0 which triggers detection */
    try {
      var origGetter = Object.getOwnPropertyDescriptor(HTMLElement.prototype, 'offsetHeight');
      if (origGetter && origGetter.get) {
        Object.defineProperty(fakeAd, 'offsetHeight', { get: function() { return 1; } });
        Object.defineProperty(fakeAd, 'offsetWidth', { get: function() { return 1; } });
        Object.defineProperty(fakeAd, 'clientHeight', { get: function() { return 1; } });
      }
    } catch(_) {}
  })();

  /* ══ Block location.assign / location.replace ad redirects ══ */
  (function() {
    try {
      var origAssign = location.assign.bind(location);
      var origReplace = location.replace.bind(location);
      location.assign = function(url) {
        if (isAdRedirect(url)) return;
        origAssign(url);
      };
      location.replace = function(url) {
        if (isAdRedirect(url)) return;
        origReplace(url);
      };
    } catch(_) {}
  })();

  /* ══ Remove invisible clickjack overlays ══ */
  function removeClickjackOverlays() {
    document.querySelectorAll('div, a, span, section, aside').forEach(function(el) {
      var s;
      try { s = getComputedStyle(el); } catch(_) { return; }
      if (s.position !== 'fixed' && s.position !== 'absolute') return;
      if (isVideoPlayer(el)) return;
      var z = parseInt(s.zIndex, 10) || 0;
      if (z < 50) return;
      var opacity = parseFloat(s.opacity);
      var r = el.getBoundingClientRect();
      var isLarge = r.width > window.innerWidth * 0.3 && r.height > window.innerHeight * 0.3;
      /* Invisible or nearly-invisible large overlay */
      if (isLarge && opacity <= 0.15) { el.remove(); return; }
      /* Transparent <a> covering the viewport (classic clickjack) */
      if (el.tagName === 'A' && isLarge && z > 100) { el.remove(); return; }
    });
  }

  /* ══ Capture-phase click guard ══ */
  document.addEventListener('click', function(e) {
    var t = e.target;
    if (!t) return;
    /* Block clicks on invisible overlays */
    try {
      var s = getComputedStyle(t);
      if (parseFloat(s.opacity) < 0.1 &&
          t.tagName !== 'VIDEO' && t.tagName !== 'INPUT' &&
          t.tagName !== 'BUTTON' && t.tagName !== 'SELECT' &&
          t.tagName !== 'TEXTAREA') {
        e.preventDefault();
        e.stopImmediatePropagation();
        return;
      }
    } catch(_) {}
    /* Handle links — open target=_blank in new tab, block ad links */
    var anchor = t.closest ? t.closest('a') : null;
    if (anchor && anchor.href) {
      if (anchor.target === '_blank' || anchor.target === '_new') {
        e.preventDefault();
        if (!isAdRedirect(anchor.href)) {
          try { NewTab.postMessage(anchor.href); } catch(_) {}
        }
        return;
      }
      if (isAdRedirect(anchor.href)) {
        e.preventDefault();
        e.stopImmediatePropagation();
      }
    }
  }, true);

  /* ══ Sanitise ad-injected event handlers ══ */
  function sanitizeLinks() {
    /* Remove onclick from body/html (common popunder technique) */
    var body = document.body, html = document.documentElement;
    if (body && body.getAttribute('onclick')) body.removeAttribute('onclick');
    if (html && html.getAttribute('onclick')) html.removeAttribute('onclick');

    /* Remove suspicious onclick / pointer handlers from elements */
    document.querySelectorAll('[onclick], [onmousedown], [onmouseup], [onpointerdown], [onpointerup]').forEach(function(el) {
      if (isVideoPlayer(el)) return;
      ['onclick', 'onmousedown', 'onmouseup', 'onpointerdown', 'onpointerup'].forEach(function(attr) {
        var val = (el.getAttribute(attr) || '').toLowerCase();
        if (val.indexOf('window.open') !== -1 || val.indexOf('location') !== -1 ||
            val.indexOf('redirect') !== -1 || val.indexOf('popup') !== -1 ||
            val.indexOf('popunder') !== -1) {
          el.removeAttribute(attr);
        }
      });
    });
  }

  /* ══ Block meta-refresh redirects to ad URLs ══ */
  function blockMetaRefresh() {
    document.querySelectorAll('meta[http-equiv="refresh"]').forEach(function(m) {
      var content = (m.getAttribute('content') || '').toLowerCase();
      if (content.indexOf('url=') !== -1) {
        var url = content.split('url=')[1];
        if (url && isAdRedirect(url.trim())) m.remove();
      }
    });
  }

  /* ══ Prevent popunder via window.blur / window.focus tricks ══ */
  (function() {
    try {
      Object.defineProperty(window, 'blur', {
        value: function() {},
        writable: false, configurable: false
      });
    } catch(_) {}
  })();

  /* ══ Prevent beforeunload abuse ══ */
  (function() {
    var origAddEL = EventTarget.prototype.addEventListener;
    EventTarget.prototype.addEventListener = function(type, fn, opts) {
      if (type === 'beforeunload' && this === window) return;
      return origAddEL.call(this, type, fn, opts);
    };
  })();

  /* ══ Schedule execution ══ */
  nuke();
  removeClickjackOverlays();
  sanitizeLinks();
  blockMetaRefresh();
  setTimeout(nuke, 300);
  setTimeout(nuke, 800);
  setTimeout(nuke, 1500);
  setTimeout(nuke, 3000);
  setTimeout(nuke, 6000);
  setTimeout(function() { nuke(); tryDismissConsent(); dismissAntiAdblock(); removeClickjackOverlays(); sanitizeLinks(); }, 2000);
  setTimeout(function() { tryDismissConsent(); dismissAntiAdblock(); removeClickjackOverlays(); sanitizeLinks(); blockMetaRefresh(); }, 4000);
  setInterval(handleYouTubeAds, 500); /* YouTube ads can appear at any time */
  setInterval(function() { removeClickjackOverlays(); sanitizeLinks(); }, 2500);

  /* ══ MutationObserver for dynamic ads ══ */
  if (typeof MutationObserver !== 'undefined') {
    var throttle = null;
    new MutationObserver(function() {
      if (throttle) return;
      throttle = setTimeout(function() {
        throttle = null;
        nuke();
        dismissAntiAdblock();
        handleYouTubeAds();
        removeClickjackOverlays();
        sanitizeLinks();
      }, 250);
    }).observe(document.body || document.documentElement, {
      childList: true, subtree: true
    });
  }
})();
''';

  // ══════════════════════════════════════════════════════════════════════════
  // Layer 5: Video detection script
  // ══════════════════════════════════════════════════════════════════════════

  static const videoDetectorScript = r'''
(function RLCasterVideoDetector() {
  "use strict";
  if (window.__rlVideoDetector) return;
  window.__rlVideoDetector = true;

  var sent = {};
  var VIDEO_RE = /\.(mp4|m3u8|webm|mkv|avi|mov|flv|ts|mpd|m4v|f4v|m4s)(\?|#|$)/i;
  var VIDEO_MIME_RE = /^(video\/|application\/x-mpegurl|application\/vnd\.apple\.mpegurl|application\/dash\+xml|application\/octet-stream.*video)/i;

  function send(url, type) {
    if (!url || sent[url]) return;
    if (url.startsWith('blob:') || url.startsWith('data:')) return;
    if (url.length < 10) return;
    /* Skip ad/tracking URLs */
    var lower = url.toLowerCase();
    if (lower.indexOf('doubleclick') !== -1 || lower.indexOf('googlesyndication') !== -1) return;
    if (lower.indexOf('googleads') !== -1 || lower.indexOf('/analytics') !== -1) return;
    if (lower.indexOf('adnxs') !== -1 || lower.indexOf('facebook.net') !== -1) return;
    if (lower.indexOf('/pixel') !== -1 || lower.indexOf('/beacon') !== -1) return;
    if (lower.indexOf('/tracker') !== -1 || lower.indexOf('/tracking') !== -1) return;
    sent[url] = true;
    try { VideoDetector.postMessage(JSON.stringify({url: url, type: type})); } catch(_) {}
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
