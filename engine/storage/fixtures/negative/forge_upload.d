module forge_upload;

import flint.storage : Upload;

@safe:

/// Attempt to rewrite an upload handle's generation outside the storage package.
Upload forgeUpload()
{
    Upload upload;
    upload.generation = 1;
    return upload;
}
