/*
 * Ported from Jakarta Annotations (jakarta.annotation-api) 3.0.0,
 * https://github.com/jakartaee/common-annotations-api, tag 3.0.0:
 *   api/src/main/java/jakarta/annotation/{PostConstruct,PreDestroy,Resource,Resources,
 *   Nullable,Nonnull,Priority,Generated}.java
 *
 * Copyright (c) 2005, 2023 Oracle and/or its affiliates. All rights reserved.
 *
 * This program and the accompanying materials are made available under the
 * terms of the Eclipse Public License v. 2.0, which is available at
 * http://www.eclipse.org/legal/epl-2.0.
 *
 * This Source Code may also be made available under the following Secondary
 * Licenses when the conditions for such availability set forth in the
 * Eclipse Public License v. 2.0 are satisfied: GNU General Public License,
 * version 2 with the GNU Classpath Exception, which is available at
 * https://www.gnu.org/software/classpath/license.html.
 *
 * SPDX-License-Identifier: EPL-2.0 OR GPL-2.0 WITH Classpath-exception-2.0
 *
 * Modified by the Flint authors: each annotation is a D UDA struct with the
 * same attributes and defaults (rulebook R2), and the Javadoc is DDoc. Flint
 * distributes this file under the EPL-2.0 option, in a module of its own.
 */

/// Jakarta Annotations: the common lifecycle, injection and nullness annotations.
module flint.jakarta.annotation;

@safe:

/**
 * The `PostConstruct` annotation is used on a method that needs to be executed
 * after dependency injection is done to perform any initialization. This method
 * must be invoked before the class is put into service. This annotation must be
 * supported on all classes that support dependency injection. The method
 * annotated with `PostConstruct` must be invoked even if the class does not
 * request any resources to be injected. Only one method in a given class can be
 * annotated with this annotation.
 *
 * The method on which `PostConstruct` is applied must take no parameters
 * (except an `InvocationContext` on interceptors), may have any visibility,
 * must not be static and should not be final. If the method throws an
 * unchecked exception the class must not be put into service, except where an
 * interceptor handles the exception.
 *
 * Target: method. Retention: runtime.
 *
 * See_Also: `PreDestroy`, `Resource`
 */
struct PostConstruct
{
}

/**
 * The `PreDestroy` annotation is used on a method as a callback notification to
 * signal that the instance is in the process of being removed by the container.
 * The method annotated with `PreDestroy` is typically used to release resources
 * that it has been holding. This annotation must be supported by all
 * container-managed objects that support the use of the `PostConstruct`
 * annotation, except the Jakarta EE application client.
 *
 * The method must take no parameters (except an `InvocationContext` on
 * interceptors), may have any visibility, must not be static and should not be
 * final. If the method throws an unchecked exception it is ignored by the
 * container.
 *
 * Target: method. Retention: runtime.
 *
 * See_Also: `PostConstruct`, `Resource`
 */
struct PreDestroy
{
}

/**
 * The `Resource` annotation marks a resource that is needed by the application.
 * This annotation may be applied to an application component class, or to
 * fields or methods of the component class. When the annotation is applied to a
 * field or method, the container will inject an instance of the requested
 * resource into the application component when the component is initialized.
 * If the annotation is applied to the component class, the annotation declares
 * a resource that the application will look up at runtime.
 *
 * Even though this annotation is not marked `Inherited`, deployment tools are
 * required to examine all superclasses of any component class to discover all
 * uses of this annotation in all superclasses.
 *
 * Java's `Class<?> type()` element is not a field: a D type is not a runtime
 * value (rulebook R4, deviation D-4). The resource type is the declared type of
 * the annotated field or the property type of the annotated method, which is
 * Java's default when `type` is left as `Object.class`.
 *
 * Target: type, field, method. Retention: runtime. Repeatable: several
 * `Resource` UDAs may be attached to one declaration, as `Resources` collects
 * them in Java.
 */
struct Resource
{
    /// The two possible authentication types for a resource.
    enum AuthenticationType
    {
        ///
        CONTAINER,
        ///
        APPLICATION
    }

    /**
     * The JNDI name of the resource. For field annotations, the default is the
     * field name. For method annotations, the default is the JavaBeans property
     * name corresponding to the method. For class annotations, there is no
     * default and this must be specified.
     */
    string name = "";

    /**
     * The name of the resource that the reference points to. It can link to any
     * compatible resource using the global JNDI names.
     */
    string lookup = "";

    /**
     * The authentication type to use for this resource. This may be specified
     * for resources representing a connection factory of any supported type,
     * and must not be specified for resources of other types.
     */
    AuthenticationType authenticationType = AuthenticationType.CONTAINER;

    /**
     * Indicates whether this resource can be shared between this component and
     * other components. This may be specified for resources representing a
     * connection factory of any supported type, and must not be specified for
     * resources of other types.
     */
    bool shareable = true;

    /**
     * A product-specific name that this resource should be mapped to. No use of
     * a mapped name is portable.
     */
    string mappedName = "";

    /**
     * Description of this resource, in the default language of the system on
     * which the application is deployed.
     */
    string description = "";
}

/// This annotation is used to allow multiple resources declarations.
struct Resources
{
    /// Array used for multiple resource declarations.
    Resource[] value;
}

/**
 * The annotated element could be null under some circumstances.
 *
 * In general, this means developers will have to read the documentation to
 * determine when a null value is acceptable and whether it is necessary to
 * check for a null value. This annotation is useful mostly for overriding a
 * `Nonnull` annotation. When this annotation is applied to a method it applies
 * to the method return value.
 *
 * See_Also: `Nonnull`
 */
struct Nullable
{
}

/**
 * The annotated element must not be null.
 *
 * Annotated fields must not be null after construction has completed. When this
 * annotation is applied to a method it applies to the method return value.
 *
 * See_Also: `Nullable`
 */
struct Nonnull
{
}

/**
 * The `Priority` annotation can be applied to any program elements to indicate
 * in what order they should be used. The effect of using the `Priority`
 * annotation in any particular instance is defined by other specifications
 * that define the use of a specific class.
 *
 * Priority values should generally be non-negative, with negative values
 * reserved for special meanings such as "undefined" or "not specified".
 */
struct Priority
{
    /// The priority value.
    int value;
}

/**
 * The `Generated` annotation is used to mark source code that has been
 * generated. It can also be used to differentiate user written code from
 * generated code in a single file.
 *
 * Retention: source. Flint keeps it as a UDA, which costs nothing at runtime.
 */
struct Generated
{
    /// The name of the code generator, conventionally its fully qualified name.
    string[] value;
    /// Date when the source was generated, in ISO 8601.
    string date = "";
    /// A place holder for any comments that the code generator may want to include in the generated code.
    string comments = "";
}
