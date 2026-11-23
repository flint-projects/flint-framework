// Writes the golden file that framework/java/tests/time_test.d and framework/jackson-databind/tests/time_test.d
// compare: for each java.time value, a line `label<TAB>toString()<TAB>Jackson 3.1.8 writeValueAsString`.
//   javac -cp 'jackson-*' GoldenTime.java && java -cp 'jackson-*:.' GoldenTime time.tsv
import java.nio.file.Files;
import java.nio.file.Path;
import java.time.*;
import java.util.ArrayList;
import java.util.List;
import tools.jackson.databind.json.JsonMapper;

public class GoldenTime {
    public static void main(String[] args) throws Exception {
        JsonMapper mapper = JsonMapper.builder().findAndAddModules().build();
        List<Object[]> values = new ArrayList<>();
        values.add(new Object[] {"date", LocalDate.of(2010, 9, 7)});
        values.add(new Object[] {"date_min4", LocalDate.of(1, 1, 1)});
        values.add(new Object[] {"date_leap", LocalDate.of(2024, 2, 29)});
        values.add(new Object[] {"date_big", LocalDate.of(10000, 1, 1)});
        values.add(new Object[] {"date_neg", LocalDate.of(-1, 12, 31)});
        values.add(new Object[] {"time_hm", LocalTime.of(10, 15)});
        values.add(new Object[] {"time_hms", LocalTime.of(10, 15, 30)});
        values.add(new Object[] {"time_milli", LocalTime.of(10, 15, 30, 100_000_000)});
        values.add(new Object[] {"time_milli3", LocalTime.of(10, 15, 30, 123_000_000)});
        values.add(new Object[] {"time_micro", LocalTime.of(10, 15, 30, 123_456_000)});
        values.add(new Object[] {"time_nano", LocalTime.of(10, 15, 30, 123_456_789)});
        values.add(new Object[] {"time_midnight", LocalTime.MIDNIGHT});
        values.add(new Object[] {"time_max", LocalTime.MAX});
        values.add(new Object[] {"datetime", LocalDateTime.of(2013, 1, 1, 9, 30)});
        values.add(new Object[] {"datetime_nano", LocalDateTime.of(2013, 1, 1, 9, 30, 5, 7_000)});
        values.add(new Object[] {"instant_epoch", Instant.EPOCH});
        values.add(new Object[] {"instant", Instant.ofEpochSecond(1_700_000_000L, 123_000_000)});
        values.add(new Object[] {"instant_whole", Instant.ofEpochSecond(1_700_000_000L)});
        values.add(new Object[] {"instant_nano", Instant.ofEpochSecond(-1L, 999_999_999)});
        values.add(new Object[] {"offset_utc", OffsetDateTime.of(2026, 11, 23, 5, 51, 34, 123_000_000, ZoneOffset.UTC)});
        values.add(new Object[] {"offset_plus", OffsetDateTime.of(2026, 11, 23, 5, 51, 34, 0, ZoneOffset.ofHours(2))});
        values.add(new Object[] {"offset_minus", OffsetDateTime.of(2026, 11, 23, 5, 51, 0, 0, ZoneOffset.ofHoursMinutes(-5, -30))});
        values.add(new Object[] {"zoned_offset", ZonedDateTime.of(2026, 11, 23, 5, 51, 34, 0, ZoneOffset.ofHours(1))});
        values.add(new Object[] {"zoned_utc", ZonedDateTime.of(2026, 11, 23, 5, 51, 34, 0, ZoneOffset.UTC)});
        values.add(new Object[] {"duration_zero", Duration.ZERO});
        values.add(new Object[] {"duration", Duration.ofHours(8).plusMinutes(6).plusSeconds(12).plusMillis(345)});
        values.add(new Object[] {"duration_neg", Duration.ofMillis(-1500)});
        values.add(new Object[] {"duration_day", Duration.ofDays(1)});
        values.add(new Object[] {"duration_neg_frac", Duration.ofSeconds(-1, 999_999_999)});
        values.add(new Object[] {"duration_nanos", Duration.ofNanos(1)});
        values.add(new Object[] {"zoneoffset", ZoneOffset.ofHoursMinutesSeconds(1, 0, 30)});
        values.add(new Object[] {"zoneoffset_utc", ZoneOffset.UTC});
        List<String> lines = new ArrayList<>();
        for (Object[] v : values) {
            lines.add(v[0] + "\t" + v[1] + "\t" + mapper.writeValueAsString(v[1]));
        }
        Files.writeString(Path.of(args[0]), String.join("\n", lines) + "\n");
    }
}
