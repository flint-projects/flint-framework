// Writes tests/golden/shapes.tsv, which framework/jackson-databind/tests/shapes_test.d compares: Jackson 3.1.8 under
// Spring Boot 4.2's default mapper on arrays, byte[] (Base64), Optional, maps, enums and records, written and read.
// Each line is `kind<TAB>case<TAB>input<TAB>result`; a read prints the value's text or "!" and the original message.
//   javac -cp 'jars/*' GoldenShapes.java && java -cp 'jars/*:.' GoldenShapes shapes.tsv
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Optional;
import tools.jackson.core.JacksonException;
import tools.jackson.databind.json.JsonMapper;

public class GoldenShapes {
    static final List<String> lines = new ArrayList<>();

    public enum Color { RED, GREEN, BLUE }

    public record Point(int x, int y, String label) {}

    public static class Shapes {
        public int[] counts = {1, 2, 3};
        public String[] names = {"a", "b"};
        public byte[] bytes = {1, 2, 3, (byte) 0xFF};
        public double[] empty = {};
        public Optional<String> present = Optional.of("here");
        public Optional<String> absent = Optional.empty();
        public Optional<Integer> number = Optional.of(7);
        public Map<String, Integer> scores = new LinkedHashMap<>(Map.of("ann", 3));
        public Color color = Color.GREEN;
        public List<Color> palette = new ArrayList<>(List.of(Color.BLUE, Color.RED));
        public Point point = new Point(1, 2, "p");
        public Point[] points = {new Point(3, 4, null)};
    }

    static void write(JsonMapper mapper, String name, Object value) {
        lines.add("write\t" + name + "\t-\t" + mapper.writeValueAsString(value));
    }

    static String text(Object v) {
        if (v instanceof int[] a) return Arrays.toString(a);
        if (v instanceof String[] a) return Arrays.toString(a);
        if (v instanceof byte[] a) return Arrays.toString(a);
        if (v instanceof Shapes s) {
            return Arrays.toString(s.counts) + " " + Arrays.toString(s.names) + " " + Arrays.toString(s.bytes) + " "
                + Arrays.toString(s.empty) + " " + s.present + " " + s.absent + " " + s.number + " " + s.scores + " "
                + s.color + " " + s.palette + " " + s.point + " " + Arrays.toString(s.points);
        }
        return String.valueOf(v);
    }

    static void read(JsonMapper mapper, String name, tools.jackson.core.type.TypeReference<?> type, String json) {
        String result;
        try {
            result = text(mapper.readValue(json, type));
        } catch (JacksonException e) {
            result = "!" + e.getOriginalMessage();
        }
        lines.add("read\t" + name + "\t" + json + "\t" + result);
    }

    public static void main(String[] args) throws Exception {
        JsonMapper boot = JsonMapper.builder().findAndAddModules().build();
        write(boot, "shapes", new Shapes());
        write(boot, "color", Color.BLUE);
        write(boot, "point", new Point(5, 6, "q"));
        write(boot, "ints", new int[] {4, 5});
        write(boot, "bytes_empty", new byte[0]);
        write(boot, "optional_empty", Optional.empty());

        read(boot, "Color", new tools.jackson.core.type.TypeReference<Color>() {}, "\"GREEN\"");
        read(boot, "Color", new tools.jackson.core.type.TypeReference<Color>() {}, "2");
        read(boot, "Color", new tools.jackson.core.type.TypeReference<Color>() {}, "\"PURPLE\"");
        read(boot, "Color", new tools.jackson.core.type.TypeReference<Color>() {}, "7");
        read(boot, "Color", new tools.jackson.core.type.TypeReference<Color>() {}, "null");
        read(boot, "Color", new tools.jackson.core.type.TypeReference<Color>() {}, "\"\"");
        read(boot, "Color", new tools.jackson.core.type.TypeReference<Color>() {}, "\"green\"");
        read(boot, "Ints", new tools.jackson.core.type.TypeReference<int[]>() {}, "[1,2,3]");
        read(boot, "Ints", new tools.jackson.core.type.TypeReference<int[]>() {}, "[]");
        read(boot, "Ints", new tools.jackson.core.type.TypeReference<int[]>() {}, "5");
        read(boot, "Strings", new tools.jackson.core.type.TypeReference<String[]>() {}, "[\"x\",null,\"z\"]");
        read(boot, "Bytes", new tools.jackson.core.type.TypeReference<byte[]>() {}, "\"AQID/w==\"");
        read(boot, "Bytes", new tools.jackson.core.type.TypeReference<byte[]>() {}, "[1,2,255]");
        read(boot, "Point", new tools.jackson.core.type.TypeReference<Point>() {}, "{\"y\":2,\"x\":1,\"label\":\"p\"}");
        read(boot, "Point", new tools.jackson.core.type.TypeReference<Point>() {}, "{\"x\":1}");
        read(boot, "Point", new tools.jackson.core.type.TypeReference<Point>() {}, "{\"x\":null,\"y\":1}");
        read(boot, "Shapes", new tools.jackson.core.type.TypeReference<Shapes>() {}, boot.writeValueAsString(new Shapes()));
        read(boot, "Shapes", new tools.jackson.core.type.TypeReference<Shapes>() {},
            "{\"present\":null,\"absent\":\"now\",\"color\":\"RED\",\"palette\":[\"GREEN\"],\"scores\":{\"bob\":1},"
            + "\"counts\":[],\"points\":[{\"x\":9,\"y\":8,\"label\":\"r\"}]}");
        Files.writeString(Path.of(args[0]), String.join("\n", lines) + "\n");
    }
}
