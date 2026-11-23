// Writes tests/golden/javatime.tsv, which framework/jackson-databind/tests/javatime_test.d compares: Jackson 3.1.8's
// java.time support (tools.jackson.databind.ext.javatime) under Spring Boot 4.2's default mapper, with the
// timestamp features switched on, with @JsonFormat patterns, and when reading (the value's toString() or "!" and
// the exception's original message). Each line is `kind<TAB>case<TAB>input<TAB>result`.
//   javac -cp 'jars/*' GoldenJavaTime.java && java -cp 'jars/*:.' GoldenJavaTime javatime.tsv
import java.nio.file.Files;
import java.nio.file.Path;
import java.time.*;
import java.util.ArrayList;
import java.util.List;
import com.fasterxml.jackson.annotation.JsonFormat;
import tools.jackson.core.JacksonException;
import tools.jackson.databind.cfg.DateTimeFeature;
import tools.jackson.databind.json.JsonMapper;

public class GoldenJavaTime {
    static final List<String> lines = new ArrayList<>();

    public static class Event {
        public LocalDate date = LocalDate.of(2010, 9, 7);
        public LocalTime time = LocalTime.of(14, 5, 9, 120_000_000);
        public LocalDateTime when = LocalDateTime.of(2010, 9, 7, 14, 5);
        public Instant instant = Instant.ofEpochSecond(1_700_000_000L, 5_000_000);
        public OffsetDateTime offset = OffsetDateTime.of(2010, 9, 7, 14, 5, 9, 0, ZoneOffset.ofHours(2));
        public ZonedDateTime zoned = ZonedDateTime.of(2010, 9, 7, 14, 5, 9, 0, ZoneId.of("UTC"));
        public Duration timeout = Duration.ofSeconds(90);
        public ZoneOffset zoneOffset = ZoneOffset.ofHours(-5);
        public ZoneId zone = ZoneId.of("UTC");
    }

    public static class Formatted {
        @JsonFormat(pattern = "dd/MM/yyyy") public LocalDate date = LocalDate.of(2010, 9, 7);
        @JsonFormat(pattern = "yyyy-MM-dd HH:mm:ss") public LocalDateTime when = LocalDateTime.of(2010, 9, 7, 14, 5, 9);
        @JsonFormat(pattern = "HH:mm") public LocalTime time = LocalTime.of(14, 5, 9);
        @JsonFormat(pattern = "yyyy-MM-dd'T'HH:mm:ss.SSSXXX") public OffsetDateTime offset =
            OffsetDateTime.of(2010, 9, 7, 14, 5, 9, 120_000_000, ZoneOffset.ofHours(2));
        @JsonFormat(shape = JsonFormat.Shape.NUMBER) public LocalDate epochDay = LocalDate.of(2010, 9, 7);
        @JsonFormat(shape = JsonFormat.Shape.STRING) public Duration asString = Duration.ofMillis(1500);
    }

    static void write(JsonMapper mapper, String name, Object value) {
        String result;
        try {
            result = mapper.writeValueAsString(value);
        } catch (JacksonException e) {
            result = "!" + e.getOriginalMessage();
        }
        lines.add("write\t" + name + "\t-\t" + result);
    }

    static void read(JsonMapper mapper, String mode, Class<?> type, String json) {
        String result;
        try {
            Object v = mapper.readValue(json, type);
            if (v instanceof Event e) {
                result = e.date + " " + e.time + " " + e.when + " " + e.instant + " " + e.offset + " " + e.zoned + " "
                    + e.timeout + " " + e.zoneOffset + " " + e.zone;
            } else if (v instanceof Formatted f) {
                result = f.date + " " + f.when + " " + f.time + " " + f.offset + " " + f.epochDay + " " + f.asString;
            } else {
                result = String.valueOf(v);
            }
        } catch (JacksonException e) {
            result = "!" + e.getOriginalMessage();
        }
        lines.add("read\t" + mode + ":" + type.getSimpleName() + "\t" + json + "\t" + result);
    }

    public static void main(String[] args) throws Exception {
        JsonMapper boot = JsonMapper.builder().findAndAddModules().build();
        JsonMapper stamps = JsonMapper.builder().findAndAddModules()
            .enable(DateTimeFeature.WRITE_DATES_AS_TIMESTAMPS).build();
        JsonMapper millis = JsonMapper.builder().findAndAddModules()
            .enable(DateTimeFeature.WRITE_DATES_AS_TIMESTAMPS, DateTimeFeature.WRITE_DURATIONS_AS_TIMESTAMPS)
            .disable(DateTimeFeature.WRITE_DATE_TIMESTAMPS_AS_NANOSECONDS).build();
        JsonMapper durations = JsonMapper.builder().findAndAddModules()
            .enable(DateTimeFeature.WRITE_DURATIONS_AS_TIMESTAMPS).build();
        JsonMapper zoneIds = JsonMapper.builder().findAndAddModules()
            .enable(DateTimeFeature.WRITE_DATES_WITH_ZONE_ID).build();

        write(boot, "event", new Event());
        write(boot, "formatted", new Formatted());
        write(stamps, "stamps_event", new Event());
        write(millis, "millis_event", new Event());
        write(durations, "durations_event", new Event());
        write(zoneIds, "zone_ids_event", new Event());
        write(stamps, "stamps_time_whole", LocalTime.of(10, 15));
        write(stamps, "stamps_time_seconds", LocalTime.of(10, 15, 30));
        write(stamps, "stamps_datetime_whole", LocalDateTime.of(2013, 1, 1, 9, 30));
        write(stamps, "stamps_instant_whole", Instant.ofEpochSecond(1_700_000_000L));
        write(stamps, "stamps_instant_neg", Instant.ofEpochSecond(-1L, 999_999_999));
        write(millis, "millis_instant_neg", Instant.ofEpochSecond(-1L, 999_999_999));
        write(millis, "millis_time", LocalTime.of(10, 15, 30, 123_456_789));
        write(durations, "durations_neg", Duration.ofMillis(-1500));
        write(durations, "durations_zero", Duration.ZERO);
        write(durations, "durations_nano", Duration.ofNanos(1));
        write(stamps, "stamps_instant_epoch", Instant.EPOCH);
        write(stamps, "stamps_instant_small", Instant.ofEpochSecond(0, 5));
        write(stamps, "stamps_instant_milli", Instant.ofEpochSecond(0, 123_000_000));
        write(stamps, "stamps_instant_big", Instant.ofEpochSecond(253_402_300_800L));
        write(millis, "millis_datetime", LocalDateTime.of(2013, 1, 1, 9, 30, 0, 1_000_000));
        write(millis, "millis_duration_neg", Duration.ofMillis(-1500));
        write(boot, "list", List.of(LocalDate.of(2010, 9, 7), LocalDate.of(2024, 2, 29)));

        String[] types = {"LocalDate", "LocalTime", "LocalDateTime", "Instant", "OffsetDateTime", "ZonedDateTime",
            "Duration", "ZoneOffset", "ZoneId"};
        Class<?>[] classes = {LocalDate.class, LocalTime.class, LocalDateTime.class, Instant.class,
            OffsetDateTime.class, ZonedDateTime.class, Duration.class, ZoneOffset.class, ZoneId.class};
        String[][] inputs = {
            {"\"2010-09-07\"", "[2010,9,7]", "\"2010-09-07T10:15:30\"", "\"\"", "\"2010-13-01\"", "14862", "null",
                "\" 2010-09-07 \"", "true", "{}"},
            {"\"10:15\"", "\"10:15:30.123\"", "[10,15]", "[10,15,30,123000000]", "\"25:00\"", "\"2010-09-07T10:15:30\"",
                "1000"},
            {"\"2010-09-07T10:15:30\"", "\"2010-09-07T10:15\"", "[2013,1,1,9,30]", "[2013,1,1,9,30,5,7000]",
                "\"2010-09-07\"", "\"2010-09-07T10:15:30Z\"", "\"2010-09-07T10:15:30+01:00\"", "\"2010-09-07 10:15\""},
            {"\"2010-09-07T10:15:30Z\"", "\"2010-09-07T10:15:30.5+01:00\"", "1700000000", "1700000000.123456789",
                "-1.000000001", "\"1700000000\"", "1700000000123", "\"2010-09-07T10:15:30\"", "\"x\""},
            {"\"2010-09-07T10:15:30+01:00\"", "\"2010-09-07T10:15:30Z\"", "1700000000.5", "\"2010-09-07T10:15:30\""},
            {"\"2010-09-07T10:15:30+01:00\"", "\"2010-09-07T10:15:30Z[UTC]\"", "\"2010-09-07T10:15:30Z\"",
                "1700000000"},
            {"\"PT1.5S\"", "\"P2DT3H\"", "90", "1.5", "-1.5", "\"90\"", "\"bogus\""},
            {"\"+05:30\"", "\"Z\"", "\"bogus\""},
            {"\"UTC\"", "\"+02:00\"", "\"UTC+2\""},
        };
        for (int i = 0; i < types.length; i++) {
            for (String input : inputs[i]) {
                read(boot, "boot", classes[i], input);
            }
        }
        read(boot, "boot", Event.class, boot.writeValueAsString(new Event()));
        read(boot, "boot", Event.class, stamps.writeValueAsString(new Event()));
        read(boot, "boot", Formatted.class, boot.writeValueAsString(new Formatted()));
        read(boot, "boot", Formatted.class, "{\"date\":\"2010-09-07\"}");
        Files.writeString(Path.of(args[0]), String.join("\n", lines) + "\n");
    }
}
