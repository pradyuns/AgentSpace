import Foundation

/// Evidence gathered from the owned page by ONE bounded Runtime.evaluate.
/// Fields are safe summaries only - no page text, no cookie values, no
/// account strings beyond the identity readback that is digested in place
/// and discarded.
public struct PageFacts: Sendable {
    public var url: String
    public var host: String
    public var title: String
    public var hasPasswordField: Bool
    public var loginPathHint: Bool
    /// Supported-site signals, keyed by site rule name -> opaque marker.
    public var markers: [String: String]
    public init(url: String, host: String, title: String, hasPasswordField: Bool,
                loginPathHint: Bool, markers: [String: String]) {
        self.url = url; self.host = host; self.title = title
        self.hasPasswordField = hasPasswordField; self.loginPathHint = loginPathHint
        self.markers = markers
    }
}

/// Evidence-based access + identity classifier. Three rules keep the states
/// honest:
///  - access (login_required / accessible / unknown) is independent of
///    identity (verified / mismatch / unknown / not_required);
///  - URL account slots (/u/0/, authuser=), hosts and login URLs never prove
///    authentication and never prove WHICH account;
///  - an expected account is only "verified" by a site-specific direct
///    readback of the active account, normalized and compared to the
///    expected digest - anything else is mismatch or unknown, both of which
///    block work while a constraint is set.
public enum SiteAccess {
    public struct Rule: Sendable {
        public let name: String
        /// Host suffixes this rule's evidence applies to.
        public let hosts: [String]
        /// Marker key carrying a "signed-in UI" signal.
        public let signedInMarker: String?
        /// Marker key carrying a login-wall signal.
        public let loginMarker: String?
        /// Marker key carrying the active-account readback (digested, never stored).
        public let accountMarker: String?
        /// Host suffixes that themselves mean a login wall for this site.
        public let loginHosts: [String]
        public init(name: String, hosts: [String], signedInMarker: String?,
                    loginMarker: String?, accountMarker: String?, loginHosts: [String]) {
            self.name = name; self.hosts = hosts; self.signedInMarker = signedInMarker
            self.loginMarker = loginMarker; self.accountMarker = accountMarker; self.loginHosts = loginHosts
        }
    }

    /// Supported verifiers. "gmail" reads Google-account chrome's own
    /// account readback; "fixture" exists only for the test pages shipped in
    /// Fixtures/ (data-fixture-* attributes no real site has). A site with
    /// no rule classifies generically and can never report verified.
    public static let rules: [Rule] = [
        Rule(name: "gmail",
             hosts: ["mail.google.com"],
             signedInMarker: "gmailMain",
             loginMarker: nil,
             accountMarker: "googleAccount",
             loginHosts: ["accounts.google.com"]),
        Rule(name: "fixture",
             hosts: ["127.0.0.1", "localhost"],
             signedInMarker: "fixtureSignedIn",
             loginMarker: "fixtureLogin",
             accountMarker: "fixtureAccount",
             loginHosts: []),
    ]

    public static func rule(for site: String?, host: String) -> Rule? {
        guard let site else { return nil }
        guard let rule = rules.first(where: { $0.name == site.lowercased() }) else { return nil }
        let candidates = rule.hosts + rule.loginHosts
        return candidates.contains(where: { host == $0 || host.hasSuffix("." + $0) }) ? rule : nil
    }

    /// The bounded, side-effect-free JS probe the broker runs on its OWN
    /// page. It returns only enum-ish signals; the account readback is
    /// returned as a string the caller digests then drops.
    public static let evidenceExpression = """
    (() => {
      const banners = [...document.querySelectorAll('#gb[role="banner"],body>header[role="banner"],body>[role="banner"]')].filter(e => !e.closest('[role="main"]'));
      const banner = banners.length === 1 ? banners[0] : null;
      const accounts = new Set();
      for (const control of banner ? banner.querySelectorAll('a[aria-label],button[aria-label]') : []) {
        const label = control.getAttribute('aria-label') || '';
        const href = control.getAttribute('href') || '';
        let accountControl = false;
        try {
          const destination = new URL(href, location.href);
          accountControl = destination.protocol === 'https:' && destination.hostname === 'accounts.google.com' && destination.pathname === '/SignOutOptions';
        } catch {}
        if (!/Google Account/i.test(label) && !accountControl) continue;
        const match = label.match(/[\\w.+-]+@[\\w.-]+/);
        if (match) accounts.add(match[0].toLowerCase());
      }
      const fix = document.querySelector('[data-fixture-auth]');
      const fixAcc = document.querySelector('[data-fixture-account]');
      return {
        document: String(performance.timeOrigin), url: location.href, host: location.hostname, title: document.title || '',
        password: !!document.querySelector('input[type="password"]'),
        loginPath: /login|signin|sign-in|sign_in|auth/i.test(location.pathname),
        gmailMain: !!document.querySelector('[role="main"] [role="grid"], [role="main"] [role="list"]'),
        googleAccount: accounts.size === 1 ? [...accounts][0] : null,
        fixtureSignedIn: fix ? fix.getAttribute('data-fixture-auth') === 'signed-in' : false,
        fixtureLogin: fix ? fix.getAttribute('data-fixture-auth') === 'login' : false,
        fixtureAccount: fixAcc ? (fixAcc.getAttribute('data-fixture-account') || null) : null,
      };
    })()
    """

    /// Classify one facts snapshot. `expectedDigest`/`hash` compare the
    /// observed account to the expected constraint without persisting it.
    public static func assess(_ facts: PageFacts, site: String?,
                              expectedDigest: String?,
                              hash: (String) -> String) -> AccessReport {
        var evidence: [String] = []
        var access = AccessState.unknown
        var reason: String?
        let rule = self.rule(for: site, host: facts.host)

        if let rule, rule.loginHosts.contains(where: { facts.host == $0 || facts.host.hasSuffix("." + $0) }) {
            access = .loginRequired; evidence.append("login-host"); reason = "the page landed on \(site!)'s sign-in host"
        } else if let marker = rule?.loginMarker, facts.markers[marker] == "1" {
            access = .loginRequired; evidence.append("\(rule!.name)-login-marker"); reason = "\(site!) reports its own sign-in UI"
        } else if let marker = rule?.signedInMarker, facts.markers[marker] == "1" {
            access = .accessible; evidence.append("\(rule!.name)-app-ui")
        } else if facts.hasPasswordField {
            access = .loginRequired; evidence.append("password-field")
            reason = "a password field is present; that suggests a sign-in wall but proves nothing about which account"
        } else if facts.loginPathHint {
            access = .loginRequired; evidence.append("login-url")
            reason = "the URL path looks like a sign-in page"
        } else if rule != nil {
            access = .unknown; reason = "\(site!) did not show its supported signed-in or sign-in evidence"
        } else {
            access = .unknown
            reason = site != nil
                ? "no supported verifier for site '\(site!)'; authentication state cannot be promised"
                : "no site verifier selected; authentication state is unknown"
        }

        var identity = expectedDigest == nil ? IdentityState.notRequired : .unknown
        var method: String?
        if expectedDigest != nil {
            if let rule, let marker = rule.accountMarker,
               let observed = facts.markers[marker], !observed.isEmpty {
                method = "\(rule.name)-account-readback"
                identity = hash(observed) == expectedDigest ? .verified : .mismatch
            } else {
                method = nil
                identity = .unknown
            }
        }
        return AccessReport(access: access, identity: identity, identityMethod: method,
                            evidence: evidence, reason: reason)
    }

    public static func facts(from value: JSONValue) -> PageFacts {
        var markers: [String: String] = [:]
        for rule in rules {
            for key in [rule.signedInMarker, rule.loginMarker, rule.accountMarker].compactMap({ $0 }) {
                if field(value, key) == .bool(true) { markers[key] = "1" }
                else if case .string(let text) = field(value, key), !text.isEmpty { markers[key] = text }
            }
        }
        return PageFacts(url: stringField(value, "url") ?? "",
                         host: stringField(value, "host") ?? "",
                         title: stringField(value, "title") ?? "",
                         hasPasswordField: field(value, "password") == .bool(true),
                         loginPathHint: field(value, "loginPath") == .bool(true),
                         markers: markers)
    }
}
