// Writes the golden files that flint-jackson-core/tests/golden_test.d compares byte for byte.
// Run with the jars Spring Boot 4.2.0 resolves (jackson-core 3.1.8):
//   javac -cp jackson-core-3.1.8.jar GoldenCore.java && java -cp jackson-core-3.1.8.jar:. GoldenCore core
// Every case here has a twin in golden_test.d that makes the same calls on Flint's generator.
import java.io.File;
import java.io.FileOutputStream;
import java.io.OutputStream;
import tools.jackson.core.JsonGenerator;
import tools.jackson.core.ObjectWriteContext;
import tools.jackson.core.json.JsonFactory;
import tools.jackson.core.util.DefaultPrettyPrinter;

public class GoldenCore {
    interface Case { void write(JsonGenerator g); }

    static final JsonFactory FACTORY = JsonFactory.builder().build();

    static void emit(String dir, String name, boolean pretty, Case c) throws Exception {
        try (OutputStream out = new FileOutputStream(new File(dir, name + ".json"))) {
            ObjectWriteContext ctx = pretty ? new ObjectWriteContext.Base() {
                @Override public tools.jackson.core.PrettyPrinter getPrettyPrinter() { return new DefaultPrettyPrinter(); }
            } : ObjectWriteContext.empty();
            try (JsonGenerator g = FACTORY.createGenerator(ctx, out)) {
                c.write(g);
            }
        }
    }

    static void nested(JsonGenerator g) {
        g.writeStartObject();
        g.writeNumberProperty("id", 1);
        g.writeStringProperty("name", "Leo");
        g.writeName("visits");
        g.writeStartArray();
        g.writeStartObject();
        g.writeStringProperty("date", "2013-01-01");
        g.writeNullProperty("description");
        g.writeEndObject();
        g.writeNumber(2);
        g.writeEndArray();
        g.writeName("empty");
        g.writeStartObject();
        g.writeEndObject();
        g.writeName("none");
        g.writeStartArray();
        g.writeEndArray();
        g.writeBooleanProperty("active", true);
        g.writeEndObject();
    }

    public static void main(String[] args) throws Exception {
        String dir = args[0];
        new File(dir).mkdirs();
        emit(dir, "greeting", false, g -> {
            g.writeStartObject();
            g.writeNumberProperty("id", 1L);
            g.writeStringProperty("content", "Hello, World!");
            g.writeEndObject();
        });
        emit(dir, "escapes", false, g -> {
            StringBuilder controls = new StringBuilder();
            for (char c = 0; c < 0x20; c++) controls.append(c);
            g.writeStartArray();
            g.writeString(controls.toString());
            g.writeString("quote \" backslash \\ slash / del \u007f");
            g.writeString("café 日本 😀    ");
            g.writeString("");
            g.writeEndArray();
        });
        emit(dir, "names", false, g -> {
            g.writeStartObject();
            g.writeName("tab\tname");
            g.writeNumber(1);
            g.writeName("über");
            g.writeNumber(2);
            g.writeEndObject();
        });
        emit(dir, "integers", false, g -> {
            g.writeStartArray();
            g.writeNumber(0);
            g.writeNumber(-1);
            g.writeNumber(Integer.MIN_VALUE);
            g.writeNumber(Integer.MAX_VALUE);
            g.writeNumber(Long.MIN_VALUE);
            g.writeNumber(Long.MAX_VALUE);
            g.writeNumber((short) -32768);
            g.writeNumber("12345678901234567890");
            g.writeEndArray();
        });
        emit(dir, "doubles", false, g -> {
            double[] values = {0.0, -0.0, 1.0, 0.1, 100.0, 1.5, 1234567.0, 1e7, 1.0E-4, 0.001, 3.141592653589793,
                    Double.MAX_VALUE, Double.MIN_VALUE, Double.MIN_NORMAL, 1e21, 1e-7, 123456789.125,
                    Double.NaN, Double.POSITIVE_INFINITY, Double.NEGATIVE_INFINITY};
            g.writeStartArray();
            for (double v : values) g.writeNumber(v);
            g.writeNumber(0.1f);
            g.writeNumber(3.4028235e38f);
            g.writeNumber(Float.NaN);
            g.writeEndArray();
        });
        emit(dir, "nested", false, GoldenCore::nested);
        emit(dir, "nested_pretty", true, GoldenCore::nested);
        emit(dir, "pretty_array", true, g -> {
            g.writeStartArray();
            g.writeNumber(1);
            g.writeString("two");
            g.writeStartArray();
            g.writeEndArray();
            g.writeStartObject();
            g.writeEndObject();
            g.writeStartArray();
            g.writeBoolean(false);
            g.writeNull();
            g.writeEndArray();
            g.writeEndArray();
        });
        emit(dir, "raw", false, g -> {
            g.writeStartObject();
            g.writeName("raw");
            g.writeRawValue("{\"pre\":\"formatted\"}");
            g.writeName("next");
            g.writeNumber(1);
            g.writeEndObject();
            g.writeRaw("\n");
        });
        emit(dir, "roots", false, g -> {
            g.writeNumber(1);
            g.writeString("two");
            g.writeStartObject();
            g.writeEndObject();
            g.writeNull();
        });
    }
}
