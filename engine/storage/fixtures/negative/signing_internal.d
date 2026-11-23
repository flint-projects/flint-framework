module signing_internal;

import flint.engine.storage.credentials : CredentialStore;

@safe:

/// Attempt to read a credential snapshot directly instead of through a signed request.
bool readSnapshot(CredentialStore store)
{
    return store.take(0).ok;
}
