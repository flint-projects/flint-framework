// Writes the golden file that framework/java/tests/time_test.d compares: java.time formatting with
// DateTimeFormatter (ISO constants and ofPattern), and parsing with the result's toString() or the exception
// message. Each line is `kind<TAB>formatter<TAB>input<TAB>result`.
//   javac GoldenTimeFormat.java && java GoldenTimeFormat time_format.tsv
import java.nio.file.Files;
import java.nio.file.Path;
import java.time.*;
import java.time.format.DateTimeFormatter;
import java.util.ArrayList;
import java.util.List;
import java.util.Locale;
import java.util.function.Function;

public class GoldenTimeFormat {
    static final List<String> lines = new ArrayList<>();

    static DateTimeFormatter formatter(String name) {
        switch (name) {
            case "ISO_LOCAL_DATE": return DateTimeFormatter.ISO_LOCAL_DATE;
            case "ISO_LOCAL_TIME": return DateTimeFormatter.ISO_LOCAL_TIME;
            case "ISO_LOCAL_DATE_TIME": return DateTimeFormatter.ISO_LOCAL_DATE_TIME;
            case "ISO_OFFSET_DATE_TIME": return DateTimeFormatter.ISO_OFFSET_DATE_TIME;
            case "ISO_ZONED_DATE_TIME": return DateTimeFormatter.ISO_ZONED_DATE_TIME;
            case "ISO_DATE_TIME": return DateTimeFormatter.ISO_DATE_TIME;
            case "ISO_DATE": return DateTimeFormatter.ISO_DATE;
            case "ISO_TIME": return DateTimeFormatter.ISO_TIME;
            case "ISO_INSTANT": return DateTimeFormatter.ISO_INSTANT;
            case "BASIC_ISO_DATE": return DateTimeFormatter.BASIC_ISO_DATE;
            default: return DateTimeFormatter.ofPattern(name, Locale.ENGLISH);
        }
    }

    static void format(String name, String kind, Object value) {
        String result;
        try {
            result = formatter(name).format((java.time.temporal.TemporalAccessor) value);
        } catch (RuntimeException e) {
            result = "!" + e.getMessage();
        }
        lines.add("format\t" + name + "\t" + kind + "\t" + result);
    }

    static void parse(String kind, String name, String text) {
        String result;
        try {
            DateTimeFormatter f = formatter(name);
            Object v;
            switch (kind) {
                case "LocalDate": v = LocalDate.parse(text, f); break;
                case "LocalTime": v = LocalTime.parse(text, f); break;
                case "LocalDateTime": v = LocalDateTime.parse(text, f); break;
                case "OffsetDateTime": v = OffsetDateTime.parse(text, f); break;
                case "ZonedDateTime": v = ZonedDateTime.parse(text, f); break;
                case "Instant": v = Instant.parse(text); break;
                case "Duration": v = Duration.parse(text); break;
                case "ZoneOffset": v = ZoneOffset.of(text); break;
                case "ZoneId": v = ZoneId.of(text); break;
                default: throw new IllegalStateException(kind);
            }
            result = v.toString();
        } catch (RuntimeException e) {
            result = "!" + e.getMessage();
        }
        lines.add("parse\t" + kind + "\t" + name + "\t" + text + "\t" + result);
    }

    public static void main(String[] args) throws Exception {
        LocalDate date = LocalDate.of(2010, 9, 7);
        LocalTime time = LocalTime.of(14, 5, 9, 120_000_000);
        LocalDateTime ldt = LocalDateTime.of(date, time);
        OffsetDateTime odt = OffsetDateTime.of(ldt, ZoneOffset.ofHoursMinutes(5, 30));
        OffsetDateTime odtUtc = OffsetDateTime.of(ldt, ZoneOffset.UTC);
        ZonedDateTime zdtUtc = ZonedDateTime.of(ldt, ZoneId.of("UTC"));
        ZonedDateTime zdtPlus = ZonedDateTime.of(ldt, ZoneId.of("UTC+2"));
        Instant instant = odt.toInstant();
        Object[][] values = {
            {"LocalDate", date}, {"LocalTime", time}, {"LocalDateTime", ldt}, {"OffsetDateTime", odt},
            {"OffsetDateTimeUtc", odtUtc}, {"ZonedDateTimeUtc", zdtUtc}, {"ZonedDateTimePlus", zdtPlus},
            {"Instant", instant},
            {"LocalDateBig", LocalDate.of(12345, 1, 2)}, {"LocalDateNeg", LocalDate.of(-44, 3, 15)},
            {"LocalTimeMidnight", LocalTime.MIDNIGHT}, {"LocalTimeNano", LocalTime.of(0, 0, 0, 1)},
        };
        String[] formatters = {
            "ISO_LOCAL_DATE", "ISO_LOCAL_TIME", "ISO_LOCAL_DATE_TIME", "ISO_OFFSET_DATE_TIME", "ISO_ZONED_DATE_TIME",
            "ISO_DATE_TIME", "ISO_DATE", "ISO_TIME", "ISO_INSTANT", "BASIC_ISO_DATE",
            "yyyy-MM-dd", "yyyy-MM-dd HH:mm:ss", "dd/MM/yyyy", "d MMM uuuu", "EEEE, MMMM d, yyyy", "EEE",
            "hh:mm a", "h:mm:ss a", "HH:mm:ss.SSS", "HH:mm:ss.SSSSSS", "yyyyMMddHHmmss", "yy-M-d", "D",
            "yyyy-MM-dd'T'HH:mm:ssXXX", "yyyy-MM-dd'T'HH:mm:ss.SSSZ", "yyyy-MM-dd'T'HH:mm:ssxxx", "HH:mm X",
            "HH:mm XX", "HH:mm x", "'Date:' yyyy 'o''clock' ''", "yyyy-MM-dd[ HH:mm]", "HH:mm[:ss]", "VV", "n",
            "yyyy-MM-dd'T'HH:mm:ss.SSSXXX'['VV']'", "uuuu", "yyyy",
        };
        for (String f : formatters) {
            for (Object[] v : values) {
                format(f, (String) v[0], v[1]);
            }
        }
        parse("LocalDate", "ISO_LOCAL_DATE", "2010-09-07");
        parse("LocalDate", "ISO_LOCAL_DATE", "+12345-01-02");
        parse("LocalDate", "ISO_LOCAL_DATE", "-0044-03-15");
        parse("LocalDate", "ISO_LOCAL_DATE", "2010-13-01");
        parse("LocalDate", "ISO_LOCAL_DATE", "2010-02-30");
        parse("LocalDate", "ISO_LOCAL_DATE", "2023-02-29");
        parse("LocalDate", "ISO_LOCAL_DATE", "2010-9-07");
        parse("LocalDate", "ISO_LOCAL_DATE", "2010-09-07x");
        parse("LocalDate", "ISO_LOCAL_DATE", "12345-01-02");
        parse("LocalDate", "ISO_LOCAL_DATE", "+2010-09-07");
        parse("LocalDate", "ISO_LOCAL_DATE", "");
        parse("LocalDate", "ISO_DATE", "2010-09-07+01:00");
        parse("LocalDate", "BASIC_ISO_DATE", "20100907");
        parse("LocalDate", "dd/MM/yyyy", "07/09/2010");
        parse("LocalDate", "d MMM uuuu", "7 Sep 2010");
        parse("LocalDate", "d MMM uuuu", "7 sep 2010");
        parse("LocalDate", "EEEE, MMMM d, yyyy", "Tuesday, September 7, 2010");
        parse("LocalDate", "EEEE, MMMM d, yyyy", "Monday, September 7, 2010");
        parse("LocalDate", "yyyyMMdd", "20100907");
        parse("LocalDate", "yy-M-d", "10-9-7");
        parse("LocalDate", "yyyy-MM-dd", "2010-09-07 10:15");
        parse("LocalTime", "ISO_LOCAL_TIME", "10:15");
        parse("LocalTime", "ISO_LOCAL_TIME", "10:15:30");
        parse("LocalTime", "ISO_LOCAL_TIME", "10:15:30.1");
        parse("LocalTime", "ISO_LOCAL_TIME", "10:15:30.123456789");
        parse("LocalTime", "ISO_LOCAL_TIME", "10:15:30.1234567891");
        parse("LocalTime", "ISO_LOCAL_TIME", "24:00");
        parse("LocalTime", "ISO_LOCAL_TIME", "10:60");
        parse("LocalTime", "ISO_LOCAL_TIME", "10");
        parse("LocalTime", "ISO_TIME", "10:15:30Z");
        parse("LocalTime", "hh:mm a", "02:05 PM");
        parse("LocalTime", "hh:mm a", "12:05 AM");
        parse("LocalTime", "HH:mm:ss.SSS", "14:05:09.120");
        parse("LocalTime", "HH:mm[:ss]", "14:05");
        parse("LocalTime", "HH", "14");
        parse("LocalDateTime", "ISO_LOCAL_DATE_TIME", "2010-09-07T10:15:30");
        parse("LocalDateTime", "ISO_LOCAL_DATE_TIME", "2010-09-07t10:15");
        parse("LocalDateTime", "ISO_LOCAL_DATE_TIME", "2010-09-07 10:15");
        parse("LocalDateTime", "ISO_LOCAL_DATE_TIME", "2010-09-07");
        parse("LocalDateTime", "ISO_DATE_TIME", "2010-09-07T10:15:30+01:00[UTC]");
        parse("LocalDateTime", "yyyy-MM-dd HH:mm:ss", "2010-09-07 14:05:09");
        parse("LocalDateTime", "yyyyMMddHHmmss", "20100907140509");
        parse("LocalDateTime", "yyyy-MM-dd[ HH:mm]", "2010-09-07");
        parse("LocalDateTime", "yyyy-MM-dd[ HH:mm]", "2010-09-07 14:05");
        parse("OffsetDateTime", "ISO_OFFSET_DATE_TIME", "2010-09-07T10:15:30+01:00");
        parse("OffsetDateTime", "ISO_OFFSET_DATE_TIME", "2010-09-07T10:15:30Z");
        parse("OffsetDateTime", "ISO_OFFSET_DATE_TIME", "2010-09-07T10:15:30z");
        parse("OffsetDateTime", "ISO_OFFSET_DATE_TIME", "2010-09-07T10:15:30+0100");
        parse("OffsetDateTime", "ISO_OFFSET_DATE_TIME", "2010-09-07T10:15:30+01");
        parse("OffsetDateTime", "ISO_OFFSET_DATE_TIME", "2010-09-07T10:15:30-05:30:15");
        parse("OffsetDateTime", "ISO_OFFSET_DATE_TIME", "2010-09-07T10:15:30+19:00");
        parse("OffsetDateTime", "ISO_OFFSET_DATE_TIME", "2010-09-07T10:15:30");
        parse("OffsetDateTime", "yyyy-MM-dd'T'HH:mm:ssXXX", "2010-09-07T14:05:09+05:30");
        parse("OffsetDateTime", "yyyy-MM-dd'T'HH:mm:ss.SSSZ", "2010-09-07T14:05:09.120+0530");
        parse("OffsetDateTime", "yyyy-MM-dd'T'HH:mm:ssxxx", "2010-09-07T14:05:09+00:00");
        parse("ZonedDateTime", "ISO_ZONED_DATE_TIME", "2010-09-07T10:15:30+01:00");
        parse("ZonedDateTime", "ISO_ZONED_DATE_TIME", "2010-09-07T10:15:30Z[UTC]");
        parse("ZonedDateTime", "ISO_ZONED_DATE_TIME", "2010-09-07T10:15:30+01:00[UTC]");
        parse("ZonedDateTime", "ISO_ZONED_DATE_TIME", "2010-09-07T10:15:30+02:00[UTC+02:00]");
        parse("ZonedDateTime", "ISO_DATE_TIME", "2010-09-07T10:15:30+01:00");
        parse("Instant", "ISO_INSTANT", "2010-09-07T10:15:30Z");
        parse("Instant", "ISO_INSTANT", "2010-09-07T10:15:30.5Z");
        parse("Instant", "ISO_INSTANT", "2010-09-07T10:15:30+01:00");
        parse("Instant", "ISO_INSTANT", "2010-09-07T10:15Z");
        parse("Instant", "ISO_INSTANT", "1969-12-31T23:59:59.999999999Z");
        parse("Instant", "ISO_INSTANT", "2010-09-07T10:15:30");
        parse("Duration", "-", "PT20.345S");
        parse("Duration", "-", "PT15M");
        parse("Duration", "-", "PT10H");
        parse("Duration", "-", "P2D");
        parse("Duration", "-", "P2DT3H4M");
        parse("Duration", "-", "PT-6H3M");
        parse("Duration", "-", "-PT6H3M");
        parse("Duration", "-", "-PT-6H+3M");
        parse("Duration", "-", "pt1.5s");
        parse("Duration", "-", "PT-0.5S");
        parse("Duration", "-", "PT0,25S");
        parse("Duration", "-", "PT");
        parse("Duration", "-", "P");
        parse("Duration", "-", "PT1.5M");
        parse("Duration", "-", "1D");
        parse("Duration", "-", "P1H");
        parse("ZoneOffset", "-", "+01:00");
        parse("ZoneOffset", "-", "-0530");
        parse("ZoneOffset", "-", "+5");
        parse("ZoneOffset", "-", "+01:00:30");
        parse("ZoneOffset", "-", "+00:00");
        parse("ZoneOffset", "-", "+19:00");
        parse("ZoneOffset", "-", "+01:60");
        parse("ZoneOffset", "-", "01:00");
        parse("ZoneOffset", "-", "+1:00");
        parse("ZoneId", "-", "UTC");
        parse("ZoneId", "-", "Z");
        parse("ZoneId", "-", "GMT");
        parse("ZoneId", "-", "UTC+2");
        parse("ZoneId", "-", "UTC+0");
        parse("ZoneId", "-", "GMT-05:30");
        parse("ZoneId", "-", "+02:00");
        Files.writeString(Path.of(args[0]), String.join("\n", lines) + "\n");
    }
}
