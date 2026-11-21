/// Control fixture running the same workload through the native generated codec.
module app;

import codec_probe : runProbe;
import ffi.codec : trial;

@safe:

/// Run and validate the fixed native codec corpus.
int main()
{
    return runProbe(&trial);
}
