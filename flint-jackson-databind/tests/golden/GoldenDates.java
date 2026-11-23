// Writes tests/golden/dates.tsv, which framework/jackson-databind/tests/java_util_date_test.d compares: Jackson
// 3.1.8's java.util.Date support (JavaUtilDateSerializer, JavaUtilDateDeserializer, StdDateFormat, and
// SimpleDateFormat for @JsonFormat patterns) under Spring Boot 4.2's default mapper. A case's format is applied as
// the Date config override, which Jackson merges exactly like a property's @JsonFormat:
//   shape=NUMBER;pattern=...;tz=GMT+2;lenient=false;+FEATURE;-FEATURE
// Each line is `write<TAB>format<TAB>millis<TAB>json` or `read<TAB>format<TAB>json<TAB>millis` (and `writekey` and
// `readkey` for a Map<Date, Integer>), a result of "null",
// or "!" and the exception's original message ("!IllegalArgumentException: " and its message for a bad pattern). The JVM locale is en_US, as Flint's English-only names assume.
//   javac -cp 'jars/*' GoldenDates.java && java -cp 'jars/*:.' GoldenDates dates.tsv
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.ArrayList;
import java.util.Date;
import java.util.List;
import java.util.Locale;
import java.util.TimeZone;
import com.fasterxml.jackson.annotation.JsonFormat;
import com.fasterxml.jackson.annotation.OptBoolean;
import tools.jackson.core.JacksonException;
import tools.jackson.databind.DeserializationFeature;
import tools.jackson.databind.cfg.DateTimeFeature;
import tools.jackson.databind.json.JsonMapper;

public class GoldenDates {
    static final List<String> lines = new ArrayList<>();

    static JsonMapper mapper(String format) {
        JsonMapper.Builder b = JsonMapper.builder();
        JsonFormat.Value v = JsonFormat.Value.empty();
        boolean any = false;
        for (String part : format.equals("-") ? new String[0] : format.split(";")) {
            if (part.startsWith("+") || part.startsWith("-")) {
                String name = part.substring(1);
                boolean on = part.startsWith("+");
                try {
                    b.configure(DateTimeFeature.valueOf(name), on);
                } catch (IllegalArgumentException e) {
                    b.configure(DeserializationFeature.valueOf(name), on);
                }
                continue;
            }
            String key = part.substring(0, part.indexOf('='));
            String value = part.substring(part.indexOf('=') + 1);
            any = true;
            switch (key) {
                case "shape" -> v = v.withShape(JsonFormat.Shape.valueOf(value));
                case "pattern" -> v = v.withPattern(value);
                case "tz" -> v = v.withTimeZone(TimeZone.getTimeZone(value));
                case "lenient" -> v = v.withLenient(Boolean.valueOf(value));
                case "locale" -> v = v.withLocale(Locale.forLanguageTag(value));
                default -> throw new IllegalArgumentException(key);
            }
        }
        if (any) {
            final JsonFormat.Value f = v;
            b.withConfigOverride(Date.class, o -> o.setFormat(f));
        }
        return b.build();
    }

    static void write(String format, long... millis) {
        JsonMapper m = mapper(format);
        for (long t : millis) {
            String result;
            try {
                result = m.writeValueAsString(new Date(t));
            } catch (JacksonException e) {
                result = "!" + e.getOriginalMessage();
            } catch (IllegalArgumentException e) {
                result = "!IllegalArgumentException: " + e.getMessage();
            }
            lines.add("write\t" + format + "\t" + t + "\t" + result);
        }
    }

    static void read(String format, String... jsons) {
        JsonMapper m = mapper(format);
        for (String json : jsons) {
            String result;
            try {
                Date d = m.readValue(json, Date.class);
                result = d == null ? "null" : Long.toString(d.getTime());
            } catch (JacksonException e) {
                result = "!" + e.getOriginalMessage();
            } catch (IllegalArgumentException e) {
                result = "!IllegalArgumentException: " + e.getMessage();
            }
            lines.add("read\t" + format + "\t" + json + "\t" + result);
        }
    }

    static void writeKey(String format, long millis) {
        JsonMapper m = mapper(format);
        java.util.Map<Date, Integer> map = new java.util.HashMap<>();
        map.put(new Date(millis), 1);
        lines.add("writekey\t" + format + "\t" + millis + "\t" + m.writeValueAsString(map));
    }

    static void readKey(String... jsons) {
        JsonMapper m = mapper("-");
        for (String json : jsons) {
            String result;
            try {
                java.util.Map<Date, Integer> map = m.readValue(json,
                    new tools.jackson.core.type.TypeReference<java.util.Map<Date, Integer>>() {});
                result = Long.toString(map.keySet().iterator().next().getTime());
            } catch (JacksonException e) {
                result = "!" + e.getOriginalMessage();
            }
            lines.add("readkey\t-\t" + json + "\t" + result);
        }
    }

    static String q(String s) {
        return "\"" + s + "\"";
    }

    public static void main(String[] args) throws Exception {
        Locale.setDefault(Locale.US);
        TimeZone.setDefault(TimeZone.getTimeZone("UTC"));
        final long[] instants = {
            0L, -1L, 1L, 999L, 1_000L, 1_234_567_890_123L, 1_700_000_000_005L, 1_795_100_510_000L, -86_400_000L,
            951_782_400_000L, // 2000-02-29
            4_107_542_399_999L, // 2100-02-28T23:59:59.999
            -62_135_596_800_000L, // 0001-01-01 Gregorian, which Java shows in the Julian calendar
            -12_219_292_800_000L, // 1582-10-15, the Gregorian cutover
            -12_219_292_800_001L, // the millisecond before: 1582-10-04T23:59:59.999 Julian
            -30_610_224_000_000L, // 1000-01-01 Gregorian
            -62_198_755_200_000L, -62_167_219_200_000L, -63_808_128_000_000L, -70_000_000_000_000L,
            253_402_300_799_999L, 253_402_300_800_000L, 3_833_727_545_600_000L, 1_000_000_000_000_000L,
        };
        write("-", instants);
        write("+WRITE_DATES_AS_TIMESTAMPS", 0L, -1L, 1_234_567_890_123L, Long.MAX_VALUE, Long.MIN_VALUE);
        write("+WRITE_DATE_TIMESTAMPS_AS_NANOSECONDS;+WRITE_DATES_AS_TIMESTAMPS", 1_234_567_890_123L);
        write("shape=NUMBER", 0L, 1_234_567_890_123L);
        write("shape=NUMBER_INT", 1_234_567_890_123L);
        write("shape=STRING", 1_234_567_890_123L);
        write("shape=STRING;+WRITE_DATES_AS_TIMESTAMPS", 1_234_567_890_123L);
        write("shape=ANY;+WRITE_DATES_AS_TIMESTAMPS", 1_234_567_890_123L);
        write("tz=GMT+2", 0L, 1_234_567_890_123L, -62_135_596_800_000L);
        write("tz=GMT-05:30", 0L, 1_234_567_890_123L);
        write("tz=GMT+0530", 0L);
        write("tz=GMT+14", 0L);
        write("tz=UTC", 0L);
        write("tz=GMT", 0L);
        write("tz=GMT+00:00", 0L);
        write("tz=GMT+2;+WRITE_DATES_AS_TIMESTAMPS", 0L);
        write("pattern=yyyy-MM-dd;+WRITE_DATES_AS_TIMESTAMPS", 0L);
        write("shape=NUMBER;pattern=yyyy-MM-dd", 0L);
        final long[] sample = {
            1_234_567_890_123L, 0L, -1L, 1_700_000_000_005L, 1_795_100_510_000L, 951_782_400_000L,
            -62_135_596_800_000L, -62_198_755_200_000L, -12_219_292_800_001L, 253_402_300_800_000L,
            1_293_753_600_000L, // 2010-12-31: week-of-year 1 of 2011 in en_US
            1_262_304_000_000L, // 2010-01-01
        };
        for (String pattern : new String[] {
            "yyyy-MM-dd", "yyyy-MM-dd'T'HH:mm:ss.SSSXXX", "yyyy-MM-dd HH:mm:ss.SSS", "EEE, dd MMM yyyy HH:mm:ss zzz",
            "EEEE MMMM d yy h:mm a", "yyyyy", "y", "yy", "yyy", "yyyyyyy", "M", "MM", "MMM", "MMMM", "MMMMM", "L", "LL",
            "LLL", "LLLL", "d", "dd", "D", "DD", "DDD", "E", "EEEE", "EEEEE", "u", "uu", "F", "w", "ww", "W", "Y", "YY",
            "YYYY", "H", "HH", "k", "kk", "K", "KK", "h", "hh", "m", "mm", "s", "ss", "S", "SS", "SSS", "SSSS", "z",
            "zzzz", "Z", "ZZZZ", "X", "XX", "XXX", "G", "GGGG", "a", "aaaa", "''", "'o''clock' h", "yyyyMMddHHmmss",
            "dd/MM/yyyy", "yyyy.MM.dd G 'at' HH:mm:ss z", "EEE, MMM d, ''yy", "hh 'o''clock' a, zzzz",
            "K:mm a, z", "yyMMddHHmmssZ", "yyyy-MM-dd'T'HH:mm:ss.SSSZ", "YYYY-'W'ww-u",
        }) {
            write("pattern=" + pattern, sample);
        }
        write("pattern=yyyy-MM-dd'T'HH:mm:ss.SSSXXX;tz=GMT+05:30", 1_234_567_890_123L, 0L);
        write("pattern=HH:mm z;tz=GMT-8", 0L);
        write("pattern=HH:mm zzzz;tz=GMT-8", 0L);
        write("pattern=HH:mm Z X XX XXX;tz=GMT-8", 0L);
        write("pattern=HH:mm Z X XX XXX;tz=GMT+05:30", 0L);
        write("pattern=HH:mm z zzzz;tz=UTC", 0L);
        write("pattern=yyyy-MM-dd'T'HH:mm:ss.SSSX;tz=GMT+05:30", 0L);
        write("pattern=yyyy-MM-dd;locale=en-GB", 0L);
        write("pattern=q", 0L);
        write("pattern=yyyy-MM-dd'T", 0L);
        write("pattern=EEE;locale=fr", 0L);
        write("pattern=yyyy-MM-dd;locale=fr", 0L);

        read("-", "0", "-1", "1234567890123", "9223372036854775807", "9223372036854775808", "-9223372036854775809",
            "1.5", "1e3", "true", "false", "null", "{}", "[]", "[1]", "[\"1970-01-01\"]", "[[1]]", "[1,2]",
            q(""), q(" "), q("null"), q("NULL"), q("  1234  "), q("1234"), q("-1234"), q("+1234"),
            q("1234567890123456789012"), q("-"), q("1972-12-28"), q("1972-12-28T00:00:00.000+0000"),
            q("1972-12-28T00:00:00.000Z"), q("1972-12-28T00:00:00.000+00:00"), q("1972-12-28T00:00:00.000+00"),
            q("2014-10-03T18:00:00.6-05:00"), q("2014-10-03T18:00:00.61-05:00"), q("1997-07-16T19:20:30.45+01:00"),
            q("1997-07-16T19:20:30.45+0100"), q("1997-07-16T19:20:30.45+01"), q("1997-07-16T19:20:30.45+01:30"),
            q("2014-10-03T18:00:00.3456-05:00"), q("2014-10-03T18:00:00.123456789-05:00"),
            q("2014-10-03T18:00:00.1234567890-05:00"), q("1997-07-16T19:20+01:00"), q("1997-07-16T19:20+0200"),
            q("1997-07-16T19:20+04"), q("1984-11-13T00:00:09"), q("2013-10-31T17:27:00"), q("2010-06-28T23:34:22Z"),
            q("2010-06-28T23:34:22+0000"), q("2010-06-28T23:34:22+00:00"), q("2010-06-28T23:34:22+00"),
            q("2010-06-28T23:34:22.Z"), q("2010-06-28T23:34"), q("2010-06-28T23:34Z"), q("2010-06-28T23"),
            q("2010-06-28 23:34:22"), q("2010-06-28T23:34:22z"), q("2010-06-28T23:34:22+1"),
            q("2010-06-28T23:34:22+01:3"), q("2010-13-45T25:61:61.000Z"), q("2010-02-30"), q("2010-00-00"),
            q("2010-1-01"), q("2010-01-1"), q("201-01-01"), q("20100-01-01"), q("+20100-01-01T00:00:00Z"),
            q("+2010-01-01T00:00:00Z"), q("-2010-01-01T00:00:00Z"), q("+0000-01-01T00:00:00Z"),
            q("-0001-01-01T00:00:00Z"), q("0001-01-01T00:00:00Z"), q("1582-10-10T00:00:00Z"),
            q("1582-10-15T00:00:00Z"), q("1000-03-01"), q("2010-06-28foo"), q("2010-06-28T23:34:22.000Zfoo"),
            q("1970-01-01T00:00:00.000+23:59"), q("1970-01-01T00:00:00.000+99:99"), q("1970-01-01T00:00:00.000-00:30"),
            q("Sat, 17 Jan 2009 06:13:58 +0000"), q("Sat, 17 Jan 2009 06:13:58 GMT"),
            q("Sat, 17 Jan 2009 06:13:58 UTC"), q("Sat, 17 Jan 2009 06:13:58 GMT+02:00"),
            q("Sat, 17 Jan 2009 06:13:58 -0130"), q("Sat, 17 Jan 2009 06:13:58 GMT trailing"),
            q("Saturday, 17 January 2009 06:13:58 GMT"), q("sat, 17 jan 2009 06:13:58 gmt"),
            q("Mon, 17 Jan 2009 06:13:58 GMT"), q("Sat, 7 Jan 09 6:3:8 GMT"), q("Sat, 32 Jan 2009 06:13:58 GMT"),
            q("Sat, 17 Foo 2009 06:13:58 GMT"), q("Sat, 17 Jan 2009 06:13:58"), q("Sat, 17 Jan 2009 06:13:58 Z"),
            q("Sat,17 Jan 2009 06:13:58 GMT"), q("Sat, 17 Jan 2009 06:13:58 +02"), q("foobar"), q("12:00"),
            q("1972"), q("1972-12"), q("1972-12-28T"), q("19721228"), q("1234567"), q("-1234567"), q("+123456"),
            q("+-123456789012"), q("1970-01-01T00:00:00.000Z "), q("\\t1970-01-01T00:00:00.000Z\\n"));
        read("+UNWRAP_SINGLE_VALUE_ARRAYS", "[1]", "[\"1970-01-01\"]", "[[1]]", "[1,2]", "[]", "[null]");
        read("+ACCEPT_EMPTY_ARRAY_AS_NULL_OBJECT", "[]", "[1]");
        read("+ACCEPT_EMPTY_STRING_AS_NULL_OBJECT", q(""));
        read("+READ_DATE_TIMESTAMPS_AS_NANOSECONDS", "1234567890123");
        read("tz=GMT-2", q("1970-01-01T00:00:00.000"), q("1970-01-01T00:00:00.000-02:00"),
            q("1970-01-01T00:00:00.000Z"), q("1970-01-01"), q("Sat, 17 Jan 2009 06:13:58"),
            q("Sat, 17 Jan 2009 06:13:58 GMT"), q("1234"));
        read("tz=GMT+05:30", q("1970-01-01T00:00:00"), q("1970-01-01"));
        read("lenient=false", q("2010-13-45T25:61:61.000Z"), q("2010-02-30"), q("2010-02-28"),
            q("2010-06-28T23:34:22Z"), q("2010-12-31T23:59:60Z"), q("2010-00-01"), q("2010-01-00"),
            q("Sat, 32 Jan 2009 06:13:58 GMT"), q("Mon, 17 Jan 2009 06:13:58 GMT"), q("Sat, 17 Jan 2009 06:13:58 GMT"),
            q("1582-10-10T00:00:00Z"));
        read("lenient=true", q("2010-13-45T25:61:61.000Z"));
        read("pattern=/yyyy/MM/dd/", q("/2005/05/25/"), q("/2005/5/25/"), q("2005/05/25"), q("/2005/05/25/x"),
            q("/2005/13/45/"), q("/05/05/25/"), q(""), q("  /2005/05/25/  "), q("null"), "12345", "[]",
            q("/2005/05/25"));
        read("pattern=/yyyy/MM/dd/;lenient=false", q("/2005/13/45/"), q("/2005/02/29/"), q("/2004/02/29/"));
        read("pattern=yyyy-MM-dd,HH;tz=GMT+1", q("2005-05-25,12"));
        read("pattern=yyyyMMddHHmmss", q("20050525123456"), q("2005052512345"), q("200505251234567"));
        read("pattern=yyyy-MM-dd HH:mm:ss.SSS", q("1970-01-01 00:00:00.000"), q("1970-01-01 00:00:00.5"),
            q("1970-01-01 00:00:00.1234"), q("1970-01-01 00:00:00"));
        read("pattern=dd/MM/yy", q("25/05/05"), q("25/05/30"), q("25/05/60"), q("25/05/2005"), q("25/05/5"),
            q("25/05/105"));
        read("pattern=dd/MM/y", q("25/05/05"), q("25/05/2005"), q("25/05/5"));
        read("pattern=EEE, dd MMM yyyy HH:mm:ss zzz", q("Sat, 17 Jan 2009 06:13:58 GMT"),
            q("Saturday, 17 January 2009 06:13:58 GMT"), q("Sat, 17 Jan 2009 06:13:58 +0100"),
            q("Sat, 17 Jan 2009 06:13:58 GMT-03:00"), q("Sat, 17 Jan 2009 06:13:58 UTC"),
            q("Sat, 17 jan 2009 06:13:58 Coordinated Universal Time"), q("Sat, 17 Jan 2009 06:13:58 Greenwich Mean Time"));
        read("pattern=yyyy-MM-dd'T'HH:mm:ss.SSSXXX", q("2009-01-17T06:13:58.123+01:00"), q("2009-01-17T06:13:58.123Z"),
            q("2009-01-17T06:13:58.123+0100"), q("2009-01-17T06:13:58.123+01"));
        read("pattern=yyyy-MM-dd'T'HH:mm:ss.SSSX", q("2009-01-17T06:13:58.123+01"), q("2009-01-17T06:13:58.123Z"),
            q("2009-01-17T06:13:58.123+01:00"));
        read("pattern=yyyy-MM-dd'T'HH:mm:ss.SSSZ", q("2009-01-17T06:13:58.123+0100"), q("2009-01-17T06:13:58.123-0130"),
            q("2009-01-17T06:13:58.123GMT+01:00"), q("2009-01-17T06:13:58.123Z"));
        read("pattern=h:mm a", q("1:05 PM"), q("12:05 AM"), q("12:05 pm"), q("13:05 PM"), q("1:05"));
        read("pattern=K:mm a", q("0:05 PM"), q("11:05 AM"));
        read("pattern=kk:mm", q("24:05"), q("01:05"));
        read("pattern=MMMM d, yyyy", q("January 5, 2009"), q("Jan 5, 2009"), q("jAnUaRy 5, 2009"), q("Janu 5, 2009"));
        read("pattern=MMM d, yyyy", q("January 5, 2009"), q("Sep 5, 2009"));
        read("pattern=D yyyy", q("60 2008"), q("366 2009"));
        read("pattern=yyyy 'W'ww", q("2009 W10"));
        read("pattern=G yyyy-MM-dd", q("AD 2009-01-05"), q("BC 0044-03-15"), q("Anno Domini 2009-01-05"));
        read("pattern=yyyy-MM-dd 'at' HH", q("2009-01-05 at 10"), q("2009-01-05 AT 10"));
        read("pattern=yyyy''MM", q("2009'01"));
        read("pattern=S", q("5"), q("1500"));
        read("pattern=yyyy-MM-dd;tz=GMT+2", q("2009-01-05"));
        read("pattern=q", q("x"));

        writeKey("-", 0L);
        writeKey("-", 1_234_567_890_123L);
        writeKey("+WRITE_DATE_KEYS_AS_TIMESTAMPS", 1_234_567_890_123L);
        readKey("{\"0\":1}", "{\"1970-01-01T00:00:00.000Z\":1}", "{\"2009-02-13T23:31:30.123+01:00\":1}",
            "{\"foo\":1}");

        Files.write(Path.of(args[0]), lines);
    }
}
