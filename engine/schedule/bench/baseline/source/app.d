module app;

import schedule_probe : Outcome, cancelled, jobsPerTrial, nextBatch, show;

@safe:

private Outcome run()
{
    Outcome result;
    for (uint position; position < jobsPerTrial;)
    {
        const count = nextBatch(position);
        foreach (index; 0 .. count)
        {
            if (!cancelled(index))
                result.invoke();
        }
        position += count;
    }
    return result;
}

int main()
{
    return show(() => run());
}
