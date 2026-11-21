module app;

import codec_replay : archiveReplay, benchmark, require;

@safe:

void main(string[] args)
{
    require(args.length == 1 || (args.length == 2 && args[1] == "--measure"));
    const measure = args.length == 2;
    bool ran;
    version (FlintNativeZlib)
    {
        import providers : gzip;

        benchmark("gzip", &gzip, measure);
        ran = true;
    }
    version (FlintNativeZstd)
    {
        import providers : zstd;

        benchmark("zstd", &zstd, measure);
        ran = true;
    }
    version (FlintNativeBrotli)
    {
        import providers : brotli;

        benchmark("brotli", &brotli, measure);
        ran = true;
    }
    version (FlintNativeLibarchive)
    {
        import providers : archive;

        archiveReplay("zip", &archive!true, measure);
        archiveReplay("tar", &archive!false, measure);
        ran = true;
    }
    require(ran);
}
