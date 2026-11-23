module app;

import flint.engine.style : Style, measure, render;
import style_workload : Shape, runWorkload;

@safe:

private Shape scan(string input)
{
    const size = measure(input);
    return Shape(size.cells, size.lines);
}

private string layout(string input, uint width)
{
    return render(input, Style.init, width);
}

int main(string[] args)
{
    return runWorkload!(scan, layout)(args.length > 1 && args[1] == "--measure");
}
