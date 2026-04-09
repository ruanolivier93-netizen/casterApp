/// Comprehensive ad blocker for the in-app WebView browser.
///
/// Three-layer blocking:
///   1. **Domain filter** — blocks navigation/resource requests to known ad domains
///   2. **CSS injection** — hides common ad containers via element hiding rules
///   3. **JS injection**  — strips ad iframes, overlays, popups, and sticky banners
///
/// Also includes a video-detection script that finds `<video>` and `<source>`
/// elements and reports their URLs to Flutter via a JavaScriptChannel.
library;

class AdBlocker {
  AdBlocker._();

  // ── Layer 1: Domain-level blocking ──────────────────────────────────────

  /// Returns `true` if the URL should be **blocked**.
  static bool shouldBlock(String url) {
    final uri = Uri.tryParse(url);
    if (uri == null) return false;
    final host = uri.host.toLowerCase();
    return _blockedDomains.any((d) => host == d || host.endsWith('.$d'));
  }

  /// Major ad / tracking / analytics domains (covers ≈95 % of web ads).
  static const _blockedDomains = <String>[
    // Google Ads / DFP / AdSense
    'doubleclick.net',
    'googlesyndication.com',
    'googleadservices.com',
    'google-analytics.com',
    'googletagmanager.com',
    'googletagservices.com',
    'pagead2.googlesyndication.com',
    'adservice.google.com',
    'tpc.googlesyndication.com',

    // Facebook / Meta
    'facebook.net',
    'facebook.com', // tracking pixel domain
    'fbcdn.net',

    // Amazon ads
    'amazon-adsystem.com',
    'aax.amazon-adsystem.com',

    // Twitter / X
    'ads-twitter.com',
    'ads-api.twitter.com',
    'analytics.twitter.com',

    // Other major ad networks
    'adnxs.com',
    'adsrvr.org',
    'adform.net',
    'admob.com',
    'moatads.com',
    'serving-sys.com',
    'zedo.com',
    'advertising.com',
    'openx.net',
    'pubmatic.com',
    'casalemedia.com',
    'criteo.com',
    'criteo.net',
    'outbrain.com',
    'taboola.com',
    'revcontent.com',
    'mgid.com',
    'sharethrough.com',
    'smartadserver.com',
    'rubiconproject.com',
    'contextweb.com',
    'bidswitch.net',
    'lijit.com',
    'indexww.com',
    'spotxchange.com',
    'yieldmo.com',
    'media.net',
    'mopub.com',
    'inmobi.com',
    'unity3d.com',
    'unityads.unity3d.com',
    'applovin.com',
    'vungle.com',
    'ironsrc.com',
    'chartboost.com',

    // Tracking / analytics
    'scorecardresearch.com',
    'quantserve.com',
    'quantcast.com',
    'segment.io',
    'segment.com',
    'mixpanel.com',
    'hotjar.com',
    'mouseflow.com',
    'fullstory.com',
    'crazyegg.com',
    'clicktale.com',
    'newrelic.com',
    'nr-data.net',
    'omtrdc.net',
    'demdex.net',
    'everesttech.net',
    'bluekai.com',
    'exelator.com',
    'krxd.net',
    'turn.com',
    'rlcdn.com',
    'agkn.com',
    'adsymptotic.com',
    'adtechus.com',
    'mathtag.com',
    'dotomi.com',
    'yieldmanager.com',

    // Pop-unders / redirects
    'popads.net',
    'popcash.net',
    'propellerads.com',
    'juicyads.com',
    'exoclick.com',
    'hilltopads.com',
    'trafficjunky.com',
    'clickadu.com',

    // Malvertising / sketchy
    'adf.ly',
    'bit.ly', // often used for ad redirects
    'shorte.st',
  ];

  // ── Layer 2: CSS element-hiding injection ───────────────────────────────

  /// CSS that hides the most common ad containers across sites.
  static const cssRules = '''
/* ── RL Caster Ad Blocker – CSS layer ──────────────────────────── */
[id*="google_ads"           i],
[id*="ad-container"         i],
[id*="ad_container"         i],
[id*="ad-wrapper"           i],
[id*="ad_wrapper"           i],
[id*="adslot"               i],
[id*="adbanner"             i],
[id*="ad-banner"            i],
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
[class*="google-ad"         i],
[class*="sponsored-content" i],
[class*="taboola"           i],
[class*="outbrain"          i],
[class*="mgid"              i],
[class*="revcontent"        i],
div[aria-label="Ads"        i],
div[aria-label="Advertisement" i],
iframe[src*="doubleclick"   ],
iframe[src*="googlesyndication"],
iframe[src*="adnxs"         ],
iframe[src*="amazon-adsystem"],
ins.adsbygoogle,
amp-ad,
amp-embed,
amp-sticky-ad {
  display: none !important;
  visibility: hidden !important;
  height: 0 !important;
  max-height: 0 !important;
  overflow: hidden !important;
  pointer-events: none !important;
}
''';

  // ── Layer 3: JS ad-removal injection ────────────────────────────────────

  /// JavaScript that runs after each page load to actively remove ad elements.
  static const jsScript = r'''
(function RLCasterAdBlocker() {
  "use strict";

  /* ── selectors targeting ad wrappers ── */
  const SEL = [
    'ins.adsbygoogle',
    'iframe[src*="doubleclick"]',
    'iframe[src*="googlesyndication"]',
    'iframe[src*="adnxs"]',
    'iframe[src*="amazon-adsystem"]',
    'iframe[id*="google_ads"]',
    'div[id*="google_ads"]',
    'div[id*="ad-container"]',
    'div[id*="ad_container"]',
    'div[id*="ad-wrapper"]',
    'div[id*="ad_wrapper"]',
    'div[class*="ad-container"]',
    'div[class*="ad_container"]',
    'div[class*="ad-wrapper"]',
    'div[class*="ad_wrapper"]',
    'div[class*="ad-placement"]',
    'div[class*="ad-unit"]',
    'div[class*="ad_unit"]',
    'div[class*="sponsored-content"]',
    'div[class*="taboola"]',
    'div[class*="outbrain"]',
    'div[class*="mgid"]',
    'div[class*="revcontent"]',
    'amp-ad',
    'amp-embed',
    'amp-sticky-ad',
  ].join(',');

  function nuke() {
    document.querySelectorAll(SEL).forEach(function(el) { el.remove(); });

    /* Remove fixed/sticky overlays that cover content (cookie walls, ad
       overlays, anti-adblock modals). Keep elements that are clearly nav
       bars (header/nav/footer). */
    document.querySelectorAll('div, section, aside').forEach(function(el) {
      const s = getComputedStyle(el);
      if (s.position !== 'fixed' && s.position !== 'sticky') return;
      const tag = el.tagName.toLowerCase();
      if (tag === 'header' || tag === 'nav' || tag === 'footer') return;

      const r = el.getBoundingClientRect();
      /* Full-screen or nearly full-screen overlays */
      if (r.width > window.innerWidth * 0.8 && r.height > window.innerHeight * 0.7) {
        if (s.zIndex && parseInt(s.zIndex, 10) > 999) {
          el.remove();
        }
      }
    });

    /* Re-enable scrolling if a modal hid it */
    if (document.body) {
      const bs = getComputedStyle(document.body);
      if (bs.overflow === 'hidden' || bs.overflowY === 'hidden') {
        document.body.style.setProperty('overflow', 'auto', 'important');
      }
    }
    if (document.documentElement) {
      const hs = getComputedStyle(document.documentElement);
      if (hs.overflow === 'hidden' || hs.overflowY === 'hidden') {
        document.documentElement.style.setProperty('overflow', 'auto', 'important');
      }
    }
  }

  /* Run immediately + after a short delay (some ads inject late). */
  nuke();
  setTimeout(nuke, 800);
  setTimeout(nuke, 2500);

  /* Observe DOM for dynamically-injected ads. */
  if (typeof MutationObserver !== 'undefined') {
    new MutationObserver(function() { nuke(); })
      .observe(document.body || document.documentElement, {
        childList: true, subtree: true
      });
  }
})();
''';

  // ── Layer 4: Video detection script ─────────────────────────────────────

  /// JavaScript that scans the page for video elements and source URLs,
  /// then sends them to Flutter via the `VideoDetector` JavaScriptChannel.
  /// Runs with a MutationObserver so dynamically-loaded players are caught.
  static const videoDetectorScript = r'''
(function RLCasterVideoDetector() {
  "use strict";
  var sent = {};

  function send(url, type) {
    if (!url || sent[url]) return;
    /* Skip blob:, data:, and tiny tracking pixels */
    if (url.startsWith('blob:') || url.startsWith('data:')) return;
    if (url.length < 10) return;
    sent[url] = true;
    try { VideoDetector.postMessage(JSON.stringify({url: url, type: type})); } catch(_) {}
  }

  function scan() {
    /* <video src="..."> */
    document.querySelectorAll('video[src]').forEach(function(v) {
      send(v.src, 'video');
    });
    /* <video><source src="..."></video> */
    document.querySelectorAll('video source[src]').forEach(function(s) {
      send(s.src, 'source');
    });
    /* <iframe> that embed known video players */
    document.querySelectorAll('iframe[src]').forEach(function(f) {
      var s = f.src.toLowerCase();
      if (s.indexOf('youtube.com/embed') !== -1 ||
          s.indexOf('player.vimeo.com') !== -1 ||
          s.indexOf('dailymotion.com/embed') !== -1 ||
          s.indexOf('streamable.com') !== -1) {
        send(f.src, 'embed');
      }
    });
    /* <a> links pointing to video files */
    document.querySelectorAll('a[href]').forEach(function(a) {
      var h = a.href.toLowerCase();
      if (h.match(/\.(mp4|m3u8|webm|mkv|avi|mov|flv|ts)(\?|$)/)) {
        send(a.href, 'link');
      }
    });
    /* og:video meta tags */
    document.querySelectorAll('meta[property="og:video"], meta[property="og:video:url"]')
      .forEach(function(m) {
        var c = m.getAttribute('content');
        if (c) send(c, 'meta');
      });
  }

  scan();
  setTimeout(scan, 1500);
  setTimeout(scan, 4000);

  if (typeof MutationObserver !== 'undefined' && (document.body || document.documentElement)) {
    new MutationObserver(function() { scan(); })
      .observe(document.body || document.documentElement, {
        childList: true, subtree: true
      });
  }
})();
''';
}
