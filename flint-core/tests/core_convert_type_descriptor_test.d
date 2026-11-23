// Ported from spring-framework v7.1.0: spring-core/src/test/java/org/springframework/core
// Copyright 2002-present the original author or authors.
// Licensed under the Apache License, Version 2.0.
// Modified by the Flint authors.
/++
Port of spring-core's `org.springframework.core.convert.TypeDescriptorTests` (v7.1.0): one `unittest` per Java
test method, each starting with a `// <JavaTestName>` comment.

Flint's `TypeDescriptor` is built from D types (`valueOf!T`, R4) or from a canonical name, an optional AOT
descriptor and merged annotations; `getType()` and `getName()` return the canonical D name, generic arguments
included (`flint.java.util.List!string` where Java prints `java.util.List<java.lang.String>`). D's `int` stands for
`int` and `Integer`, `long` for `Long`; `NumberValue` and `IntegerValue` play `Number` and `Integer` where the
class hierarchy matters.

Skipped Java tests (8), with reasons:
- parameterListNoParamTypes, fieldListOfListUnknown, valueOfCollection, nestedNotParameterized: raw generic types
  (`List`, `List<List>`, `Collection`) have no D equivalent; every D template instance has its arguments.
- valueOfScalar, fieldScalar: they check that the `Integer` wrapper is not primitive; D has no wrapper types
  (valueOfPrimitive covers `int`).
- getAnnotationsReturnsClonedArray: `getAnnotations()` returns a `const` slice, so the write the test makes
  to the returned array is rejected at compile time.
- serializable: Java serialization, excluded from the port (jvm-platform).

Adapted: a field's descriptor (`new TypeDescriptor(getClass().getField(name))`) is the descriptor of its declared
type, `valueOf!(typeof(Fields.name))`, wherever the test checks the type alone; the raw-type assertions of
isAssignableElementTypes and isAssignableMapKeyValueTypes are left out, and the `getObjectType()` assertions are
dropped (no wrapper types). equalityWithGenerics compares `valueOf!(Optional!int)` and
`valueOf!(Optional!string)`, since there is no `ResolvableType`; recursiveTypeWithInterface's type is an interface
extending `Map` of itself, since a D class cannot re-list an interface its base class implements.

Gated tests are written against the R4 façades a port would add: `forParameter!(method)(index)`,
`forField!(T, name)`, `forProperty!(T, name)` and `nested`, the `collection`/`map`/`array` factories, and
`narrow`/`upcast`/`elementTypeDescriptor(value)`.
+/
module flint.core.convert_type_descriptor_test;

import flint.core.convert : TypeDescriptor;
import flint.engine.aot.any : Any;
import flint.engine.aot.name : typeNameOf;
import flint.java.util : ArrayList, HashMap, HashSet, List, Map, Optional, Set;
import flint.util : MultiValueMap;

@safe:

// ---------------------------------------------------------------------------------------------------------------
// Annotations used on tested elements

private struct ParameterAnnotation
{
    int value;
}

private struct FieldAnnotation
{
}

private struct MethodAnnotation1
{
}

private struct MethodAnnotation2
{
}

private struct MethodAnnotation3
{
}

@MethodAnnotation1 private struct ComposedMethodAnnotation1
{
}

@ComposedMethodAnnotation1 private struct ComposedComposedMethodAnnotation1
{
}

// ---------------------------------------------------------------------------------------------------------------
// Classes designed for test introspection

/// Java's `Number`.
private abstract class NumberValue
{
}

/// Java's `Integer`, a `Number`.
private final class IntegerValue : NumberValue
{
}

/// Java's `java.util.Date`, a plain class.
private final class Date
{
}

/// Java's `Enum<?>`.
private enum Tropes
{
    FOO,
}

private class PassDownGeneric(T) : ArrayList!(List!(Set!T))
{
}

private class RecursiveMap : HashMap!(string, RecursiveMap)
{
}

/// D cannot re-list an interface its base class implements without re-implementing it: the recursion runs
/// through the interface alone.
private interface RecursiveMapWithInterface : Map!(string, RecursiveMapWithInterface)
{
}

/// The fields of Java's test class, for `typeof` (fields designed for test introspection).
private final class Fields
{
    List!string listOfString;
    List!(List!string) listOfListOfString;
    int[] intArray;
    List!string[] arrayOfListOfString;
    List!int listField;
    Map!(string, int) mapField;
    Map!(string, List!int) nestedMapField;
    Map!(List!int, List!long) fieldMap;
    List!(Map!(int, string)) test4;
    @FieldAnnotation List!string fieldAnnotated;
    @FieldAnnotation List!(List!int) listPreserveContext;
    @FieldAnnotation Map!(List!int, List!int) mapPreserveContext;
    List!NumberValue isAssignableElementTypes;
    Map!(const(char)[], NumberValue) isAssignableMapKeyValueTypes;
    MultiValueMap!(string, int) multiValueMap;
    PassDownGeneric!int passDownGeneric;
}

version (FlintTypeDescriptorSources) // no TypeDescriptor from a MethodParameter, field or Property
{
    /// The methods of Java's test class (methods designed for test introspection).
    private class Methods
    {
        @MethodAnnotation3 private Map!(List!int, List!long) property_;

        void testParameterPrimitive(int primitive)
        {
        }

        void testParameterScalar(string value)
        {
        }

        void testParameterList(List!(List!(Map!(int, Tropes))) list)
        {
        }

        void testParameterArray(int[] array)
        {
        }

        void testParameterMap(Map!(int, List!string) map)
        {
        }

        void test1(List!string param1)
        {
        }

        void test2(List!(List!string) param1)
        {
        }

        void test3(Map!(int, string) param1)
        {
        }

        void test4(List!(Map!(int, string)) param1)
        {
        }

        void test5(string param1)
        {
        }

        List!(Map!(int, string)) getTest4()
        {
            return null;
        }

        void setTest4(List!(Map!(int, string)) test4)
        {
        }

        Map!(string, List!(List!int)) getComplexProperty()
        {
            return null;
        }

        @MethodAnnotation1 Map!(List!int, List!long) getProperty()
        {
            return property_;
        }

        @MethodAnnotation2 void setProperty(Map!(List!int, List!long) property)
        {
            property_ = property;
        }

        @MethodAnnotation1 void methodWithLocalAnnotation()
        {
        }

        @ComposedMethodAnnotation1 void methodWithComposedAnnotation()
        {
        }

        @ComposedComposedMethodAnnotation1 void methodWithComposedComposedAnnotation()
        {
        }

        void setComplexProperty(Map!(string, List!(List!int)) complexProperty)
        {
        }

        void testAnnotatedMethod(@ParameterAnnotation(123) string parameter)
        {
        }

        void testAnnotatedMethodDifferentAnnotationValue(@ParameterAnnotation(567) string parameter)
        {
        }
    }

    private class GenericClass(T)
    {
        T getProperty()
        {
            return T.init;
        }

        void setProperty(T t)
        {
        }

        @MethodAnnotation1 List!T getListProperty()
        {
            return null;
        }

        void setListProperty(List!T t)
        {
        }
    }

    private class IntegerClass : GenericClass!int
    {
    }

    private interface GenericType(T)
    {
        T getProperty();

        void setProperty(T t);

        List!T getListProperty();

        void setListProperty(List!T t);
    }

    private class IntegerType : GenericType!int
    {
        int getProperty()
        {
            return 0;
        }

        void setProperty(int t)
        {
        }

        List!int getListProperty()
        {
            return null;
        }

        void setListProperty(List!int t)
        {
        }
    }

    private class NumberType : GenericType!NumberValue
    {
        IntegerValue getProperty()
        {
            return null;
        }

        void setProperty(NumberValue t)
        {
        }

        List!NumberValue getListProperty()
        {
            return null;
        }

        void setListProperty(List!NumberValue t)
        {
        }
    }

    private void assertAnnotationFoundOnMethod(A, alias method)()
    {
        auto typeDescriptor = TypeDescriptor.forParameter!method(-1);
        bool found;
        typeDescriptor.getAnnotation!A(found);
        assert(found, "Should have found @" ~ A.stringof ~ " on " ~ __traits(identifier, method) ~ ".");
    }
}

// parameterPrimitive
version (FlintTypeDescriptorSources) // no TypeDescriptor from a MethodParameter, field or Property
{
    unittest
    {
        auto desc = TypeDescriptor.forParameter!(Methods.testParameterPrimitive)(0);
        assert(desc.getType() == "int");
        assert(desc.getName() == "int");
        assert(desc.toString() == "int");
        assert(desc.isPrimitive());
        assert(desc.getAnnotations().length == 0);
        assert(!desc.isCollection());
        assert(!desc.isMap());
    }
}

// parameterScalar
version (FlintTypeDescriptorSources) // no TypeDescriptor from a MethodParameter, field or Property
{
    unittest
    {
        auto desc = TypeDescriptor.forParameter!(Methods.testParameterScalar)(0);
        assert(desc.getType() == "string");
        assert(desc.getName() == "string");
        assert(desc.toString() == "string");
        assert(!desc.isPrimitive());
        assert(desc.getAnnotations().length == 0);
        assert(!desc.isCollection());
        assert(!desc.isArray());
        assert(!desc.isMap());
    }
}

// parameterList
version (FlintTypeDescriptorSources) // no TypeDescriptor from a MethodParameter, field or Property
{
    unittest
    {
        alias Parameter = List!(List!(Map!(int, Tropes)));
        auto desc = TypeDescriptor.forParameter!(Methods.testParameterList)(0);
        assert(desc.getType() == typeNameOf!Parameter);
        assert(desc.getName() == typeNameOf!Parameter);
        assert(desc.toString() == typeNameOf!Parameter);
        assert(!desc.isPrimitive());
        assert(desc.getAnnotations().length == 0);
        assert(desc.isCollection());
        assert(!desc.isArray());
        assert(desc.getElementTypeDescriptor().getType() == typeNameOf!(List!(Map!(int, Tropes))));
        assert(desc.getElementTypeDescriptor() == TypeDescriptor.nested!(Methods.testParameterList)(0, 1));
        assert(desc.getElementTypeDescriptor()
                .getElementTypeDescriptor() == TypeDescriptor.nested!(Methods.testParameterList)(0, 2));
        assert(desc.getElementTypeDescriptor().getElementTypeDescriptor()
                .getMapValueTypeDescriptor() == TypeDescriptor.nested!(Methods.testParameterList)(0, 3));
        assert(desc.getElementTypeDescriptor().getElementTypeDescriptor().getMapKeyTypeDescriptor().getType() == "int");
        assert(desc.getElementTypeDescriptor().getElementTypeDescriptor()
                .getMapValueTypeDescriptor().getType() == typeNameOf!Tropes);
        assert(!desc.isMap());
    }
}

// parameterArray
version (FlintTypeDescriptorSources) // no TypeDescriptor from a MethodParameter, field or Property
{
    unittest
    {
        auto desc = TypeDescriptor.forParameter!(Methods.testParameterArray)(0);
        assert(desc.getType() == "int[]");
        assert(desc.getName() == "int[]");
        assert(desc.toString() == "int[]");
        assert(!desc.isPrimitive());
        assert(desc.getAnnotations().length == 0);
        assert(!desc.isCollection());
        assert(desc.isArray());
        assert(desc.getElementTypeDescriptor().getType() == "int");
        assert(desc.getElementTypeDescriptor() == TypeDescriptor.valueOf!int);
        assert(!desc.isMap());
    }
}

// parameterMap
version (FlintTypeDescriptorSources) // no TypeDescriptor from a MethodParameter, field or Property
{
    unittest
    {
        alias Parameter = Map!(int, List!string);
        auto desc = TypeDescriptor.forParameter!(Methods.testParameterMap)(0);
        assert(desc.getType() == typeNameOf!Parameter);
        assert(desc.getName() == typeNameOf!Parameter);
        assert(desc.toString() == typeNameOf!Parameter);
        assert(!desc.isPrimitive());
        assert(desc.getAnnotations().length == 0);
        assert(!desc.isCollection());
        assert(!desc.isArray());
        assert(desc.isMap());
        assert(desc.getMapValueTypeDescriptor() == TypeDescriptor.nested!(Methods.testParameterMap)(0, 1));
        assert(desc.getMapValueTypeDescriptor()
                .getElementTypeDescriptor() == TypeDescriptor.nested!(Methods.testParameterMap)(0, 2));
        assert(desc.getMapKeyTypeDescriptor().getType() == "int");
        assert(desc.getMapValueTypeDescriptor().getType() == typeNameOf!(List!string));
        assert(desc.getMapValueTypeDescriptor().getElementTypeDescriptor().getType() == "string");
    }
}

// parameterAnnotated
version (FlintTypeDescriptorSources) // no TypeDescriptor from a MethodParameter, field or Property
{
    unittest
    {
        auto t1 = TypeDescriptor.forParameter!(Methods.testAnnotatedMethod)(0);
        assert(t1.getType() == "string");
        assert(t1.getAnnotations().length == 1);
        bool found;
        const annotation = t1.getAnnotation!ParameterAnnotation(found);
        assert(found);
        assert(t1.hasAnnotation(typeNameOf!ParameterAnnotation));
        assert(annotation.value == 123);
    }
}

// propertyComplex
version (FlintTypeDescriptorSources) // no TypeDescriptor from a MethodParameter, field or Property
{
    unittest
    {
        auto desc = TypeDescriptor.forProperty!(Methods, "complexProperty");
        assert(desc.getMapKeyTypeDescriptor().getType() == "string");
        const valueType = desc.getMapValueTypeDescriptor();
        assert(valueType.getElementTypeDescriptor().getElementTypeDescriptor().getType() == "int");
    }
}

// propertyGenericType
version (FlintTypeDescriptorSources) // no TypeDescriptor from a MethodParameter, field or Property
{
    unittest
    {
        auto desc = TypeDescriptor.forProperty!(IntegerType, "property");
        assert(desc.getType() == "int");
    }
}

// propertyTypeCovariance
version (FlintTypeDescriptorSources) // no TypeDescriptor from a MethodParameter, field or Property
{
    unittest
    {
        auto desc = TypeDescriptor.forProperty!(NumberType, "property");
        assert(desc.getType() == typeNameOf!IntegerValue);
    }
}

// propertyGenericTypeList
version (FlintTypeDescriptorSources) // no TypeDescriptor from a MethodParameter, field or Property
{
    unittest
    {
        auto desc = TypeDescriptor.forProperty!(IntegerType, "listProperty");
        assert(desc.getType() == typeNameOf!(List!int));
        assert(desc.getElementTypeDescriptor().getType() == "int");
    }
}

// propertyGenericClassList
version (FlintTypeDescriptorSources) // no TypeDescriptor from a MethodParameter, field or Property
{
    unittest
    {
        auto desc = TypeDescriptor.forProperty!(IntegerClass, "listProperty");
        assert(desc.getType() == typeNameOf!(List!int));
        assert(desc.getElementTypeDescriptor().getType() == "int");
        bool found;
        desc.getAnnotation!MethodAnnotation1(found);
        assert(found);
        assert(desc.hasAnnotation(typeNameOf!MethodAnnotation1));
    }
}

// property
version (FlintTypeDescriptorSources) // no TypeDescriptor from a MethodParameter, field or Property
{
    unittest
    {
        auto desc = TypeDescriptor.forProperty!(Methods, "property");
        assert(desc.getType() == typeNameOf!(Map!(List!int, List!long)));
        assert(desc.getMapKeyTypeDescriptor().getElementTypeDescriptor().getType() == "int");
        assert(desc.getMapValueTypeDescriptor().getElementTypeDescriptor().getType() == "long");
        assert(desc.hasAnnotation(typeNameOf!MethodAnnotation1));
        assert(desc.hasAnnotation(typeNameOf!MethodAnnotation2));
        assert(desc.hasAnnotation(typeNameOf!MethodAnnotation3));
    }
}

// getAnnotationOnMethodThatIsLocallyAnnotated
version (FlintTypeDescriptorSources) // no TypeDescriptor from a MethodParameter, field or Property
{
    unittest
    {
        assertAnnotationFoundOnMethod!(MethodAnnotation1, Methods.methodWithLocalAnnotation)();
    }
}

// getAnnotationOnMethodThatIsMetaAnnotated
version (FlintTypeDescriptorSources) // no TypeDescriptor from a MethodParameter, field or Property
{
    unittest
    {
        assertAnnotationFoundOnMethod!(MethodAnnotation1, Methods.methodWithComposedAnnotation)();
    }
}

// getAnnotationOnMethodThatIsMetaMetaAnnotated
version (FlintTypeDescriptorSources) // no TypeDescriptor from a MethodParameter, field or Property
{
    unittest
    {
        assertAnnotationFoundOnMethod!(MethodAnnotation1, Methods.methodWithComposedComposedAnnotation)();
    }
}

// fieldList
unittest
{
    auto typeDescriptor = TypeDescriptor.valueOf!(typeof(Fields.listOfString));
    assert(!typeDescriptor.isArray());
    assert(typeDescriptor.getType() == typeNameOf!(List!string));
    assert(typeDescriptor.getElementTypeDescriptor().getType() == "string");
    assert(typeDescriptor.toString() == "flint.java.util.List!string");
}

// fieldListOfListOfString
unittest
{
    auto typeDescriptor = TypeDescriptor.valueOf!(typeof(Fields.listOfListOfString));
    assert(!typeDescriptor.isArray());
    assert(typeDescriptor.getType() == typeNameOf!(List!(List!string)));
    assert(typeDescriptor.getElementTypeDescriptor().getType() == typeNameOf!(List!string));
    version (FlintTypeDescriptorNestedElementTypes) // nested element descriptors lose their own element types
        assert(typeDescriptor.getElementTypeDescriptor().getElementTypeDescriptor().getType() == "string");
    assert(typeDescriptor.toString() == "flint.java.util.List!(List!string)");
}

// fieldArray
unittest
{
    auto typeDescriptor = TypeDescriptor.valueOf!(typeof(Fields.intArray));
    assert(typeDescriptor.isArray());
    assert(typeDescriptor.getElementTypeDescriptor().getType() == "int");
    assert(typeDescriptor.toString() == "int[]");
}

// fieldComplexTypeDescriptor
unittest
{
    auto typeDescriptor = TypeDescriptor.valueOf!(typeof(Fields.arrayOfListOfString));
    assert(typeDescriptor.isArray());
    assert(typeDescriptor.getElementTypeDescriptor().getType() == typeNameOf!(List!string));
    version (FlintTypeDescriptorNestedElementTypes) // nested element descriptors lose their own element types
        assert(typeDescriptor.getElementTypeDescriptor().getElementTypeDescriptor().getType() == "string");
    assert(typeDescriptor.toString() == "flint.java.util.List!string[]");
}

// fieldComplexTypeDescriptor2
unittest
{
    auto typeDescriptor = TypeDescriptor.valueOf!(typeof(Fields.nestedMapField));
    assert(typeDescriptor.isMap());
    assert(typeDescriptor.getMapKeyTypeDescriptor().getType() == "string");
    assert(typeDescriptor.getMapValueTypeDescriptor().getType() == typeNameOf!(List!int));
    version (FlintTypeDescriptorNestedElementTypes) // nested element descriptors lose their own element types
        assert(typeDescriptor.getMapValueTypeDescriptor().getElementTypeDescriptor().getType() == "int");
    assert(typeDescriptor.toString() == "flint.java.util.Map!(string, List!int)");
}

// fieldMap
unittest
{
    auto desc = TypeDescriptor.valueOf!(typeof(Fields.fieldMap));
    assert(desc.isMap());
    version (FlintTypeDescriptorNestedElementTypes) // nested element descriptors lose their own element types
    {
        assert(desc.getMapKeyTypeDescriptor().getElementTypeDescriptor().getType() == "int");
        assert(desc.getMapValueTypeDescriptor().getElementTypeDescriptor().getType() == "long");
    }
}

// fieldAnnotated
version (FlintTypeDescriptorSources) // no TypeDescriptor from a MethodParameter, field or Property
{
    unittest
    {
        auto typeDescriptor = TypeDescriptor.forField!(Fields, "fieldAnnotated");
        assert(typeDescriptor.getAnnotations().length == 1);
        assert(typeDescriptor.hasAnnotation(typeNameOf!FieldAnnotation));
    }
}

// valueOfPrimitive
unittest
{
    auto typeDescriptor = TypeDescriptor.valueOf!int;
    assert(typeDescriptor.isPrimitive());
    assert(!typeDescriptor.isArray());
    assert(!typeDescriptor.isCollection());
    assert(!typeDescriptor.isMap());
    assert(typeDescriptor.getType() == "int");
}

// valueOfArray
unittest
{
    auto typeDescriptor = TypeDescriptor.valueOf!(int[]);
    assert(typeDescriptor.isArray());
    assert(!typeDescriptor.isCollection());
    assert(!typeDescriptor.isMap());
    assert(typeDescriptor.getElementTypeDescriptor().getType() == "int");
}

// forObject
unittest
{
    auto desc = TypeDescriptor.forObject(Any.of("3"));
    assert(desc.getType() == "string");
}

// forObjectNullTypeDescriptor
unittest
{
    auto desc = TypeDescriptor.forObject(Any.init);
    assert(desc is null);
}

// nestedMethodParameterType2Levels
version (FlintTypeDescriptorSources) // no TypeDescriptor from a MethodParameter, field or Property
{
    unittest
    {
        auto t1 = TypeDescriptor.nested!(Methods.test2)(0, 2);
        assert(t1.getType() == "string");
    }
}

// nestedMethodParameterTypeMap
version (FlintTypeDescriptorSources) // no TypeDescriptor from a MethodParameter, field or Property
{
    unittest
    {
        auto t1 = TypeDescriptor.nested!(Methods.test3)(0, 1);
        assert(t1.getType() == "string");
    }
}

// nestedMethodParameterTypeMapTwoLevels
version (FlintTypeDescriptorSources) // no TypeDescriptor from a MethodParameter, field or Property
{
    unittest
    {
        auto t1 = TypeDescriptor.nested!(Methods.test4)(0, 2);
        assert(t1.getType() == "string");
    }
}

// nestedMethodParameterNot1NestedLevel
version (FlintTypeDescriptorSources) // no TypeDescriptor from a MethodParameter, field or Property
{
    unittest
    {
        import flint.java.lang : IllegalArgumentException;
        import flint.util.test_support : expectThrows;

        expectThrows!IllegalArgumentException(() {
            TypeDescriptor.nested!(Methods.test4)(0, 2, /* parameter nesting level */ 2);
        });
    }
}

// nestedTooManyLevels
version (FlintTypeDescriptorSources) // no TypeDescriptor from a MethodParameter, field or Property
{
    unittest
    {
        auto t1 = TypeDescriptor.nested!(Methods.test4)(0, 3);
        assert(t1 is null);
    }
}

// nestedMethodParameterTypeNotNestable
version (FlintTypeDescriptorSources) // no TypeDescriptor from a MethodParameter, field or Property
{
    unittest
    {
        auto t1 = TypeDescriptor.nested!(Methods.test5)(0, 2);
        assert(t1 is null);
    }
}

// nestedMethodParameterTypeInvalidNestingLevel
version (FlintTypeDescriptorSources) // no TypeDescriptor from a MethodParameter, field or Property
{
    unittest
    {
        import flint.java.lang : IllegalArgumentException;
        import flint.util.test_support : expectThrows;

        expectThrows!IllegalArgumentException(() {
            TypeDescriptor.nested!(Methods.test5)(0, 2, /* parameter nesting level */ 2);
        });
    }
}

// nestedFieldTypeMapTwoLevels
version (FlintTypeDescriptorSources) // no TypeDescriptor from a MethodParameter, field or Property
{
    unittest
    {
        auto t1 = TypeDescriptor.nested(TypeDescriptor.forField!(Fields, "test4"), 2);
        assert(t1.getType() == "string");
    }
}

// nestedPropertyTypeMapTwoLevels
version (FlintTypeDescriptorSources) // no TypeDescriptor from a MethodParameter, field or Property
{
    unittest
    {
        auto t1 = TypeDescriptor.nested(TypeDescriptor.forProperty!(Methods, "test4"), 2);
        assert(t1.getType() == "string");
    }
}

// collection
version (FlintTypeDescriptorFactories) // no TypeDescriptor.collection, map or array factories
{
    unittest
    {
        auto desc = TypeDescriptor.collection!List(TypeDescriptor.valueOf!int);
        assert(desc.getType() == typeNameOf!(List!int));
        assert(desc.getName() == typeNameOf!(List!int));
        assert(desc.toString() == "flint.java.util.List!int");
        assert(!desc.isPrimitive());
        assert(desc.getAnnotations().length == 0);
        assert(desc.isCollection());
        assert(!desc.isArray());
        assert(desc.getElementTypeDescriptor().getType() == "int");
        assert(desc.getElementTypeDescriptor() == TypeDescriptor.valueOf!int);
        assert(!desc.isMap());
    }
}

// collectionNested
version (FlintTypeDescriptorFactories) // no TypeDescriptor.collection, map or array factories
{
    unittest
    {
        auto desc = TypeDescriptor.collection!List(TypeDescriptor.collection!List(TypeDescriptor.valueOf!int));
        assert(desc.getType() == typeNameOf!(List!(List!int)));
        assert(desc.getName() == typeNameOf!(List!(List!int)));
        assert(desc.toString() == "flint.java.util.List!(List!int)");
        assert(!desc.isPrimitive());
        assert(desc.getAnnotations().length == 0);
        assert(desc.isCollection());
        assert(!desc.isArray());
        assert(desc.getElementTypeDescriptor().getType() == typeNameOf!(List!int));
        assert(desc.getElementTypeDescriptor().getElementTypeDescriptor() == TypeDescriptor.valueOf!int);
        assert(!desc.isMap());
    }
}

// map
version (FlintTypeDescriptorFactories) // no TypeDescriptor.collection, map or array factories
{
    unittest
    {
        auto desc = TypeDescriptor.map!Map(TypeDescriptor.valueOf!string, TypeDescriptor.valueOf!int);
        assert(desc.getType() == typeNameOf!(Map!(string, int)));
        assert(desc.getName() == typeNameOf!(Map!(string, int)));
        assert(desc.toString() == "flint.java.util.Map!(string, int)");
        assert(!desc.isPrimitive());
        assert(desc.getAnnotations().length == 0);
        assert(!desc.isCollection());
        assert(!desc.isArray());
        assert(desc.isMap());
        assert(desc.getMapKeyTypeDescriptor().getType() == "string");
        assert(desc.getMapValueTypeDescriptor().getType() == "int");
    }
}

// mapNested
version (FlintTypeDescriptorFactories) // no TypeDescriptor.collection, map or array factories
{
    unittest
    {
        auto desc = TypeDescriptor.map!Map(TypeDescriptor.valueOf!string,
                TypeDescriptor.map!Map(TypeDescriptor.valueOf!string, TypeDescriptor.valueOf!int));
        assert(desc.getType() == typeNameOf!(Map!(string, Map!(string, int))));
        assert(desc.getName() == typeNameOf!(Map!(string, Map!(string, int))));
        assert(desc.toString() == "flint.java.util.Map!(string, Map!(string, int))");
        assert(!desc.isPrimitive());
        assert(desc.getAnnotations().length == 0);
        assert(!desc.isCollection());
        assert(!desc.isArray());
        assert(desc.isMap());
        assert(desc.getMapKeyTypeDescriptor().getType() == "string");
        assert(desc.getMapValueTypeDescriptor().getMapKeyTypeDescriptor().getType() == "string");
        assert(desc.getMapValueTypeDescriptor().getMapValueTypeDescriptor().getType() == "int");
    }
}

// narrow
version (FlintTypeDescriptorNarrowing) // no narrow, upcast or element/key/value descriptors narrowed by a value
{
    unittest
    {
        auto desc = TypeDescriptor.valueOf!NumberValue;
        auto value = new IntegerValue;
        desc = desc.narrow(Any.of(value));
        assert(desc.getType() == typeNameOf!IntegerValue);
    }
}

// elementType
version (FlintTypeDescriptorNarrowing) // no narrow, upcast or element/key/value descriptors narrowed by a value
{
    unittest
    {
        auto desc = TypeDescriptor.valueOf!(List!NumberValue);
        auto value = new IntegerValue;
        desc = desc.elementTypeDescriptor(Any.of(value));
        assert(desc.getType() == typeNameOf!IntegerValue);
    }
}

// elementTypePreserveContext
version (FlintTypeDescriptorSources) // no TypeDescriptor from a MethodParameter, field or Property
{
    version (FlintTypeDescriptorNarrowing) // no narrow, upcast or element/key/value descriptors narrowed by a value
    {
        unittest
        {
            auto desc = TypeDescriptor.forField!(Fields, "listPreserveContext");
            assert(desc.getElementTypeDescriptor().getElementTypeDescriptor().getType() == "int");
            List!int value = new ArrayList!int(3);
            desc = desc.elementTypeDescriptor(Any.of(value));
            assert(desc.getElementTypeDescriptor().getType() == "int");
            assert(desc.hasAnnotation(typeNameOf!FieldAnnotation));
        }
    }
}

// mapKeyType
version (FlintTypeDescriptorNarrowing) // no narrow, upcast or element/key/value descriptors narrowed by a value
{
    unittest
    {
        auto desc = TypeDescriptor.valueOf!(Map!(NumberValue, NumberValue));
        auto value = new IntegerValue;
        desc = desc.getMapKeyTypeDescriptor(Any.of(value));
        assert(desc.getType() == typeNameOf!IntegerValue);
    }
}

// mapKeyTypePreserveContext
version (FlintTypeDescriptorSources) // no TypeDescriptor from a MethodParameter, field or Property
{
    version (FlintTypeDescriptorNarrowing) // no narrow, upcast or element/key/value descriptors narrowed by a value
    {
        unittest
        {
            auto desc = TypeDescriptor.forField!(Fields, "mapPreserveContext");
            assert(desc.getMapKeyTypeDescriptor().getElementTypeDescriptor().getType() == "int");
            List!int value = new ArrayList!int(3);
            desc = desc.getMapKeyTypeDescriptor(Any.of(value));
            assert(desc.getElementTypeDescriptor().getType() == "int");
            assert(desc.hasAnnotation(typeNameOf!FieldAnnotation));
        }
    }
}

// mapValueType
version (FlintTypeDescriptorNarrowing) // no narrow, upcast or element/key/value descriptors narrowed by a value
{
    unittest
    {
        auto desc = TypeDescriptor.valueOf!(Map!(NumberValue, NumberValue));
        auto value = new IntegerValue;
        desc = desc.getMapValueTypeDescriptor(Any.of(value));
        assert(desc.getType() == typeNameOf!IntegerValue);
    }
}

// mapValueTypePreserveContext
version (FlintTypeDescriptorSources) // no TypeDescriptor from a MethodParameter, field or Property
{
    version (FlintTypeDescriptorNarrowing) // no narrow, upcast or element/key/value descriptors narrowed by a value
    {
        unittest
        {
            auto desc = TypeDescriptor.forField!(Fields, "mapPreserveContext");
            assert(desc.getMapValueTypeDescriptor().getElementTypeDescriptor().getType() == "int");
            List!int value = new ArrayList!int(3);
            desc = desc.getMapValueTypeDescriptor(Any.of(value));
            assert(desc.getElementTypeDescriptor().getType() == "int");
            assert(desc.hasAnnotation(typeNameOf!FieldAnnotation));
        }
    }
}

// equality
unittest
{
    auto t1 = TypeDescriptor.valueOf!string;
    auto t2 = TypeDescriptor.valueOf!string;
    auto t3 = TypeDescriptor.valueOf!Date;
    auto t4 = TypeDescriptor.valueOf!Date;
    auto t5 = TypeDescriptor.valueOf!(List!int);
    auto t6 = TypeDescriptor.valueOf!(List!int);
    auto t7 = TypeDescriptor.valueOf!(Map!(string, int));
    auto t8 = TypeDescriptor.valueOf!(Map!(string, int));
    assert(t2 == t1);
    assert(t4 == t3);
    assert(t6 == t5);
    assert(t8 == t7);

    auto t9 = TypeDescriptor.valueOf!(typeof(Fields.listField));
    auto t10 = TypeDescriptor.valueOf!(typeof(Fields.listField));
    assert(t10 == t9);

    auto t11 = TypeDescriptor.valueOf!(typeof(Fields.mapField));
    auto t12 = TypeDescriptor.valueOf!(typeof(Fields.mapField));
    assert(t12 == t11);

    version (FlintTypeDescriptorSources) // no TypeDescriptor from a MethodParameter, field or Property
    {
        auto t13 = TypeDescriptor.forParameter!(Methods.testAnnotatedMethod)(0);
        auto t14 = TypeDescriptor.forParameter!(Methods.testAnnotatedMethod)(0);
        assert(t14 == t13);

        auto t15 = TypeDescriptor.forParameter!(Methods.testAnnotatedMethod)(0);
        auto t16 = TypeDescriptor.forParameter!(Methods.testAnnotatedMethodDifferentAnnotationValue)(0);
        assert(t16 != t15);

        auto t17 = TypeDescriptor.forParameter!(Methods.testAnnotatedMethod)(0);
        auto t18 = TypeDescriptor.forParameter!(Methods.test5)(0);
        assert(t18 != t17);
    }
}

// isAssignableTypes
unittest
{
    assert(TypeDescriptor.valueOf!IntegerValue.isAssignableTo(TypeDescriptor.valueOf!NumberValue));
    assert(!TypeDescriptor.valueOf!NumberValue.isAssignableTo(TypeDescriptor.valueOf!IntegerValue));
    assert(!TypeDescriptor.valueOf!string.isAssignableTo(TypeDescriptor.valueOf!(string[])));
}

// isAssignableElementTypes
unittest
{
    assert(TypeDescriptor.valueOf!(typeof(Fields.listField))
            .isAssignableTo(TypeDescriptor.valueOf!(typeof(Fields.listField))));
    assert(!TypeDescriptor.valueOf!(typeof(Fields.isAssignableElementTypes))
            .isAssignableTo(TypeDescriptor.valueOf!(typeof(Fields.listField))));
}

// isAssignableMapKeyValueTypes
unittest
{
    assert(TypeDescriptor.valueOf!(typeof(Fields.mapField))
            .isAssignableTo(TypeDescriptor.valueOf!(typeof(Fields.mapField))));
    assert(!TypeDescriptor.valueOf!(typeof(Fields.isAssignableMapKeyValueTypes))
            .isAssignableTo(TypeDescriptor.valueOf!(typeof(Fields.mapField))));
}

// multiValueMap
unittest
{
    auto td = TypeDescriptor.valueOf!(typeof(Fields.multiValueMap));
    assert(td.isMap());
    assert(td.getMapKeyTypeDescriptor().getType() == "string");
    assert(td.getMapValueTypeDescriptor().getType() == typeNameOf!(List!int));
    version (FlintTypeDescriptorNestedElementTypes) // nested element descriptors lose their own element types
        assert(td.getMapValueTypeDescriptor().getElementTypeDescriptor().getType() == "int");
}

// passDownGeneric
unittest
{
    auto td = TypeDescriptor.valueOf!(typeof(Fields.passDownGeneric));
    assert(td.getElementTypeDescriptor().getType() == typeNameOf!(List!(Set!int)));
    version (FlintTypeDescriptorNestedElementTypes) // nested element descriptors lose their own element types
    {
        assert(td.getElementTypeDescriptor().getElementTypeDescriptor().getType() == typeNameOf!(Set!int));
        assert(td.getElementTypeDescriptor().getElementTypeDescriptor().getElementTypeDescriptor().getType() == "int");
    }
}

// upcast
version (FlintTypeDescriptorSources) // no TypeDescriptor from a MethodParameter, field or Property
{
    version (FlintTypeDescriptorNarrowing) // no narrow, upcast or element/key/value descriptors narrowed by a value
    {
        unittest
        {
            auto typeDescriptor = TypeDescriptor.forProperty!(Methods, "property");
            auto upcast = typeDescriptor.upcast!Object();
            assert(upcast.hasAnnotation(typeNameOf!MethodAnnotation1));
        }
    }
}

// upCastNotSuper
version (FlintTypeDescriptorSources) // no TypeDescriptor from a MethodParameter, field or Property
{
    version (FlintTypeDescriptorNarrowing) // no narrow, upcast or element/key/value descriptors narrowed by a value
    {
        unittest
        {
            import flint.java.lang : IllegalArgumentException;
            import flint.java.util : Collection;
            import flint.util.test_support : expectThrows;

            auto typeDescriptor = TypeDescriptor.forProperty!(Methods, "property");
            const e = expectThrows!IllegalArgumentException(() {
                typeDescriptor.upcast!(Collection!(List!int))();
            });
            assert(e.msg == "interface " ~ typeNameOf!(Map!(List!int,
                    List!long)) ~ " is not assignable to interface " ~ typeNameOf!(Collection!(List!int)));
        }
    }
}

// elementTypeForCollectionSubclass
unittest
{
    static class CustomSet : HashSet!string
    {
    }

    assert(TypeDescriptor.valueOf!string == TypeDescriptor.valueOf!CustomSet.getElementTypeDescriptor());
    version (FlintTypeDescriptorForObjectElementTypes) // forObject records only the value's type name
        assert(TypeDescriptor.valueOf!string == TypeDescriptor.forObject(Any.of(new CustomSet))
                .getElementTypeDescriptor());
}

// elementTypeForMapSubclass
unittest
{
    static class CustomMap : HashMap!(string, int)
    {
    }

    assert(TypeDescriptor.valueOf!string == TypeDescriptor.valueOf!CustomMap.getMapKeyTypeDescriptor());
    assert(TypeDescriptor.valueOf!int == TypeDescriptor.valueOf!CustomMap.getMapValueTypeDescriptor());
    version (FlintTypeDescriptorForObjectElementTypes) // forObject records only the value's type name
    {
        auto customMap = TypeDescriptor.forObject(Any.of(new CustomMap));
        assert(TypeDescriptor.valueOf!string == customMap.getMapKeyTypeDescriptor());
        assert(TypeDescriptor.valueOf!int == customMap.getMapValueTypeDescriptor());
    }
}

// createMapArray
version (FlintTypeDescriptorFactories) // no TypeDescriptor.collection, map or array factories
{
    unittest
    {
        import flint.java.util : LinkedHashMap;

        auto mapType = TypeDescriptor.map!LinkedHashMap(TypeDescriptor.valueOf!string, TypeDescriptor.valueOf!int);
        auto arrayType = TypeDescriptor.array(mapType);
        assert(typeNameOf!(LinkedHashMap!(string, int)[]) == arrayType.getType());
        assert(mapType == arrayType.getElementTypeDescriptor());
    }
}

// createStringArray
version (FlintTypeDescriptorFactories) // no TypeDescriptor.collection, map or array factories
{
    unittest
    {
        auto arrayType = TypeDescriptor.array(TypeDescriptor.valueOf!string);
        assert(TypeDescriptor.valueOf!(string[]) == arrayType);
    }
}

// createNullArray
version (FlintTypeDescriptorFactories) // no TypeDescriptor.collection, map or array factories
{
    unittest
    {
        assert(TypeDescriptor.array(null) is null);
    }
}

// createCollectionWithNullElement
version (FlintTypeDescriptorFactories) // no TypeDescriptor.collection, map or array factories
{
    unittest
    {
        auto typeDescriptor = TypeDescriptor.collection!List(null);
        assert(typeDescriptor.getElementTypeDescriptor() is null);
    }
}

// createMapWithNullElements
version (FlintTypeDescriptorFactories) // no TypeDescriptor.collection, map or array factories
{
    unittest
    {
        import flint.java.util : LinkedHashMap;

        auto typeDescriptor = TypeDescriptor.map!LinkedHashMap(null, null);
        assert(typeDescriptor.getMapKeyTypeDescriptor() is null);
        assert(typeDescriptor.getMapValueTypeDescriptor() is null);
    }
}

// getSource
version (FlintTypeDescriptorSources) // no TypeDescriptor from a MethodParameter, field or Property
{
    unittest
    {
        assert(TypeDescriptor.forField!(Fields, "listField").getSource() == "listField");
        assert(TypeDescriptor.forParameter!(Methods.testParameterPrimitive)(0).getSource() == "primitive");
        assert(TypeDescriptor.valueOf!int.getSource() == "int");
    }
}

// equalityWithGenerics
unittest
{
    auto td1 = TypeDescriptor.valueOf!(Optional!int);
    auto td2 = TypeDescriptor.valueOf!(Optional!string);

    assert(td1 != td2);
}

// recursiveType
unittest
{
    assert(TypeDescriptor.valueOf!RecursiveMap == TypeDescriptor.valueOf!RecursiveMap);

    version (FlintTypeDescriptorFactories) // no TypeDescriptor.collection, map or array factories
    {
        auto typeDescriptor1 = TypeDescriptor.map!Map(TypeDescriptor.valueOf!string,
                TypeDescriptor.valueOf!RecursiveMap);
        auto typeDescriptor2 = TypeDescriptor.map!Map(TypeDescriptor.valueOf!string,
                TypeDescriptor.valueOf!RecursiveMap);
        assert(typeDescriptor1 == typeDescriptor2);
    }
}

// recursiveTypeWithInterface
unittest
{
    assert(TypeDescriptor.valueOf!RecursiveMapWithInterface == TypeDescriptor.valueOf!RecursiveMapWithInterface);

    version (FlintTypeDescriptorFactories) // no TypeDescriptor.collection, map or array factories
    {
        auto typeDescriptor1 = TypeDescriptor.map!Map(TypeDescriptor.valueOf!string,
                TypeDescriptor.valueOf!RecursiveMapWithInterface);
        auto typeDescriptor2 = TypeDescriptor.map!Map(TypeDescriptor.valueOf!string,
                TypeDescriptor.valueOf!RecursiveMapWithInterface);
        assert(typeDescriptor1 == typeDescriptor2);
    }
}
