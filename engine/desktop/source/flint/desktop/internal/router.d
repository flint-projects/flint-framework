/// Compile-time command and listener tables over an explicit application struct.
module flint.desktop.internal.router;

import flint.arena : Buffer, Error, Result, Status;
import flint.desktop.ipc : Command, DesktopCommands, InvokeContext, IpcKind, Listen, validName;
import flint.serde : DecodeOptions, decodeInto, encodeJson;
import std.traits : Parameters, ParameterStorageClass, ParameterStorageClassTuple, ReturnType,
    Unqual, functionAttributes, FunctionAttribute;

@safe:

private enum unknown = Error(Status.notFound, "desktop command or listener is not implemented");

private bool commandSet(T)() pure nothrow @nogc
{
    static if (is(T == struct) || is(T == class))
    {
        static foreach (attribute; __traits(getAttributes, T))
        {
            static if (is(attribute == DesktopCommands) || is(typeof(attribute) == DesktopCommands))
                return true;
        }
    }
    return false;
}

private enum isResult(T) = is(T == Result!Value, Value);

/// Validate one annotated method's shape with a diagnostic naming it.
private void checkShape(alias method, string label)()
{
    alias Arguments = Parameters!method;
    alias Storage = ParameterStorageClassTuple!method;
    enum attributes = functionAttributes!method;
    static assert(attributes & FunctionAttribute.nothrow_ && attributes & FunctionAttribute.nogc,
            label ~ " must be nothrow @nogc");
    static assert(Arguments.length == 1 || Arguments.length == 2,
            label ~ " takes (ref scope InvokeContext) or (scope const ref Dto, ref scope InvokeContext)");
    static assert(is(Arguments[$ - 1] == InvokeContext)
            && (Storage[$ - 1] & ParameterStorageClass.ref_), label ~ " must end with ref scope InvokeContext");
    static if (Arguments.length == 2)
        static assert(is(Arguments[0] == struct), label ~ " argument must be a serde DTO struct");
    static assert(is(ReturnType!method == Error) || isResult!(ReturnType!method),
            label ~ " must return Error or Result!T");
}

/// Reject duplicate and malformed names at compile time.
private bool uniqueNames(App)()
{
    string[] seen;
    static foreach (index, Field; typeof(App.tupleof))
    {
        static if (commandSet!Field())
        {
            static foreach (member; __traits(allMembers, Field))
            {
                static foreach (overload; __traits(getOverloads, Field, member))
                {
                    static foreach (attribute; __traits(getAttributes, overload))
                    {
                        static if (is(typeof(attribute) == Command) || is(typeof(attribute) == Listen))
                        {
                            {
                                enum key = (is(typeof(attribute) == Command) ? "command " : "event ") ~ attribute.name;
                                assert(validName(attribute.name), "invalid desktop name: " ~ key);
                                foreach (previous; seen)
                                    assert(previous != key, "duplicate desktop " ~ key);
                                seen ~= key;
                            }
                        }
                    }
                }
            }
        }
    }
    return true;
}

private Error call(alias method, Target)(ref Target target, scope const(ubyte)[] body,
        ref scope InvokeContext context, ref Buffer result) nothrow @nogc
{
    alias Arguments = Parameters!method;
    static if (Arguments.length == 2)
    {
        Unqual!(Arguments[0]) request;
        const decoded = decodeInto(body.length ? body : cast(const(ubyte)[]) "null", request,
                context.arena, DecodeOptions.init);
        if (decoded.code != Status.ok)
            return decoded;
        const outcome = __traits(child, target, method)(request, context);
    }
    else
        const outcome = __traits(child, target, method)(context);

    static if (is(Unqual!(typeof(outcome)) == Error))
        return outcome;
    else
    {
        if (!outcome.ok())
            return outcome.error;
        auto encoded = encodeJson(outcome.value, context.arena);
        if (!encoded.ok())
            return encoded.error;
        result = encoded.value;
        return Error.init;
    }
}

/// Dispatch one permitted frame to the method annotated with its name.
package(flint.desktop) Error route(App)(ref App app, IpcKind kind, scope const(char)[] name,
        scope const(ubyte)[] body, ref scope InvokeContext context, ref Buffer result) nothrow @nogc
{
    static assert(is(App == struct), "desktop application root must be a struct of @DesktopCommands fields");
    static assert(uniqueNames!App());
    static foreach (index, Field; typeof(App.tupleof))
    {
        static if (commandSet!Field())
        {
            static foreach (member; __traits(allMembers, Field))
            {
                static foreach (overload; __traits(getOverloads, Field, member))
                {
                    static foreach (attribute; __traits(getAttributes, overload))
                    {
                        static if (is(typeof(attribute) == Command) || is(typeof(attribute) == Listen))
                        {
                            checkShape!(overload, Field.stringof ~ "." ~ member)();
                            if (kind == (is(typeof(attribute) == Command) ? IpcKind.invoke
                                    : IpcKind.emit) && name == attribute.name)
                                return call!overload(app.tupleof[index], body, context, result);
                        }
                    }
                }
            }
        }
    }
    return unknown;
}
