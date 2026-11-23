// Ported from spring-framework v7.1.0: spring-core/src/main/java/org/springframework/core/convert/converter
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
 * spring-core/src/main/java/org/springframework/core/convert/converter/{Converter,GenericConverter,
 * ConditionalConverter,ConditionalGenericConverter,ConverterRegistry}.java. Generic converters are erased over
 * canonical type names; typed converters register through template façades (ADR-030 section 5, R4).
 */

/++
`org.springframework.core.convert.converter`: the converter SPI.

`Converter!(S, T)` is the typed interface users implement. The registry stores everything as an erased
`GenericConverter`; `addConverter!(S, T)` wraps a typed converter or a delegate (R9). Java's `ConverterFactory`,
whose `getConverter(Class<T>)` is a generic method, has no virtual D equivalent: its role is played by
`ConditionalGenericConverter`s that match a family of target types.
+/
module flint.core.convert.converter;

import flint.core.convert : TypeDescriptor;
import flint.engine.aot.any : Any;
import flint.engine.aot.name : typeNameOf;

@safe:

/// A converter from `S` to `T`.
interface Converter(S, T)
{
    /// Convert `source` to `T`.
    T convert(S source);
}

/// A source and target type pair, by canonical name (Java's `GenericConverter.ConvertiblePair`, R13).
struct ConvertiblePair
{
    /// The source type's canonical name.
    string sourceType;
    /// The target type's canonical name.
    string targetType;

    /// `S -> T`.
    string toString() const pure
    {
        return sourceType ~ " -> " ~ targetType;
    }
}

/// A converter between one or more type pairs, working on erased values.
interface GenericConverter
{
    /// Java's nested `GenericConverter.ConvertiblePair` (R13).
    alias ConvertiblePair = .ConvertiblePair;

    /// The pairs this converter converts between; null for a conditional converter that matches families.
    ConvertiblePair[] getConvertibleTypes();

    /// Convert `source` from `sourceType` to `targetType`.
    Any convert(Any source, const TypeDescriptor sourceType, const TypeDescriptor targetType);
}

/// Allows a converter to execute conditionally on the source and target types.
interface ConditionalConverter
{
    /// Whether the conversion from `sourceType` to `targetType` should be selected.
    bool matches(const TypeDescriptor sourceType, const TypeDescriptor targetType);
}

/// A `GenericConverter` that may conditionally execute.
interface ConditionalGenericConverter : GenericConverter, ConditionalConverter
{
}

/// For registering converters with a type conversion system. Java's overloads are `final` over the virtual
/// `addConverterErased` and `removeConvertibleErased` (deviation D-22).
interface ConverterRegistry
{
    /// The erased primitive: add a generic converter.
    void addConverterErased(GenericConverter converter);

    /// The erased primitive: remove every converter from `sourceType` to `targetType` (canonical names).
    void removeConvertibleErased(string sourceType, string targetType);

    /// Add a generic converter.
    final void addConverter(GenericConverter converter)
    {
        addConverterErased(converter);
    }

    /// Add a typed converter from `S` to `T`.
    void addConverter(S, T)(Converter!(S, T) converter)
    {
        // A converter that is also a ConditionalConverter is consulted, as Spring's ConverterAdapter does.
        addConverterErased(new TypedConverter!(S, T)(&converter.convert, cast(ConditionalConverter) converter));
    }

    /// Add a delegate converting `S` to `T` (R9).
    void addConverter(S, T)(T delegate(S) @safe converter)
    {
        addConverterErased(new TypedConverter!(S, T)(converter));
    }

    /// Remove every converter from `S` to `T`.
    void removeConvertible(S, T)()
    {
        removeConvertibleErased(typeNameOf!S, typeNameOf!T);
    }
}

/// The erased adapter around a typed converter (Spring's `ConverterAdapter`).
private final class TypedConverter(S, T) : ConditionalGenericConverter
{
    private T delegate(S) @safe converter;
    private ConditionalConverter condition;

    this(T delegate(S) @safe converter, ConditionalConverter condition = null) pure nothrow @nogc
    {
        this.converter = converter;
        this.condition = condition;
    }

    bool matches(const TypeDescriptor sourceType, const TypeDescriptor targetType)
    {
        return condition is null || condition.matches(sourceType, targetType);
    }

    ConvertiblePair[] getConvertibleTypes()
    {
        return [ConvertiblePair(typeNameOf!S, typeNameOf!T)];
    }

    Any convert(Any source, const TypeDescriptor, const TypeDescriptor)
    {
        if (source.isNull)
            return Any.init;
        return Any.of(converter(source.get!S));
    }

    override string toString() const
    {
        return typeNameOf!S ~ " -> " ~ typeNameOf!T;
    }
}
