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
 * Modified by the Flint authors: ported from spring-framework v7.1.0, spring-core/src/main/java/org/springframework/util.
 */

/++
`org.springframework.util`: miscellaneous utility classes.
+/
module flint.util;

@safe:

// TEMPORARY STUB (framework-core local only): replaced by the ported flint.util on merge.
import flint.java.lang : IllegalArgumentException, IllegalStateException;

/// stub
struct Assert
{
    /// stub
    static void notNull(T)(T value, string message)
    {
        static if (is(T == class) || is(T == interface) || is(T : const(char)[]))
            if (value is null)
                throw new IllegalArgumentException(message);
    }

    /// stub
    static void hasText(string text, string message)
    {
        if (!StringUtils.hasText(text))
            throw new IllegalArgumentException(message);
    }

    /// stub
    static void hasLength(string text, string message)
    {
        if (text.length == 0)
            throw new IllegalArgumentException(message);
    }

    /// stub
    static void isTrue(bool expression, string message)
    {
        if (!expression)
            throw new IllegalArgumentException(message);
    }

    /// stub
    static void state(bool expression, string message)
    {
        if (!expression)
            throw new IllegalStateException(message);
    }
}

/// stub
struct StringUtils
{
    /// stub
    static bool hasText(string s)
    {
        foreach (c; s)
            if (c != ' ' && c != '\t' && c != '\n' && c != '\r')
                return true;
        return false;
    }

    /// stub
    static bool hasLength(string s)
    {
        return s.length > 0;
    }

    /// stub
    static string[] commaDelimitedListToStringArray(string s)
    {
        import std.array : split;

        return s.length ? s.split(",") : null;
    }

    /// stub
    static string cleanPath(string p)
    {
        return p;
    }

    /// stub
    static string applyRelativePath(string path, string relative)
    {
        size_t slash = path.length;
        foreach_reverse (i, c; path)
            if (c == '/')
            {
                slash = i;
                break;
            }
        if (slash == path.length)
            return relative;
        return path[0 .. slash + 1] ~ (relative.length && relative[0] == '/' ? relative[1 .. $] : relative);
    }

    /// stub
    static string getFilename(string p)
    {
        size_t start;
        foreach (i, c; p)
            if (c == '/')
                start = i + 1;
        return p[start .. $];
    }

    /// stub
    static bool startsWithIgnoreCase(string s, string prefix)
    {
        import std.uni : sicmp;

        return s.length >= prefix.length && sicmp(s[0 .. prefix.length], prefix) == 0;
    }

    /// stub
    static string trimAllWhitespace(string s)
    {
        string r;
        foreach (c; s)
            if (c != ' ' && c != '\t' && c != '\n' && c != '\r')
                r ~= c;
        return r;
    }

    /// stub
    static string trimWhitespace(string s)
    {
        import std.string : strip;

        return s.strip;
    }

    /// stub
    static string[] trimArrayElements(string[] array)
    {
        import std.string : strip;

        string[] result;
        foreach (a; array)
            result ~= a.strip;
        return result;
    }
}

/// stub
interface StringValueResolver
{
    /// stub
    string resolveStringValue(string strVal);
}

/// stub
class PlaceholderResolutionException : IllegalArgumentException
{
    /// stub
    this(string message)
    {
        super(message);
    }
}

/// stub
class PropertyPlaceholderHelper
{
    private string prefix, suffix, separator;
    private bool ignore;

    /// stub
    this(string prefix, string suffix, string separator, char escape, bool ignore)
    {
        this.prefix = prefix;
        this.suffix = suffix;
        this.separator = separator;
        this.ignore = ignore;
    }

    /// stub
    string replacePlaceholders(string value, string delegate(string) @safe resolver)
    {
        import std.string : indexOf;

        for (;;)
        {
            const start = value.indexOf(prefix);
            if (start < 0)
                return value;
            const end = value[start .. $].indexOf(suffix);
            if (end < 0)
                return value;
            auto inner = value[start + prefix.length .. start + end];
            string def;
            bool hasDefault;
            const sep = inner.indexOf(separator);
            if (sep >= 0)
            {
                def = inner[sep + separator.length .. $];
                inner = inner[0 .. sep];
                hasDefault = true;
            }
            auto resolved = resolver(inner);
            if (resolved is null)
                resolved = hasDefault ? def : null;
            if (resolved is null)
            {
                if (ignore)
                    return value;
                throw new PlaceholderResolutionException("Could not resolve placeholder '" ~ inner ~ "' in value \"" ~ value ~ "\"");
            }
            value = value[0 .. start] ~ resolved ~ value[start + end + suffix.length .. $];
        }
    }
}

/// stub
struct NumberUtils
{
    /// stub
    static T parseNumber(T)(string text)
    {
        import std.conv : to;

        return text.to!T;
    }
}
