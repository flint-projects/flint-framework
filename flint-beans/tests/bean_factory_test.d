module flint.beans.bean_factory_test;

import flint.beans.factory : BeanCurrentlyInCreationException, BeanFactory, BeanNameAware,
    DisposableBean, InitializingBean, NoSuchBeanDefinitionException, NoUniqueBeanDefinitionException;
import flint.beans.factory.config : BeanPostProcessor;
import flint.beans.factory.support : DefaultListableBeanFactory, RootBeanDefinition;
import flint.engine.aot.bean : AotBeanDefinition = BeanDefinition, AotBeanFactory = BeanFactory;
import flint.engine.aot.name : typeNameOf;

@safe:

private interface Greeter
{
    string greet();
}

private final class English : Greeter, BeanNameAware, InitializingBean, DisposableBean
{
    string name;
    bool initialized, destroyed;

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

    void destroy()
    {
        destroyed = true;
    }
}

private final class French : Greeter
{
    string greet()
    {
        return "Bonjour";
    }
}

private Object createEnglish(AotBeanFactory) @safe
{
    return new English;
}

private Object createFrench(AotBeanFactory) @safe
{
    return new French;
}

private AotBeanDefinition definition(string name, string type, Object function(AotBeanFactory) @safe create)
{
    AotBeanDefinition record;
    record.name = name;
    record.type = type;
    record.types = [type, typeNameOf!Greeter];
    record.create = create;
    return record;
}

unittest
{
    auto factory = new DefaultListableBeanFactory;
    factory.registerAotDefinition(definition("english", typeNameOf!English, &createEnglish));
    const english = factory.getBean!English();
    assert(english is factory.getBean!English("english") && english.name == "english" && english.initialized);
    assert(factory.getBean!Greeter().greet() == "Hello");
    factory.registerAotDefinition(definition("french", typeNameOf!French, &createFrench));
    bool threw;
    try
        factory.getBean!Greeter();
    catch (NoUniqueBeanDefinitionException e)
        threw = e.getMessage() == "No qualifying bean of type '" ~ typeNameOf!Greeter
            ~ "' available: expected single matching bean but found 2: english,french";
    assert(threw);
    factory.getBeanDefinition("french").setPrimary(true);
    assert(factory.getBean!Greeter().greet() == "Bonjour");
    assert(factory.getBeansOfType!Greeter().size() == 2);
    threw = false;
    try
        factory.getBean("missing");
    catch (NoSuchBeanDefinitionException e)
        threw = e.getMessage() == "No bean named 'missing' available";
    assert(threw);
    factory.destroySingletons();
    assert(english.destroyed);
}
