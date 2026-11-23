/// Exercise fixed, explicitly registered DI startup graphs and typed reads.
module app;

import di_probe_harness : Counter, Reader, Settings, Worker, checkArena, failed, invoke, measure;
import flint.arena : Status;
import flint.engine.di : AppContext;

@safe:

private alias Context1 = AppContext!(Settings);

private alias Context16 = AppContext!(Settings, Worker!1, Worker!2, Worker!3, Worker!4,
        Worker!5, Worker!6, Worker!7, Worker!8, Worker!9, Worker!10, Worker!11, Worker!12,
        Worker!13, Worker!14, Worker!15);

private alias Context64 = AppContext!(Settings, Worker!1, Worker!2, Worker!3, Worker!4,
        Worker!5, Worker!6, Worker!7, Worker!8, Worker!9, Worker!10, Worker!11, Worker!12,
        Worker!13, Worker!14, Worker!15, Worker!16, Worker!17, Worker!18, Worker!19,
        Worker!20, Worker!21, Worker!22, Worker!23, Worker!24, Worker!25, Worker!26,
        Worker!27, Worker!28, Worker!29, Worker!30, Worker!31, Worker!32, Worker!33,
        Worker!34, Worker!35, Worker!36, Worker!37, Worker!38, Worker!39, Worker!40,
        Worker!41, Worker!42, Worker!43, Worker!44, Worker!45, Worker!46, Worker!47,
        Worker!48, Worker!49, Worker!50, Worker!51, Worker!52, Worker!53, Worker!54,
        Worker!55, Worker!56, Worker!57, Worker!58, Worker!59, Worker!60, Worker!61, Worker!62, Worker!63);

private alias Context128 = AppContext!(Settings, Worker!1, Worker!2, Worker!3, Worker!4,
        Worker!5, Worker!6, Worker!7, Worker!8, Worker!9, Worker!10, Worker!11, Worker!12,
        Worker!13, Worker!14, Worker!15, Worker!16, Worker!17, Worker!18, Worker!19,
        Worker!20, Worker!21, Worker!22, Worker!23, Worker!24, Worker!25, Worker!26,
        Worker!27, Worker!28, Worker!29, Worker!30, Worker!31, Worker!32, Worker!33,
        Worker!34, Worker!35, Worker!36, Worker!37, Worker!38, Worker!39, Worker!40,
        Worker!41, Worker!42, Worker!43, Worker!44, Worker!45, Worker!46, Worker!47,
        Worker!48, Worker!49, Worker!50, Worker!51, Worker!52, Worker!53, Worker!54,
        Worker!55, Worker!56, Worker!57, Worker!58, Worker!59, Worker!60, Worker!61,
        Worker!62, Worker!63, Worker!64, Worker!65, Worker!66, Worker!67, Worker!68,
        Worker!69, Worker!70, Worker!71, Worker!72, Worker!73, Worker!74, Worker!75,
        Worker!76, Worker!77, Worker!78, Worker!79, Worker!80, Worker!81, Worker!82,
        Worker!83, Worker!84, Worker!85, Worker!86, Worker!87, Worker!88, Worker!89,
        Worker!90, Worker!91, Worker!92, Worker!93, Worker!94, Worker!95, Worker!96,
        Worker!97, Worker!98, Worker!99, Worker!100, Worker!101, Worker!102, Worker!103,
        Worker!104, Worker!105, Worker!106, Worker!107, Worker!108, Worker!109, Worker!110,
        Worker!111, Worker!112, Worker!113, Worker!114, Worker!115, Worker!116, Worker!117,
        Worker!118, Worker!119, Worker!120, Worker!121, Worker!122, Worker!123, Worker!124,
        Worker!125, Worker!126, Worker!127);

private ulong startup(Context, uint count)(uint input)
{
    Context context;
    if (context.provide(Settings(input)).code != Status.ok || context.initialize().code != Status.ok)
        return failed;
    scope (exit)
        context.shutdown();

    const settings = context.get!Settings();
    static if (count == 1)
        return settings.nonce + settings.initialized;
    else
        return context.get!(Worker!(count - 1))().value + settings.initialized;
}

/// Check and consume all startup sizes, a concrete lookup and an interface call.
int main()
{
    enum uint configured = 731;
    if (!checkArena() || !measure("startup-1", 0, true, (input) => startup!(Context1, 1)(input))
            || !measure("startup-16", 135, true, (input) => startup!(Context16, 16)(input)) || !measure("startup-64",
                2079, true, (input) => startup!(Context64, 64)(input)) || !measure("startup-128",
                8255, true, (input) => startup!(Context128, 128)(input)))
        return 1;

    auto counter = new Counter;
    counter.value = configured;
    AppContext!(Counter, Reader) context;
    if (context.provide(counter).code != Status.ok || context.provide!Reader(counter)
            .code != Status.ok || context.initialize().code != Status.ok)
        return 1;
    scope (exit)
        context.shutdown();

    auto reader = context.get!Reader();
    return measure("direct-get", configured, false, (input) => context.get!Counter().value + input)
        && measure("interface-invoke", configured, false, (input) => invoke(reader, input)) ? 0 : 1;
}
