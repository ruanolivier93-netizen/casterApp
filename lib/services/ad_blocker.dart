/// Comprehensive ad blocker for the in-app WebView browser.
///
/// Three-layer blocking:
///   1. **Domain filter** — blocks navigation/resource requests to known ad domains
///   2. **CSS injection** — hides common ad containers via element hiding rules
///   3. **JS injection**  — strips ad iframes, overlays, popups, and sticky banners
///
/// Also includes a video-detection script that intercepts network requests
/// (XMLHttpRequest, fetch) and scans DOM elements to find video URLs,
/// reporting them to Flutter via a JavaScriptChannel.
library;

class AdBlocker {
  AdBlocker._();

  // ── Layer 1: Domain-level blocking ──────────────────────────────────────

  /// Returns `true` if the URL should be **blocked**.
  ///
  /// Video/media content is always allowed through so that players can load.
  static bool shouldBlock(String url) {
    final uri = Uri.tryParse(url);
    if (uri == null) return false;

    // Never block actual video/media resources regardless of domain.
    final path = uri.path.toLowerCase();
    if (_videoExtensions.any((ext) => path.endsWith(ext))) return false;
    if (path.endsWith('.m3u8') || path.endsWith('.mpd')) return false;

    final host = uri.host.toLowerCase();

    // Whitelist video CDNs and streaming platforms.
    if (_videoDomains.any((d) => host == d || host.endsWith('.$d'))) {
      return false;
    }

    return _blockedDomains.any((d) => host == d || host.endsWith('.$d'));
  }

  /// File extensions that indicate actual video/media content.
  static const _videoExtensions = [
    '.mp4', '.m4v', '.webm', '.mkv', '.avi', '.mov', '.flv', '.ts',
    '.3gp', '.wmv', '.ogv', '.m3u8', '.mpd',
  ];

  /// Domains that serve legitimate video content — never block these.
  static const _videoDomains = <String>[
    // Video platforms & CDNs
    'googlevideo.com',
    'ytimg.com',
    'youtube.com',
    'youtu.be',
    'vimeocdn.com',
    'player.vimeo.com',
    'akamaihd.net',
    'akamaized.net',
    'cloudfront.net',
    'fastly.net',
    'cdn77.org',
    'jwpcdn.com',
    'jwplatform.com',
    'brightcovecdn.com',
    'brightcove.com',
    'vidible.tv',
    'dailymotion.com',
    'dmcdn.net',
    'twitch.tv',
    'ttvnw.net',
    'jtvnw.net',
    'streamable.com',
    'bitmovin.com',
    'cdn.flowplayer.com',
    'mux.com',
    'stream.mux.com',
    'cloudflarestream.com',
    'videodelivery.net',
    'fbcdn.net',
    'fbvideo.com',
    'cdninstagram.com',
    'pstatp.com',
    'tiktokcdn.com',
    'muscdn.com',
    'media.tumblr.com',
    'redditvideo.com',
    'redditmedia.com',
  ];

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

    // Facebook / Meta tracking (NOT facebook.com/fbcdn.net — users watch videos there)
    'facebook.net',

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
    'shorte.st',

    // Cookie / consent walls (usually just tracking)
    'cookielaw.org',
    'cookiepro.com',
    'trustarc.com',
    'consensu.org',

    // Specific Facebook ad/tracking subdomains
    'an.facebook.com',
    'pixel.facebook.com',

    // More ad / popup networks
    'adcolony.com',
    'startappservice.com',
    'supersonic.com',
    'tapjoy.com',
    'flurry.com',
    'adjust.com',
    'branch.io',
    'kochava.com',
    'appsflyer.com',
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
amp-sticky-ad,
/* Cookie consent / GDPR banners */
[id*="cookie-banner"      i],
[id*="cookie_banner"      i],
[id*="cookie-consent"     i],
[id*="cookie_consent"     i],
[id*="gdpr"               i],
[id*="consent-banner"     i],
[class*="cookie-banner"   i],
[class*="cookie_banner"   i],
[class*="cookie-consent"  i],
[class*="cookie_consent"  i],
[class*="gdpr"            i],
[class*="consent-banner"  i],
[class*="CookieConsent"   i],
[class*="cc-window"       i],
[class*="cc-banner"       i],
/* Newsletter / subscribe popups */
[class*="newsletter-popup" i],
[class*="subscribe-modal"  i],
[id*="newsletter-popup"    i],
[id*="subscribe-modal"     i],
/* Overlay / interstitial ads */
[class*="interstitial"     i],
[class*="overlay-ad"       i],
[id*="interstitial"        i] {
  display: none !important;
  visibility: hidden !important;
  height: 0 !important;
  max-height: 0 !important;
  overflow: hidden !important;
  pointer-events: none !important;
}

/* ── PROTECT actual video players — never hide these ── */
video,
video *,
[class*="video-player"] video,
[class*="videoPlayer"] video,
[class*="video-js"] video,
[class*="plyr"] video,
[class*="jw-video"] video,
[class*="html5-video"] video {
  display: revert !important;
  visibility: visible !important;
  height: revert !important;
  max-height: revert !important;
  overflow: revert !important;
  pointer-events: auto !important;
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

  /* ── cookie consent selectors ── */
  const CONSENT_SEL = [
    '[class*="cookie-banner"]',
    '[class*="cookie_banner"]',
    '[class*="cookie-consent"]',
    '[class*="cookie_consent"]',
    '[class*="CookieConsent"]',
    '[class*="cc-window"]',
    '[class*="cc-banner"]',
    '[class*="gdpr"]',
    '[class*="consent-banner"]',
    '[id*="cookie-banner"]',
    '[id*="cookie_banner"]',
    '[id*="cookie-consent"]',
    '[id*="cookie_consent"]',
    '[id*="gdpr"]',
    '[id*="consent-banner"]',
    '[class*="newsletter-popup"]',
    '[class*="subscribe-modal"]',
    '[id*="newsletter-popup"]',
    '[id*="subscribe-modal"]',
  ].join(',');

  /* ── Accept-all consent buttons ── */
  const ACCEPT_TEXTS = ['accept all', 'accept cookies', 'i agree', 'agree', 'allow all',
    'allow cookies', 'ok', 'got it', 'continue', 'dismiss'];

  function tryDismissConsent() {
    /* Try clicking accept/dismiss buttons */
    var buttons = document.querySelectorAll('button, a[role="button"], [class*="accept"], [class*="agree"], [class*="dismiss"], [class*="close"]');
    for (var i = 0; i < buttons.length; i++) {
      var txt = (buttons[i].textContent || '').trim().toLowerCase();
      for (var j = 0; j < ACCEPT_TEXTS.length; j++) {
        if (txt === ACCEPT_TEXTS[j] || txt.indexOf(ACCEPT_TEXTS[j]) !== -1) {
          try { buttons[i].click(); } catch(_) {}
          return;
        }
      }
    }
    /* Fallback: just remove consent banners */
    document.querySelectorAll(CONSENT_SEL).forEach(function(el) { el.remove(); });
  }

  /* Check if an element is a video player or contains one */
  function isVideoPlayer(el) {
    if (!el || !el.tagName) return false;
    var tag = el.tagName.toLowerCase();
    if (tag === 'video' || tag === 'audio') return true;
    /* Contains a <video> or <audio> element */
    if (el.querySelector && (el.querySelector('video') || el.querySelector('audio'))) return true;
    /* Known player class patterns */
    var cls = (el.className || '').toString().toLowerCase();
    var id = (el.id || '').toLowerCase();
    var playerHints = ['video-player', 'videoplayer', 'video-js', 'vjs-', 'plyr', 'jw-', 'jwplayer',
      'html5-video', 'flowplayer', 'mediaelement', 'mejs', 'bitmovin', 'shaka-', 'hls-player',
      'dash-player', 'player-container', 'media-player', 'clappr', 'videojs', 'theoplayer'];
    for (var i = 0; i < playerHints.length; i++) {
      if (cls.indexOf(playerHints[i]) !== -1 || id.indexOf(playerHints[i]) !== -1) return true;
    }
    return false;
  }

  function nuke() {
    document.querySelectorAll(SEL).forEach(function(el) {
      /* NEVER remove elements that are part of a video player */
      if (isVideoPlayer(el)) return;
      if (el.closest && el.closest('video, [class*="video-player"], [class*="video-js"], [class*="plyr"]')) return;
      el.remove();
    });

    /* Remove fixed/sticky overlays that cover content */
    document.querySelectorAll('div, section, aside').forEach(function(el) {
      var s = getComputedStyle(el);
      if (s.position !== 'fixed' && s.position !== 'sticky') return;
      var tag = el.tagName.toLowerCase();
      if (tag === 'header' || tag === 'nav' || tag === 'footer') return;
      /* NEVER remove video players */
      if (isVideoPlayer(el)) return;

      var r = el.getBoundingClientRect();
      /* Full-screen or nearly full-screen overlays */
      if (r.width > window.innerWidth * 0.8 && r.height > window.innerHeight * 0.7) {
        if (s.zIndex && parseInt(s.zIndex, 10) > 999) {
          el.remove();
        }
      }
      /* Bottom sticky ad banners */
      if (r.height < 120 && r.bottom >= window.innerHeight - 5) {
        if (s.zIndex && parseInt(s.zIndex, 10) > 10) {
          el.remove();
        }
      }
    });

    /* Re-enable scrolling if a modal hid it */
    if (document.body) {
      var bs = getComputedStyle(document.body);
      if (bs.overflow === 'hidden' || bs.overflowY === 'hidden') {
        document.body.style.setProperty('overflow', 'auto', 'important');
      }
    }
    if (document.documentElement) {
      var hs = getComputedStyle(document.documentElement);
      if (hs.overflow === 'hidden' || hs.overflowY === 'hidden') {
        document.documentElement.style.setProperty('overflow', 'auto', 'important');
      }
    }
  }

  /* Run immediately + after delays (some ads inject late). */
  nuke();
  setTimeout(nuke, 500);
  setTimeout(nuke, 1500);
  setTimeout(nuke, 3000);
  setTimeout(function() { nuke(); tryDismissConsent(); }, 2000);
  setTimeout(tryDismissConsent, 4000);

  /* Observe DOM for dynamically-injected ads. */
  if (typeof MutationObserver !== 'undefined') {
    var throttle = null;
    new MutationObserver(function() {
      if (throttle) return;
      throttle = setTimeout(function() { throttle = null; nuke(); }, 300);
    }).observe(document.body || document.documentElement, {
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
  var VIDEO_RE = /\.(mp4|m3u8|webm|mkv|avi|mov|flv|ts|mpd)(\?|#|$)/i;
  var VIDEO_MIME_RE = /^(video\/|application\/x-mpegurl|application\/vnd\.apple\.mpegurl|application\/dash\+xml)/i;

  function send(url, type) {
    if (!url || sent[url]) return;
    /* Skip blob:, data:, and tiny tracking pixels */
    if (url.startsWith('blob:') || url.startsWith('data:')) return;
    if (url.length < 10) return;
    /* Skip known ad/tracking URLs */
    if (url.indexOf('doubleclick') !== -1 || url.indexOf('googlesyndication') !== -1) return;
    if (url.indexOf('googleads') !== -1 || url.indexOf('analytics') !== -1) return;
    sent[url] = true;
    try { VideoDetector.postMessage(JSON.stringify({url: url, type: type})); } catch(_) {}
  }

  /* ── Layer 1: Intercept XMLHttpRequest ── */
  (function() {
    var origOpen = XMLHttpRequest.prototype.open;
    XMLHttpRequest.prototype.open = function(method, url) {
      try {
        var resolved = new URL(url, location.href).href;
        if (VIDEO_RE.test(resolved)) {
          send(resolved, 'xhr');
        }
      } catch(_) {}
      return origOpen.apply(this, arguments);
    };

    /* Also check response type after load */
    var origSend = XMLHttpRequest.prototype.send;
    XMLHttpRequest.prototype.send = function() {
      var xhr = this;
      xhr.addEventListener('load', function() {
        try {
          var ct = xhr.getResponseHeader('content-type') || '';
          if (VIDEO_MIME_RE.test(ct) && xhr.responseURL) {
            send(xhr.responseURL, 'xhr');
          }
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
          if (VIDEO_RE.test(resolved)) {
            send(resolved, 'fetch');
          }
        }
      } catch(_) {}
      return origFetch.apply(this, arguments).then(function(response) {
        try {
          var ct = response.headers.get('content-type') || '';
          if (VIDEO_MIME_RE.test(ct) && response.url) {
            send(response.url, 'fetch');
          }
        } catch(_) {}
        return response;
      });
    };
  })();

  /* ── Layer 3: Monitor <video>/<source> elements + attribute changes ── */
  function scanDOM() {
    /* <video src="..."> */
    document.querySelectorAll('video').forEach(function(v) {
      if (v.src && !v.src.startsWith('blob:')) send(v.src, 'video');
      if (v.currentSrc && !v.currentSrc.startsWith('blob:')) send(v.currentSrc, 'video');
    });
    /* <video><source src="..."></video> */
    document.querySelectorAll('video source[src]').forEach(function(s) {
      if (!s.src.startsWith('blob:')) send(s.src, 'source');
    });
    /* <iframe> that embed known video players */
    document.querySelectorAll('iframe[src]').forEach(function(f) {
      var s = f.src.toLowerCase();
      if (s.indexOf('youtube.com/embed') !== -1 ||
          s.indexOf('player.vimeo.com') !== -1 ||
          s.indexOf('dailymotion.com/embed') !== -1 ||
          s.indexOf('streamable.com') !== -1 ||
          s.indexOf('facebook.com/plugins/video') !== -1 ||
          s.indexOf('twitch.tv/embed') !== -1) {
        send(f.src, 'embed');
      }
    });
    /* <a> links pointing to video files */
    document.querySelectorAll('a[href]').forEach(function(a) {
      if (VIDEO_RE.test(a.href)) {
        send(a.href, 'link');
      }
    });
    /* og:video meta tags */
    document.querySelectorAll('meta[property="og:video"], meta[property="og:video:url"], meta[property="og:video:secure_url"]')
      .forEach(function(m) {
        var c = m.getAttribute('content');
        if (c) send(c, 'meta');
      });
    /* Data attributes on player wrappers */
    document.querySelectorAll('[data-src], [data-video-url], [data-video-src], [data-stream-url], [data-hls], [data-dash]')
      .forEach(function(el) {
        ['data-src', 'data-video-url', 'data-video-src', 'data-stream-url', 'data-hls', 'data-dash'].forEach(function(attr) {
          var v = el.getAttribute(attr);
          if (v && VIDEO_RE.test(v)) {
            try { send(new URL(v, location.href).href, 'data-attr'); } catch(_) {}
          }
        });
      });
    /* JSON-LD structured data (VideoObject) */
    document.querySelectorAll('script[type="application/ld+json"]').forEach(function(s) {
      try {
        var json = JSON.parse(s.textContent);
        var items = Array.isArray(json) ? json : [json];
        items.forEach(function(item) {
          if (item['@type'] === 'VideoObject') {
            if (item.contentUrl) send(item.contentUrl, 'json-ld');
            if (item.embedUrl) send(item.embedUrl, 'json-ld');
          }
        });
      } catch(_) {}
    });
  }

  /* ── Layer 4: PerformanceObserver — catches ALL resource loads ── */
  (function() {
    if (typeof PerformanceObserver === 'undefined') return;
    try {
      var po = new PerformanceObserver(function(list) {
        list.getEntries().forEach(function(entry) {
          var url = entry.name || '';
          if (VIDEO_RE.test(url)) {
            send(url, 'resource');
          }
          /* Also check initiatorType */
          if (entry.initiatorType === 'video' || entry.initiatorType === 'media') {
            if (url && !url.startsWith('blob:') && !url.startsWith('data:')) {
              send(url, 'resource');
            }
          }
        });
      });
      po.observe({entryTypes: ['resource']});
    } catch(_) {}

    /* Also scan already-loaded resources */
    try {
      performance.getEntriesByType('resource').forEach(function(entry) {
        if (VIDEO_RE.test(entry.name)) {
          send(entry.name, 'resource');
        }
      });
    } catch(_) {}
  })();

  /* ── Layer 5: Monitor <video> element creation via MutationObserver ── */
  scanDOM();
  setTimeout(scanDOM, 1500);
  setTimeout(scanDOM, 4000);

  if (typeof MutationObserver !== 'undefined' && (document.body || document.documentElement)) {
    var throttle = null;
    new MutationObserver(function(mutations) {
      /* Quick check if any mutation involves video-related elements */
      var dominated = false;
      for (var i = 0; i < mutations.length; i++) {
        var m = mutations[i];
        if (m.type === 'attributes') { dominated = true; break; }
        for (var j = 0; j < m.addedNodes.length; j++) {
          var n = m.addedNodes[j];
          if (n.nodeType === 1) { dominated = true; break; }
        }
        if (dominated) break;
      }
      if (!dominated) return;
      if (throttle) return;
      throttle = setTimeout(function() { throttle = null; scanDOM(); }, 500);
    }).observe(document.body || document.documentElement, {
      childList: true, subtree: true, attributes: true,
      attributeFilter: ['src', 'data-src', 'data-video-url']
    });
  }
})();
''';
}
