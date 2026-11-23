/// Jakarta Annotations: @Resource, @PostConstruct and @Priority read at compile time, as Flint AOT reads them.
module app;

import flint.jakarta.annotation : PostConstruct, Priority, Resource;
import core.stdc.stdio : fputc, stdout;

@safe:

/// Writes one line without Phobos, so the probe adds no std.format template instances to the module's count.
private void emit(scope const(char)[] text) nothrow @nogc
{
    foreach (c; text)
        fputc(c, stdout);
    fputc('\n', stdout);
}

private final class Component
{
    @Resource("jdbc/petclinic")
    string dataSource;

    @PostConstruct
    void start()
    {
    }
}

@Priority(7)
private struct Interceptor
{
}

int main(string[] args)
{
    enum resource = __traits(getAttributes, Component.dataSource)[0].name;
    enum priority = __traits(getAttributes, Interceptor)[0].value;
    enum hooks = __traits(getAttributes, Component.start).length;
    emit(args.length > 1 ? resource : resource ~ " " ~ cast(char)('0' + priority) ~ " " ~ cast(char)('0' + hooks));
    return 0;
}
