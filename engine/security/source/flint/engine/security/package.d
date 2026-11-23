/// Authentication policy, CORS and pinned cryptographic operations.
module flint.engine.security;

public import flint.engine.security.authorization : PrincipalPolicy, RegisteredPolicy, authorize,
    hasRole, rolesAllowed;
public import flint.engine.security.bcrypt : bcryptAvailable, bcryptHash, bcryptSalt;
public import flint.engine.security.cors : originAllowed, preflight;
public import flint.engine.security.crypto : eraseSecret, hashPassword, hmacSha256, sha256, verifyPassword;
public import flint.engine.security.jwt : JwtVerifier;
public import flint.engine.security.types : CorsDecision, CorsPolicy, JwtAlgorithm, JwtPolicy,
    PreAuthorize, Principal, RolesAllowed;

@safe:
