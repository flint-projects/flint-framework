module flint.java.java_types_test;

import flint.engine.aot.any : Any;
import flint.engine.aot.descriptor : descriptorOf;
import flint.java.io : ByteArrayInputStream, File, FileNotFoundException, FileInputStream,
    IOException, UncheckedIOException;
import flint.java.lang : Boolean, Double, IllegalArgumentException, IllegalStateException,
    IndexOutOfBoundsException, Integer, JavaObject,
    Long, NullPointerException,
    NumberFormatException, RuntimeException, UnsupportedOperationException, equals, javaHashCode,
    javaToString, stringHashCode, valueOf;
import flint.java.util : ArrayList, Arrays, Collection, Collections, Comparator, HashMap, HashSet,
    LinkedHashMap, LinkedHashSet, List, Map, MapEntry, NoSuchElementException, Objects, Optional,
    RawCollection, RawMap, Set;
import flint.java.util.function_ : Function, Predicate, Supplier;
import flint.java.util.stream : Collectors, Stream;

@safe:

private final class Owner
{
    mixin JavaObject;

    private string name;
    private int age;

    this(string name, int age)
    {
        this.name = name;
        this.age = age;
    }

    string getName()
    {
        return name;
    }

    int getAge()
    {
        return age;
    }

    bool equals(Object o)
    {
        auto that = cast(Owner) o;
        return that !is null && that.name == name;
    }

    int hashCode()
    {
        return stringHashCode(name);
    }

    int compareTo(Owner other)
    {
        return Integer.compare(age, other.age);
    }

    override string toString()
    {
        return "Owner(" ~ name ~ ")";
    }
}

private class ControlFlow : RuntimeException
{
    this(string message)
    {
        super(message, null, false, false);
    }
}

unittest
{
    // R8: Java's hierarchy, messages, causes and toString.
    auto cause = new IllegalStateException("inner");
    auto e = new IllegalArgumentException("outer", cause);
    assert(cast(RuntimeException) e !is null && cast(Exception) e !is null);
    assert(e.getMessage() == "outer" && e.getCause() is cause);
    assert(e.toString() == "flint.java.lang.IllegalArgumentException: outer");
    assert(new UnsupportedOperationException().getMessage() is null);
    assert(new UnsupportedOperationException().toString() == "flint.java.lang.UnsupportedOperationException");
    auto wrapped = new RuntimeException(cast(Throwable) cause);
    assert(wrapped.getMessage() == "flint.java.lang.IllegalStateException: inner");
    // initCause: once only, never itself.
    auto late = new RuntimeException("late");
    late.initCause(cause);
    assert(late.getCause() is cause);
    bool threw;
    try
        late.initCause(cause);
    catch (IllegalStateException)
        threw = true;
    assert(threw);
    threw = false;
    try
        new RuntimeException("self").initCause(null).initCause(null);
    catch (IllegalStateException)
        threw = true;
    assert(threw);
    assert(cast(IllegalArgumentException) new NumberFormatException("x") !is null);
    assert(new IndexOutOfBoundsException(5).getMessage() == "Index out of range: 5");
}

unittest
{
    // writableStackTrace = false: the throw captures no trace (control-flow exceptions, ADR-030 section 4).
    try
        throw new ControlFlow("skip");
    catch (ControlFlow e)
        assert(typeid(cast(Object) e.info).name == "flint.java.lang.NoTrace");
    try
        throw new IllegalStateException("traced");
    catch (IllegalStateException e)
        assert(e.info !is null);
}

unittest
{
    // R11: mixin JavaObject maps equals/hashCode/compareTo onto ==, AA hashing and <.
    auto a = new Owner("Betty", 40), b = new Owner("Betty", 41), c = new Owner("George", 30);
    assert(a == b && a !is b && a != c);
    assert(a.toHash() == b.toHash());
    int[Owner] visits;
    visits[a] = 1;
    assert(b in visits);
    assert(c < a && a < b);
    // Free equals/hashCode give classes without the mixin Java's identity defaults.
    Object plain = new Object;
    assert(plain.equals(plain) && !plain.equals(new Object));
    assert(stringHashCode("hello") == 99_162_322);
    assert(stringHashCode("") == 0 && stringHashCode("é") == 233);
    assert(stringHashCode("😀") == 1_772_899); // a surrogate pair, as Java hashes it
    assert(javaHashCode(true) == 1231 && javaHashCode(5L) == 5 && javaHashCode(-1L) == 0);
}

unittest
{
    // Boxed-number statics with Java's messages.
    assert(Integer.parseInt("-42") == -42 && Integer.parseInt("+7") == 7 && Integer.parseInt("ff", 16) == 255);
    assert(Integer.parseInt("-2147483648") == int.min);
    assert(Long.parseLong("-9223372036854775808") == long.min);
    foreach (bad; ["", "-", "12a", " 1", "2147483648", "1.0"])
    {
        bool threw;
        try
            Integer.parseInt(bad);
        catch (NumberFormatException e)
            threw = e.getMessage() == "For input string: \"" ~ bad ~ "\"";
        assert(threw, bad);
    }
    assert(Boolean.parseBoolean("TRUE") && !Boolean.parseBoolean("yes") && !Boolean.parseBoolean(null));
    assert(Double.parseDouble(" 2.5 ") == 2.5 && Double.parseDouble("1e3") == 1000);
    assert(valueOf(1.0) == "1.0" && valueOf(2.5) == "2.5" && valueOf(true) == "true");
    assert(Double.toString(1e7) == "1.0E7" && Double.toString(0.0001) == "1.0E-4" && valueOf(0.1f) == "0.1");
    Owner nobody;
    assert(valueOf(nobody) == "null" && valueOf(42) == "42");
}

unittest
{
    // String.valueOf's scalars and Double.parseDouble go through flint.engine.aot.text; they print and parse as
    // std.conv did.
    import std.conv : to;

    enum Colour
    {
        red,
        green
    }

    const long big = long.min;
    assert(valueOf(-7) == (-7).to!string && valueOf(big) == big.to!string);
    assert(valueOf(ulong.max) == ulong.max.to!string && valueOf(cast(ubyte) 200) == "200");
    assert(valueOf(Colour.green) == "green" && valueOf(cast(Colour) 5) == "cast(Colour)5");
    assert(valueOf('x') == "x" && valueOf(cast(char) 0xFF) == [cast(char) 0xFF] && valueOf('\u00E9') == "\u00E9");
    assert(valueOf(cast(wchar) 0x436) == "\u0436" && valueOf(cast(dchar) 0xD800) == "\uFFFD");
    assert(Double.parseDouble("-0x1p3") == -8 && Double.parseDouble("1_000.5") == 1000.5);
    assert(Double.parseDouble("2f") == 2);
    foreach (bad; ["1e", "+inf", "0x", "1..2", "_1"])
    {
        bool threw;
        try
            Double.parseDouble(bad);
        catch (NumberFormatException e)
            threw = e.getMessage() == "For input string: \"" ~ bad ~ "\"";
        assert(threw, bad);
    }
}

unittest
{
    // R5: Optional.
    auto present = Optional!string.of("x");
    auto absent = Optional!string.empty();
    assert(present.isPresent && !present.isEmpty && present.get() == "x");
    assert(absent.isEmpty && absent.orElse("y") == "y" && absent.orElseGet(() => "z") == "z");
    assert(Optional!string.ofNullable(null).isEmpty);
    assert(present.map!size_t((string s) => s.length).get() == 1);
    assert(present.filter((string s) => s == "q").isEmpty);
    assert(present.toString() == "Optional[x]" && absent.toString() == "Optional.empty");
    assert(present == Optional!string.of("x") && absent == Optional!string.empty());
    bool threw;
    try
        absent.get();
    catch (NoSuchElementException e)
        threw = e.getMessage() == "No value present";
    assert(threw);
    threw = false;
    Owner nobody;
    try
        Optional!Owner.of(nobody);
    catch (NullPointerException)
        threw = true;
    assert(threw);
    threw = false;
    try
        absent.orElseThrow(() => new IllegalArgumentException("missing"));
    catch (IllegalArgumentException e)
        threw = e.getMessage() == "missing";
    assert(threw);
    string seen;
    present.ifPresent((string s) { seen = s; });
    assert(seen == "x");
    assert(descriptorOf!(Optional!int).elementType == "int");
}

unittest
{
    // R10: List.
    List!string names = new ArrayList!string();
    assert(names.isEmpty);
    names.add("b");
    names.add("a");
    names.add(0, "c");
    assert(names.size() == 3 && names.get(0) == "c" && names.toString() == "[c, b, a]");
    assert(names.indexOf("a") == 2 && names.contains("b") && !names.contains("z"));
    assert(names.remove("b") && !names.remove("b"));
    assert(names.remove(0) == "c" && names.toArray() == ["a"]);
    names.add("d");
    assert(names.set(1, "e") == "d" && names.getLast() == "e");
    names.sort(null);
    assert(names.toArray() == ["a", "e"]);
    assert(names.equals(new ArrayList!string(["a", "e"])));
    assert(names.hashCode() == new ArrayList!string(["a", "e"]).hashCode());
    assert(new ArrayList!string(["a"]) == new ArrayList!string(["a"]), "== between concrete lists is @safe");
    bool threw;
    try
        names.get(5);
    catch (IndexOutOfBoundsException e)
        threw = e.getMessage() == "Index 5 out of bounds for length 2";
    assert(threw);
    // List.of is unmodifiable.
    auto fixed = List!int.of(3, 1, 2);
    assert(fixed.size() == 3 && fixed.get(0) == 3);
    threw = false;
    try
        fixed.add(4);
    catch (UnsupportedOperationException)
        threw = true;
    assert(threw);
    // List!int uses removeAt for indices; remove(T) removes the element.
    auto numbers = new ArrayList!int([5, 6, 7]);
    assert(numbers.remove(6) && numbers.removeAt(0) == 5 && numbers.toArray() == [7]);
    // foreach and the erased view.
    string joined;
    foreach (n; new ArrayList!string(["x", "y"]))
        joined ~= n;
    assert(joined == "xy");
    RawCollection raw = new ArrayList!int([1, 2]);
    assert(raw.size() == 2 && raw.toAnyArray()[1].get!int == 2 && raw.elementTypeName() == "int" && !raw.isSet());
    raw.addAny(Any.of(3));
    assert((cast(List!int) raw).get(2) == 3);
    assert(descriptorOf!(List!int).elementType == "int");
}

unittest
{
    // Stable sort with comparators.
    auto owners = new ArrayList!Owner([new Owner("Ann", 30), new Owner("Bob", 20), new Owner("Cy", 30)]);
    owners.sort(Comparator!Owner.comparing!int((Owner o) => o.getAge()));
    assert(owners.get(0).getName() == "Bob" && owners.get(1).getName() == "Ann" && owners.get(2).getName() == "Cy");
    owners.sort(Comparator!Owner.comparing!string((Owner o) => o.getName()).reversed());
    assert(owners.get(0).getName() == "Cy");
    Collections.sort!Owner(owners); // natural order (age), stable: Cy stays before Ann
    assert(owners.get(0).getName() == "Bob" && owners.get(1).getName() == "Cy");
    auto byAge = Comparator!Owner.comparing!int((Owner o) => o.getAge()).thenComparing!string((Owner o) => o.getName());
    assert(byAge.compare(owners.get(2), owners.get(1)) < 0); // Ann before Cy at equal age
}

unittest
{
    // Set: no duplicates, insertion order, Java's equals/hashCode.
    auto set = new HashSet!string();
    assert(set.add("b") && set.add("a") && !set.add("b"));
    assert(set.size() == 2 && set.toString() == "[b, a]" && set.contains("a"));
    assert(set.remove("b") && set.toArray() == ["a"]);
    assert(set == new LinkedHashSet!string(["a"]));
    auto it = new LinkedHashSet!int([1, 2, 3]).iterator();
    assert(it.next() == 1);
    bool threw;
    try
        Set!int.of(1, 1);
    catch (IllegalArgumentException)
        threw = true;
    assert(threw);
    threw = false;
    try
        Set!int.of(1).add(2);
    catch (UnsupportedOperationException)
        threw = true;
    assert(threw);
    assert((cast(RawCollection) set).isSet());
}

unittest
{
    // Map: put/get/remove, insertion order, entries writing through, the erased view.
    Map!(string, int) ages = new HashMap!(string, int)();
    assert(ages.put("Ann", 30) == 0 && ages.put("Bob", 20) == 0 && ages.put("Ann", 31) == 30);
    assert(ages.get("Ann") == 31 && ages.get("Zed") == 0 && ages.getOrDefault("Zed", -1) == -1);
    assert(ages.size() == 2 && ages.containsKey("Bob") && ages.containsValue(20));
    assert(ages.toString() == "{Ann=31, Bob=20}");
    assert(ages.keySet().toArray() == ["Ann", "Bob"] && ages.values().toArray() == [31, 20]);
    foreach (entry; ages.entrySet())
        if (entry.getKey() == "Bob")
            entry.setValue(21);
    assert(ages.get("Bob") == 21);
    assert(ages.remove("Ann") == 31 && ages.size() == 1);
    assert(ages.computeIfAbsent("Cy", (string k) => cast(int) k.length) == 2);
    assert(ages.merge("Cy", 10, (int a, int b) => a + b) == 12);
    assert(ages.putIfAbsent("Cy", 99) == 12);
    auto copy = new LinkedHashMap!(string, int)(ages);
    assert(copy.equals(cast(Object) ages) && copy.hashCode() == (cast(HashMap!(string, int)) ages).hashCode());
    auto fixed = Map!(string, int).of("a", 1, "b", 2);
    assert(fixed.get("b") == 2);
    bool threw;
    try
        fixed.put("c", 3);
    catch (UnsupportedOperationException)
        threw = true;
    assert(threw);
    RawMap raw = new HashMap!(string, int)(["k": 7]);
    assert(raw.keysAsAny()[0].get!string == "k" && raw.getAny(Any.of("k")).get!int == 7);
    raw.putAny(Any.of("j"), Any.of(8));
    assert(raw.size() == 2 && raw.keyTypeName() == "string" && raw.valueTypeName() == "int");
    assert(descriptorOf!(Map!(string, int)).keyType == "string");
}

unittest
{
    // R10: streams are lazy and short-circuit in Java's order.
    string[] visited;
    auto first = Stream!string.of("a", "bb", "ccc").peek((string s) { visited ~= s; }).filter(
            (string s) => s.length > 1).findFirst();
    assert(first.get() == "bb" && visited == ["a", "bb"]);
    auto lengths = Stream!string.of("a", "bb", "ccc").map!size_t((string s) => s.length).collect(Collectors.toList());
    assert(lengths.toArray() == [1, 2, 3]);
    assert(Stream!int.of(3, 1, 2).sorted().toArray() == [1, 2, 3]);
    assert(Stream!int.of(1, 2, 2, 3, 1).distinct().count() == 3);
    assert(Stream!int.of(1, 2, 3, 4).skip(1).limit(2).toArray() == [2, 3]);
    assert(Stream!int.of(1, 2, 3).anyMatch((int x) => x == 2) && Stream!int.of(1, 2).allMatch((int x) => x > 0));
    assert(Stream!int.of(1, 2, 3).noneMatch((int x) => x > 5) && Stream!int.empty().allMatch((int x) => false));
    assert(Stream!int.of(1, 2, 3).reduce(0, (int a, int b) => a + b) == 6 && Stream!int.of(4, 5).sum() == 9);
    assert(Stream!int.iterate(1, (int x) => x * 2).limit(5).toArray() == [1, 2, 4, 8, 16]);
    assert(Stream!string.of("x", "y").collect(Collectors.joining(", ", "[", "]")) == "[x, y]");
    assert(Stream!int.of(1, 2).flatMap!int((int x) => Stream!int.of(x, x * 10)).toArray() == [
        1, 10, 2, 20
    ]);
    assert(Stream!int.of(5, 3, 9).max(Comparator!int.naturalOrder()).get() == 9);
}

unittest
{
    // Collectors over objects, and single use.
    auto owners = new ArrayList!Owner([new Owner("Ann", 30), new Owner("Bob", 20), new Owner("Cy", 30)]);
    auto byAge = owners.stream().collect(Collectors.groupingBy((Owner o) => o.getAge()));
    assert(byAge.get(30).size() == 2 && byAge.keySet().toArray() == [30, 20]);
    auto byName = owners.stream().collect(Collectors.toMap((Owner o) => o.getName(), (Owner o) => o.getAge()));
    assert(byName.get("Bob") == 20);
    bool threw;
    try
        owners.stream().collect(Collectors.toMap((Owner o) => o.getAge(), (Owner o) => o.getName()));
    catch (IllegalStateException e)
        threw = e.getMessage() == "Duplicate key 30 (attempted merging values Ann and Cy)";
    assert(threw);
    // A stream is used once.
    auto once = Stream!int.of(1);
    once.count();
    threw = false;
    try
        once.count();
    catch (IllegalStateException)
        threw = true;
    assert(threw);
}

unittest
{
    // R9: functional interfaces adapt to and from delegates.
    auto upper = Function!(string, size_t).of((string s) => s.length);
    assert(upper.apply("abc") == 3 && upper.asDelegate()("ab") == 2);
    auto even = Predicate!int.of((int x) => x % 2 == 0);
    assert(even.test(2) && even.negate().test(3) && even.and(Predicate!int.of((int x) => x > 2)).test(4));
    assert(Supplier!int.of(() => 7).get() == 7);
    assert(Function!(int, int).identity().apply(5) == 5);
}

unittest
{
    // Objects, Collections and Arrays.
    assert(Objects.equals("a", "a") && !Objects.equals("a", "b"));
    Owner nobody;
    assert(Objects.isNull(nobody) && Objects.hash("a", 1) == 31 * (31 + 97) + 1);
    assert(Objects.toString(nobody, "none") == "none");
    bool threw;
    try
        Objects.requireNonNull(nobody, "owner");
    catch (NullPointerException e)
        threw = e.getMessage() == "owner";
    assert(threw);
    auto list = Arrays.asList(1, 2, 3);
    list.set(0, 9);
    assert(list.toArray() == [9, 2, 3]);
    threw = false;
    try
        list.add(4);
    catch (UnsupportedOperationException)
        threw = true;
    assert(threw);
    auto backing = new ArrayList!int([1]);
    auto view = Collections.unmodifiableList!int(backing);
    backing.add(2);
    assert(view.size() == 2);
    assert(Collections.emptyList!int().isEmpty && Collections.singletonList(5).get(0) == 5);
    Collections.reverse!int(backing);
    assert(backing.toArray() == [2, 1]);
}

unittest
{
    // java.io: streams and files.
    auto stream = new ByteArrayInputStream([1, 2, 3]);
    assert(stream.read() == 1 && stream.available() == 2);
    ubyte[4] buffer;
    assert(stream.read(buffer[]) == 2 && buffer[0 .. 2] == [2, 3] && stream.read() == -1);
    assert(new File("/a/b/c.txt").getName() == "c.txt" && new File("/a/b/c.txt").getParent() == "/a/b");
    assert(new File("/a", "b").getPath() == "/a/b" && !new File("/no/such/flint/file").exists());
    bool threw;
    try
        new FileInputStream(new File("/no/such/flint/file"));
    catch (FileNotFoundException e)
        threw = e.getMessage() == "/no/such/flint/file (No such file or directory)";
    assert(threw);
    auto io = new IOException("disk");
    assert(new UncheckedIOException(io).getCause() is io);
    assert(cast(IOException) new FileNotFoundException("x") !is null);
}

unittest
{
    // java.util.Properties: Java's .properties format.
    import flint.java.util : Properties;

    auto defaults = new Properties;
    defaults.setProperty("fallback", "yes");
    auto p = new Properties(defaults);
    p.load("# comment\n! also\nserver.port=8080\nname : Ada Lovelace\nspaced   value\n"
            ~ "multi = one, \\\n    two\nescaped\\ key=a\\tb\\u00e9\n  \nempty=\n");
    assert(p.getProperty("server.port") == "8080" && p.getProperty("name") == "Ada Lovelace");
    assert(p.getProperty("spaced") == "value" && p.getProperty("multi") == "one, two");
    assert(p.getProperty("escaped key") == "a\tbé" && p.getProperty("empty") == "");
    assert(p.getProperty("fallback") == "yes" && p.getProperty("missing", "d") == "d");
    assert(p.stringPropertyNames().size() == 7);
    bool threw;
    try
        new Properties().load("bad=\\u12x4");
    catch (IllegalArgumentException e)
        threw = e.getMessage() == "Malformed \\uxxxx encoding.";
    assert(threw);
}

unittest
{
    // Map!(string, Any): Spring's Map<String, Object> (model maps, error attributes) is @safe.
    import flint.engine.aot.any : Any;

    Map!(string, Any) model = new LinkedHashMap!(string, Any)();
    model.put("status", Any.of(404));
    model.put("error", Any.of("Not Found"));
    assert(model.get("status").get!int == 404 && model.containsValue(Any.of("Not Found")));
    assert(model.equals(cast(Object) new LinkedHashMap!(string, Any)(model)));
}

unittest
{
    // Descriptor builders over flint:java collections (contract 2 runtime extensions).
    import flint.engine.aot.any : Any;
    import flint.engine.aot.descriptor : descriptorOf;

    auto lists = descriptorOf!(List!int);
    auto built = lists.fromElements([Any.of(1), Any.of(2)]);
    assert(built.get!(List!int).toArray() == [1, 2] && lists.length(built) == 2);
    assert(lists.element(built, 1).get!int == 2);
    auto maps = descriptorOf!(Map!(string, int));
    auto map = maps.fromEntries([Any.of("a")], [Any.of(1)]);
    assert(map.get!(Map!(string, int)).get("a") == 1 && maps.toKeys(map)[0].get!string == "a");
    auto optionals = descriptorOf!(Optional!int);
    auto some = optionals.wrap(Any.of(5));
    assert(some.get!(Optional!int).get() == 5 && optionals.unwrap(some).get!int == 5);
    auto none = optionals.wrap(Any.init);
    assert(optionals.unwrap(none).isNull);
    assert(descriptorOf!(Set!string).fromElements([Any.of("x")]).get!(Set!string).contains("x"));
}

unittest
{
    // java.net.URI, java.nio.charset, atomics, AssertionError and the writers the web layer uses.
    import flint.java.io : ByteArrayOutputStream, PrintWriter, StringWriter;
    import flint.java.lang : AssertionError;
    import flint.java.net : URI;
    import flint.java.nio.charset : Charset, StandardCharsets, UnsupportedCharsetException;
    import flint.java.util.concurrent.atomic : AtomicBoolean, AtomicInteger, AtomicLong;

    auto uri = URI.create("http://localhost:8080/owners/é");
    assert(uri.isAbsolute() && uri.getScheme() == "http");
    assert(uri.toASCIIString() == "http://localhost:8080/owners/%C3%A9");
    assert(!URI.create("/owners").isAbsolute() && URI.create("/a") == URI.create("/a"));
    bool threw;
    try
        URI.create("a b");
    catch (IllegalArgumentException)
        threw = true;
    assert(threw);
    assert(Charset.forName("utf8") == StandardCharsets.UTF_8 && Charset.forName("latin1").name() == "ISO-8859-1");
    threw = false;
    try
        Charset.forName("EBCDIC-x");
    catch (UnsupportedCharsetException e)
        threw = e.getCharsetName() == "EBCDIC-x";
    assert(threw);
    auto counter = new AtomicLong;
    assert(counter.incrementAndGet() == 1 && counter.getAndIncrement() == 1 && counter.get() == 2);
    assert(counter.compareAndSet(2, 10) && counter.addAndGet(5) == 15 && counter.toString() == "15");
    assert(new AtomicInteger(3).incrementAndGet() == 4);
    auto flag = new AtomicBoolean;
    assert(flag.compareAndSet(false, true) && flag.get());
    assert(new AssertionError("expected 2").getMessage() == "expected 2");
    auto text = new StringWriter;
    auto out_ = new PrintWriter(text);
    out_.print("a");
    out_.println(42);
    out_.append("b").write('é');
    assert(text.toString() == "a42\nbé");
    auto bytes = new ByteArrayOutputStream;
    new PrintWriter(bytes).print("hi");
    assert(bytes.toString() == "hi" && bytes.size() == 2);
}

unittest
{
    // List!T of a mutable array type (Java's List<Object[]>) instantiates; distinct compares by value.
    import flint.engine.aot.any : Any;
    import flint.java.util : ArrayList, List;

    List!(Any[]) rows = new ArrayList!(Any[]);
    rows.add([Any.of(1), Any.of("a")]);
    rows.add([Any.of(1), Any.of("a")]);
    rows.add([Any.of(2)]);
    assert(rows.size() == 3 && rows.get(2)[0] == Any.of(2));
    assert(rows.stream().distinct().count() == 2);
    List!(int[]) ints = new ArrayList!(int[]);
    ints.add([1, 2]);
    assert(ints.contains([1, 2]) && ints.indexOf([1, 2]) == 0);
}

unittest
{
    // java.util.Locale: normalization, toString, language tags, constants and the POSIX default.
    import flint.java.util : Locale;

    auto us = Locale("EN", "us");
    assert(us == Locale.US && us.getLanguage() == "en" && us.getCountry() == "US");
    assert(us.toString() == "en_US" && us.toLanguageTag() == "en-US"
            && us.hashCode() == Locale.US.hashCode() && us.equals(Locale.US));
    assert(Locale.ENGLISH.toString() == "en" && Locale.ENGLISH.toLanguageTag() == "en");
    assert(Locale("", "US").toString() == "_US" && Locale.ROOT.toLanguageTag() == "und");
    assert(Locale("de", "DE", "POSIX").toString() == "de_DE_POSIX");
    assert(Locale.forLanguageTag("en-US") == Locale.US && Locale.forLanguageTag("de") == Locale.GERMAN);
    assert(Locale.forLanguageTag("und") == Locale.ROOT && Locale.forLanguageTag("zh-Hant-TW") == Locale("zh", "TW"));
    assert(Locale.forLanguageTag("es-419").getCountry() == "419" && Locale.forLanguageTag("en_US") == Locale.ROOT);
    assert(Locale.forLanguageTag("de-DE-1996").getVariant() == "1996");
    assert(Locale.fromPosix("en_US.UTF-8") == Locale.US && Locale.fromPosix("fr_FR@euro") == Locale.FRANCE);
    assert(Locale.fromPosix("C") == Locale.US && Locale.fromPosix("") == Locale.US
            && Locale.fromPosix("de") == Locale.GERMAN);
    assert(Locale.getDefault().toLanguageTag().length >= 2);
}
