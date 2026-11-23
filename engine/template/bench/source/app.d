module template_probe;

import flint.arena : Buffer, RequestArena, Result;
import flint.engine.templates : render;
import template_replay : benchmark;

@safe:

private struct Model
{
    const(char)[] body;
}

private Result!Buffer renderBody(scope const(char)[] body, ref scope RequestArena arena) nothrow @nogc
{
    scope model = Model(body);
    return render!"fragment.html"(model, arena);
}

int main(string[] args)
{
    benchmark(&renderBody, args.length > 1 && args[1] == "--measure");
    return 0;
}
