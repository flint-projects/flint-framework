// Ported from spring-framework v7.1.0: spring-tx/src/main/java/org/springframework/transaction/annotation/ProxyTransactionManagementConfiguration.java
// Copyright 2002-present the original author or authors.
// Licensed under the Apache License, Version 2.0.
// Modified by the Flint authors.
// Also ported: AbstractTransactionManagementConfiguration.java and TransactionManagementConfigurer.java.

/++
The configurations that `@EnableTransactionManagement` imports, from Spring's
`org.springframework.transaction.annotation`.

$(UL
    $(LI They are a child module of `flint.transaction.annotation` rather than part of it: they build a
        `TransactionInterceptor`, and `flint.transaction.interceptor` reads `@Transactional` from that module, so one
        module would import itself in a cycle. `@EnableTransactionManagement` stays in `flint.transaction.annotation`
        and imports `ProxyTransactionManagementConfiguration` by name.)
    $(LI The interceptor is the advisor: Flint AOT's proxies run every `Advisor` bean whose `appliesTo` accepts the
        method (aot-contract section 7), so Spring's `BeanFactoryTransactionAttributeSourceAdvisor` and
        `TransactionAttributeSourcePointcut` have no separate bean. The attribute source is
        `DescriptorTransactionAttributeSource`, Spring's `AnnotationTransactionAttributeSource` over Flint AOT's
        merged annotations.)
    $(LI Spring's `TransactionAspectSupport` is `BeanFactoryAware`. Here the `transactionInterceptor` bean method hands
        it the context's AOT bean factory, which it looks transaction managers up in.)
    $(LI `ImportAware` is not available yet, so `@EnableTransactionManagement`'s `order` and `rollbackOn` are not
        applied; `setConfigurers` (`TransactionManagementConfigurer` beans) and the `TransactionalEventListenerFactory`
        bean are not ported yet.)
)
+/
module flint.transaction.annotation.configuration;

import flint.beans.factory.config : BeanDefinition;
import flint.beans.factory.support : DefaultListableBeanFactory;
import flint.context : ConfigurableApplicationContext;
import flint.context.annotation : Bean, Configuration, Role;
import flint.transaction : TransactionManager;
import flint.transaction.interceptor : DescriptorTransactionAttributeSource,
    TransactionAttributeSource, TransactionInterceptor;

@safe:

/++
Interface to be implemented by `@Configuration` classes annotated with `@EnableTransactionManagement` that wish to
(or need to) explicitly specify the default `TransactionManager` bean to be used for annotation-driven transaction
management, as opposed to the default approach of a by-type lookup.
+/
interface TransactionManagementConfigurer
{
    /// Return the default transaction manager bean to use for annotation-driven database transaction management.
    TransactionManager annotationDrivenTransactionManager();
}

/++
Abstract base `@Configuration` class providing common structure for enabling Spring's annotation-driven transaction
management capability. Boot's `TransactionAutoConfiguration` backs off when a bean of this type exists.
+/
abstract class AbstractTransactionManagementConfiguration
{
    /// Default transaction manager, as configured through a `TransactionManagementConfigurer`.
    protected TransactionManager txManager;
}

/++
`@Configuration` class that registers the Spring infrastructure beans necessary to enable proxy-based
annotation-driven transaction management.
+/
@Configuration(proxyBeanMethods: false)
@Role(BeanDefinition.ROLE_INFRASTRUCTURE)
class ProxyTransactionManagementConfiguration : AbstractTransactionManagementConfiguration
{
    /// The source of `@Transactional` attributes.
    @Bean
    @Role(BeanDefinition.ROLE_INFRASTRUCTURE)
    TransactionAttributeSource transactionAttributeSource()
    {
        return new DescriptorTransactionAttributeSource;
    }

    /// The interceptor (and advisor) that runs `@Transactional` methods in a transaction.
    @Bean
    @Role(BeanDefinition.ROLE_INFRASTRUCTURE)
    TransactionInterceptor transactionInterceptor(TransactionAttributeSource transactionAttributeSource,
            ConfigurableApplicationContext context)
    {
        auto interceptor = new TransactionInterceptor;
        interceptor.setTransactionAttributeSource(transactionAttributeSource);
        if (txManager !is null)
            interceptor.setTransactionManager(txManager);
        if (auto factory = cast(DefaultListableBeanFactory) context.getBeanFactory())
            interceptor.setBeanFactory(factory.aotBeanFactory());
        return interceptor;
    }
}
