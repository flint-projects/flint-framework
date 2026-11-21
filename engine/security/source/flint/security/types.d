/// Value policies and request-arena authorization results.
module flint.security.types;

import flint.arena : Buffer, Text;

@safe:

/// Require at least one of the named roles.
struct RolesAllowed
{
    /// Compile-time role names.
    string[] roles;
}

/// Select an explicitly registered authorization check.
struct PreAuthorize
{
    /// Registry identifier.
    string policy;
}

/// Asymmetric JSON Web Signature algorithms.
enum JwtAlgorithm : ubyte
{
    rs256,
    es256,
    eddsa
}

/// Operator-supplied issuer, audience, and key-fetch policy.
struct JwtPolicy
{
    /// Required issuer claim.
    string issuer;
    /// Required audience member.
    string audience;
    /// Accepted algorithms, fixed at open.
    JwtAlgorithm[] algorithms;
    /// Nonnegative skew applied to expiration and not-before claims.
    long clockSkewSeconds = 30;
    /// Maximum compact JWT bytes.
    uint maxTokenBytes = 16_384;
    /// Require an expiration claim.
    bool requireExpiry = true;
    /// Optional PEM trust bundle for the configured HTTPS JWKS URL.
    string jwksCaBundle;
    /// Monotonic lifetime of a verified key snapshot.
    uint jwksTtlSeconds = 300;
}

/// Verified claims held by the supplied request arena.
struct Principal
{
    /// Optional UTF-8 subject, with an empty handle for absent subject.
    Text subject;
    /// Packed role names. Test membership through hasRole.
    Buffer roles;
    /// Absolute Unix seconds, or long.max if the policy permits absent expiry.
    long expiresAtUnixSeconds;
}

/// Explicit browser access policy.
struct CorsPolicy
{
    /// Exact HTTP origins, or a wildcard when credentials are disabled.
    string[] origins;
    /// Allowed preflight methods.
    string[] methods;
    /// Case-insensitive allowed preflight headers.
    string[] headers;
    /// Whether browser credentials are allowed.
    bool credentials = false;
    /// Maximum preflight cache age in seconds.
    uint maxAgeSeconds = 600;
}

/// Information needed by an application composing a preflight response.
struct CorsDecision
{
    /// Whether the origin, method and requested headers passed.
    bool allowed;
    /// Whether credential use was granted.
    bool credentials;
    /// Policy cache age for an allowed request.
    uint maxAgeSeconds;
    /// Value of the Vary response field.
    string vary = "Origin, Access-Control-Request-Method, Access-Control-Request-Headers";
}
