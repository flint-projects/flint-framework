/// spring-beans' DefaultListableBeanFactory: an AOT bean definition, its lifecycle callbacks and getBean by type.
module app;

import flint.beans.factory : BeanNameAware, InitializingBean;
import flint.beans.factory.support : DefaultListableBeanFactory;
import flint.engine.aot.bean : AotBeanDefinition = BeanDefinition, AotBeanFactory = BeanFactory;
import flint.engine.aot.name : typeNameOf;
import core.stdc.stdio : fputc, stdout;

@safe:

/// Writes one line without Phobos, so the probe adds no std.format template instances to the module's count.
private void emit(scope const(char)[] text) nothrow @nogc
{
    foreach (c; text)
        fputc(c, stdout);
    fputc('\n', stdout);
}

private interface Greeter
{
    string greet();
}

private final class English : Greeter, BeanNameAware, InitializingBean
{
    string name;
    bool initialized;

    string greet()
    {
        return "Hello";
    }

    void setBeanName(string name)
    {
        this.name = name;
    }

    void afterPropertiesSet()
    {
        initialized = true;
    }
}

private Object createEnglish(AotBeanFactory) @safe
{
    return new English;
}

int main(string[] args)
{
    AotBeanDefinition record;
    record.name = args.length > 1 ? "greeter" : "english";
    record.type = typeNameOf!English;
    record.types = [record.type, typeNameOf!Greeter];
    record.create = &createEnglish;
    auto factory = new DefaultListableBeanFactory;
    factory.registerAotDefinition(record);
    auto english = factory.getBean!English();
    emit(factory.getBean!Greeter().greet() ~ " " ~ english.name ~ (english.initialized ? " initialized" : ""));
    return 0;
}
