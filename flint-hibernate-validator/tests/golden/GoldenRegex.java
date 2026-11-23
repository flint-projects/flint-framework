// Writes the golden file that framework/hibernate-validator/tests/regex_test.d compares line for line: each case's
// java.util.regex result on JDK 21, Pattern.compile(regex, flags).matcher(input).matches(), or "error" when the
// pattern does not compile. Fields are tab-separated and escaped (backslash t, n, r and backslash, and backslash-u with four hex digits for other controls).
//   javac GoldenRegex.java && java GoldenRegex regex.tsv
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.ArrayList;
import java.util.List;
import java.util.regex.Pattern;
import java.util.regex.PatternSyntaxException;

public class GoldenRegex {
    static final List<String> out = new ArrayList<>();

    static String esc(String s) {
        StringBuilder b = new StringBuilder();
        for (char c : s.toCharArray()) {
            switch (c) {
                case '\t' -> b.append("\\t");
                case '\n' -> b.append("\\n");
                case '\r' -> b.append("\\r");
                case '\\' -> b.append("\\\\");
                default -> {
                    if (c < 0x20 || c == 0x7f) b.append(String.format("\\u%04x", (int) c));
                    else b.append(c);
                }
            }
        }
        return b.toString();
    }

    static void c(String regex, int flags, String... inputs) {
        Pattern p;
        try {
            p = Pattern.compile(regex, flags);
        } catch (PatternSyntaxException e) {
            out.add(esc(regex) + "\t" + flags + "\t\terror");
            return;
        }
        for (String in : inputs)
            out.add(esc(regex) + "\t" + flags + "\t" + esc(in) + "\t" + p.matcher(in).matches());
    }

    static void c(String regex, String... inputs) {
        c(regex, 0, inputs);
    }

    public static void main(String[] args) throws Exception {
        final int I = Pattern.CASE_INSENSITIVE, M = Pattern.MULTILINE, S = Pattern.DOTALL, X = Pattern.COMMENTS,
                D = Pattern.UNIX_LINES;
        // literals, dot, alternation
        c("abc", "abc", "ab", "abcd", "", "ABC");
        c("a.c", "abc", "a\nc", "a\rc", "ac", "a c", "aéc", "a😀c");
        c("a.c", S, "a\nc", "a\rc");
        c("a.c", D, "a\rc", "a\nc");
        c("cat|dog|", "cat", "dog", "", "cats");
        c("(a|ab)(c|bcd)", "abcd", "abc", "acd");
        // classes
        c("[abc]+", "abccba", "abd", "");
        c("[^abc]", "d", "a", "\n", "é");
        c("[a-z0-9_-]+", "a-b_9", "A", "a-");
        c("[-a]", "-", "a", "b");
        c("[a-]", "-", "a");
        c("[]a]", "]", "a");
        c("[^]a]", "b", "]");
        c("[a-z&&[^aeiou]]+", "bcd", "bad", "");
        c("[a-z&&[def]]", "e", "a");
        c("[a-c[x-z]]", "b", "y", "m");
        c("[\\w&&[^\\d]]+", "abc_", "ab1");
        c("[\\[\\]\\\\]+", "[]\\", "a");
        c("[a-c&&b-d]", "b", "c", "a", "d");
        c("[\\x41-\\x43]", "B", "D");
        c("[\\u00e0-\\u00ff]", "é", "e");
        c("[é]", "é", "e");
        c("[z-a]", "a");
        c("[a", "a");
        c("[]", "a");
        c("[^]", "a");
        // predefined classes
        c("\\d+", "0123456789", "١", "a");
        c("\\D", "a", "1");
        c("\\s", " ", "\t", "\n", "\u000b", "\f", "\r", " ", "a");
        c("\\S+", "ab", "a b");
        c("\\w+", "aZ_9", "é", "-");
        c("\\W", "-", "a", "é");
        c("\\h", " ", "\t", " ", " ", "\n");
        c("\\H", "a", " ");
        c("\\v", "\n", "\u000b", " ", " ");
        c("\\V", "a", "\n");
        c("\\R", "\n", "\r\n", "\r", "\u0085", "a");
        c("a\\Rb", "a\r\nb", "a\nb");
        // POSIX and Unicode properties
        c("\\p{Lower}+", "abc", "aBc", "é");
        c("\\p{Upper}", "A", "a", "É");
        c("\\p{Alpha}+", "aZ", "a1");
        c("\\p{Digit}", "5", "a");
        c("\\p{Alnum}+", "a1Z", "a-");
        c("\\p{Punct}+", "!\"#$%&'()*+,-./:;<=>?@[\\]^_`{|}~", "a");
        c("\\p{Space}", " ", "\u000b", "a");
        c("\\p{XDigit}+", "0aF", "g");
        c("\\p{ASCII}+", "a~", "é");
        c("\\p{Blank}", " ", "\t", "\n");
        c("\\p{Cntrl}", "\u0001", "\u007f", "a");
        c("\\p{Graph}+", "a!", "a b");
        c("\\p{Print}+", "a b", "a\tb");
        c("\\p{L}+", "abcÉé漢字", "a1");
        c("\\pL", "x", "1");
        c("\\p{IsL}", "ß", "1");
        c("\\p{IsLetter}", "ж", "!");
        c("\\P{L}", "1", "a");
        c("[\\p{L}\\d]+", "ab12é", "ab-");
        c("[^\\p{L}]", "1", "a");
        c("\\p{Foo}", "a");
        c("\\p{L", "a");
        // petclinic-rest and Hibernate-style patterns
        c("^[\\p{L}]+([ '-][\\p{L}]+){0,2}\\.?$", "George", "Jean-Luc", "O'Neil Jr.", "Mc Donald", "Al--x", "", "Jo1");
        c("^[0-9]{10}$", "6085551023", "608555102", "60855510234", "608555102a");
        c("^[a-zA-Z0-9.!#$%&'*+/=?^_`{|}~-]+@[a-zA-Z0-9-]+(?:\\.[a-zA-Z0-9-]+)*$", "a.b@c.org", "a@b", "a b@c", "@c");
        c("^\\d{4}-\\d{2}-\\d{2}$", "2013-01-01", "2013-1-01");
        c("[{0-9]{1,160}$", "123", "{1", "test", "");
        c("[0-9]{1,300}", "12345678901234567890", "");
        // quantifiers
        c("a*", "", "aaaa", "b");
        c("a+", "", "a", "aa");
        c("a?b", "b", "ab", "aab");
        c("a{3}", "aaa", "aa", "aaaa");
        c("a{2,}", "a", "aa", "aaaaaa");
        c("a{2,3}", "a", "aa", "aaa", "aaaa");
        c("a{0}b", "b", "ab");
        c("(ab){2}", "abab", "ab");
        c("a*?b", "aaab");
        c("a+?", "aaa");
        c("a*+a", "aaa");
        c("a++b", "aab");
        c("(a|b)*+b", "abab");
        c("a?+a", "a", "aa");
        c("a{2,3}?a", "aaa", "aaaa");
        c("a{2,3}+a", "aaa", "aaaa");
        c("(a*)*", "aaa", "");
        c("(a?)+b", "b", "aab");
        c("(a*)+$", "aaaa", "aaab");
        c("x{1,2}{3}", "xxx", "xxxxxx", "xxxxxxx");
        c("a{2,1}", "a");
        c("a{", "a{");
        c("a{1", "a");
        c("a{,2}", "a");
        c("*a", "a");
        c("a**", "a");
        c("a{1}{2}", "aa");
        c("{1}", "a");
        c("x{999999999999}", "x");
        // groups, backreferences, named groups
        c("(a)(b)\\2\\1", "abba", "abab");
        c("(a)\\2", "aa");
        c("(?<first>a)(?<second>b)\\k<second>\\k<first>", "abba", "abab");
        c("\\k<nope>", "a");
        c("(?<1a>a)", "a");
        c("(?:ab)+", "abab", "aba");
        c("(?>a+)b", "aab");
        c("(?>a*)a", "aaa");
        c("((a)|b)+", "ab", "abab");
        c("(a)|\\1", "a", "");
        c("(\\d)(\\d)(\\d)(\\d)(\\d)(\\d)(\\d)(\\d)(\\d)(\\d)\\10", "01234567899", "01234567890");
        c("(a)\\11", "a1", "aa1");
        c("(", "a");
        c(")", "a");
        c("(?", "a");
        c("(?<n>a)(?<n>b)", "ab");
        c("(?i)(a)\\1", "aA", "Aa");
        // look-around
        c("(?=a)a", "a", "b");
        c("(?!a)\\w", "b", "a");
        c("a(?=b)\\w", "ab", "ac");
        c("\\w+(?<=x)", "abx", "abc");
        c("\\w(?<!a)b", "cb", "ab");
        c("(?<=ab|abc)d", "d");
        c(".*(?<=ab|xyz)", "zzab", "zzxyz", "zzaa");
        c("(?<=a+)b", "ab");
        c("(?<=a*)b", "b");
        c("(?<=a{1,3})b", "b");
        c("^(?=.*\\d)(?=.*[a-z])(?=.*[A-Z]).{8,}$", "Passw0rdX", "password1", "PASSWORD1a", "Pa1");
        c("^(?!.*\\.\\.)[a-z.]+$", "a.b.c", "a..b");
        c("(?=(\\w))\\1", "a", "ab");
        c("(?<!^)x", "ax", "x");
        c("^(?:(?!ab).)*$", "aacb", "xaby");
        c("(?<=(a))b\\1", "aba", "abb");
        // anchors and boundaries
        c("^abc$", "abc", "abc\n");
        c("abc$", "abc", "abc\n");
        c("^a$\\n^b$", M, "a\nb", "ab");
        c("a$", M, "a");
        c("(?m)^a$\\n^b$", "a\nb");
        c("\\Aab\\z", "ab");
        c("ab\\Z", "ab", "ab\n");
        c("ab\\Z\\n", "ab\n");
        c("\\bfoo\\b", "foo");
        c(".*\\bfoo\\b.*", "a foo b", "afoob", "é foo", "éfoo");
        c(".*\\Bfoo.*", "afoo", "a foo");
        c("\\Gab", "ab");
        // flags
        c("abc", I, "ABC", "aBc", "abd");
        c("[a-c]+", I, "ABC", "AbD");
        c("é", I, "É", "é");
        c("é", I | Pattern.UNICODE_CASE, "É");
        c("(?i)abc", "ABC");
        c("a(?i)bc", "aBC", "ABC");
        c("a(?i:b)c", "aBc", "aBC");
        c("(?i)a(?-i)b", "Ab", "AB");
        c("(?s).", "\n");
        c("(?x) a b # comment\n c", "abc", "a b c");
        c("a b", X, "ab", "a b");
        c("[a b]+", X, "ab", "a b");
        c("a\\ b", X, "a b");
        c("(?d).", "\r", "\n");
        c("(?q)a", "a");
        c("(?i-s:a.)", "A\n", "Ab");
        c("(?u)é", "é");
        c("(?U)\\w", "é", "a");
        // escapes
        c("\\t\\n\\r\\f\\a\\e", "\t\n\r\f\u0007\u001b");
        c("\\x41\\x{1F600}\\u0042", "A😀B");
        c("\\0101", "A");
        c("\\0377", "ÿ");
        c("\\0400", " 0");
        c("\\cA\\c@", "\u0001\u0000");
        c("\\Qa.b*\\E+", "a.b*", "a.b**", "axbb");
        c("\\Qa.b", "a.b");
        c("a\\.b", "a.b", "axb");
        c("\\$\\^\\{\\}\\(\\)\\|\\?\\*\\+", "$^{}()|?*+");
        c("\\y", "y");
        c("\\", "a");
        c("\\x4", "a");
        c("\\u004", "a");
        c("\\N{LATIN SMALL LETTER A}", "a");
        c("é+", "éé", "e");
        c("😀{2}", "😀😀", "😀");
        c("[😀-😂]", "😁", "😃");
        c("a\\u0300", "à");
        // catastrophic shapes that still finish on short inputs
        c("(a+)+b", "aaaaaaaaaaaaaaaaaaab", "aaaaaaaaaaaaaaa");
        c("(x+x+)+y", "xxxxxxxxxxy", "xxxxxxxxxx");
        Files.write(Path.of(args[0]), out, StandardCharsets.UTF_8);
        System.out.println(out.size() + " cases");
    }
}
