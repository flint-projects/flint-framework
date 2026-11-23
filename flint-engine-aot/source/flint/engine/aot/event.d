/++
`@EventListener` methods as Flint AOT emits them (AOT contract section 4.6).
+/
module flint.engine.aot.event;

import flint.engine.aot.any : Any;
import flint.engine.aot.expression : CompiledExpression;

@safe:

/// One `@EventListener` method.
struct EventListenerSpec
{
    /// The bean declaring the method.
    string bean;
    /// The parameter's type: an `ApplicationEvent` subclass or a payload type.
    string eventType;
    /// The SpEL condition; empty when absent.
    string condition;
    /// `@Order` of the listener; `int.max` when absent.
    int order = int.max;
    /// Call the method with the event (or the payload of a `PayloadApplicationEvent`).
    void function(Object bean, ref Any event) @safe invoke;
    /// `condition` compiled by Flint AOT (contract 3); null when there is no condition or for older generated code.
    CompiledExpression conditionExpression;
    /// For a method returning a value (contract 3): call it and return its result, boxed, which the runtime
    /// publishes as replies (a non-null value, or each element of an array or `Collection`). When set, it is called
    /// instead of `invoke`.
    Any function(Object bean, ref Any event) @safe invokeForResult;
}
