// Ported from spring-framework v7.1.0: spring-beans/src/test/java/org/springframework/beans/factory/support/RootBeanDefinitionTests.java
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
 * spring-beans/src/test/java/org/springframework/beans/factory/support/RootBeanDefinitionTests.java.
 */

/++
`RootBeanDefinitionTests`. `new RootBeanDefinition(X.class)` is the record Flint AOT emits for `X`; Java's
`ExecutorService` is a local interface declaring `shutdown()`, and `AutoCloseable` is `flint.java.lang`'s.

Skipped Java tests (8 in the class):
- setInstanceSetResolvedFactoryMethod, setInstanceDoesNotOverrideResolvedFactoryMethodWithNull: an
  `InstanceSupplier` exposing its `java.lang.reflect.Method` (`getResolvedFactoryMethod`), reflection only.
+/
module flint.beans.root_bean_definition_test;

@safe:

// RootBeanDefinition has no destroy-method names (setDestroyMethodName, resolveDestroyMethodIfNecessary,
// getDestroyMethodNames): Flint AOT infers `(inferred)` close/shutdown at build time.
version (FlintBeanDefinitionDestroyMethods)
{
    import flint.beans.dlbf_fixtures : definitionOf;
    import flint.beans.factory.support : AbstractBeanDefinition, RootBeanDefinition;
    import flint.engine.aot.name : typeNameOf;
    import flint.java.lang : AutoCloseable;

    private final class BeanWithCloseMethod
    {
        void close()
        {
        }
    }

    private final class BeanWithShutdownMethod
    {
        void shutdown()
        {
        }
    }

    /// Java's `java.util.concurrent.ExecutorService`, down to its `shutdown()`.
    private interface ExecutorService
    {
        void shutdown();
    }

    private abstract class BeanImplementingExecutorService : ExecutorService
    {
    }

    private abstract class BeanImplementingExecutorServiceAndAutoCloseable : ExecutorService, AutoCloseable
    {
        void close()
        {
        }
    }

    private final class BeanWithNoDestroyMethod
    {
    }

    unittest
    {
        // resolveDestroyMethodWithMatchingCandidateReplacedForCloseMethod
        auto beanDefinition = definitionOf!BeanWithCloseMethod();
        beanDefinition.setDestroyMethodName(AbstractBeanDefinition.INFER_METHOD);
        beanDefinition.resolveDestroyMethodIfNecessary();
        assert(beanDefinition.getDestroyMethodNames() == ["close"]);
    }

    unittest
    {
        // resolveDestroyMethodWithMatchingCandidateReplacedForShutdownMethod
        auto beanDefinition = definitionOf!BeanWithShutdownMethod();
        beanDefinition.setDestroyMethodName(AbstractBeanDefinition.INFER_METHOD);
        beanDefinition.resolveDestroyMethodIfNecessary();
        assert(beanDefinition.getDestroyMethodNames() == ["shutdown"]);
    }

    unittest
    {
        // resolveDestroyMethodWithMatchingCandidateReplacedForExecutorService
        auto beanDefinition = new RootBeanDefinition(typeNameOf!BeanImplementingExecutorService, null);
        beanDefinition.setDestroyMethodName(AbstractBeanDefinition.INFER_METHOD);
        beanDefinition.resolveDestroyMethodIfNecessary();
        assert(beanDefinition.getDestroyMethodNames() == ["shutdown"]);
        // even on JDK 19+ where the ExecutorService interface declares a default AutoCloseable implementation
    }

    unittest
    {
        // resolveDestroyMethodWithMatchingCandidateReplacedForAutoCloseableExecutorService
        auto beanDefinition = new RootBeanDefinition(typeNameOf!BeanImplementingExecutorServiceAndAutoCloseable, null);
        beanDefinition.setDestroyMethodName(AbstractBeanDefinition.INFER_METHOD);
        beanDefinition.resolveDestroyMethodIfNecessary();
        assert(beanDefinition.getDestroyMethodNames() == ["close"]);
    }

    unittest
    {
        // resolveDestroyMethodWithNoCandidateSetDestroyMethodNameToNull
        auto beanDefinition = definitionOf!BeanWithNoDestroyMethod();
        beanDefinition.setDestroyMethodName(AbstractBeanDefinition.INFER_METHOD);
        beanDefinition.resolveDestroyMethodIfNecessary();
        assert(beanDefinition.getDestroyMethodNames() is null);
    }

    unittest
    {
        // resolveDestroyMethodWithNoResolvableType
        auto beanDefinition = new RootBeanDefinition(null, null);
        beanDefinition.setDestroyMethodName(AbstractBeanDefinition.INFER_METHOD);
        beanDefinition.resolveDestroyMethodIfNecessary();
        assert(beanDefinition.getDestroyMethodNames() is null);
    }
}
