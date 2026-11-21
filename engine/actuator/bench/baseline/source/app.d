module app;

import observe_probe : measure;
import transport_probe : checkManagementTransport;

@safe:

private struct Cell
{
    ulong count;
    double sum = 0;
}

private final class Observations
{
    Cell[] cells;

    this(uint cores)
    {
        cells = new Cell[cores];
    }

    void record(uint worker) nothrow @nogc
    {
        ++cells[worker].count;
        cells[worker].sum += 2.0;
    }

    bool verify(ulong expected)
    {
        ulong count;
        double sum = 0;
        foreach (ref cell; cells)
        {
            count += cell.count;
            sum += cell.sum;
        }
        return count == expected && sum == 2.0 * expected;
    }
}

@system int main()
{
    if (!checkManagementTransport())
        return 1;
    foreach (cores; [1U, 8U, 32U])
    {
        auto workload = new Observations(cores);
        if (!measure(cores, &workload.record, &workload.verify))
            return 2;
    }
    return 0;
}
