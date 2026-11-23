/// spring-context's GenericApplicationContext: register, refresh, getBean, events and close.
module app;

import flint.context : ApplicationEvent, ApplicationListener;
import flint.context.event : ContextClosedEvent, ContextRefreshedEvent;
import flint.context.support : GenericApplicationContext;
import std.stdio : writeln;

@safe:

private final class Recorder : ApplicationListener!ApplicationEvent
{
    string events;

    override void onApplicationEvent(ApplicationEvent event)
    {
        if (cast(ContextRefreshedEvent) event)
            events ~= "refreshed";
        else if (cast(ContextClosedEvent) event)
            events ~= " closed";
    }
}

int main(string[] args)
{
    auto context = new GenericApplicationContext;
    context.registerBean!Recorder(args.length > 1 ? "audit" : "recorder");
    context.refresh();
    auto recorder = context.getBean!Recorder();
    const named = context.containsBean("audit") ? " audit" : " recorder";
    context.close();
    writeln(recorder.events ~ named ~ (context.isActive() ? " active" : " inactive"));
    return 0;
}
