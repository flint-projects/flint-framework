// Ported from spring-framework v7.1.0: spring-core/src/main/java/org/springframework/core/convert
// Copyright 2002-present the original author or authors.
// Licensed under the Apache License, Version 2.0.
// Modified by the Flint authors.
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
 * spring-core/src/main/java/org/springframework/core/convert/{ConversionService,TypeDescriptor,ConversionException,
 * ConversionFailedException,ConverterNotFoundException}.java. The service is erased (ADR-030 section 5): types are
 * canonical D names and values are flint.engine.aot.any.Any; Class-typed parameters are template façades (R4).
 */

/++
`org.springframework.core.convert`: the type conversion system API.

`ConversionService` is erased: it converts an `Any` between types named by `TypeDescriptor`s, so generated code that
knows a target type only by name (`@Value` injection, AOT contract section 5.2) and engines share one non-template
implementation. `convert!T(source)` and `canConvert!(S, T)` are the one-line typed façades.
+/
module flint.core.convert;

import flint.core : NestedRuntimeException;
import flint.engine.aot.any : Any;
import flint.engine.aot.descriptor : Descriptor, MergedAnnotation, TypeKind, descriptorOf, findAnnotation;
import flint.engine.aot.name : typeNameOf;
import flint.java.lang : valueOf;

@safe:

/++
Contextual information about a type to convert from or to: its canonical name, its element and map-key types, its
annotations, and its Flint AOT descriptor when one is known.
+/
final class TypeDescriptor
{
    private string name_;
    private string elementType_;
    private string keyType_;
    private const(MergedAnnotation)[] annotations_;
    private const(Descriptor) descriptor_;
    private string[] supertypes_;
    // valueOf's element and key descriptors, built on demand so nested types keep their own element types (a
    // pointer rather than a value, so a type whose element type is itself does not recurse at compile time).
    private TypeDescriptor function() @safe elementOf_;
    private TypeDescriptor function() @safe keyOf_;

    /// A descriptor for the type named `typeName`, with its AOT `descriptor` when known.
    this(string typeName, const Descriptor descriptor = null, const(MergedAnnotation)[] annotations = null)
    {
        name_ = typeName;
        descriptor_ = descriptor;
        annotations_ = annotations;
        if (descriptor !is null)
        {
            elementType_ = descriptor.elementType;
            keyType_ = descriptor.keyType;
        }
        else
            elementType_ = arrayElement(typeName);
    }

    /// The descriptor of `T` (Java's `TypeDescriptor.valueOf(Class)`, R4). Only enums carry a full AOT
    /// descriptor; other types record their element, key and super types.
    static TypeDescriptor valueOf(T)()
    {
        import std.traits : BaseClassesTuple, InterfacesTuple, Unqual;

        alias U = Unqual!T;
        static if (is(U == enum))
            return new TypeDescriptor(typeNameOf!U, descriptorOf!U);
        else
        {
            auto result = new TypeDescriptor(typeNameOf!U);
            static if (__traits(compiles, U.__flintElementType.init))
            {
                result.elementType_ = typeNameOf!(U.__flintElementType);
                result.elementOf_ = &valueOf!(U.__flintElementType);
            }
            static if (__traits(compiles, U.__flintKeyType.init))
            {
                result.keyType_ = typeNameOf!(U.__flintKeyType);
                result.keyOf_ = &valueOf!(U.__flintKeyType);
            }
            static if (is(U == V[K], V, K))
            {
                result.elementType_ = typeNameOf!V;
                result.keyType_ = typeNameOf!K;
                result.elementOf_ = &valueOf!V;
                result.keyOf_ = &valueOf!K;
            }
            else static if (is(U == E[], E) && !is(U : const(char)[]))
                result.elementOf_ = &valueOf!E;
            static if (is(U == class))
            {
                static foreach (S; BaseClassesTuple!U)
                    static if (!is(S == Object))
                        result.supertypes_ ~= typeNameOf!S;
            }
            static if (is(U == class) || is(U == interface))
            {
                static foreach (S; InterfacesTuple!U)
                    result.supertypes_ ~= typeNameOf!S;
            }
            return result;
        }
    }

    /// The descriptor of the value `source` holds; null for an empty `Any`.
    static TypeDescriptor forObject(Any source)
    {
        return source.typeName.length == 0 ? null : new TypeDescriptor(source.typeName);
    }

    /// The canonical D name of the type.
    string getName() const pure nothrow @nogc
    {
        return name_;
    }

    /// The canonical D name of the type (Java's `getType()`, a `Class`, R4).
    string getType() const pure nothrow @nogc
    {
        return name_;
    }

    /// The Flint AOT descriptor, when known.
    const(Descriptor) getDescriptor() const pure nothrow @nogc
    {
        return descriptor_;
    }

    /// The element type of an array or collection, or null.
    TypeDescriptor getElementTypeDescriptor() const
    {
        if (elementOf_ !is null)
            return elementOf_();
        return elementType_.length ? new TypeDescriptor(elementType_) : null;
    }

    /// The key type of a map, or null.
    TypeDescriptor getMapKeyTypeDescriptor() const
    {
        if (keyOf_ !is null)
            return keyOf_();
        return keyType_.length ? new TypeDescriptor(keyType_) : null;
    }

    /// The value type of a map, or null.
    TypeDescriptor getMapValueTypeDescriptor() const
    {
        if (keyType_.length == 0)
            return null;
        return getElementTypeDescriptor();
    }

    /// Whether this is a D array other than `string`.
    bool isArray() const pure nothrow @nogc
    {
        return arrayElement(name_).length != 0 && keyType_.length == 0;
    }

    /// Whether this is a `flint.java.util` collection.
    bool isCollection() const pure nothrow @nogc
    {
        return !isArray() && keyType_.length == 0 && elementType_.length != 0 && !isOptional();
    }

    /// Whether this is a map.
    bool isMap() const pure nothrow @nogc
    {
        return keyType_.length != 0;
    }

    /// Whether this is `flint.java.util.Optional!T`.
    bool isOptional() const pure nothrow @nogc
    {
        enum prefix = "flint.java.util.Optional!"; // DMD prints `Optional!string` and `Optional!(Foo[])`
        return name_.length > prefix.length && name_[0 .. prefix.length] == prefix;
    }

    /// Whether this is a scalar: a boolean, character or number (Java's primitives and their wrappers).
    bool isPrimitive() const pure nothrow @nogc
    {
        return scalarName(name_);
    }

    /// Whether this is an enum, judged from the descriptor.
    bool isEnum() const pure nothrow @nogc
    {
        return descriptor_ !is null && descriptor_.kind == TypeKind.enum_;
    }

    /// Whether a value of this type can be used where `typeDescriptor` is expected.
    bool isAssignableTo(const TypeDescriptor typeDescriptor) const nothrow @nogc
    {
        if (typeDescriptor is null)
            return false;
        if (name_ == typeDescriptor.name_)
            return true;
        foreach (s; supertypes_)
            if (s == typeDescriptor.name_)
                return true;
        return descriptor_ !is null && descriptor_.isAssignableTo(typeDescriptor.name_);
    }

    /// The canonical names of the base classes and interfaces `valueOf` recorded (for converter lookup).
    package(flint.core) const(string)[] supertypeNames() const pure nothrow @nogc
    {
        return supertypes_;
    }

    /// The annotations on the source element (a field, parameter or method).
    const(MergedAnnotation)[] getAnnotations() const pure nothrow @nogc
    {
        return annotations_;
    }

    /// Whether the annotation `annotationType` (a canonical name) is present.
    bool hasAnnotation(string annotationType) const nothrow @nogc
    {
        return findAnnotation(annotations_, annotationType) !is null;
    }

    /// The annotation `A`, or `A.init` with `found` false.
    const(A) getAnnotation(A)(out bool found) const
    {
        auto annotation = findAnnotation(annotations_, typeNameOf!A);
        found = annotation !is null;
        if (!found)
            return A.init;
        return annotation.value.get!(const A);
    }

    /// Equal names.
    override bool opEquals(Object other) const
    {
        auto that = cast(const TypeDescriptor) other;
        return that !is null && that.name_ == name_;
    }

    /// Hash of the name.
    override size_t toHash() const nothrow
    {
        return hashOf(name_);
    }

    /// The type name.
    override string toString() const
    {
        return name_;
    }
}

private string arrayElement(string name) pure nothrow @nogc
{
    if (name.length > 2 && name[$ - 2 .. $] == "[]" && name != "string")
        return name[0 .. $ - 2];
    return null;
}

/// Whether `name` is a D scalar type name: `bool`, the characters, the integers and the floating-point types.
bool scalarName(string name) pure nothrow @nogc
{
    switch (name)
    {
    case "bool", "char", "wchar", "dchar", "byte", "ubyte", "short", "ushort", "int", "uint",
            "long", "ulong", "float", "double", "real":
            return true;
    default:
        return false;
    }
}

/++
A service interface for type conversion: the entry point into the conversion system.

Java's `canConvert` and `convert` overloads are `final` here, over the virtual `canConvertErased` and
`convertErased`, so the `Class`-typed overloads can be template façades (R4) callable on any implementation
(deviation D-22).
+/
interface ConversionService
{
    /// The erased primitive: whether values of `sourceType` convert to `targetType` (a null `sourceType` means a
    /// null source).
    bool canConvertErased(const TypeDescriptor sourceType, const TypeDescriptor targetType);

    /// The erased primitive: `source` (described by `sourceType`) converted to `targetType`.
    Any convertErased(Any source, const TypeDescriptor sourceType, const TypeDescriptor targetType);

    /// Whether values of `sourceType` can be converted to `targetType`.
    final bool canConvert(const TypeDescriptor sourceType, const TypeDescriptor targetType)
    {
        return canConvertErased(sourceType, targetType);
    }

    /// Convert `source` (described by `sourceType`) to `targetType`. Throws `ConversionException`.
    final Any convert(Any source, const TypeDescriptor sourceType, const TypeDescriptor targetType)
    {
        return convertErased(source, sourceType, targetType);
    }

    /// Convert `source` to the type named `targetType` (a canonical D name), as generated code and the web layer
    /// do for values whose target is known only by name.
    final Any convert(Any source, string targetType)
    {
        return convertErased(source, TypeDescriptor.forObject(source), new TypeDescriptor(targetType));
    }

    /// Whether `S` can be converted to `T`.
    bool canConvert(S, T)()
    {
        return canConvertErased(TypeDescriptor.valueOf!S, TypeDescriptor.valueOf!T);
    }

    /// Convert `source` to `T`. A null source converts to `T.init` (null for references).
    T convert(T, S)(S source)
    {
        static if (is(S == Any))
            auto result = convertErased(source, TypeDescriptor.forObject(source), TypeDescriptor.valueOf!T);
        else
            auto result = convertErased(Any.of(source), TypeDescriptor.valueOf!S, TypeDescriptor.valueOf!T);
        return result.isNull ? T.init : result.get!T;
    }
}

/// Base class for exceptions thrown by the conversion system.
abstract class ConversionException : NestedRuntimeException
{
    /// `message`, and optionally a `cause`.
    this(string message, Throwable cause = null, string file = __FILE__, size_t line = __LINE__) pure nothrow
    {
        super(message, cause, file, line);
    }
}

/// Thrown when an actual type conversion attempt fails.
class ConversionFailedException : ConversionException
{
    private const(TypeDescriptor) sourceType_, targetType_;
    private Any value_;

    /// The failed conversion of `value` from `sourceType` to `targetType`, caused by `cause`.
    this(const TypeDescriptor sourceType, const TypeDescriptor targetType, Any value, Throwable cause)
    {
        super("Failed to convert from type [" ~ typeName(sourceType) ~ "] to type [" ~ typeName(
                targetType) ~ "] for value [" ~ displayValue(value) ~ "]", cause);
        sourceType_ = sourceType;
        targetType_ = targetType;
        value_ = value;
    }

    /// The source type.
    const(TypeDescriptor) getSourceType() const pure nothrow @nogc
    {
        return sourceType_;
    }

    /// The target type.
    const(TypeDescriptor) getTargetType() const pure nothrow @nogc
    {
        return targetType_;
    }

    /// The value that failed to convert.
    Any getValue() pure nothrow @nogc
    {
        return value_;
    }
}

/// Thrown when no suitable converter could be found in a conversion service.
class ConverterNotFoundException : ConversionException
{
    private const(TypeDescriptor) sourceType_, targetType_;

    /// No converter from `sourceType` to `targetType`.
    this(const TypeDescriptor sourceType, const TypeDescriptor targetType)
    {
        super("No converter found capable of converting from type [" ~ typeName(
                sourceType) ~ "] to type [" ~ typeName(targetType) ~ "]");
        sourceType_ = sourceType;
        targetType_ = targetType;
    }

    /// The source type requested.
    const(TypeDescriptor) getSourceType() const pure nothrow @nogc
    {
        return sourceType_;
    }

    /// The target type requested.
    const(TypeDescriptor) getTargetType() const pure nothrow @nogc
    {
        return targetType_;
    }
}

/// A type in a message: its name, or `null` (Java's string concatenation of a null `TypeDescriptor`).
private string typeName(const TypeDescriptor type) pure nothrow @nogc
{
    return type is null ? "null" : type.getName();
}

/// `ObjectUtils.nullSafeConciseToString`-style rendering of a value in a message.
private string displayValue(Any value)
{
    if (value.isNull)
        return "null";
    if (auto o = value.asObject())
        return valueOf(o);
    return value.toString();
}
