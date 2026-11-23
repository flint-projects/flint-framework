// Ported from spring-framework v7.1.0: spring-context/src/test/java/org/springframework/context/support/DefaultLifecycleProcessorTests.java
/*
 * Copyright 2002-present the original author or authors.
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *      https://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 *
 * Modified by the Flint authors: ported from spring-framework v7.1.0,
 * spring-context/src/test/java/org/springframework/context/support/DefaultLifecycleProcessorTests.java.
 */

/++
`DefaultLifecycleProcessorTests`. `StaticApplicationContext` is a `GenericApplicationContext` here. Stop callbacks
run synchronously, so the shutdown tests (`LONG_RUNNING` in Spring because of their stop delays) run without delays.

Skipped Java tests (24 in the class):
- singleSmartLifecycleAutoStartupWithLazyInitFactoryBean: FactoryBean (not supported in Phase 1).
- singleSmartLifecycleAutoStartupWithBootstrapExecutor: concurrent startup on a bootstrap executor.
- contextRefreshThenStopForRestartWithMixedBeans, contextRefreshThenRestartWithMixedBeans: `stopForRestart`,
  `restartAfterStop`, `ConfigurableApplicationContext.restart/pause` and `SmartLifecycle.pause/restart` (Spring 7
  additions not ported).
+/
module flint.context.lifecycle_processor_test;

import flint.context : ApplicationContextException, Lifecycle, SmartLifecycle;
import flint.context.support : DefaultLifecycleProcessor, GenericApplicationContext;
import flint.java.lang : IllegalStateException, Runnable;
import std.exception : collectException;

@safe:

/// Java's CopyOnWriteArrayList of started or stopped beans.
private final class Recorder
{
    Lifecycle[] beans;
}

private class TestLifecycleBean : Lifecycle
{
    private Recorder startedBeans;
    private Recorder stoppedBeans;
    private bool running;

    static TestLifecycleBean forStartupTests(Recorder startedBeans)
    {
        return new TestLifecycleBean(startedBeans, null);
    }

    static TestLifecycleBean forShutdownTests(Recorder stoppedBeans)
    {
        return new TestLifecycleBean(null, stoppedBeans);
    }

    this(Recorder startedBeans, Recorder stoppedBeans) pure nothrow @nogc
    {
        this.startedBeans = startedBeans;
        this.stoppedBeans = stoppedBeans;
    }

    bool isRunning()
    {
        return running;
    }

    void start()
    {
        if (startedBeans !is null)
            startedBeans.beans ~= this;
        running = true;
    }

    void stop()
    {
        if (stoppedBeans !is null)
            stoppedBeans.beans ~= this;
        running = false;
    }
}

private final class TestSmartLifecycleBean : TestLifecycleBean, SmartLifecycle
{
    private int phase;
    private bool autoStartup = true;

    static TestSmartLifecycleBean forStartupTests(int phase, Recorder startedBeans)
    {
        return new TestSmartLifecycleBean(phase, startedBeans, null);
    }

    static TestSmartLifecycleBean forShutdownTests(int phase, Recorder stoppedBeans)
    {
        return new TestSmartLifecycleBean(phase, null, stoppedBeans);
    }

    this(int phase, Recorder startedBeans, Recorder stoppedBeans) pure nothrow @nogc
    {
        super(startedBeans, stoppedBeans);
        this.phase = phase;
    }

    int getPhase()
    {
        return phase;
    }

    bool isAutoStartup()
    {
        return autoStartup;
    }

    void setAutoStartup(bool autoStartup) pure nothrow @nogc
    {
        this.autoStartup = autoStartup;
    }

    alias stop = TestLifecycleBean.stop;

    /// Calls stop() before the callback, preserving the invocation order in the stopped list.
    void stop(Runnable callback)
    {
        stop();
        callback.run();
    }
}

private final class DummySmartLifecycleBean : SmartLifecycle
{
    bool running;

    bool isAutoStartup()
    {
        return true;
    }

    void stop(Runnable callback)
    {
        running = false;
        callback.run();
    }

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

    int getPhase()
    {
        return 0;
    }
}

private final class FailingLifecycleBean : SmartLifecycle
{
    mixin SmartLifecycle.Defaults;

    void start()
    {
        throw new IllegalStateException();
    }

    void stop()
    {
        throw new IllegalStateException();
    }

    bool isRunning()
    {
        return false;
    }
}

/// Java's `hasPhase`: the beans' phases (a plain `Lifecycle` is phase 0), in order.
private int[] phases(Lifecycle[] beans)
{
    int[] result;
    foreach (bean; beans)
    {
        auto smart = cast(SmartLifecycle) bean;
        result ~= smart is null ? 0 : smart.getPhase();
    }
    return result;
}

unittest
{
    // defaultLifecycleProcessorInstance
    auto context = new GenericApplicationContext;
    context.refresh();
    const lifecycleProcessor = context.getBean("lifecycleProcessor");
    assert(lifecycleProcessor !is null);
    assert(typeid(lifecycleProcessor) is typeid(DefaultLifecycleProcessor));
    context.close();
}

unittest
{
    // customLifecycleProcessorInstance
    // (DefaultLifecycleProcessor has no timeoutPerShutdownPhase: stop callbacks are synchronous.)
    auto context = new GenericApplicationContext;
    auto factory = context.getBeanFactory();
    context.registerBean!DefaultLifecycleProcessor("lifecycleProcessor", () => new DefaultLifecycleProcessor(factory));
    context.refresh();
    auto bean = context.getBean!DefaultLifecycleProcessor("lifecycleProcessor");
    assert(bean.isRunning() && context.isRunning());
    context.close();
    assert(!bean.isRunning());
}

unittest
{
    // singleSmartLifecycleAutoStartup
    auto context = new GenericApplicationContext;
    auto startedBeans = new Recorder;
    auto bean = TestSmartLifecycleBean.forStartupTests(1, startedBeans);
    bean.setAutoStartup(true);
    context.getBeanFactory().registerSingleton("bean", bean);
    assert(!bean.isRunning());
    context.refresh();
    assert(bean.isRunning());
    context.stop();
    assert(!bean.isRunning());
    assert(startedBeans.beans.length == 1);
    context.close();
}

unittest
{
    // singleSmartLifecycleAutoStartupWithLazyInit
    auto context = new GenericApplicationContext;
    context.registerBean!DummySmartLifecycleBean("bean", () => new DummySmartLifecycleBean, (definition) {
        definition.setLazyInit(true);
    });
    context.refresh();
    auto bean = context.getBean!DummySmartLifecycleBean("bean");
    assert(bean.isRunning());
    context.stop();
    assert(!bean.isRunning());
    context.close();
}

unittest
{
    // singleSmartLifecycleAutoStartupWithFailingLifecycleBean
    auto context = new GenericApplicationContext;
    auto startedBeans = new Recorder;
    auto bean = TestSmartLifecycleBean.forStartupTests(1, startedBeans);
    bean.setAutoStartup(true);
    context.getBeanFactory().registerSingleton("bean", bean);
    context.registerBean!FailingLifecycleBean("failingBean");
    assert(!bean.isRunning());
    auto e = collectException!ApplicationContextException(context.refresh());
    assert(e !is null && cast(IllegalStateException) e.getCause() !is null);
    assert(!bean.isRunning());
    assert(startedBeans.beans.length == 1);
    context.close();
}

unittest
{
    // singleSmartLifecycleWithoutAutoStartup
    auto context = new GenericApplicationContext;
    auto startedBeans = new Recorder;
    auto bean = TestSmartLifecycleBean.forStartupTests(1, startedBeans);
    bean.setAutoStartup(false);
    context.getBeanFactory().registerSingleton("bean", bean);
    assert(!bean.isRunning());
    context.refresh();
    assert(!bean.isRunning());
    assert(startedBeans.beans.length == 0);
    context.start();
    assert(bean.isRunning());
    assert(startedBeans.beans.length == 1);
    context.stop();
    context.close();
}

unittest
{
    // singleSmartLifecycleAutoStartupWithNonAutoStartupDependency
    auto context = new GenericApplicationContext;
    auto startedBeans = new Recorder;
    auto bean = TestSmartLifecycleBean.forStartupTests(1, startedBeans);
    bean.setAutoStartup(true);
    auto dependency = TestSmartLifecycleBean.forStartupTests(1, startedBeans);
    dependency.setAutoStartup(false);
    context.getBeanFactory().registerSingleton("bean", bean);
    context.getBeanFactory().registerSingleton("dependency", dependency);
    context.getBeanFactory().registerDependentBean("dependency", "bean");
    assert(!bean.isRunning() && !dependency.isRunning());
    context.refresh();
    assert(bean.isRunning() && !dependency.isRunning());
    context.stop();
    assert(!bean.isRunning() && !dependency.isRunning());
    assert(startedBeans.beans.length == 1);
    context.close();
}

unittest
{
    // smartLifecycleGroupStartup
    auto context = new GenericApplicationContext;
    auto startedBeans = new Recorder;
    auto beanMin = TestSmartLifecycleBean.forStartupTests(int.min, startedBeans);
    auto bean1 = TestSmartLifecycleBean.forStartupTests(1, startedBeans);
    auto bean2 = TestSmartLifecycleBean.forStartupTests(2, startedBeans);
    auto bean3 = TestSmartLifecycleBean.forStartupTests(3, startedBeans);
    auto beanMax = TestSmartLifecycleBean.forStartupTests(int.max, startedBeans);
    auto factory = context.getBeanFactory();
    factory.registerSingleton("bean3", bean3);
    factory.registerSingleton("beanMin", beanMin);
    factory.registerSingleton("bean2", bean2);
    factory.registerSingleton("beanMax", beanMax);
    factory.registerSingleton("bean1", bean1);
    assert(!beanMin.isRunning() && !bean1.isRunning() && !bean2.isRunning());
    assert(!bean3.isRunning() && !beanMax.isRunning());
    context.refresh();
    assert(beanMin.isRunning() && bean1.isRunning() && bean2.isRunning());
    assert(bean3.isRunning() && beanMax.isRunning());
    context.stop();
    assert(phases(startedBeans.beans) == [int.min, 1, 2, 3, int.max]);
    context.close();
}

/// The four beans of the mixed-bean tests, registered as in Java.
private struct MixedBeans
{
    TestLifecycleBean simpleBean1, simpleBean2;
    TestSmartLifecycleBean smartBean1, smartBean2;
}

private MixedBeans registerMixedBeans(GenericApplicationContext context, Recorder startedBeans)
{
    MixedBeans beans;
    beans.simpleBean1 = TestLifecycleBean.forStartupTests(startedBeans);
    beans.simpleBean2 = TestLifecycleBean.forStartupTests(startedBeans);
    beans.smartBean1 = TestSmartLifecycleBean.forStartupTests(5, startedBeans);
    beans.smartBean2 = TestSmartLifecycleBean.forStartupTests(-3, startedBeans);
    auto factory = context.getBeanFactory();
    factory.registerSingleton("simpleBean1", beans.simpleBean1);
    factory.registerSingleton("smartBean1", beans.smartBean1);
    factory.registerSingleton("simpleBean2", beans.simpleBean2);
    factory.registerSingleton("smartBean2", beans.smartBean2);
    return beans;
}

unittest
{
    // contextRefreshThenStartWithMixedBeans
    auto context = new GenericApplicationContext;
    auto startedBeans = new Recorder;
    auto beans = registerMixedBeans(context, startedBeans);
    assert(!beans.simpleBean1.isRunning() && !beans.simpleBean2.isRunning());
    assert(!beans.smartBean1.isRunning() && !beans.smartBean2.isRunning());
    context.refresh();
    assert(beans.smartBean1.isRunning() && beans.smartBean2.isRunning());
    assert(!beans.simpleBean1.isRunning() && !beans.simpleBean2.isRunning());
    assert(phases(startedBeans.beans) == [-3, 5]);
    context.start();
    assert(beans.smartBean1.isRunning() && beans.smartBean2.isRunning());
    assert(beans.simpleBean1.isRunning() && beans.simpleBean2.isRunning());
    assert(phases(startedBeans.beans) == [-3, 5, 0, 0]);
    context.close();
}

unittest
{
    // contextRefreshThenStopAndRestartWithMixedBeans
    auto context = new GenericApplicationContext;
    auto startedBeans = new Recorder;
    auto beans = registerMixedBeans(context, startedBeans);
    context.refresh();
    assert(beans.smartBean1.isRunning() && beans.smartBean2.isRunning());
    assert(!beans.simpleBean1.isRunning() && !beans.simpleBean2.isRunning());
    assert(phases(startedBeans.beans) == [-3, 5]);
    context.stop();
    assert(!beans.simpleBean1.isRunning() && !beans.simpleBean2.isRunning());
    assert(!beans.smartBean1.isRunning() && !beans.smartBean2.isRunning());
    context.start();
    assert(beans.smartBean1.isRunning() && beans.smartBean2.isRunning());
    assert(beans.simpleBean1.isRunning() && beans.simpleBean2.isRunning());
    assert(phases(startedBeans.beans) == [-3, 5, -3, 0, 0, 5]);
    context.close();
}

/// Seven shutdown beans in Java's registration order.
private void registerAll(GenericApplicationContext context, Lifecycle[] beans...)
{
    import flint.java.lang : valueOf;

    foreach (i, bean; beans)
        context.getBeanFactory().registerSingleton("bean" ~ valueOf(cast(int) i + 1), cast(Object) bean);
}

unittest
{
    // smartLifecycleGroupShutdown
    auto context = new GenericApplicationContext;
    auto stoppedBeans = new Recorder;
    registerAll(context, TestSmartLifecycleBean.forShutdownTests(1, stoppedBeans),
            TestSmartLifecycleBean.forShutdownTests(3,
                stoppedBeans), TestSmartLifecycleBean.forShutdownTests(1, stoppedBeans),
            TestSmartLifecycleBean.forShutdownTests(2, stoppedBeans),
            TestSmartLifecycleBean.forShutdownTests(2, stoppedBeans), TestSmartLifecycleBean.forShutdownTests(int.max,
                stoppedBeans), TestSmartLifecycleBean.forShutdownTests(3, stoppedBeans));
    context.refresh();
    context.stop();
    assert(phases(stoppedBeans.beans) == [int.max, 3, 3, 2, 2, 1, 1]);
    context.close();
}

unittest
{
    // singleSmartLifecycleShutdown
    auto context = new GenericApplicationContext;
    auto stoppedBeans = new Recorder;
    auto bean = TestSmartLifecycleBean.forShutdownTests(99, stoppedBeans);
    context.getBeanFactory().registerSingleton("bean", bean);
    context.refresh();
    assert(bean.isRunning());
    context.stop();
    assert(!bean.isRunning());
    assert(stoppedBeans.beans.length == 1 && cast(Object) stoppedBeans.beans[0] is bean);
    context.close();
}

unittest
{
    // singleLifecycleShutdown
    auto context = new GenericApplicationContext;
    auto stoppedBeans = new Recorder;
    auto bean = new TestLifecycleBean(null, stoppedBeans);
    context.getBeanFactory().registerSingleton("bean", bean);
    context.refresh();
    assert(!bean.isRunning());
    bean.start();
    assert(bean.isRunning());
    context.stop();
    assert(!bean.isRunning());
    assert(stoppedBeans.beans.length == 1 && cast(Object) stoppedBeans.beans[0] is bean);
    context.close();
}

unittest
{
    // mixedShutdown
    auto context = new GenericApplicationContext;
    auto stoppedBeans = new Recorder;
    Lifecycle bean1 = TestLifecycleBean.forShutdownTests(stoppedBeans);
    Lifecycle bean2 = TestSmartLifecycleBean.forShutdownTests(500, stoppedBeans);
    Lifecycle bean3 = TestSmartLifecycleBean.forShutdownTests(int.max, stoppedBeans);
    Lifecycle bean4 = TestLifecycleBean.forShutdownTests(stoppedBeans);
    Lifecycle bean5 = TestSmartLifecycleBean.forShutdownTests(1, stoppedBeans);
    Lifecycle bean6 = TestSmartLifecycleBean.forShutdownTests(-1, stoppedBeans);
    Lifecycle bean7 = TestSmartLifecycleBean.forShutdownTests(int.min, stoppedBeans);
    registerAll(context, bean1, bean2, bean3, bean4, bean5, bean6, bean7);
    context.refresh();
    assert(bean2.isRunning() && bean3.isRunning() && bean5.isRunning() && bean6.isRunning() && bean7.isRunning());
    assert(!bean1.isRunning() && !bean4.isRunning());
    bean1.start();
    bean4.start();
    assert(bean1.isRunning() && bean4.isRunning());
    context.stop();
    foreach (bean; [bean1, bean2, bean3, bean4, bean5, bean6, bean7])
        assert(!bean.isRunning());
    assert(phases(stoppedBeans.beans) == [int.max, 500, 1, 0, 0, -1, int.min]);
    context.close();
}

unittest
{
    // dependencyStartedFirstEvenIfItsPhaseIsHigher
    auto context = new GenericApplicationContext;
    auto startedBeans = new Recorder;
    auto beanMin = TestSmartLifecycleBean.forStartupTests(int.min, startedBeans);
    auto bean2 = TestSmartLifecycleBean.forStartupTests(2, startedBeans);
    auto bean99 = TestSmartLifecycleBean.forStartupTests(99, startedBeans);
    auto beanMax = TestSmartLifecycleBean.forStartupTests(int.max, startedBeans);
    auto factory = context.getBeanFactory();
    factory.registerSingleton("beanMin", beanMin);
    factory.registerSingleton("bean2", bean2);
    factory.registerSingleton("bean99", bean99);
    factory.registerSingleton("beanMax", beanMax);
    factory.registerDependentBean("bean99", "bean2");
    context.refresh();
    assert(beanMin.isRunning() && bean2.isRunning() && bean99.isRunning() && beanMax.isRunning());
    assert(phases(startedBeans.beans) == [int.min, 99, 2, int.max]);
    assert(cast(Object) startedBeans.beans[1] is bean99 && cast(Object) startedBeans.beans[2] is bean2);
    context.stop();
    context.close();
}

unittest
{
    // dependentShutdownFirstEvenIfItsPhaseIsLower
    auto context = new GenericApplicationContext;
    auto stoppedBeans = new Recorder;
    auto beanMin = TestSmartLifecycleBean.forShutdownTests(int.min, stoppedBeans);
    auto bean1 = TestSmartLifecycleBean.forShutdownTests(1, stoppedBeans);
    auto bean99 = TestSmartLifecycleBean.forShutdownTests(99, stoppedBeans);
    auto bean2 = TestSmartLifecycleBean.forShutdownTests(2, stoppedBeans);
    auto bean7 = TestSmartLifecycleBean.forShutdownTests(7, stoppedBeans);
    auto beanMax = TestSmartLifecycleBean.forShutdownTests(int.max, stoppedBeans);
    auto factory = context.getBeanFactory();
    factory.registerSingleton("beanMin", beanMin);
    factory.registerSingleton("bean1", bean1);
    factory.registerSingleton("bean2", bean2);
    factory.registerSingleton("bean7", bean7);
    factory.registerSingleton("bean99", bean99);
    factory.registerSingleton("beanMax", beanMax);
    factory.registerDependentBean("bean99", "bean2");
    context.refresh();
    foreach (bean; [beanMin, bean1, bean2, bean7, bean99, beanMax])
        assert(bean.isRunning());
    context.stop();
    foreach (bean; [beanMin, bean1, bean2, bean7, bean99, beanMax])
        assert(!bean.isRunning());
    assert(stoppedBeans.beans.length == 6);
    assert(phases(stoppedBeans.beans) == [int.max, 2, 99, 7, 1, int.min]);
    assert(cast(Object) stoppedBeans.beans[1] is bean2 && cast(Object) stoppedBeans.beans[2] is bean99);
    context.close();
}

unittest
{
    // dependencyStartedFirstAndIsSmartLifecycle
    auto context = new GenericApplicationContext;
    auto startedBeans = new Recorder;
    auto beanNegative = TestSmartLifecycleBean.forStartupTests(-99, startedBeans);
    auto bean99 = TestSmartLifecycleBean.forStartupTests(99, startedBeans);
    auto bean7 = TestSmartLifecycleBean.forStartupTests(7, startedBeans);
    auto simpleBean = TestLifecycleBean.forStartupTests(startedBeans);
    auto factory = context.getBeanFactory();
    factory.registerSingleton("beanNegative", beanNegative);
    factory.registerSingleton("bean7", bean7);
    factory.registerSingleton("bean99", bean99);
    factory.registerSingleton("simpleBean", simpleBean);
    factory.registerDependentBean("bean7", "simpleBean");
    context.refresh();
    context.stop();
    startedBeans.beans = null;
    // clean start so that simpleBean is included
    context.start();
    assert(beanNegative.isRunning() && bean99.isRunning() && bean7.isRunning() && simpleBean.isRunning());
    assert(phases(startedBeans.beans) == [-99, 7, 0, 99]);
    context.stop();
    context.close();
}

unittest
{
    // dependentShutdownFirstAndIsSmartLifecycle
    auto context = new GenericApplicationContext;
    auto stoppedBeans = new Recorder;
    auto beanMin = TestSmartLifecycleBean.forShutdownTests(int.min, stoppedBeans);
    auto beanNegative = TestSmartLifecycleBean.forShutdownTests(-99, stoppedBeans);
    auto bean1 = TestSmartLifecycleBean.forShutdownTests(1, stoppedBeans);
    auto bean2 = TestSmartLifecycleBean.forShutdownTests(2, stoppedBeans);
    auto bean7 = TestSmartLifecycleBean.forShutdownTests(7, stoppedBeans);
    auto simpleBean = TestLifecycleBean.forShutdownTests(stoppedBeans);
    auto factory = context.getBeanFactory();
    factory.registerSingleton("beanMin", beanMin);
    factory.registerSingleton("beanNegative", beanNegative);
    factory.registerSingleton("bean1", bean1);
    factory.registerSingleton("bean2", bean2);
    factory.registerSingleton("bean7", bean7);
    factory.registerSingleton("simpleBean", simpleBean);
    factory.registerDependentBean("simpleBean", "beanNegative");
    context.refresh();
    assert(beanMin.isRunning() && beanNegative.isRunning() && bean1.isRunning());
    assert(bean2.isRunning() && bean7.isRunning());
    // should start since it's a dependency of an auto-started bean
    assert(simpleBean.isRunning());
    context.stop();
    assert(!beanMin.isRunning() && !beanNegative.isRunning() && !bean1.isRunning());
    assert(!bean2.isRunning() && !bean7.isRunning() && !simpleBean.isRunning());
    assert(phases(stoppedBeans.beans) == [7, 2, 1, -99, 0, int.min]);
    context.close();
}

unittest
{
    // dependencyStartedFirstButNotSmartLifecycle
    auto context = new GenericApplicationContext;
    auto startedBeans = new Recorder;
    auto beanMin = TestSmartLifecycleBean.forStartupTests(int.min, startedBeans);
    auto bean7 = TestSmartLifecycleBean.forStartupTests(7, startedBeans);
    auto simpleBean = TestLifecycleBean.forStartupTests(startedBeans);
    auto factory = context.getBeanFactory();
    factory.registerSingleton("beanMin", beanMin);
    factory.registerSingleton("bean7", bean7);
    factory.registerSingleton("simpleBean", simpleBean);
    factory.registerDependentBean("simpleBean", "beanMin");
    context.refresh();
    assert(beanMin.isRunning() && bean7.isRunning() && simpleBean.isRunning());
    assert(phases(startedBeans.beans) == [0, int.min, 7]);
    context.stop();
    context.close();
}

unittest
{
    // dependentShutdownFirstButNotSmartLifecycle
    auto context = new GenericApplicationContext;
    auto stoppedBeans = new Recorder;
    auto bean1 = TestSmartLifecycleBean.forShutdownTests(1, stoppedBeans);
    auto simpleBean = TestLifecycleBean.forShutdownTests(stoppedBeans);
    auto bean2 = TestSmartLifecycleBean.forShutdownTests(2, stoppedBeans);
    auto bean7 = TestSmartLifecycleBean.forShutdownTests(7, stoppedBeans);
    auto beanMin = TestSmartLifecycleBean.forShutdownTests(int.min, stoppedBeans);
    auto factory = context.getBeanFactory();
    factory.registerSingleton("beanMin", beanMin);
    factory.registerSingleton("bean1", bean1);
    factory.registerSingleton("bean2", bean2);
    factory.registerSingleton("bean7", bean7);
    factory.registerSingleton("simpleBean", simpleBean);
    factory.registerDependentBean("bean2", "simpleBean");
    context.refresh();
    assert(beanMin.isRunning() && bean1.isRunning() && bean2.isRunning() && bean7.isRunning());
    assert(!simpleBean.isRunning());
    simpleBean.start();
    assert(simpleBean.isRunning());
    context.stop();
    assert(!beanMin.isRunning() && !bean1.isRunning() && !bean2.isRunning() && !bean7.isRunning());
    assert(!simpleBean.isRunning());
    assert(phases(stoppedBeans.beans) == [7, 0, 2, 1, int.min]);
    context.close();
}
