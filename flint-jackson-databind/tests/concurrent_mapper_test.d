/// Flint tests: one mapper shared by several threads, each introspecting and writing many bean types at once, as
/// reactor threads do. The bean cache is read without a lock and grows copy-on-write.
module concurrent_mapper_test;

import flint.engine.aot.descriptor : DescriptorTable, descriptorOf;
import flint.jackson.databind : JsonMapper;

@safe:

private final class Bean(int n)
{
    int value = n;
    string name = "b";
}

private enum beanCount = 48;

// Each thread writes every bean, in a different order, 20 times; true when every document was right.
private bool writeAll(JsonMapper mapper, size_t thread)
{
    import std.conv : to;

    bool all = true;
    foreach (round; 0 .. 20)
        static foreach (k; 0 .. beanCount)
        {
            {
                const n = (k * 7 + 3 + thread * 11) % beanCount;
                static foreach (m; 0 .. beanCount)
                    if (n == m)
                        all = all && mapper.writeValueAsString(
                                new Bean!m()) == `{"name":"b","value":` ~ m.to!string ~ "}";
            }
        }
    return all;
}

@("several threads introspect and write through one mapper")
@system unittest
{
    import core.thread.osthread : Thread;
    import std.conv : to;

    auto table = DescriptorTable.withBuiltins();
    static foreach (n; 0 .. beanCount)
        table.add(descriptorOf!(Bean!n)());
    auto mapper = JsonMapper.builder().descriptors(table).build();
    bool[4] ok;
    Thread spawn(size_t t)
    {
        return new Thread(() { ok[t] = writeAll(mapper, t); });
    }

    Thread[] threads;
    foreach (t; 0 .. ok.length)
        threads ~= spawn(t);
    foreach (thread; threads)
        thread.start();
    foreach (thread; threads)
        thread.join();
    foreach (t, result; ok)
        assert(result, "thread " ~ t.to!string);
}
