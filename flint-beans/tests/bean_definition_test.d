// Ported from spring-framework v7.1.0: spring-beans/src/test/java/org/springframework/beans/factory/support/BeanDefinitionTests.java
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
 * spring-beans/src/test/java/org/springframework/beans/factory/support/BeanDefinitionTests.java.
 */

/++
`BeanDefinitionTests`. `new RootBeanDefinition(TestBean.class)` is the record Flint AOT emits for `TestBean`
(`testBeanDefinition()`); Java's `equals`/`hashCode` are D's `==`/`toHash`. Comparing class references with `==`
calls `Object.opEquals`, which is `@system`, so the equality tests are `@system`.

Every test is gated: `RootBeanDefinition` keeps Object identity for equality, and has no property values,
constructor argument values, parent name or `BeanDefinitionHolder`.
+/
module flint.beans.bean_definition_test;

// RootBeanDefinition does not override opEquals/toHash: equal settings still compare unequal (Object identity).
version (FlintBeanDefinitionEquality)
{
    import flint.beans.dlbf_fixtures : testBeanDefinition;

    @system unittest
    {
        // beanDefinitionEquality
        auto bd = testBeanDefinition();
        bd.setAbstract(true);
        bd.setLazyInit(true);
        bd.setScope("request");
        auto otherBd = testBeanDefinition();
        assert(bd != otherBd);
        assert(otherBd != bd);
        otherBd.setAbstract(true);
        otherBd.setLazyInit(true);
        otherBd.setScope("request");
        assert(bd == otherBd);
        assert(otherBd == bd);
        assert(bd.toHash() == otherBd.toHash());
    }
}

// RootBeanDefinition has no property values (getPropertyValues): Flint AOT sets properties in generated code.
version (FlintBeanDefinitionPropertyValues)
{
    import flint.beans.dlbf_fixtures : testBeanDefinition;

    @system unittest
    {
        // beanDefinitionEqualityWithPropertyValues
        auto bd = testBeanDefinition();
        bd.getPropertyValues().add("name", "myName");
        bd.getPropertyValues().add("age", "99");
        auto otherBd = testBeanDefinition();
        otherBd.getPropertyValues().add("name", "myName");
        assert(bd != otherBd);
        assert(otherBd != bd);
        otherBd.getPropertyValues().add("age", "11");
        assert(bd != otherBd);
        assert(otherBd != bd);
        otherBd.getPropertyValues().add("age", "99");
        assert(bd == otherBd);
        assert(otherBd == bd);
        assert(bd.toHash() == otherBd.toHash());
    }
}

// RootBeanDefinition has no constructor argument values (getConstructorArgumentValues): generated factories pass
// the arguments.
version (FlintBeanDefinitionConstructorArguments)
{
    import flint.beans.dlbf_fixtures : testBeanDefinition;
    import flint.engine.aot.any : Any;

    @system unittest
    {
        // beanDefinitionEqualityWithConstructorArguments
        auto bd = testBeanDefinition();
        bd.getConstructorArgumentValues().addGenericArgumentValue(Any.of("test"));
        bd.getConstructorArgumentValues().addIndexedArgumentValue(1, Any.of(5));
        auto otherBd = testBeanDefinition();
        otherBd.getConstructorArgumentValues().addGenericArgumentValue(Any.of("test"));
        assert(bd != otherBd);
        assert(otherBd != bd);
        otherBd.getConstructorArgumentValues().addIndexedArgumentValue(1, Any.of(9));
        assert(bd != otherBd);
        assert(otherBd != bd);
        otherBd.getConstructorArgumentValues().addIndexedArgumentValue(1, Any.of(5));
        assert(bd == otherBd);
        assert(otherBd == bd);
        assert(bd.toHash() == otherBd.toHash());
    }

    @system unittest
    {
        // beanDefinitionEqualityWithTypedConstructorArguments
        auto bd = testBeanDefinition();
        bd.getConstructorArgumentValues().addGenericArgumentValue(Any.of("test"), "int");
        bd.getConstructorArgumentValues().addIndexedArgumentValue(1, Any.of(5), "long");
        auto otherBd = testBeanDefinition();
        otherBd.getConstructorArgumentValues().addGenericArgumentValue(Any.of("test"), "int");
        otherBd.getConstructorArgumentValues().addIndexedArgumentValue(1, Any.of(5));
        assert(bd != otherBd);
        assert(otherBd != bd);
        otherBd.getConstructorArgumentValues().addIndexedArgumentValue(1, Any.of(5), "int");
        assert(bd != otherBd);
        assert(otherBd != bd);
        otherBd.getConstructorArgumentValues().addIndexedArgumentValue(1, Any.of(5), "long");
        assert(bd == otherBd);
        assert(otherBd == bd);
        assert(bd.toHash() == otherBd.toHash());
    }
}

// Bean definitions have no parent name and cannot be merged (setParentName, overrideFrom, a copy constructor).
version (FlintChildBeanDefinitions)
{
    import flint.beans.dlbf_fixtures : testBeanDefinition;
    import flint.beans.factory.support : GenericBeanDefinition, RootBeanDefinition;
    import flint.engine.aot.any : Any;

    @system unittest
    {
        // genericBeanDefinitionEquality
        auto bd = new GenericBeanDefinition;
        bd.setParentName("parent");
        bd.setScope("request");
        bd.setAbstract(true);
        bd.setLazyInit(true);
        auto otherBd = new GenericBeanDefinition;
        otherBd.setScope("request");
        otherBd.setAbstract(true);
        otherBd.setLazyInit(true);
        assert(bd != otherBd);
        assert(otherBd != bd);
        otherBd.setParentName("parent");
        assert(bd == otherBd);
        assert(otherBd == bd);
        assert(bd.toHash() == otherBd.toHash());

        bd.getPropertyValues();
        assert(bd == otherBd);
        assert(otherBd == bd);
        assert(bd.toHash() == otherBd.toHash());

        bd.getConstructorArgumentValues();
        assert(bd == otherBd);
        assert(otherBd == bd);
        assert(bd.toHash() == otherBd.toHash());
    }

    @system unittest
    {
        // beanDefinitionMerging
        auto bd = testBeanDefinition();
        bd.getConstructorArgumentValues().addGenericArgumentValue(Any.of("test"));
        bd.getConstructorArgumentValues().addIndexedArgumentValue(1, Any.of(5));
        bd.getPropertyValues().add("name", "myName");
        bd.getPropertyValues().add("age", "99");
        bd.setQualifiedElement(typeid(BeanDefinitionTests));

        auto childBd = new GenericBeanDefinition;
        childBd.setParentName("bd");

        auto mergedBd = new RootBeanDefinition(bd);
        mergedBd.overrideFrom(childBd);
        assert(mergedBd.getConstructorArgumentValues().getArgumentCount() == 2);
        assert(mergedBd.getPropertyValues().size() == 2);
        assert(mergedBd == bd);

        mergedBd.getConstructorArgumentValues().getArgumentValue(1, null).setValue(Any.of(9));
        assert(bd.getConstructorArgumentValues().getArgumentValue(1, null).getValue().get!int == 5);
        assert(bd.getQualifiedElement() is typeid(BeanDefinitionTests));
    }

    /// The test class, the qualified element of `beanDefinitionMerging`.
    private final class BeanDefinitionTests
    {
    }
}

// Flint has no BeanDefinitionHolder.
version (FlintBeanDefinitionHolder)
{
    import flint.beans.dlbf_fixtures : testBeanDefinition;
    import flint.beans.factory.config : BeanDefinitionHolder;

    @system unittest
    {
        // beanDefinitionHolderEquality
        auto bd = testBeanDefinition();
        bd.setAbstract(true);
        bd.setLazyInit(true);
        bd.setScope("request");
        const holder = new BeanDefinitionHolder(bd, "bd");
        auto otherBd = testBeanDefinition();
        assert(bd != otherBd);
        assert(otherBd != bd);
        otherBd.setAbstract(true);
        otherBd.setLazyInit(true);
        otherBd.setScope("request");
        const otherHolder = new BeanDefinitionHolder(bd, "bd");
        assert(holder == otherHolder);
        assert(otherHolder == holder);
        assert(holder.toHash() == otherHolder.toHash());
    }
}
