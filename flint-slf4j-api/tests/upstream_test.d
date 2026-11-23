/*
 * Ported from SLF4J (slf4j-api) 2.0.20 tests, https://github.com/qos-ch/slf4j, tag v_2.0.20:
 * slf4j-api/src/test/java/org/slf4j/helpers/MessageFormatterTest.java,
 * org/slf4j/basicTests/BasicMarkerTest.java, org/slf4j/helpers/MDCAdapterTestBase.java.
 *
 * Copyright (c) 2004-2023 QOS.ch
 * All rights reserved.
 *
 * Permission is hereby granted, free  of charge, to any person obtaining
 * a  copy  of this  software  and  associated  documentation files  (the
 * "Software"), to  deal in  the Software without  restriction, including
 * without limitation  the rights to  use, copy, modify,  merge, publish,
 * distribute,  sublicense, and/or sell  copies of  the Software,  and to
 * permit persons to whom the Software  is furnished to do so, subject to
 * the following conditions:
 *
 * The  above  copyright  notice  and  this permission  notice  shall  be
 * included in all copies or substantial portions of the Software.
 *
 * THE  SOFTWARE IS  PROVIDED  "AS  IS", WITHOUT  WARRANTY  OF ANY  KIND,
 * EXPRESS OR  IMPLIED, INCLUDING  BUT NOT LIMITED  TO THE  WARRANTIES OF
 * MERCHANTABILITY,    FITNESS    FOR    A   PARTICULAR    PURPOSE    AND
 * NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE
 * LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION
 * OF CONTRACT, TORT OR OTHERWISE,  ARISING FROM, OUT OF OR IN CONNECTION
 * WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
 *
 * Modified by the Flint authors: translated to D. testCyclicArrays is not
 * ported (a D array cannot contain itself); the MDC thread tests follow
 * Logback's non-inheriting MDC, which Spring Boot uses, rather than
 * BasicMDCAdapter's InheritableThreadLocal.
 */
module upstream_test;

import flint.engine.aot.any : Any;
import flint.slf4j : Marker, toArgument;
import flint.slf4j.helpers : BasicMarkerFactory, FormattingTuple, MessageFormatter;
import flint.slf4j.provider : FiberMDCAdapter;

@safe:

private string format(Args...)(string pattern, Args args)
{
    static if (Args.length == 1)
        return MessageFormatter.format(pattern, toArgument(args[0])).getMessage();
    else
        return MessageFormatter.format(pattern, toArgument(args[0]), toArgument(args[1])).getMessage();
}

private Any[] boxed(Args...)(Args args)
{
    Any[] result;
    foreach (a; args)
        result ~= toArgument(a);
    return result;
}

// MessageFormatterTest

@("MessageFormatterTest.testNull")
unittest
{
    assert(MessageFormatter.format(null, toArgument(1)).getMessage() is null);
}

@("MessageFormatterTest.testParamaterContainingAnAnchor")
unittest
{
    assert(format("Value is {}.", "[{}]") == "Value is [{}].");
    assert(format("Values are {} and {}.", 1, "[{}]") == "Values are 1 and [{}].");
}

@("MessageFormatterTest.nullParametersShouldBeHandledWithoutBarfing")
unittest
{
    Object none;
    string nothing;
    assert(format("Value is {}.", none) == "Value is null.");
    assert(format("Val1 is {}, val2 is {}.", none, nothing) == "Val1 is null, val2 is null.");
    assert(format("Val1 is {}, val2 is {}.", 1, none) == "Val1 is 1, val2 is null.");
    assert(format("Val1 is {}, val2 is {}.", none, 2) == "Val1 is null, val2 is 2.");
    Any[3] nulls;
    assert(MessageFormatter.arrayFormat("Val1 is {}, val2 is {}, val3 is {}", nulls[])
            .getMessage() == "Val1 is null, val2 is null, val3 is null");
    Any[] mixed = [Any.init, toArgument(2), toArgument(3)];
    assert(MessageFormatter.arrayFormat("Val1 is {}, val2 is {}, val3 is {}", mixed)
            .getMessage() == "Val1 is null, val2 is 2, val3 is 3");
}

@("MessageFormatterTest.verifyOneParameterIsHandledCorrectly")
unittest
{
    assert(format("Value is {}.", 3) == "Value is 3.");
    assert(format("Value is {", 3) == "Value is {");
    assert(format("{} is larger than 2.", 3) == "3 is larger than 2.");
    assert(format("No subst", 3) == "No subst");
    assert(format("Incorrect {subst", 3) == "Incorrect {subst");
    assert(format("Value is {bla} {}", 3) == "Value is {bla} 3");
    assert(format(`Escaped \{} subst`, 3) == "Escaped {} subst");
    assert(format("{Escaped", 3) == "{Escaped");
    assert(format(`\{}Escaped`, 3) == "{}Escaped");
    assert(format("File name is {{}}.", "App folder.zip") == "File name is {App folder.zip}.");
    assert(format(`File name is C:\\{}.`, "App folder.zip") == `File name is C:\App folder.zip.`);
}

@("MessageFormatterTest.testTwoParameters")
unittest
{
    assert(format("Value {} is smaller than {}.", 1, 2) == "Value 1 is smaller than 2.");
    assert(format("Value {} is smaller than {}", 1, 2) == "Value 1 is smaller than 2");
    assert(format("{}{}", 1, 2) == "12");
    assert(format("Val1={}, Val2={", 1, 2) == "Val1=1, Val2={");
    assert(format(`Value {} is smaller than \{}`, 1, 2) == "Value 1 is smaller than {}");
    assert(format(`Value {} is smaller than \{} tail`, 1, 2) == "Value 1 is smaller than {} tail");
    assert(format(`Value {} is smaller than \{`, 1, 2) == `Value 1 is smaller than \{`);
    assert(format("Value {} is smaller than {tail", 1, 2) == "Value 1 is smaller than {tail");
    assert(format(`Value \{} is smaller than {}`, 1, 2) == "Value {} is smaller than 1");
}

private final class Troublesome
{
    override string toString() const
    {
        import flint.java.lang : IllegalStateException;

        throw new IllegalStateException("a");
    }
}

@("MessageFormatterTest.testExceptionIn_toString")
unittest
{
    assert(format("Troublesome object {}", new Troublesome()) == "Troublesome object [FAILED toString()]");
}

@("MessageFormatterTest.testNullArray")
unittest
{
    Any[] args = null;
    foreach (msg; ["msg0", "msg1 {}", "msg2 {} {}", "msg3 {} {} {}"])
        assert(MessageFormatter.arrayFormat(msg, args).getMessage() == msg);
}

@("MessageFormatterTest.testArrayFormat")
unittest
{
    auto ia0 = boxed(1, 2, 3);
    assert(MessageFormatter.arrayFormat("Value {} is smaller than {} and {}.", ia0)
            .getMessage() == "Value 1 is smaller than 2 and 3.");
    assert(MessageFormatter.arrayFormat("{}{}{}", ia0).getMessage() == "123");
    assert(MessageFormatter.arrayFormat("Value {} is smaller than {}.", ia0)
            .getMessage() == "Value 1 is smaller than 2.");
    const smaller = MessageFormatter.arrayFormat("Value {} is smaller than {}", ia0).getMessage();
    assert(smaller == "Value 1 is smaller than 2");
    assert(MessageFormatter.arrayFormat("Val={}, {, Val={}", ia0).getMessage() == "Val=1, {, Val=2");
    assert(MessageFormatter.arrayFormat("Val1={}, Val2={", ia0).getMessage() == "Val1=1, Val2={");
}

@("MessageFormatterTest.testArrayValues")
unittest
{
    int[] p1 = [2, 3];
    assert(format("{}{}", 1, p1) == "1[2, 3]");
    assert(MessageFormatter.arrayFormat("{}{}", boxed("a", p1)).getMessage() == "a[2, 3]");
    byte[] bytes = [1, 2];
    assert(MessageFormatter.arrayFormat("{}{}", boxed("a", bytes)).getMessage() == "a[1, 2]");
    float[] floats = [1, 2];
    assert(MessageFormatter.arrayFormat("{}{}", boxed("a", floats)).getMessage() == "a[1.0, 2.0]");
    double[] doubles = [1, 2];
    assert(MessageFormatter.arrayFormat("{}{}", boxed("a", doubles)).getMessage() == "a[1.0, 2.0]");
}

@("MessageFormatterTest.testMultiDimensionalArrayValues")
unittest
{
    int[][] multiIntA = [[1, 2, 3], [10, 20, 30]];
    assert(MessageFormatter.arrayFormat("{}{}", boxed("a", multiIntA)).getMessage() == "a[[1, 2, 3], [10, 20, 30]]");
    float[][] multiFloatA = [[1, 2], [10, 20]];
    assert(MessageFormatter.arrayFormat("{}{}", boxed("a", multiFloatA)).getMessage() == "a[[1.0, 2.0], [10.0, 20.0]]");
    int[][][] threeD = [multiIntA, multiIntA];
    assert(MessageFormatter.arrayFormat("{}{}", boxed("a", threeD))
            .getMessage() == "a[[[1, 2, 3], [10, 20, 30]], [[1, 2, 3], [10, 20, 30]]]");
}

@("MessageFormatterTest.testArrayThrowable")
unittest
{
    auto t = new Exception("boom");
    auto ia = boxed(1, 2, 3) ~ toArgument(t);
    auto witness = boxed(1, 2, 3);
    void check(string pattern, string expected)
    {
        FormattingTuple ft = MessageFormatter.arrayFormat(pattern, ia);
        assert(ft.getMessage() == expected, ft.getMessage());
        assert(ft.getArgArray().length == witness.length);
        foreach (i, a; ft.getArgArray())
            assert(MessageFormatter.render(a) == MessageFormatter.render(witness[i]));
        assert(ft.getThrowable() is t);
    }

    check("Value {} is smaller than {} and {}.", "Value 1 is smaller than 2 and 3.");
    check("{}{}{}", "123");
    check("Value {} is smaller than {}.", "Value 1 is smaller than 2.");
    check("Value {} is smaller than {}", "Value 1 is smaller than 2");
    check("Val={}, {, Val={}", "Val=1, {, Val=2");
    check(`Val={}, \{, Val={}`, `Val=1, \{, Val=2`);
    check("Val1={}, Val2={", "Val1=1, Val2={");
    check("{}{}{}{}", "123{}");
    auto ft = MessageFormatter.arrayFormat("1={}", boxed(1), t);
    assert(ft.getMessage() == "1=1" && ft.getThrowable() is t);
}

@("String.valueOf rendering: doubles as Double.toString, floats as Float.toString, booleans, chars, enums")
unittest
{
    enum Color
    {
        RED,
        GREEN
    }

    static void same(string actual, string expected)
    {
        assert(actual == expected, actual ~ " != " ~ expected);
    }

    same(format("{} {} {}", 100.0, 1e7), "100.0 1.0E7 {}");
    same(format("{} {}", 0.1f, true), "0.1 true");
    same(format("{}{}", 'x', Color.GREEN), "xGREEN");
    same(format("{}", long.min), "-9223372036854775808");
    // A throwable that is not the last argument is rendered as Java's Throwable.toString().
    same(format("{} {}", new Exception("bad input"), 1), "object.Exception: bad input 1");
    // A lone trailing throwable is the event's throwable, so the anchor stays.
    same(format("{}", new Exception("bad input")), "{}");
}

// BasicMarkerTest

private struct Markers
{
    BasicMarkerFactory factory;
    Marker blue, red, green, comp, multiComp;

    static Markers make()
    {
        Markers m;
        m.factory = new BasicMarkerFactory();
        m.blue = m.factory.getMarker("BLUE");
        m.red = m.factory.getMarker("RED");
        m.green = m.factory.getMarker("GREEN");
        m.comp = m.factory.getMarker("COMP");
        m.comp.add(m.blue);
        m.multiComp = m.factory.getMarker("MULTI_COMP");
        m.multiComp.add(m.green);
        m.multiComp.add(m.comp);
        return m;
    }
}

@("BasicMarkerTest.testPrimitive and testPrimitiveByName")
unittest
{
    auto m = Markers.make();
    assert(m.blue.getName() == "BLUE" && m.blue.contains(m.blue));
    auto blue2 = m.factory.getMarker("BLUE");
    assert(blue2.getName() == "BLUE" && blue2 is m.blue);
    assert(m.blue.contains(blue2) && blue2.contains(m.blue));
    assert(m.blue.contains("BLUE"));
}

@("BasicMarkerTest.testComposite, testMultiComposite and their ByName forms")
unittest
{
    auto m = Markers.make();
    assert(m.comp.contains(m.comp) && m.comp.contains(m.blue));
    assert(m.comp.contains("COMP") && m.comp.contains("BLUE"));
    assert(m.multiComp.contains(m.comp) && m.multiComp.contains(m.blue) && m.multiComp.contains(m.green));
    assert(!m.multiComp.contains(m.red));
    assert(m.multiComp.contains("COMP") && m.multiComp.contains("BLUE") && m.multiComp.contains("GREEN"));
    assert(!m.multiComp.contains("RED"));
}

@("BasicMarkerTest.testMultiAdd: a child is added once")
unittest
{
    auto m = Markers.make();
    auto parent = m.factory.getMarker("PARENT_MARKER");
    auto child = m.factory.getMarker("CHILD_MARKER");
    foreach (_; 0 .. 10)
        parent.add(child);
    assert(parent.references().length == 1 && parent.references()[0].getName() == "CHILD_MARKER");
}

@("BasicMarkerTest.testAddRemove")
unittest
{
    auto m = Markers.make();
    auto parent = m.factory.getMarker("NEW_PARENT_MARKER");
    auto child = m.factory.getMarker("NEW_CHILD_MARKER");
    assert(!parent.contains(child) && !parent.contains("NEW_CHILD_MARKER") && !parent.remove(child));
    parent.add(child);
    assert(parent.contains(child) && parent.contains("NEW_CHILD_MARKER"));
    assert(parent.remove(child));
    assert(!parent.contains(child) && !parent.contains("NEW_CHILD_MARKER") && !parent.remove(child));
}

@("BasicMarkerTest.testSelfRecursion and testIndirectRecursion")
unittest
{
    auto m = Markers.make();
    auto parent = m.factory.getMarker("NEW_0PARENT_MARKER");
    auto notContained = m.factory.getMarker("NEW_0NOT_CONTAINED");
    parent.add(parent);
    assert(parent.contains(parent) && parent.contains("NEW_0PARENT_MARKER"));
    assert(!parent.contains(notContained) && !parent.contains("NOT_CONTAINED"));

    auto p2 = m.factory.getMarker("NEW_1PARENT_MARKER");
    auto child = m.factory.getMarker("NEW_1CHILD_MARKER");
    p2.add(child);
    child.add(p2);
    assert(p2.contains(p2) && p2.contains(child) && p2.contains("NEW_1PARENT_MARKER"));
    assert(p2.contains("NEW_1CHILD_MARKER") && !p2.contains(notContained));
}

@("BasicMarkerTest.testHomonyms: detached markers are distinct objects with the same name")
unittest
{
    auto m = Markers.make();
    auto detached = m.factory.getDetachedMarker("BLUE");
    assert(detached !is m.blue && detached.getName() == "BLUE");
    assert(m.factory.exists("BLUE") && m.factory.detachMarker("BLUE") && !m.factory.exists("BLUE"));
}

// MDCAdapterTestBase, over the fiber-local adapter

@("MDCAdapterTestBase.testSettingAndGettingWithMDC and testOverwritingAKeyInMDC")
unittest
{
    auto mdc = new FiberMDCAdapter();
    scope (exit)
        mdc.clear();
    assert(mdc.get("testKey") is null);
    mdc.put("testKey", "testValue");
    assert(mdc.get("testKey") == "testValue");
    mdc.put("testKey", "differentTestValue");
    assert(mdc.get("testKey") == "differentTestValue");
}

@("MDCAdapterTestBase.testGetCopyOfContextMapFromMDC: the copy does not follow later puts")
unittest
{
    auto mdc = new FiberMDCAdapter();
    scope (exit)
        mdc.clear();
    mdc.put("testKey", "testValue");
    auto copy = mdc.getCopyOfContextMap();
    mdc.put("anotherTestKey", "anotherTestValue");
    assert(copy.size() != mdc.getCopyOfContextMap().size());
}

@("MDCAdapterTestBase.testInvokingSetContextMap_WithANullMap_SLF4J_414")
unittest
{
    auto mdc = new FiberMDCAdapter();
    mdc.setContextMap(null);
    assert(mdc.getCopyOfContextMap() is null);
}

@("MDCAdapterTestBase: a child thread neither sees nor changes the parent's MDC (Logback semantics)")
@system unittest
{
    import core.thread.osthread : Thread; // DMD on Windows resolves Thread only from its declaring module (ADR-026)

    auto mdc = new FiberMDCAdapter();
    scope (exit)
        mdc.clear();
    mdc.put("sharedKey", "parentValue");
    string seenByChild = "unset";
    auto child = new Thread(() {
        seenByChild = mdc.get("sharedKey");
        mdc.put("sharedKey", "childValue");
        mdc.put("childKey", "childValue");
    });
    child.start();
    child.join();
    assert(seenByChild is null);
    assert(mdc.get("sharedKey") == "parentValue" && mdc.get("childKey") is null);
}

@("MDC deques: pushByKey and popByKey are a stack per key")
unittest
{
    auto mdc = new FiberMDCAdapter();
    scope (exit)
        mdc.clear();
    mdc.pushByKey("k", "a");
    mdc.pushByKey("k", "b");
    assert(mdc.popByKey("k") == "b" && mdc.popByKey("k") == "a" && mdc.popByKey("k") is null);
}
