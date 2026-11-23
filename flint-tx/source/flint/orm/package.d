// Ported from spring-framework v7.1.0: spring-orm/src/main/java/org/springframework/orm/ObjectRetrievalFailureException.java
// Copyright 2002-present the original author or authors.
// Licensed under the Apache License, Version 2.0.
// Modified by the Flint authors.

/++
`org.springframework.orm`: the object-mapping exceptions that JDBC repositories throw too, such as
`ObjectRetrievalFailureException` for "not found" (ADR-030). The rest of spring-orm (JPA) is Phase 2.

The module lives in `flint:tx` beside `flint.dao`, whose hierarchy it extends. Java's `Class<?>` is a
`TypeInfo_Class` (R4) and the `Object` identifier an `Any` (R7).
+/
module flint.orm;

import flint.dao : DataRetrievalFailureException;
import flint.engine.aot.any : Any;

@safe:

/++
Exception thrown if a mapped object could not be retrieved via its identifier. Provides information about the
persistent class and the identifier.
+/
class ObjectRetrievalFailureException : DataRetrievalFailureException
{
    private const(TypeInfo_Class) persistentClass;
    private string persistentClassName;
    private Any identifier;

    /// Create a general `ObjectRetrievalFailureException` with the given message, without any information on the
    /// affected object.
    this(string msg, Throwable cause, string file = __FILE__, size_t line = __LINE__)
    {
        super(msg, cause, file, line);
        persistentClass = null;
    }

    /// Create a new `ObjectRetrievalFailureException` for the given object, with the default "not found" message.
    this(const TypeInfo_Class persistentClass, Any identifier, string file = __FILE__, size_t line = __LINE__)
    {
        this(persistentClass, identifier, notFound(persistentClass.name, identifier), null, file, line);
    }

    /// Create a new `ObjectRetrievalFailureException` for the given object, with the given explicit message and
    /// exception.
    this(const TypeInfo_Class persistentClass, Any identifier, string msg, Throwable cause,
            string file = __FILE__, size_t line = __LINE__)
    {
        super(msg, cause, file, line);
        this.persistentClass = persistentClass;
        persistentClassName = persistentClass is null ? null : persistentClass.name;
        this.identifier = identifier;
    }

    /// Create a new `ObjectRetrievalFailureException` for the given object, with the default "not found" message.
    this(string persistentClassName, Any identifier, string file = __FILE__, size_t line = __LINE__)
    {
        this(persistentClassName, identifier, notFound(persistentClassName, identifier), null, file, line);
    }

    /// Create a new `ObjectRetrievalFailureException` for the given object, with the given explicit message and
    /// exception.
    this(string persistentClassName, Any identifier, string msg, Throwable cause, string file = __FILE__,
            size_t line = __LINE__)
    {
        super(msg, cause, file, line);
        persistentClass = null;
        this.persistentClassName = persistentClassName;
        this.identifier = identifier;
    }

    /// Return the persistent class of the object that was not found. If no class was specified, this method
    /// returns null.
    const(TypeInfo_Class) getPersistentClass()
    {
        return persistentClass;
    }

    /// Return the name of the persistent class of the object that was not found. Will work for both `Class`
    /// objects and `String` names.
    string getPersistentClassName()
    {
        return persistentClassName;
    }

    /// Return the identifier of the object that was not found.
    Any getIdentifier()
    {
        return identifier;
    }

    private static string notFound(string className, Any identifier)
    {
        return "Object of class [" ~ className ~ "] with identifier [" ~ (identifier.isNull
                ? "null" : identifier.toString()) ~ "]: not found";
    }
}
