/*
 * Ported from Jackson (jackson-databind) 3.1.8, https://github.com/FasterXML/jackson-databind,
 * tag jackson-databind-3.1.8: src/main/java/tools/jackson/databind/JsonNode.java and
 * node/{JsonNodeType,JsonNodeFactory,BaseJsonNode,ContainerNode,ObjectNode,ArrayNode,
 * ValueNode,StringNode,NumericNode,IntNode,LongNode,ShortNode,DoubleNode,FloatNode,
 * BigIntegerNode,DecimalNode,BooleanNode,NullNode,MissingNode}.java
 *
 * Jackson JSON-processor.
 * Copyright (c) 2007- Tatu Saloranta, tatu.saloranta@iki.fi
 * Licensed under the Apache License, Version 2.0.
 *
 * Modified by the Flint authors: translated to D (rulebook v2). Collection-valued
 * accessors return D arrays (deviation D-JACKSON-2); BigIntegerNode and DecimalNode
 * keep their exact decimal text until flint.java.math lands.
 */

/// Jackson's tree model: `JsonNode` and its object, array and value nodes.
module flint.jackson.databind.node;

import flint.jackson.core : JsonGenerator, JsonParser, JsonToken, ObjectWriteContext, PrettyPrinter;
import flint.jackson.core.json : JsonFactory;
import flint.jackson.core.util : ByteArrayBuilder, DefaultPrettyPrinter;
import flint.jackson.databind.exc : DatabindException;
import flint.serde.java_number : javaDoubleString, javaFloatString;

@safe:

/// Enumeration of JSON types. Covers all JSON types defined by RFC 8259 (Arrays, Objects, Strings, Numbers, Booleans, null) plus Jackson-specific types.
enum JsonNodeType
{
    ///
    ARRAY,
    ///
    BINARY,
    ///
    BOOLEAN,
    ///
    MISSING,
    ///
    NULL,
    ///
    NUMBER,
    ///
    OBJECT,
    ///
    POJO,
    ///
    STRING,
}

/// Exception thrown when an accessor of a node is called on a node of another type.
class JsonNodeException : DatabindException
{
    ///
    this(string msg, string file = __FILE__, size_t line = __LINE__) pure nothrow
    {
        super(msg, null, null, file, line);
    }
}

/**
 * Base class for all JSON nodes, which form the basis of JSON Tree Model that
 * Jackson implements. One way to think of these nodes is to consider them
 * similar to DOM nodes in XML DOM trees.
 */
abstract class JsonNode
{
    /// One property of an Object node: Java's `Map.Entry<String, JsonNode>`.
    static struct Entry
    {
        /// The property name.
        string key;
        /// The property value.
        JsonNode value;

        /// The property name.
        string getKey() const pure nothrow @nogc
        {
            return key;
        }

        /// The property value.
        inout(JsonNode) getValue() inout pure nothrow @nogc
        {
            return value;
        }
    }

    /// Return the basic type of this node.
    abstract JsonNodeType getNodeType() const pure nothrow @nogc;

    /// Serialize this node through `g`.
    abstract void serialize(JsonGenerator g);

    /// Deep equality, as `equals`.
    abstract bool equals(const JsonNode other) const;

    /// A deep copy; value nodes return themselves.
    abstract JsonNode deepCopy();

    ///
    override bool opEquals(Object other) const
    {
        auto node = cast(const JsonNode) other;
        return node !is null && equals(node);
    }

    ///
    override size_t toHash() const nothrow
    {
        return getNodeType();
    }

    /// Whether this is an Array or Object node.
    bool isContainer() const pure nothrow @nogc
    {
        return getNodeType() == JsonNodeType.ARRAY || getNodeType() == JsonNodeType.OBJECT;
    }

    /// Whether this is a value node (neither container nor missing).
    final bool isValueNode() const pure nothrow @nogc
    {
        return !isContainer() && getNodeType() != JsonNodeType.MISSING;
    }

    /// Whether this is the missing node (`path` of an absent property).
    bool isMissingNode() const pure nothrow @nogc
    {
        return getNodeType() == JsonNodeType.MISSING;
    }

    /// Whether this is an Array node.
    bool isArray() const pure nothrow @nogc
    {
        return getNodeType() == JsonNodeType.ARRAY;
    }

    /// Whether this is an Object node.
    bool isObject() const pure nothrow @nogc
    {
        return getNodeType() == JsonNodeType.OBJECT;
    }

    /// Whether this is a String node.
    final bool isString() const pure nothrow @nogc
    {
        return getNodeType() == JsonNodeType.STRING;
    }

    /// Jackson 2's name for `isString()`.
    bool isTextual() const pure nothrow @nogc
    {
        return isString();
    }

    /// Whether this is a Boolean node.
    final bool isBoolean() const pure nothrow @nogc
    {
        return getNodeType() == JsonNodeType.BOOLEAN;
    }

    /// Whether this is the null node.
    final bool isNull() const pure nothrow @nogc
    {
        return getNodeType() == JsonNodeType.NULL;
    }

    /// Whether this is a numeric node.
    final bool isNumber() const pure nothrow @nogc
    {
        return getNodeType() == JsonNodeType.NUMBER;
    }

    /// Whether this is a binary node.
    final bool isBinary() const pure nothrow @nogc
    {
        return getNodeType() == JsonNodeType.BINARY;
    }

    /// Whether this is a POJO node.
    final bool isPojo() const pure nothrow @nogc
    {
        return getNodeType() == JsonNodeType.POJO;
    }

    /// Whether this is an integral number node.
    bool isIntegralNumber() const pure nothrow @nogc
    {
        return false;
    }

    /// Whether this is a floating-point number node.
    bool isFloatingPointNumber() const pure nothrow @nogc
    {
        return false;
    }

    /// Whether this is an `int` node.
    bool isInt() const pure nothrow @nogc
    {
        return false;
    }

    /// Whether this is a `long` node.
    bool isLong() const pure nothrow @nogc
    {
        return false;
    }

    /// Whether this is a `short` node.
    bool isShort() const pure nothrow @nogc
    {
        return false;
    }

    /// Whether this is a `double` node.
    bool isDouble() const pure nothrow @nogc
    {
        return false;
    }

    /// Whether this is a `float` node.
    bool isFloat() const pure nothrow @nogc
    {
        return false;
    }

    /// Whether this is a BigInteger node.
    bool isBigInteger() const pure nothrow @nogc
    {
        return false;
    }

    /// Whether this is a BigDecimal node.
    bool isBigDecimal() const pure nothrow @nogc
    {
        return false;
    }

    /// Number of child nodes: entries of an Object, elements of an Array, else 0.
    int size() const pure nothrow @nogc
    {
        return 0;
    }

    /// Whether `size()` is 0.
    bool isEmpty() const pure nothrow @nogc
    {
        return size() == 0;
    }

    /// The element at `index` of an Array node, else null.
    JsonNode get(int)
    {
        return null;
    }

    /// The value of property `propertyName` of an Object node, else null.
    JsonNode get(string)
    {
        return null;
    }

    /// Like `get(index)`, but the missing node instead of null.
    JsonNode path(int)
    {
        return MissingNode.getInstance();
    }

    /// Like `get(propertyName)`, but the missing node instead of null.
    JsonNode path(string)
    {
        return MissingNode.getInstance();
    }

    /// Like `get(propertyName)`, but throws when the property is absent.
    JsonNode required(string propertyName)
    {
        auto node = get(propertyName);
        if (node is null)
            throw new JsonNodeException("No value for property '" ~ propertyName ~ "' of `" ~ className() ~ "`");
        return node;
    }

    /// Like `get(index)`, but throws when there is no such element.
    JsonNode required(int index)
    {
        import std.conv : to;

        auto node = get(index);
        if (node is null)
            throw new JsonNodeException("No value at index #" ~ index.to!string ~ " of `" ~ className() ~ "`");
        return node;
    }

    /// Whether an Object node has property `propertyName` (even if its value is null).
    bool has(string propertyName)
    {
        return get(propertyName) !is null;
    }

    /// Whether an Array node has an element at `index`.
    bool has(int index)
    {
        return get(index) !is null;
    }

    /// The properties of an Object node in insertion order; empty for other nodes.
    Entry[] properties()
    {
        return null;
    }

    /// The property names of an Object node in insertion order; empty for other nodes.
    string[] propertyNames()
    {
        return null;
    }

    /// The child values: an Array's elements, an Object's property values; empty for other nodes.
    JsonNode[] values()
    {
        return null;
    }

    /// The first value of property `propertyName` found in this tree, depth first; null when none.
    JsonNode findValue(string)
    {
        return null;
    }

    /// The String value of a String node; throws for other nodes.
    string stringValue()
    {
        throw wrongType("stringValue()", "String");
    }

    /// The String value of a String node, else `defaultValue`.
    string stringValue(string defaultValue)
    {
        return defaultValue;
    }

    /// Jackson 2's name for `stringValue()`, returning null for non-String nodes.
    final string textValue()
    {
        return isString() ? stringValue() : null;
    }

    /// The node's value as a String: the text of strings, numbers and booleans, "null" for null, "" for containers.
    string asString()
    {
        return "";
    }

    /// Like `asString()`, but `defaultValue` for nodes with no scalar value.
    string asString(string defaultValue)
    {
        return defaultValue;
    }

    /// Jackson 2's name for `asString()`.
    final string asText()
    {
        return asString();
    }

    /// The `int` value of a numeric node that fits; throws otherwise.
    int intValue()
    {
        throw wrongType("intValue()", "int");
    }

    /// The `int` value of a numeric node that fits, else `defaultValue`.
    int intValue(int defaultValue)
    {
        return defaultValue;
    }

    /// The `long` value of a numeric node that fits; throws otherwise.
    long longValue()
    {
        throw wrongType("longValue()", "long");
    }

    /// The `long` value of a numeric node that fits, else `defaultValue`.
    long longValue(long defaultValue)
    {
        return defaultValue;
    }

    /// The `double` value of a numeric node; throws otherwise.
    double doubleValue()
    {
        throw wrongType("doubleValue()", "double");
    }

    /// The `double` value of a numeric node, else `defaultValue`.
    double doubleValue(double defaultValue)
    {
        return defaultValue;
    }

    /// The boolean value of a Boolean node; throws otherwise.
    bool booleanValue()
    {
        throw wrongType("booleanValue()", "boolean");
    }

    /// The boolean value of a Boolean node, else `defaultValue`.
    bool booleanValue(bool defaultValue)
    {
        return defaultValue;
    }

    /// The node coerced to `int`: numbers truncated, numeric strings parsed, booleans 1 or 0; else 0.
    int asInt()
    {
        return asInt(0);
    }

    /// ditto, with a default.
    int asInt(int defaultValue)
    {
        return defaultValue;
    }

    /// The node coerced to `long`, as `asInt`.
    long asLong()
    {
        return asLong(0);
    }

    /// ditto, with a default.
    long asLong(long defaultValue)
    {
        return defaultValue;
    }

    /// The node coerced to `double`, as `asInt`.
    double asDouble()
    {
        return asDouble(0.0);
    }

    /// ditto, with a default.
    double asDouble(double defaultValue)
    {
        return defaultValue;
    }

    /// The node coerced to boolean: booleans, non-zero numbers, "true" strings; else false.
    bool asBoolean()
    {
        return asBoolean(false);
    }

    /// ditto, with a default.
    bool asBoolean(bool defaultValue)
    {
        return defaultValue;
    }

    /// This node as an Object node; throws for other nodes.
    ObjectNode asObject()
    {
        throw wrongType("asObject()", "Object");
    }

    /// This node as an Array node; throws for other nodes.
    ArrayNode asArray()
    {
        throw wrongType("asArray()", "Array");
    }

    /// The token that starts this node's serialization.
    abstract JsonToken asToken() const pure nothrow @nogc;

    /// Compact JSON, as Jackson's `JsonNode.toString()`; the missing node prints as "".
    override string toString()
    {
        return isMissingNode() ? "" : write(null);
    }

    /// JSON with Jackson's default pretty printer.
    string toPrettyString()
    {
        return write(new DefaultPrettyPrinter());
    }

    private string write(PrettyPrinter printer)
    {
        auto output = new ByteArrayBuilder();
        auto context = new PrinterContext(printer);
        auto g = new JsonFactory().createGenerator(context, output);
        serialize(g);
        g.close();
        return output.toUtf8String();
    }

    /// The node type's name for messages.
    protected string className() const pure nothrow
    {
        final switch (getNodeType())
        {
        case JsonNodeType.ARRAY:
            return "ArrayNode";
        case JsonNodeType.BINARY:
            return "BinaryNode";
        case JsonNodeType.BOOLEAN:
            return "BooleanNode";
        case JsonNodeType.MISSING:
            return "MissingNode";
        case JsonNodeType.NULL:
            return "NullNode";
        case JsonNodeType.NUMBER:
            return "NumericNode";
        case JsonNodeType.OBJECT:
            return "ObjectNode";
        case JsonNodeType.POJO:
            return "POJONode";
        case JsonNodeType.STRING:
            return "StringNode";
        }
    }

    /// The exception for an accessor called on the wrong node type.
    protected JsonNodeException wrongType(string method, string expected)
    {
        const value = toString();
        return new JsonNodeException("`" ~ className() ~ "` method `" ~ method
                ~ "` cannot convert value " ~ value ~ " to `" ~ expected ~ "`: value type not " ~ expected);
    }
}

private final class PrinterContext : ObjectWriteContext.Base
{
    private PrettyPrinter printer;

    this(PrettyPrinter printer) pure nothrow @nogc
    {
        this.printer = printer;
    }

    override PrettyPrinter getPrettyPrinter()
    {
        return printer;
    }
}

/// Base class for Array and Object nodes.
abstract class ContainerNode : JsonNode
{
    alias get = JsonNode.get;
    alias path = JsonNode.path;
    alias required = JsonNode.required;
    alias has = JsonNode.has;
    alias stringValue = JsonNode.stringValue;
    alias asString = JsonNode.asString;
    alias intValue = JsonNode.intValue;
    alias longValue = JsonNode.longValue;
    alias doubleValue = JsonNode.doubleValue;
    alias booleanValue = JsonNode.booleanValue;
    alias asInt = JsonNode.asInt;
    alias asLong = JsonNode.asLong;
    alias asDouble = JsonNode.asDouble;
    alias asBoolean = JsonNode.asBoolean;

    /// The factory that creates child nodes.
    protected JsonNodeFactory _nodeFactory;

    ///
    protected this(JsonNodeFactory nf) pure nothrow @nogc
    {
        _nodeFactory = nf;
    }

    /// Factory method that constructs and returns an empty `ArrayNode`.
    final ArrayNode arrayNode()
    {
        return _nodeFactory.arrayNode();
    }

    /// Factory method that constructs and returns an empty `ObjectNode`.
    final ObjectNode objectNode()
    {
        return _nodeFactory.objectNode();
    }

    /// Remove all children.
    abstract ContainerNode removeAll();
}

/// Node that maps to JSON Object structures in JSON content. Properties keep their insertion order.
final class ObjectNode : ContainerNode
{
    alias get = JsonNode.get;
    alias path = JsonNode.path;
    alias required = JsonNode.required;
    alias has = JsonNode.has;
    alias stringValue = JsonNode.stringValue;
    alias asString = JsonNode.asString;
    alias intValue = JsonNode.intValue;
    alias longValue = JsonNode.longValue;
    alias doubleValue = JsonNode.doubleValue;
    alias booleanValue = JsonNode.booleanValue;
    alias asInt = JsonNode.asInt;
    alias asLong = JsonNode.asLong;
    alias asDouble = JsonNode.asDouble;
    alias asBoolean = JsonNode.asBoolean;

    private string[] keys;
    private JsonNode[string] children;

    ///
    this(JsonNodeFactory nf) pure nothrow @nogc
    {
        super(nf);
    }

    override JsonNodeType getNodeType() const pure nothrow @nogc
    {
        return JsonNodeType.OBJECT;
    }

    override JsonToken asToken() const pure nothrow @nogc
    {
        return JsonToken.START_OBJECT;
    }

    override int size() const pure nothrow @nogc
    {
        return cast(int) keys.length;
    }

    override JsonNode get(string propertyName)
    {
        if (auto found = propertyName in children)
            return *found;
        return null;
    }

    override JsonNode path(string propertyName)
    {
        auto node = get(propertyName);
        return node is null ? MissingNode.getInstance() : node;
    }

    override Entry[] properties()
    {
        Entry[] result;
        foreach (k; keys)
            result ~= Entry(k, children[k]);
        return result;
    }

    override string[] propertyNames()
    {
        return keys.dup;
    }

    override JsonNode[] values()
    {
        JsonNode[] result;
        foreach (k; keys)
            result ~= children[k];
        return result;
    }

    override JsonNode findValue(string propertyName)
    {
        foreach (k; keys)
        {
            if (k == propertyName)
                return children[k];
            if (auto found = children[k].findValue(propertyName))
                return found;
        }
        return null;
    }

    override ObjectNode asObject()
    {
        return this;
    }

    /// Set property `propertyName` to `value` (null becomes the null node); returns this node.
    ObjectNode set(string propertyName, JsonNode value)
    {
        if (value is null)
            value = _nodeFactory.nullNode();
        if ((propertyName in children) is null)
            keys ~= propertyName;
        children[propertyName] = value;
        return this;
    }

    /// Replace property `propertyName`, returning its earlier value or null.
    JsonNode replace(string propertyName, JsonNode value)
    {
        auto old = get(propertyName);
        set(propertyName, value);
        return old;
    }

    /// Set every property of `properties`; returns this node.
    ObjectNode setAll(ObjectNode other)
    {
        foreach (entry; other.properties())
            set(entry.key, entry.value);
        return this;
    }

    /// Remove property `propertyName`, returning its value or null.
    JsonNode remove(string propertyName)
    {
        auto old = get(propertyName);
        if (old is null)
            return null;
        children.remove(propertyName);
        foreach (i, k; keys)
        {
            if (k == propertyName)
            {
                keys = keys[0 .. i] ~ keys[i + 1 .. $];
                break;
            }
        }
        return old;
    }

    override ObjectNode removeAll()
    {
        keys = null;
        children = null;
        return this;
    }

    /// Set property `propertyName` to a new Object node and return that node.
    ObjectNode putObject(string propertyName)
    {
        auto node = objectNode();
        set(propertyName, node);
        return node;
    }

    /// Set property `propertyName` to a new Array node and return that node.
    ArrayNode putArray(string propertyName)
    {
        auto node = arrayNode();
        set(propertyName, node);
        return node;
    }

    /// Set property `propertyName` to the null node; returns this node.
    ObjectNode putNull(string propertyName)
    {
        return set(propertyName, _nodeFactory.nullNode());
    }

    /// Set property `propertyName` to a String node (null becomes the null node); returns this node.
    ObjectNode put(string propertyName, string v)
    {
        return set(propertyName, v is null ? _nodeFactory.nullNode() : _nodeFactory.textNode(v));
    }

    /// Set property `propertyName` to a numeric node; returns this node.
    ObjectNode put(string propertyName, short v)
    {
        return set(propertyName, _nodeFactory.numberNode(v));
    }

    /// ditto
    ObjectNode put(string propertyName, int v)
    {
        return set(propertyName, _nodeFactory.numberNode(v));
    }

    /// ditto
    ObjectNode put(string propertyName, long v)
    {
        return set(propertyName, _nodeFactory.numberNode(v));
    }

    /// ditto
    ObjectNode put(string propertyName, float v)
    {
        return set(propertyName, _nodeFactory.numberNode(v));
    }

    /// ditto
    ObjectNode put(string propertyName, double v)
    {
        return set(propertyName, _nodeFactory.numberNode(v));
    }

    /// Set property `propertyName` to a Boolean node; returns this node.
    ObjectNode put(string propertyName, bool v)
    {
        return set(propertyName, _nodeFactory.booleanNode(v));
    }

    override void serialize(JsonGenerator g)
    {
        g.writeStartObject();
        foreach (k; keys)
        {
            g.writeName(k);
            children[k].serialize(g);
        }
        g.writeEndObject();
    }

    override bool equals(const JsonNode other) const
    {
        auto that = cast(const ObjectNode) other;
        if (that is null || that.keys.length != keys.length)
            return false;
        foreach (k, v; children)
        {
            auto there = k in that.children;
            if (there is null || !v.equals(*there))
                return false;
        }
        return true;
    }

    override ObjectNode deepCopy()
    {
        auto copy = new ObjectNode(_nodeFactory);
        foreach (k; keys)
            copy.set(k, children[k].deepCopy());
        return copy;
    }
}

/// Node class that represents Arrays mapped from JSON content.
final class ArrayNode : ContainerNode
{
    alias get = JsonNode.get;
    alias path = JsonNode.path;
    alias required = JsonNode.required;
    alias has = JsonNode.has;
    alias stringValue = JsonNode.stringValue;
    alias asString = JsonNode.asString;
    alias intValue = JsonNode.intValue;
    alias longValue = JsonNode.longValue;
    alias doubleValue = JsonNode.doubleValue;
    alias booleanValue = JsonNode.booleanValue;
    alias asInt = JsonNode.asInt;
    alias asLong = JsonNode.asLong;
    alias asDouble = JsonNode.asDouble;
    alias asBoolean = JsonNode.asBoolean;

    private JsonNode[] elements;

    ///
    this(JsonNodeFactory nf) pure nothrow @nogc
    {
        super(nf);
    }

    override JsonNodeType getNodeType() const pure nothrow @nogc
    {
        return JsonNodeType.ARRAY;
    }

    override JsonToken asToken() const pure nothrow @nogc
    {
        return JsonToken.START_ARRAY;
    }

    override int size() const pure nothrow @nogc
    {
        return cast(int) elements.length;
    }

    override JsonNode get(int index)
    {
        return index >= 0 && index < elements.length ? elements[index] : null;
    }

    override JsonNode path(int index)
    {
        auto node = get(index);
        return node is null ? MissingNode.getInstance() : node;
    }

    override JsonNode[] values()
    {
        return elements.dup;
    }

    override JsonNode findValue(string propertyName)
    {
        foreach (e; elements)
            if (auto found = e.findValue(propertyName))
                return found;
        return null;
    }

    override ArrayNode asArray()
    {
        return this;
    }

    /// Append `value` (null becomes the null node); returns this node.
    ArrayNode add(JsonNode value)
    {
        elements ~= value is null ? _nodeFactory.nullNode() : value;
        return this;
    }

    /// Append a String node (null becomes the null node); returns this node.
    ArrayNode add(string v)
    {
        return add(v is null ? _nodeFactory.nullNode() : _nodeFactory.textNode(v));
    }

    /// Append a numeric node; returns this node.
    ArrayNode add(int v)
    {
        return add(_nodeFactory.numberNode(v));
    }

    /// ditto
    ArrayNode add(long v)
    {
        return add(_nodeFactory.numberNode(v));
    }

    /// ditto
    ArrayNode add(double v)
    {
        return add(_nodeFactory.numberNode(v));
    }

    /// ditto
    ArrayNode add(float v)
    {
        return add(_nodeFactory.numberNode(v));
    }

    /// Append a Boolean node; returns this node.
    ArrayNode add(bool v)
    {
        return add(_nodeFactory.booleanNode(v));
    }

    /// Append the null node; returns this node.
    ArrayNode addNull()
    {
        return add(_nodeFactory.nullNode());
    }

    /// Append a new Object node and return that node.
    ObjectNode addObject()
    {
        auto node = objectNode();
        add(node);
        return node;
    }

    /// Append a new Array node and return that node.
    ArrayNode addArray()
    {
        auto node = arrayNode();
        add(node);
        return node;
    }

    /// Append every element of `other`; returns this node.
    ArrayNode addAll(ArrayNode other)
    {
        elements ~= other.elements;
        return this;
    }

    /// Replace the element at `index`, returning the earlier one.
    JsonNode set(int index, JsonNode value)
    {
        import flint.java.lang : IndexOutOfBoundsException;
        import std.conv : to;

        if (index < 0 || index >= elements.length)
            throw new IndexOutOfBoundsException("Illegal index " ~ index.to!string ~ ", array size " ~ size()
                    .to!string);
        auto old = elements[index];
        elements[index] = value is null ? _nodeFactory.nullNode() : value;
        return old;
    }

    /// Remove the element at `index`, returning it, or null when there is none.
    JsonNode remove(int index)
    {
        if (index < 0 || index >= elements.length)
            return null;
        auto old = elements[index];
        elements = elements[0 .. index] ~ elements[index + 1 .. $];
        return old;
    }

    override ArrayNode removeAll()
    {
        elements = null;
        return this;
    }

    override void serialize(JsonGenerator g)
    {
        g.writeStartArray();
        foreach (e; elements)
            e.serialize(g);
        g.writeEndArray();
    }

    override bool equals(const JsonNode other) const
    {
        auto that = cast(const ArrayNode) other;
        if (that is null || that.elements.length != elements.length)
            return false;
        foreach (i, e; elements)
            if (!e.equals(that.elements[i]))
                return false;
        return true;
    }

    override ArrayNode deepCopy()
    {
        auto copy = new ArrayNode(_nodeFactory);
        foreach (e; elements)
            copy.add(e.deepCopy());
        return copy;
    }
}

/// This intermediate base class is used for all leaf nodes, that is, all non-container (array or object) nodes, except for the "missing node".
abstract class ValueNode : JsonNode
{
    alias get = JsonNode.get;
    alias path = JsonNode.path;
    alias required = JsonNode.required;
    alias has = JsonNode.has;
    alias stringValue = JsonNode.stringValue;
    alias asString = JsonNode.asString;
    alias intValue = JsonNode.intValue;
    alias longValue = JsonNode.longValue;
    alias doubleValue = JsonNode.doubleValue;
    alias booleanValue = JsonNode.booleanValue;
    alias asInt = JsonNode.asInt;
    alias asLong = JsonNode.asLong;
    alias asDouble = JsonNode.asDouble;
    alias asBoolean = JsonNode.asBoolean;

    override JsonNode deepCopy()
    {
        return this;
    }

    override string asString(string defaultValue)
    {
        return asString();
    }
}

/// Value node that contains a String value.
final class StringNode : ValueNode
{
    alias get = JsonNode.get;
    alias path = JsonNode.path;
    alias required = JsonNode.required;
    alias has = JsonNode.has;
    alias stringValue = JsonNode.stringValue;
    alias asString = JsonNode.asString;
    alias intValue = JsonNode.intValue;
    alias longValue = JsonNode.longValue;
    alias doubleValue = JsonNode.doubleValue;
    alias booleanValue = JsonNode.booleanValue;
    alias asInt = JsonNode.asInt;
    alias asLong = JsonNode.asLong;
    alias asDouble = JsonNode.asDouble;
    alias asBoolean = JsonNode.asBoolean;

    private string _value;

    ///
    this(string v) pure nothrow @nogc
    {
        _value = v;
    }

    /// Factory method that should be used to construct instances.
    static StringNode valueOf(string v) pure nothrow
    {
        return new StringNode(v is null ? "" : v);
    }

    override JsonNodeType getNodeType() const pure nothrow @nogc
    {
        return JsonNodeType.STRING;
    }

    override JsonToken asToken() const pure nothrow @nogc
    {
        return JsonToken.VALUE_STRING;
    }

    override string stringValue()
    {
        return _value;
    }

    override string stringValue(string)
    {
        return _value;
    }

    override string asString()
    {
        return _value;
    }

    override int asInt(int defaultValue)
    {
        import std.conv : to;
        import std.string : strip;

        try
            return _value.strip().to!int;
        catch (Exception)
            return defaultValue;
    }

    override long asLong(long defaultValue)
    {
        import std.conv : to;
        import std.string : strip;

        try
            return _value.strip().to!long;
        catch (Exception)
            return defaultValue;
    }

    override double asDouble(double defaultValue)
    {
        import flint.serde.json_read : parseJsonDecimal;
        import std.string : strip;

        double[1] parsed;
        auto text = cast(const(ubyte)[]) _value.strip();
        return text.length && parseJsonDecimal(text, parsed[0]) ? parsed[0] : defaultValue;
    }

    override bool asBoolean(bool defaultValue)
    {
        import std.string : strip;

        const text = _value.strip();
        if (text == "true")
            return true;
        if (text == "false")
            return false;
        return defaultValue;
    }

    override void serialize(JsonGenerator g)
    {
        g.writeString(_value);
    }

    override bool equals(const JsonNode other) const
    {
        auto that = cast(const StringNode) other;
        return that !is null && that._value == _value;
    }
}

/// Intermediate value node used for numeric nodes.
abstract class NumericNode : ValueNode
{
    alias get = JsonNode.get;
    alias path = JsonNode.path;
    alias required = JsonNode.required;
    alias has = JsonNode.has;
    alias stringValue = JsonNode.stringValue;
    alias asString = JsonNode.asString;
    alias intValue = JsonNode.intValue;
    alias longValue = JsonNode.longValue;
    alias doubleValue = JsonNode.doubleValue;
    alias booleanValue = JsonNode.booleanValue;
    alias asInt = JsonNode.asInt;
    alias asLong = JsonNode.asLong;
    alias asDouble = JsonNode.asDouble;
    alias asBoolean = JsonNode.asBoolean;

    override JsonNodeType getNodeType() const pure nothrow @nogc
    {
        return JsonNodeType.NUMBER;
    }

    override bool asBoolean(bool)
    {
        return asLong() != 0;
    }
}

/// Numeric node that contains simple 32-bit integer values.
final class IntNode : NumericNode
{
    alias get = JsonNode.get;
    alias path = JsonNode.path;
    alias required = JsonNode.required;
    alias has = JsonNode.has;
    alias stringValue = JsonNode.stringValue;
    alias asString = JsonNode.asString;
    alias intValue = JsonNode.intValue;
    alias longValue = JsonNode.longValue;
    alias doubleValue = JsonNode.doubleValue;
    alias booleanValue = JsonNode.booleanValue;
    alias asInt = JsonNode.asInt;
    alias asLong = JsonNode.asLong;
    alias asDouble = JsonNode.asDouble;
    alias asBoolean = JsonNode.asBoolean;

    private int _value;

    ///
    this(int v) pure nothrow @nogc
    {
        _value = v;
    }

    /// Factory method.
    static IntNode valueOf(int i) pure nothrow
    {
        return new IntNode(i);
    }

    override JsonToken asToken() const pure nothrow @nogc
    {
        return JsonToken.VALUE_NUMBER_INT;
    }

    override bool isIntegralNumber() const pure nothrow @nogc
    {
        return true;
    }

    override bool isInt() const pure nothrow @nogc
    {
        return true;
    }

    override int intValue()
    {
        return _value;
    }

    override int intValue(int)
    {
        return _value;
    }

    override long longValue()
    {
        return _value;
    }

    override long longValue(long)
    {
        return _value;
    }

    override double doubleValue()
    {
        return _value;
    }

    override double doubleValue(double)
    {
        return _value;
    }

    override string asString()
    {
        import std.conv : to;

        return _value.to!string;
    }

    override int asInt(int)
    {
        return _value;
    }

    override long asLong(long)
    {
        return _value;
    }

    override double asDouble(double)
    {
        return _value;
    }

    override void serialize(JsonGenerator g)
    {
        g.writeNumber(_value);
    }

    override bool equals(const JsonNode other) const
    {
        auto that = cast(const IntNode) other;
        return that !is null && that._value == _value;
    }
}

/// Numeric node that contains a 16-bit integer value.
final class ShortNode : NumericNode
{
    alias get = JsonNode.get;
    alias path = JsonNode.path;
    alias required = JsonNode.required;
    alias has = JsonNode.has;
    alias stringValue = JsonNode.stringValue;
    alias asString = JsonNode.asString;
    alias intValue = JsonNode.intValue;
    alias longValue = JsonNode.longValue;
    alias doubleValue = JsonNode.doubleValue;
    alias booleanValue = JsonNode.booleanValue;
    alias asInt = JsonNode.asInt;
    alias asLong = JsonNode.asLong;
    alias asDouble = JsonNode.asDouble;
    alias asBoolean = JsonNode.asBoolean;

    private short _value;

    ///
    this(short v) pure nothrow @nogc
    {
        _value = v;
    }

    /// Factory method.
    static ShortNode valueOf(short v) pure nothrow
    {
        return new ShortNode(v);
    }

    override JsonToken asToken() const pure nothrow @nogc
    {
        return JsonToken.VALUE_NUMBER_INT;
    }

    override bool isIntegralNumber() const pure nothrow @nogc
    {
        return true;
    }

    override bool isShort() const pure nothrow @nogc
    {
        return true;
    }

    override int intValue()
    {
        return _value;
    }

    override long longValue()
    {
        return _value;
    }

    override double doubleValue()
    {
        return _value;
    }

    override string asString()
    {
        import std.conv : to;

        return _value.to!string;
    }

    override int asInt(int)
    {
        return _value;
    }

    override long asLong(long)
    {
        return _value;
    }

    override double asDouble(double)
    {
        return _value;
    }

    override void serialize(JsonGenerator g)
    {
        g.writeNumber(_value);
    }

    override bool equals(const JsonNode other) const
    {
        auto that = cast(const ShortNode) other;
        return that !is null && that._value == _value;
    }
}

/// Numeric node that contains simple 64-bit integer values.
final class LongNode : NumericNode
{
    alias get = JsonNode.get;
    alias path = JsonNode.path;
    alias required = JsonNode.required;
    alias has = JsonNode.has;
    alias stringValue = JsonNode.stringValue;
    alias asString = JsonNode.asString;
    alias intValue = JsonNode.intValue;
    alias longValue = JsonNode.longValue;
    alias doubleValue = JsonNode.doubleValue;
    alias booleanValue = JsonNode.booleanValue;
    alias asInt = JsonNode.asInt;
    alias asLong = JsonNode.asLong;
    alias asDouble = JsonNode.asDouble;
    alias asBoolean = JsonNode.asBoolean;

    private long _value;

    ///
    this(long v) pure nothrow @nogc
    {
        _value = v;
    }

    /// Factory method.
    static LongNode valueOf(long l) pure nothrow
    {
        return new LongNode(l);
    }

    override JsonToken asToken() const pure nothrow @nogc
    {
        return JsonToken.VALUE_NUMBER_INT;
    }

    override bool isIntegralNumber() const pure nothrow @nogc
    {
        return true;
    }

    override bool isLong() const pure nothrow @nogc
    {
        return true;
    }

    override int intValue()
    {
        if (_value < int.min || _value > int.max)
            throw wrongType("intValue()", "int");
        return cast(int) _value;
    }

    override int intValue(int defaultValue)
    {
        return _value < int.min || _value > int.max ? defaultValue : cast(int) _value;
    }

    override long longValue()
    {
        return _value;
    }

    override long longValue(long)
    {
        return _value;
    }

    override double doubleValue()
    {
        return _value;
    }

    override double doubleValue(double)
    {
        return _value;
    }

    override string asString()
    {
        import std.conv : to;

        return _value.to!string;
    }

    override int asInt(int)
    {
        return cast(int) _value;
    }

    override long asLong(long)
    {
        return _value;
    }

    override double asDouble(double)
    {
        return _value;
    }

    override void serialize(JsonGenerator g)
    {
        g.writeNumber(_value);
    }

    override bool equals(const JsonNode other) const
    {
        auto that = cast(const LongNode) other;
        return that !is null && that._value == _value;
    }
}

/// Numeric node that contains 64-bit ("double precision") floating point values simple 32-bit integer values.
final class DoubleNode : NumericNode
{
    alias get = JsonNode.get;
    alias path = JsonNode.path;
    alias required = JsonNode.required;
    alias has = JsonNode.has;
    alias stringValue = JsonNode.stringValue;
    alias asString = JsonNode.asString;
    alias intValue = JsonNode.intValue;
    alias longValue = JsonNode.longValue;
    alias doubleValue = JsonNode.doubleValue;
    alias booleanValue = JsonNode.booleanValue;
    alias asInt = JsonNode.asInt;
    alias asLong = JsonNode.asLong;
    alias asDouble = JsonNode.asDouble;
    alias asBoolean = JsonNode.asBoolean;

    private double _value;

    ///
    this(double v) pure nothrow @nogc
    {
        _value = v;
    }

    /// Factory method.
    static DoubleNode valueOf(double v) pure nothrow
    {
        return new DoubleNode(v);
    }

    override JsonToken asToken() const pure nothrow @nogc
    {
        return JsonToken.VALUE_NUMBER_FLOAT;
    }

    override bool isFloatingPointNumber() const pure nothrow @nogc
    {
        return true;
    }

    override bool isDouble() const pure nothrow @nogc
    {
        return true;
    }

    override double doubleValue()
    {
        return _value;
    }

    override double doubleValue(double)
    {
        return _value;
    }

    override int intValue()
    {
        if (_value != cast(int) _value)
            throw wrongType("intValue()", "int");
        return cast(int) _value;
    }

    override long longValue()
    {
        if (_value != cast(long) _value)
            throw wrongType("longValue()", "long");
        return cast(long) _value;
    }

    override string asString()
    {
        return javaDoubleString(_value);
    }

    override int asInt(int)
    {
        return cast(int) _value;
    }

    override long asLong(long)
    {
        return cast(long) _value;
    }

    override double asDouble(double)
    {
        return _value;
    }

    override void serialize(JsonGenerator g)
    {
        g.writeNumber(_value);
    }

    override bool equals(const JsonNode other) const
    {
        auto that = cast(const DoubleNode) other;
        return that !is null && (that._value == _value || (that._value != that._value && _value != _value));
    }
}

/// Numeric node that contains a 32-bit floating point value.
final class FloatNode : NumericNode
{
    alias get = JsonNode.get;
    alias path = JsonNode.path;
    alias required = JsonNode.required;
    alias has = JsonNode.has;
    alias stringValue = JsonNode.stringValue;
    alias asString = JsonNode.asString;
    alias intValue = JsonNode.intValue;
    alias longValue = JsonNode.longValue;
    alias doubleValue = JsonNode.doubleValue;
    alias booleanValue = JsonNode.booleanValue;
    alias asInt = JsonNode.asInt;
    alias asLong = JsonNode.asLong;
    alias asDouble = JsonNode.asDouble;
    alias asBoolean = JsonNode.asBoolean;

    private float _value;

    ///
    this(float v) pure nothrow @nogc
    {
        _value = v;
    }

    /// Factory method.
    static FloatNode valueOf(float v) pure nothrow
    {
        return new FloatNode(v);
    }

    override JsonToken asToken() const pure nothrow @nogc
    {
        return JsonToken.VALUE_NUMBER_FLOAT;
    }

    override bool isFloatingPointNumber() const pure nothrow @nogc
    {
        return true;
    }

    override bool isFloat() const pure nothrow @nogc
    {
        return true;
    }

    override double doubleValue()
    {
        return _value;
    }

    override string asString()
    {
        return javaFloatString(_value);
    }

    override int asInt(int)
    {
        return cast(int) _value;
    }

    override long asLong(long)
    {
        return cast(long) _value;
    }

    override double asDouble(double)
    {
        return _value;
    }

    override void serialize(JsonGenerator g)
    {
        g.writeNumber(_value);
    }

    override bool equals(const JsonNode other) const
    {
        auto that = cast(const FloatNode) other;
        return that !is null && that._value == _value;
    }
}

/// Numeric node that contains an integer too large for `long`, kept as its exact decimal text.
final class BigIntegerNode : NumericNode
{
    alias get = JsonNode.get;
    alias path = JsonNode.path;
    alias required = JsonNode.required;
    alias has = JsonNode.has;
    alias stringValue = JsonNode.stringValue;
    alias asString = JsonNode.asString;
    alias intValue = JsonNode.intValue;
    alias longValue = JsonNode.longValue;
    alias doubleValue = JsonNode.doubleValue;
    alias booleanValue = JsonNode.booleanValue;
    alias asInt = JsonNode.asInt;
    alias asLong = JsonNode.asLong;
    alias asDouble = JsonNode.asDouble;
    alias asBoolean = JsonNode.asBoolean;

    private string _text;

    ///
    this(string decimalText) pure nothrow @nogc
    {
        _text = decimalText;
    }

    override JsonToken asToken() const pure nothrow @nogc
    {
        return JsonToken.VALUE_NUMBER_INT;
    }

    override bool isIntegralNumber() const pure nothrow @nogc
    {
        return true;
    }

    override bool isBigInteger() const pure nothrow @nogc
    {
        return true;
    }

    override string asString()
    {
        return _text;
    }

    override double asDouble(double defaultValue)
    {
        return StringNode.valueOf(_text).asDouble(defaultValue);
    }

    override double doubleValue()
    {
        return asDouble(0);
    }

    override void serialize(JsonGenerator g)
    {
        g.writeNumber(_text);
    }

    override bool equals(const JsonNode other) const
    {
        auto that = cast(const BigIntegerNode) other;
        return that !is null && that._text == _text;
    }
}

/// Numeric node that contains values that do not fit in simple floating point (double) values, kept as decimal text.
final class DecimalNode : NumericNode
{
    alias get = JsonNode.get;
    alias path = JsonNode.path;
    alias required = JsonNode.required;
    alias has = JsonNode.has;
    alias stringValue = JsonNode.stringValue;
    alias asString = JsonNode.asString;
    alias intValue = JsonNode.intValue;
    alias longValue = JsonNode.longValue;
    alias doubleValue = JsonNode.doubleValue;
    alias booleanValue = JsonNode.booleanValue;
    alias asInt = JsonNode.asInt;
    alias asLong = JsonNode.asLong;
    alias asDouble = JsonNode.asDouble;
    alias asBoolean = JsonNode.asBoolean;

    private string _text;

    ///
    this(string decimalText) pure nothrow @nogc
    {
        _text = decimalText;
    }

    override JsonToken asToken() const pure nothrow @nogc
    {
        return JsonToken.VALUE_NUMBER_FLOAT;
    }

    override bool isFloatingPointNumber() const pure nothrow @nogc
    {
        return true;
    }

    override bool isBigDecimal() const pure nothrow @nogc
    {
        return true;
    }

    override string asString()
    {
        return _text;
    }

    override double asDouble(double defaultValue)
    {
        return StringNode.valueOf(_text).asDouble(defaultValue);
    }

    override double doubleValue()
    {
        return asDouble(0);
    }

    override void serialize(JsonGenerator g)
    {
        g.writeNumber(_text);
    }

    override bool equals(const JsonNode other) const
    {
        auto that = cast(const DecimalNode) other;
        return that !is null && that._text == _text;
    }
}

/// This concrete value class is used to contain boolean (true / false) values.
final class BooleanNode : ValueNode
{
    alias get = JsonNode.get;
    alias path = JsonNode.path;
    alias required = JsonNode.required;
    alias has = JsonNode.has;
    alias stringValue = JsonNode.stringValue;
    alias asString = JsonNode.asString;
    alias intValue = JsonNode.intValue;
    alias longValue = JsonNode.longValue;
    alias doubleValue = JsonNode.doubleValue;
    alias booleanValue = JsonNode.booleanValue;
    alias asInt = JsonNode.asInt;
    alias asLong = JsonNode.asLong;
    alias asDouble = JsonNode.asDouble;
    alias asBoolean = JsonNode.asBoolean;

    private bool _value;

    private this(bool v) pure nothrow @nogc
    {
        _value = v;
    }

    /// The node for `true`.
    static BooleanNode getTrue() pure nothrow
    {
        return new BooleanNode(true);
    }

    /// The node for `false`.
    static BooleanNode getFalse() pure nothrow
    {
        return new BooleanNode(false);
    }

    /// The node for `b`.
    static BooleanNode valueOf(bool b) pure nothrow
    {
        return new BooleanNode(b);
    }

    override JsonNodeType getNodeType() const pure nothrow @nogc
    {
        return JsonNodeType.BOOLEAN;
    }

    override JsonToken asToken() const pure nothrow @nogc
    {
        return _value ? JsonToken.VALUE_TRUE : JsonToken.VALUE_FALSE;
    }

    override bool booleanValue()
    {
        return _value;
    }

    override bool booleanValue(bool)
    {
        return _value;
    }

    override string asString()
    {
        return _value ? "true" : "false";
    }

    override bool asBoolean(bool)
    {
        return _value;
    }

    override int asInt(int)
    {
        return _value ? 1 : 0;
    }

    override long asLong(long)
    {
        return _value ? 1 : 0;
    }

    override double asDouble(double)
    {
        return _value ? 1.0 : 0.0;
    }

    override void serialize(JsonGenerator g)
    {
        g.writeBoolean(_value);
    }

    override bool equals(const JsonNode other) const
    {
        auto that = cast(const BooleanNode) other;
        return that !is null && that._value == _value;
    }
}

/// This singleton value class is used to contain explicit JSON null value.
final class NullNode : ValueNode
{
    alias get = JsonNode.get;
    alias path = JsonNode.path;
    alias required = JsonNode.required;
    alias has = JsonNode.has;
    alias stringValue = JsonNode.stringValue;
    alias asString = JsonNode.asString;
    alias intValue = JsonNode.intValue;
    alias longValue = JsonNode.longValue;
    alias doubleValue = JsonNode.doubleValue;
    alias booleanValue = JsonNode.booleanValue;
    alias asInt = JsonNode.asInt;
    alias asLong = JsonNode.asLong;
    alias asDouble = JsonNode.asDouble;
    alias asBoolean = JsonNode.asBoolean;

    private this() pure nothrow @nogc
    {
    }

    /// The null node.
    static NullNode getInstance() pure nothrow
    {
        return new NullNode();
    }

    override JsonNodeType getNodeType() const pure nothrow @nogc
    {
        return JsonNodeType.NULL;
    }

    override JsonToken asToken() const pure nothrow @nogc
    {
        return JsonToken.VALUE_NULL;
    }

    override string asString()
    {
        return "null";
    }

    override string asString(string defaultValue)
    {
        return defaultValue;
    }

    override void serialize(JsonGenerator g)
    {
        g.writeNull();
    }

    override bool equals(const JsonNode other) const
    {
        return cast(const NullNode) other !is null;
    }
}

/// This singleton node class is generated to denote "missing nodes" along paths that do not exist.
final class MissingNode : JsonNode
{
    alias get = JsonNode.get;
    alias path = JsonNode.path;
    alias required = JsonNode.required;
    alias has = JsonNode.has;
    alias stringValue = JsonNode.stringValue;
    alias asString = JsonNode.asString;
    alias intValue = JsonNode.intValue;
    alias longValue = JsonNode.longValue;
    alias doubleValue = JsonNode.doubleValue;
    alias booleanValue = JsonNode.booleanValue;
    alias asInt = JsonNode.asInt;
    alias asLong = JsonNode.asLong;
    alias asDouble = JsonNode.asDouble;
    alias asBoolean = JsonNode.asBoolean;

    private this() pure nothrow @nogc
    {
    }

    /// The missing node.
    static MissingNode getInstance() pure nothrow
    {
        return new MissingNode();
    }

    override JsonNodeType getNodeType() const pure nothrow @nogc
    {
        return JsonNodeType.MISSING;
    }

    override JsonToken asToken() const pure nothrow @nogc
    {
        return JsonToken.NOT_AVAILABLE;
    }

    override JsonNode deepCopy()
    {
        return this;
    }

    override void serialize(JsonGenerator g)
    {
        g.writeNull();
    }

    override bool equals(const JsonNode other) const
    {
        return cast(const MissingNode) other !is null;
    }

}

/// Base class that specifies methods for getting access to Node instances (newly constructed, or shared, depending on type), as well as basic implementation of the methods.
class JsonNodeFactory
{
    /// Default singleton instance that construct "standard" node instances.
    static JsonNodeFactory instance() pure nothrow
    {
        return new JsonNodeFactory();
    }

    /// Factory method for getting an instance of JSON boolean value (either literal 'true' or 'false').
    BooleanNode booleanNode(bool v) pure nothrow
    {
        return BooleanNode.valueOf(v);
    }

    /// Factory method for getting an instance of JSON null node (which represents literal null value).
    NullNode nullNode() pure nothrow
    {
        return NullNode.getInstance();
    }

    /// Factory method for getting an instance of the missing node.
    MissingNode missingNode() pure nothrow
    {
        return MissingNode.getInstance();
    }

    /// Factory method for getting an instance of JSON numeric value that expresses given 16-bit integer value.
    NumericNode numberNode(short v) pure nothrow
    {
        return ShortNode.valueOf(v);
    }

    /// Factory method for getting an instance of JSON numeric value that expresses given 32-bit integer value.
    NumericNode numberNode(int v) pure nothrow
    {
        return IntNode.valueOf(v);
    }

    /// Factory method for getting an instance of JSON numeric value that expresses given 64-bit integer value.
    NumericNode numberNode(long v) pure nothrow
    {
        return LongNode.valueOf(v);
    }

    /// Factory method for getting an instance of JSON numeric value that expresses given 32-bit floating point value.
    NumericNode numberNode(float v) pure nothrow
    {
        return FloatNode.valueOf(v);
    }

    /// Factory method for getting an instance of JSON numeric value that expresses given 64-bit floating point value.
    NumericNode numberNode(double v) pure nothrow
    {
        return DoubleNode.valueOf(v);
    }

    /// Factory method for constructing a node that represents JSON String value.
    StringNode textNode(string text) pure nothrow
    {
        return StringNode.valueOf(text);
    }

    /// Factory method for constructing an empty JSON Array node.
    ArrayNode arrayNode() pure nothrow
    {
        return new ArrayNode(this);
    }

    /// Factory method for constructing an empty JSON Object ("struct") node.
    ObjectNode objectNode() pure nothrow
    {
        return new ObjectNode(this);
    }
}

/// Read the value at the parser's current token (advancing first when there is none) into a tree.
JsonNode readTree(JsonParser p, JsonNodeFactory nf)
{
    auto t = p.currentToken();
    if (t == JsonToken.NOT_AVAILABLE)
        t = p.nextToken();
    if (t == JsonToken.NOT_AVAILABLE)
        return null;
    return readNode(p, nf, t);
}

private JsonNode readNode(JsonParser p, JsonNodeFactory nf, JsonToken t)
{
    switch (t)
    {
    case JsonToken.START_OBJECT:
        auto node = nf.objectNode();
        for (auto next = p.nextToken(); next == JsonToken.PROPERTY_NAME; next = p.nextToken())
        {
            const name = p.currentName();
            node.set(name, readNode(p, nf, p.nextToken()));
        }
        return node;
    case JsonToken.START_ARRAY:
        auto array = nf.arrayNode();
        for (auto next = p.nextToken(); next != JsonToken.END_ARRAY; next = p.nextToken())
            array.add(readNode(p, nf, next));
        return array;
    case JsonToken.VALUE_STRING:
        return nf.textNode(p.getString());
    case JsonToken.VALUE_NUMBER_INT:
        return integralNode(p, nf);
    case JsonToken.VALUE_NUMBER_FLOAT:
        return nf.numberNode(p.getDoubleValue());
    case JsonToken.VALUE_TRUE:
    case JsonToken.VALUE_FALSE:
        return nf.booleanNode(t == JsonToken.VALUE_TRUE);
    case JsonToken.VALUE_NULL:
        return nf.nullNode();
    default:
        throw new JsonNodeException("Unexpected token (" ~ p.getString() ~ ") when reading a tree");
    }
}

// JsonNodeDeserializer: the smallest node that holds the integer.
private JsonNode integralNode(JsonParser p, JsonNodeFactory nf)
{
    switch (p.getNumberType())
    {
    case JsonParser.NumberType.INT:
        return nf.numberNode(p.getIntValue());
    case JsonParser.NumberType.LONG:
        return nf.numberNode(p.getLongValue());
    default:
        return new BigIntegerNode(p.getString());
    }
}
