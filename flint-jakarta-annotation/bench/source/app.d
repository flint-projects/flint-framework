/// Jakarta Annotations: @Resource, @PostConstruct and @Priority read at compile time, as Flint AOT reads them.
module app;

import flint.jakarta.annotation : PostConstruct, Priority, Resource;
import std.stdio : writeln;

@safe:

private final class Component
{
    @Resource("jdbc/petclinic") string dataSource;

    @PostConstruct void start()
    {
    }
}

@Priority(7) private struct Interceptor
{
}

int main(string[] args)
{
    enum resource = __traits(getAttributes, Component.dataSource)[0].name;
    enum priority = __traits(getAttributes, Interceptor)[0].value;
    enum hooks = __traits(getAttributes, Component.start).length;
    writeln(args.length > 1 ? resource : resource ~ " " ~ cast(char)('0' + priority) ~ " " ~ cast(char)('0' + hooks));
    return 0;
}
