/++
`org.springframework.web.util.pattern`: parsed URI path patterns, matched segment by segment.

Ported from spring-projects/spring-framework v7.1.0,
spring-web/src/main/java/org/springframework/web/util/pattern/ (PathPattern.java, PathPatternParser.java,
PatternParseException.java and the path elements) and spring-web/src/main/java/org/springframework/http/server/
PathContainer.java.
Copyright 2002-present the original author or authors.
Licensed under the Apache License, Version 2.0 (https://www.apache.org/licenses/LICENSE-2.0).
Modified by the Flint authors: Spring's linked list of path elements becomes one array of segment matchers with
the same element kinds, scores and normalized lengths, so matching, variable extraction and
`SPECIFICITY_COMPARATOR` order are Spring's. Matching runs on decoded segment values with matrix variables
removed, as `PathContainer.parsePath` does. Index arithmetic is on UTF-8 bytes (R14). Not yet ported:
`{name:regex}` captures and `*`/`?` inside a literal segment (Phase 1 applications use neither); the parser
rejects them with `PatternParseException`.
+/
module flint.web.util.pattern;

import flint.java.lang : IllegalArgumentException;

@safe:

/// `PatternParseException`: a pattern that cannot be parsed.
class PatternParseException : IllegalArgumentException
{
    private size_t position;
    private string pattern;

    ///
    this(size_t position, string pattern, string message, string file = __FILE__, size_t line = __LINE__) pure nothrow
    {
        super(message, null, file, line);
        this.position = position;
        this.pattern = pattern;
    }

    /// The position of the problem in the pattern, in UTF-8 bytes (R14).
    size_t getPosition() const pure nothrow @nogc
    {
        return position;
    }

    /// The pattern.
    string getPatternString() const pure nothrow @nogc
    {
        return pattern;
    }
}

/// `PathPattern.PathMatchInfo`: the URI variables of a match (and matrix variables, empty in this port).
struct PathMatchInfo
{
    private string[] names;
    private string[] values;

    /// The variables in pattern order.
    string[2][] getUriVariables() const pure nothrow
    {
        string[2][] result;
        foreach (i, name; names)
            result ~= [name, values[i]];
        return result;
    }

    /// The value of variable `name`, or `null`.
    string getUriVariable(scope const(char)[] name) const pure nothrow @nogc
    {
        foreach (i, candidate; names)
            if (candidate == name)
                return values[i];
        return null;
    }

    /// The variable names in pattern order.
    const(string)[] getUriVariableNames() const pure nothrow @nogc
    {
        return names;
    }
}

private enum ElementKind : ubyte
{
    literal, // a fixed segment
    capture, // {name}
    wildcard, // *
    wildcardSegments, // ** (only last)
    captureSegments // {*name} (only last)
}

private struct Element
{
    ElementKind kind;
    string text; // literal text or variable name
}

/// `PathPattern`: a parsed path pattern such as `/owners/{ownerId}/pets/{petId}`.
final class PathPattern
{
    private enum int CAPTURE_VARIABLE_WEIGHT = 1;
    private enum int WILDCARD_WEIGHT = 100;

    private string patternString;
    private Element[] elements;
    private bool leadingSeparator;
    private bool trailingSeparator;
    private int score;
    private int normalizedLength;
    private int capturedVariableCount;
    private bool catchAll;

    private this(string patternString) pure nothrow
    {
        this.patternString = patternString;
    }

    /// The pattern text as given.
    string getPatternString() const pure nothrow @nogc
    {
        return patternString;
    }

    /// Whether the pattern has wildcards or captures (`isPattern()` in Java).
    bool hasPatternSyntax() const pure nothrow @nogc
    {
        return score > 0 || catchAll;
    }

    /// Whether `path` (an encoded request path, without query) matches.
    bool matches(string path) const
    {
        const parsed = PathContainer.parsePath(path);
        return matches(parsed);
    }

    /// Whether the parsed `path` matches; a request parses its path once for every pattern
    /// (`ServletRequestPathUtils.parseAndCache`).
    package(flint) bool matches(scope const ref PathContainer path) const
    {
        string[][2] captured;
        return match(path, false, captured);
    }

    /// The URI variables when `path` matches, else `null` (R5).
    PathMatchInfo* matchAndExtract(string path) const
    {
        const parsed = PathContainer.parsePath(path);
        return matchAndExtract(parsed);
    }

    /// ditto
    package(flint) PathMatchInfo* matchAndExtract(scope const ref PathContainer path) const
    {
        string[][2] captured;
        if (!match(path, true, captured))
            return null;
        auto info = new PathMatchInfo;
        info.names = captured[0];
        info.values = captured[1];
        return info;
    }

    private bool match(scope const ref PathContainer segments, bool extract, ref string[][2] captured) const
    {
        if (elements.length == 0)
        {
            // "" and "/" match only an empty path or a lone separator.
            return segments.segments.length == 0 || (segments.segments.length == 1 && segments.segments[0].length == 0);
        }
        if (segments.raw.length == 0)
        {
            if (elements[0].kind == ElementKind.wildcardSegments || elements[0].kind == ElementKind.captureSegments)
            {
                if (extract && elements[0].kind == ElementKind.captureSegments)
                {
                    captured[0] ~= elements[0].text;
                    captured[1] ~= "";
                }
                return true;
            }
            return false;
        }
        if (leadingSeparator != segments.leadingSeparator)
            return false;
        size_t i;
        foreach (index, element; elements)
        {
            final switch (element.kind)
            {
            case ElementKind.literal:
                if (i >= segments.segments.length || segments.segments[i] != element.text)
                    return false;
                i++;
                break;
            case ElementKind.capture:
                if (i >= segments.segments.length || segments.segments[i].length == 0)
                    return false;
                if (extract)
                {
                    captured[0] ~= element.text;
                    captured[1] ~= segments.segments[i];
                }
                i++;
                break;
            case ElementKind.wildcard:
                if (i >= segments.segments.length || segments.segments[i].length == 0)
                    return false;
                i++;
                break;
            case ElementKind.wildcardSegments:
                return true;
            case ElementKind.captureSegments:
                if (extract)
                {
                    string rest;
                    foreach (segment; segments.segments[i .. $])
                        rest ~= "/" ~ segment;
                    captured[0] ~= element.text;
                    captured[1] ~= rest;
                }
                return true;
            }
        }
        // Every element matched: the path must have no further segments, and agree on a trailing separator.
        if (i == segments.segments.length)
            return true;
        return false;
    }

    /// Spring's `compareTo`: specificity, then the pattern text.
    int compareTo(const PathPattern other) const pure nothrow @nogc
    {
        const result = compareSpecificity(this, other);
        if (result != 0 || other is null)
            return result;
        return patternString < other.patternString ? -1 : patternString > other.patternString ? 1 : 0;
    }

    /// `PathPattern.SPECIFICITY_COMPARATOR`: nulls last, catch-all last, lower score first, longer first.
    static int compareSpecificity(const PathPattern a, const PathPattern b) pure nothrow @nogc
    {
        if (a is null || b is null)
            return a is null ? (b is null ? 0 : 1) : -1;
        int compare(int x, int y)
        {
            return x < y ? -1 : x > y ? 1 : 0;
        }

        int r = compare(a.catchAll ? 1 : 0, b.catchAll ? 1 : 0);
        if (r != 0)
            return r;
        r = compare(a.catchAll ? -a.normalizedLength : 0, b.catchAll ? -b.normalizedLength : 0);
        if (r != 0)
            return r;
        r = compare(a.score, b.score);
        if (r != 0)
            return r;
        return compare(-a.normalizedLength, -b.normalizedLength);
    }

    /// Spring's `combine`: `/owners` + `/{id}` → `/owners/{id}`.
    PathPattern combine(const PathPattern pattern2) const
    {
        if (patternString.length == 0)
            return pattern2.patternString.length == 0 ? new PathPatternParser()
                .parse("") : new PathPatternParser().parse(pattern2.patternString);
        if (pattern2.patternString.length == 0)
            return new PathPatternParser().parse(patternString);
        string left = patternString;
        if (left.length >= 3 && left[$ - 3 .. $] == "/**")
            left = left[0 .. $ - 3];
        else if (left.length >= 2 && left[$ - 2 .. $] == "/*")
            left = left[0 .. $ - 2];
        string right = pattern2.patternString;
        const leftSlash = left.length != 0 && left[$ - 1] == '/';
        const rightSlash = right.length != 0 && right[0] == '/';
        string joined = leftSlash && rightSlash ? left ~ right[1 .. $] : !leftSlash && !rightSlash
            ? left ~ "/" ~ right : left ~ right;
        return new PathPatternParser().parse(joined);
    }

    override string toString() const pure nothrow @nogc
    {
        return patternString;
    }

    override bool opEquals(Object other) const
    {
        auto that = cast(const PathPattern) other;
        return that !is null && that.patternString == patternString;
    }

    override size_t toHash() const nothrow
    {
        return hashOf(patternString);
    }

    package(flint) int getScore() const pure nothrow @nogc
    {
        return score;
    }

    package(flint) bool isCatchAll() const pure nothrow @nogc
    {
        return catchAll;
    }

    package(flint) int getCapturedVariableCount() const pure nothrow @nogc
    {
        return capturedVariableCount;
    }
}

/// `PathPatternParser`: parses pattern text into `PathPattern`s.
final class PathPatternParser
{
    /// The shared default instance (Java's `PathPatternParser.defaultInstance`).
    static PathPatternParser defaultInstance() pure nothrow
    {
        return new PathPatternParser;
    }

    /// Parses `pathPattern`. Throws: `PatternParseException`.
    PathPattern parse(string pathPattern) const
    {
        auto pattern = new PathPattern(pathPattern);
        if (pathPattern.length == 0)
            return pattern;
        size_t start;
        if (pathPattern[0] == '/')
        {
            pattern.leadingSeparator = true;
            start = 1;
        }
        // Separators count one each in the normalized length.
        string[] segments = splitSegments(pathPattern[start .. $]);
        const separators = segments.length > 0 ? cast(int) segments.length - 1 : 0;
        pattern.normalizedLength = (pattern.leadingSeparator ? 1 : 0) + separators;
        foreach (index, segment; segments)
        {
            const last = index + 1 == segments.length;
            const position = start + offsetOf(segments, index);
            if (segment == "**")
            {
                if (!last)
                    throw new PatternParseException(position, pathPattern,
                            "No more pattern data allowed after {*...} or ** pattern element");
                pattern.elements ~= Element(ElementKind.wildcardSegments, null);
                pattern.catchAll = true;
                pattern.normalizedLength += 1;
            }
            else if (segment.length >= 3 && segment[0] == '{' && segment[1] == '*' && segment[$ - 1] == '}')
            {
                if (!last)
                    throw new PatternParseException(position, pathPattern,
                            "No more pattern data allowed after {*...} or ** pattern element");
                pattern.elements ~= Element(ElementKind.captureSegments, segment[2 .. $ - 1]);
                pattern.catchAll = true;
                pattern.capturedVariableCount++;
                pattern.normalizedLength += 1;
            }
            else if (segment == "*")
            {
                pattern.elements ~= Element(ElementKind.wildcard, null);
                pattern.score += PathPattern.WILDCARD_WEIGHT;
                pattern.normalizedLength += 1;
            }
            else if (segment.length >= 2 && segment[0] == '{' && segment[$ - 1] == '}')
            {
                const name = segment[1 .. $ - 1];
                foreach (c; name)
                    if (c == ':' || c == '{' || c == '}' || c == '*')
                        throw new PatternParseException(position, pathPattern,
                                "Regular-expression captures are not supported by this port: " ~ segment);
                if (name.length == 0)
                    throw new PatternParseException(position, pathPattern, "Missing variable name");
                foreach (element; pattern.elements)
                    if ((element.kind == ElementKind.capture
                            || element.kind == ElementKind.captureSegments) && element.text == name)
                        throw new PatternParseException(position, pathPattern,
                                "Path pattern contains the same variable name twice: " ~ name);
                pattern.elements ~= Element(ElementKind.capture, name);
                pattern.score += PathPattern.CAPTURE_VARIABLE_WEIGHT;
                pattern.capturedVariableCount++;
                pattern.normalizedLength += 1;
            }
            else
            {
                foreach (c; segment)
                    if (c == '{' || c == '}' || c == '*' || c == '?')
                        throw new PatternParseException(position, pathPattern,
                                "Wildcards and captures inside a literal segment are not supported by this port: "
                                ~ segment);
                pattern.elements ~= Element(ElementKind.literal, PathContainer.decodeSegment(segment));
                pattern.normalizedLength += cast(int) segment.length;
            }
        }
        if (pathPattern.length > 1 && pathPattern[$ - 1] == '/')
            pattern.trailingSeparator = true;
        return pattern;
    }
}

/// `PathContainer`, reduced to what matching needs: decoded segments and separators.
package(flint) struct PathContainer
{
    string raw;
    bool leadingSeparator;
    string[] segments; // decoded, matrix variables removed; "" for an empty segment (e.g. a trailing '/')

    /// Parses an encoded path into decoded segments.
    static PathContainer parsePath(string path) pure
    {
        PathContainer result;
        result.raw = path;
        if (path.length == 0)
            return result;
        size_t start;
        if (path[0] == '/')
        {
            result.leadingSeparator = true;
            start = 1;
        }
        if (start == path.length)
        {
            result.segments = [""];
            return result;
        }
        // One allocation for the segments: count the separators first.
        const rest = path[start .. $];
        size_t count = 1;
        foreach (c; rest)
            if (c == '/')
                count++;
        result.segments = new string[count];
        size_t from, index;
        foreach (i; 0 .. rest.length + 1)
        {
            if (i < rest.length && rest[i] != '/')
                continue;
            auto segment = rest[from .. i];
            from = i + 1;
            // Matrix variables (`;a=b`) are not part of the value matched.
            foreach (j, c; segment)
                if (c == ';')
                {
                    segment = segment[0 .. j];
                    break;
                }
            result.segments[index++] = decodeSegment(segment);
        }
        return result;
    }

    /// Percent-decodes one segment as UTF-8 (R14); `+` stays `+` in paths.
    static string decodeSegment(string segment) pure
    {
        bool encoded;
        foreach (c; segment)
            encoded = encoded || c == '%';
        if (!encoded)
            return segment;
        char[] result;
        for (size_t i = 0; i < segment.length; i++)
        {
            if (segment[i] == '%' && i + 2 < segment.length && isHex(segment[i + 1]) && isHex(segment[i + 2]))
            {
                result ~= cast(char)(hexValue(segment[i + 1]) * 16 + hexValue(segment[i + 2]));
                i += 2;
            }
            else
                result ~= segment[i];
        }
        return result.idup;
    }
}

private string[] splitSegments(string path) pure nothrow
{
    string[] segments;
    size_t start;
    foreach (i, c; path)
    {
        if (c == '/')
        {
            segments ~= path[start .. i];
            start = i + 1;
        }
    }
    segments ~= path[start .. $];
    return segments;
}

private size_t offsetOf(string[] segments, size_t index) pure nothrow @nogc
{
    size_t offset;
    foreach (segment; segments[0 .. index])
        offset += segment.length + 1;
    return offset;
}

private bool isHex(char c) pure nothrow @nogc
{
    return (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f') || (c >= 'A' && c <= 'F');
}

private int hexValue(char c) pure nothrow @nogc
{
    return c <= '9' ? c - '0' : (c | 0x20) - 'a' + 10;
}
