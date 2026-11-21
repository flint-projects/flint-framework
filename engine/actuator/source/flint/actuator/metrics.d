module flint.actuator.metrics;

import core.atomic : atomicLoad, atomicOp, atomicStore, cas;
import core.sync.mutex : Mutex;
import flint.arena : Error, Result, Status;
import flint.reactor : Reactor;

@safe:

package(flint.actuator) bool finite(double value) pure nothrow @nogc
{
    return value >= -double.max && value <= double.max;
}

package(flint.actuator) ulong saturated(ulong first, ulong second) pure nothrow @nogc
{
    return second > ulong.max - first ? ulong.max : first + second;
}

package(flint.actuator) enum spanDropsName = "flint_spans_dropped_total";
package(flint.actuator) enum rejectionsName = "flint_export_rejected_total";

private bool validHelp(string text) pure nothrow @nogc
{
    if (text.length > 256)
        return false;
    foreach (char value; text)
        if ((value < 32 && value != '\n' && value != '\r' && value != '\t') || value == 127)
            return false;
    return true;
}

package(flint.actuator) struct Sample
{
    ulong counter;
    ulong[33] buckets;
    double sum = 0;
    ulong invalid;
}

package(flint.actuator) struct Snapshot
{
    string name;
    string help;
    immutable(double)[] bounds;
    bool histogram;
    Sample sample;
}

private struct Cell
{
align(64):
    private shared bool held;
    private Sample sample;

    void add(ulong delta) nothrow @nogc
    {
        lock();
        sample.counter = saturated(sample.counter, delta);
        atomicStore(held, false);
    }

    void observe(uint bucket, double value) nothrow @nogc
    {
        lock();
        const next = sample.sum + value;
        if (finite(value) && finite(next))
        {
            sample.buckets[bucket] = saturated(sample.buckets[bucket], 1);
            sample.sum = next;
        }
        else
            sample.invalid = saturated(sample.invalid, 1);
        atomicStore(held, false);
    }

    Sample read() nothrow @nogc
    {
        lock();
        const copy = sample;
        atomicStore(held, false);
        return copy;
    }

    private void lock() nothrow @nogc
    {
        while (!cas(&held, false, true))
        {
        }
    }
}

private struct Series
{
    string name;
    string help;
    immutable(double)[] bounds;
    bool histogram;
    Cell[] cells;
}

private uint assignedCore = uint.max;
private shared uint nextCore;

private size_t cellFor(size_t count) nothrow @nogc
{
    const owner = Reactor.current().currentCore;
    if (owner != uint.max)
        return owner % count;
    if (assignedCore == uint.max)
        assignedCore = atomicOp!"+="(nextCore, 1U) - 1;
    return assignedCore % count;
}

private bool firstLetter(char c) pure nothrow @nogc
{
    return c == '_' || c == ':' || (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z');
}

package(flint.actuator) bool validName(string name) pure nothrow @nogc
{
    if (name.length == 0 || name.length > 128 || !firstLetter(name[0]))
        return false;
    foreach (char c; name[1 .. $])
        if (!firstLetter(c) && !(c >= '0' && c <= '9'))
            return false;
    return true;
}

private bool validBounds(scope const(double)[] bounds) pure nothrow @nogc
{
    if (bounds.length > 32)
        return false;
    foreach (index, value; bounds)
        if (!finite(value) || (index != 0 && bounds[index - 1] >= value))
            return false;
    return true;
}

private bool takesName(string base, string other) pure nothrow @nogc
{
    if (other.length <= base.length || other[0 .. base.length] != base)
        return false;
    const suffix = other[base.length .. $];
    return suffix == "_bucket" || suffix == "_count" || suffix == "_sum" || suffix == "_invalid_total";
}

private bool conflicting(ref const Series first, ref const Series second) pure nothrow @nogc
{
    return first.name == second.name || (first.histogram && takesName(first.name, second.name))
        || (second.histogram && takesName(second.name, first.name));
}

package(flint.actuator) final class Metrics
{
    private Series[] series;
    private shared uint used;
    private Mutex gate;
    private uint cores;

    this(uint capacity, uint cores)
    {
        series = new Series[capacity + 1];
        gate = new Mutex;
        this.cores = cores;
    }

    Result!uint register(string name, string help, scope const(double)[] bounds, bool isHistogram)
    {
        if (!validName(name) || !validHelp(help) || !validBounds(bounds))
            return Result!uint(0, Error(Status.invalidArgument, "invalid metric schema"));
        if (name == spanDropsName || name == rejectionsName)
            return Result!uint(0, Error(Status.conflict, "reserved metric name"));
        gate.lock_nothrow();
        scope (exit)
            gate.unlock_nothrow();
        const current = atomicLoad(used);
        if (current + 1 >= series.length)
            return Result!uint(0, Error(Status.resourceExhausted, "metric series capacity reached"));
        Series candidate = Series(name, help, null, isHistogram);
        foreach (ref existing; series[1 .. current + 1])
            if (conflicting(existing, candidate))
                return Result!uint(0, Error(Status.conflict, "duplicate metric name"));
        candidate.bounds = bounds.idup;
        candidate.cells = new Cell[cores];
        const id = current + 1;
        series[id] = candidate;
        atomicStore(used, id);
        return Result!uint(id);
    }

    void add(uint id, ulong delta) nothrow @nogc
    {
        if (id != 0 && id <= atomicLoad(used) && !series[id].histogram)
        {
            auto cells = series[id].cells;
            cells[cellFor(cells.length)].add(delta);
        }
    }

    void record(uint id, double value) nothrow @nogc
    {
        if (id == 0 || id > atomicLoad(used) || !series[id].histogram)
            return;
        auto row = &series[id];
        const bounds = row.bounds;
        uint bucket;
        while (bucket < bounds.length && value > bounds[bucket])
            ++bucket;
        row.cells[cellFor(row.cells.length)].observe(bucket, value);
    }

    uint count() const nothrow @nogc
    {
        return atomicLoad(used);
    }

    Snapshot snapshot(uint id) nothrow @nogc
    {
        assert(id != 0 && id <= atomicLoad(used));
        auto row = &series[id];
        Snapshot result = Snapshot(row.name, row.help, row.bounds, row.histogram);
        foreach (ref cell; row.cells)
        {
            const sample = cell.read();
            result.sample.counter = saturated(result.sample.counter, sample.counter);
            result.sample.invalid = saturated(result.sample.invalid, sample.invalid);
            foreach (bucket; 0 .. row.bounds.length + 1)
                result.sample.buckets[bucket] = saturated(result.sample.buckets[bucket], sample.buckets[bucket]);
            const sum = result.sample.sum + sample.sum;
            result.sample.sum = finite(sum) ? sum : (sum < 0 ? -double.max : double.max);
        }
        return result;
    }
}
