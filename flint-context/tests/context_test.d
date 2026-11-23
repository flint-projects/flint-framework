module flint.context.context_test;

import flint.beans.factory : InitializingBean;
import flint.context : ApplicationContext, ApplicationContextAware, ApplicationEvent,
    ApplicationListener, SmartLifecycle;
import flint.context.annotation : AnnotationConfigApplicationContext;
import flint.context.event : ContextClosedEvent, ContextRefreshedEvent;
import flint.context.support : GenericApplicationContext;
import flint.core.env : Environment;

@safe:

private final class Recorder : ApplicationListener!ApplicationEvent
{
    string[] events;

    override void onApplicationEvent(ApplicationEvent event)
    {
        if (cast(ContextRefreshedEvent) event)
            events ~= "refreshed";
        else if (cast(ContextClosedEvent) event)
            events ~= "closed";
    }
}

private final class Server : SmartLifecycle, ApplicationContextAware
{
    mixin SmartLifecycle.Defaults;

    bool running;
    ApplicationContext context;

    void start()
    {
        running = true;
    }

    void stop()
    {
        running = false;
    }

    bool isRunning()
    {
        return running;
    }

    void setApplicationContext(ApplicationContext applicationContext)
    {
        context = applicationContext;
    }
}

unittest
{
    auto context = new GenericApplicationContext;
    context.registerBean!Recorder();
    context.registerBean!Server("server");
    context.refresh();
    const recorder = context.getBean!Recorder();
    const server = context.getBean!Server();
    assert(server.running && server.context is context);
    assert(recorder.events == ["refreshed"]);
    assert(context.getBean!Environment() !is null);
    context.close();
    assert(!server.running && recorder.events == ["refreshed", "closed"] && !context.isActive());
}

unittest
{
    auto context = new AnnotationConfigApplicationContext;
    context.register!Recorder();
    context.refresh();
    assert(context.getBean!Recorder("recorder").events == ["refreshed"]);
    context.publishEvent("payload");
    context.close();
}

private interface TwoPathListener : imported!"flint.context".GenericApplicationListener
{
}

private final class TwoPathRecorder : imported!"flint.context".GenericApplicationListener, TwoPathListener
{
    int seen;

    bool supportsEvent(Object)
    {
        return true;
    }

    void dispatchEvent(Object)
    {
        seen++;
    }

    int getListenerOrder()
    {
        return 0;
    }
}

unittest
{
    // A listener added through one interface path is removed through another: removal compares objects.
    import flint.context : GenericApplicationListener;
    import flint.context.event : SimpleApplicationEventMulticaster;

    auto recorder = new TwoPathRecorder;
    GenericApplicationListener direct = recorder;
    GenericApplicationListener viaBase = cast(TwoPathListener) recorder;
    auto multicaster = new SimpleApplicationEventMulticaster;
    multicaster.addApplicationListener(direct);
    multicaster.removeApplicationListener(viaBase);
    assert(multicaster.getApplicationListeners(null).length == 0);
}
