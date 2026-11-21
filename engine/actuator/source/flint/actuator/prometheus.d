module flint.actuator.prometheus;

import flint.actuator.metrics : Metrics, Snapshot, rejectionsName, saturated, spanDropsName;
import flint.actuator.text : TextWriter;
import flint.arena : Buffer, RequestArena, Result;

@safe:

private void help(ref TextWriter writer, ref scope RequestArena arena, scope const(char)[] text) nothrow @nogc
{
    size_t start;
    foreach (index, char value; text)
    {
        if (value == '\\' || value == '\n' || value == '\r')
        {
            writer.put(arena, text[start .. index]);
            writer.put(arena, value == '\\' ? "\\\\" : "\\n");
            start = index + 1;
        }
    }
    writer.put(arena, text[start .. $]);
}

private void integer(ref TextWriter writer, ref scope RequestArena arena, scope const(char)[] name,
        string suffix, ulong value) nothrow @nogc
{
    writer.put(arena, name);
    writer.put(arena, suffix);
    writer.put(arena, " ");
    writer.integer(arena, value);
    writer.put(arena, "\n");
}

private void histogram(ref TextWriter writer, ref scope RequestArena arena, scope const ref Snapshot row) nothrow @nogc
{
    ulong count;
    foreach (index; 0 .. row.bounds.length + 1)
    {
        count = saturated(count, row.sample.buckets[index]);
        writer.put(arena, row.name);
        writer.put(arena, "_bucket{le=\"");
        if (index == row.bounds.length)
            writer.put(arena, "+Inf");
        else
            writer.number(arena, row.bounds[index]);
        writer.put(arena, "\"} ");
        writer.integer(arena, count);
        writer.put(arena, "\n");
    }
    writer.put(arena, row.name);
    writer.put(arena, "_sum ");
    writer.number(arena, row.sample.sum);
    writer.put(arena, "\n");
    integer(writer, arena, row.name, "_count", count);
    integer(writer, arena, row.name, "_invalid_total", row.sample.invalid);
}

package(flint.actuator):

Result!Buffer render(Metrics table, ulong dropped, ulong rejected, ref scope RequestArena arena) nothrow @nogc
{
    TextWriter writer;
    writer.open(arena);
    const count = table.count;
    foreach (id; 1 .. count + 1)
    {
        const row = table.snapshot(id);
        if (row.help.length != 0)
        {
            writer.put(arena, "# HELP ");
            writer.put(arena, row.name);
            writer.put(arena, " ");
            help(writer, arena, row.help);
            writer.put(arena, "\n");
        }
        writer.put(arena, "# TYPE ");
        writer.put(arena, row.name);
        writer.put(arena, row.histogram ? " histogram\n" : " counter\n");
        if (row.histogram)
            histogram(writer, arena, row);
        else
            integer(writer, arena, row.name, "", row.sample.counter);
    }
    integer(writer, arena, spanDropsName, "", dropped);
    integer(writer, arena, rejectionsName, "", rejected);
    return Result!Buffer(writer.bytes, writer.error);
}
