/// Explicit object-store credentials, configuration and result handles.
module flint.engine.storage.types;

import flint.arena : Buffer, Result;
import flint.conc : Context;

@safe:

/// One credential snapshot provided by the caller.
struct Credentials
{
    /// Access identity used in the SigV4 credential scope.
    string accessKeyId;
    /// Signing secret supplied by the configured provider.
    string secretAccessKey;
    /// Optional temporary credential token.
    string sessionToken;
    /// Absolute Unix expiry. Zero describes non-expiring credentials without a token.
    long expiresAtUnixSeconds;
}

/// Called on the storage management worker with a bounded caller context.
alias CredentialProvider = Result!Credentials delegate(ref Context context) @safe nothrow;

/// Endpoint, TLS, and multipart configuration.
struct StorageOptions
{
    /// Explicit origin.
    string endpoint;
    /// Region included in the credential scope.
    string region = "us-east-1";
    /// Put the bucket in the request path instead of the authority.
    bool pathStyle = false;
    /// Fully buffered and independently signed size for each nonfinal part.
    size_t partBytes = 8 * 1024 * 1024;
    /// Shared number of owned part buffers and concurrent transfers.
    uint concurrentParts = 4;
    /// Require certificate-chain and hostname verification.
    bool verifyPeer = true;
    /// Optional PEM trust bundle for a private HTTPS endpoint.
    string caBundle;
    /// Allow cleartext only on a numeric loopback origin.
    bool allowLoopbackCleartext = false;
    /// Maximum simultaneously active upload identities.
    uint maxUploads = 1;
    /// Maximum bytes reserved across all multipart payload buffers.
    size_t maxBufferedBytes = 32 * 1024 * 1024;
    /// Explicit UTC offset for request signatures, bounded to fifteen minutes.
    int clockSkewSeconds;
    /// Maximum decoded bytes accepted from an object download.
    size_t maxDownloadBytes = 1024 * 1024 * 1024;
}

/// S3 response identity. Byte handles belong to the caller's arena.
struct ObjectInfo
{
    /// Complete object size.
    ulong size;
    /// Opaque value returned by the service.
    Buffer etag;
    /// Optional object revision.
    Buffer versionId;
}

/// Optional selectors for a streamed object download.
struct DownloadOptions
{
    /// Request the closed interval from first through last.
    bool hasRange;
    /// Initial byte offset.
    ulong first;
    /// Inclusive final byte offset.
    ulong last;
    /// Require the specified opaque ETag.
    string ifMatch;
    /// Read a specific revision.
    string versionId;
}
