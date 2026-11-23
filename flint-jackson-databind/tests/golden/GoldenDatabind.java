// Writes the golden files that flint-jackson-databind/tests/golden_test.d compares byte for byte.
// The mapper is configured as Spring Boot 4.2's JacksonAutoConfiguration configures it by default:
// JsonMapper.builder().findAndAddModules().build(), Jackson 3.1.8 defaults otherwise.
//   javac -cp jackson-databind-3.1.8.jar:jackson-core-3.1.8.jar:jackson-annotations-2.21.jar GoldenDatabind.java
//   java -cp jackson-databind-3.1.8.jar:jackson-core-3.1.8.jar:jackson-annotations-2.21.jar:. GoldenDatabind databind
// Every case has a D twin in golden_test.d with the same shape and values.
import java.io.File;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import com.fasterxml.jackson.annotation.JsonIgnore;
import com.fasterxml.jackson.annotation.JsonInclude;
import com.fasterxml.jackson.annotation.JsonProperty;
import com.fasterxml.jackson.annotation.JsonPropertyOrder;
import tools.jackson.databind.JsonNode;
import tools.jackson.databind.PropertyNamingStrategies;
import tools.jackson.databind.SerializationFeature;
import tools.jackson.databind.json.JsonMapper;
import tools.jackson.databind.node.ArrayNode;
import tools.jackson.databind.node.ObjectNode;

public class GoldenDatabind {
    // gs-rest-service's Greeting.
    public record Greeting(long id, String content) {}

    // A Java Beans class with a default constructor, fields declared out of alphabetical order.
    public static class Owner {
        public long id = 1;
        public String lastName = "Franklin";
        public String firstName = "George";
        public String address = "110 W. Liberty St.";
        public String city = "Madison";
        public String telephone = "6085551023";
        public List<String> pets = new ArrayList<>(List.of("Leo"));
    }

    @JsonPropertyOrder({"id", "name", "birthDate", "type"})
    public static class Pet {
        public int id = 7;
        public String type = "cat";
        public String name = "Leo";
        public String birthDate = "2010-09-07";
        public String owner = null;
    }

    public static class Annotated {
        @JsonProperty("first_name") public String firstName = "Betty";
        @JsonIgnore public String password = "secret";
        @JsonInclude(JsonInclude.Include.NON_NULL) public String nickname = null;
        @JsonInclude(JsonInclude.Include.NON_EMPTY) public List<String> tags = new ArrayList<>();
        @JsonInclude(JsonInclude.Include.NON_EMPTY) public String note = "";
        public String lastName = "Davis";
        public String middle = null;
    }

    @JsonInclude(JsonInclude.Include.NON_NULL)
    public static class Sparse {
        public String present = "yes";
        public String absent = null;
        public Integer count = null;
        public int zero = 0;
    }

    // One public constructor with named parameters, no default constructor: a properties-based creator.
    public static class Vet {
        private final int id;
        private final String lastName;
        private final String firstName;
        public Vet(int id, String lastName, String firstName) {
            this.id = id; this.lastName = lastName; this.firstName = firstName;
        }
        public int getId() { return id; }
        public String getLastName() { return lastName; }
        public String getFirstName() { return firstName; }
        public int getAlphaFirst() { return 9; }
        public String getZulu() { return "z"; }
    }

    public static class Numbers {
        public int anInt = -42;
        public long aLong = 9007199254740993L;
        public double aDouble = 0.1;
        public double big = 1e21;
        public double integral = 100.0;
        public float aFloat = 1.1f;
        public boolean flag = true;
        public char letter = 'x';
        public short aShort = -7;
        public byte aByte = 5;
    }

    public static class Nested {
        public Greeting greeting = new Greeting(2, "nested");
        public Greeting none = null;
        public Map<String, Integer> counts = new LinkedHashMap<>();
        public List<Greeting> greetings = new ArrayList<>();
        public Nested() {
            counts.put("b", 2); counts.put("a", 1);
            greetings.add(new Greeting(3, "x")); greetings.add(new Greeting(4, "y"));
        }
    }

    public static class Snake {
        public String firstName = "Helen";
        public int visitCount = 3;
        public String homePageUrl = "/vets";
    }

    static void write(String dir, String name, String json) throws Exception {
        Files.writeString(new File(dir, name + ".json").toPath(), json, StandardCharsets.UTF_8);
    }

    public static void main(String[] args) throws Exception {
        String dir = args[0];
        new File(dir).mkdirs();
        JsonMapper mapper = JsonMapper.builder().findAndAddModules().build();
        write(dir, "greeting", mapper.writeValueAsString(new Greeting(1, "Hello, World!")));
        write(dir, "owner", mapper.writeValueAsString(new Owner()));
        write(dir, "pet", mapper.writeValueAsString(new Pet()));
        write(dir, "annotated", mapper.writeValueAsString(new Annotated()));
        write(dir, "sparse", mapper.writeValueAsString(new Sparse()));
        write(dir, "vet", mapper.writeValueAsString(new Vet(5, "Carter", "James")));
        write(dir, "numbers", mapper.writeValueAsString(new Numbers()));
        write(dir, "nested", mapper.writeValueAsString(new Nested()));
        write(dir, "greeting_list", mapper.writeValueAsString(List.of(new Greeting(1, "a"), new Greeting(2, "b"))));
        write(dir, "owner_pretty", mapper.writerWithDefaultPrettyPrinter().writeValueAsString(new Owner()));
        JsonMapper indent = JsonMapper.builder().enable(SerializationFeature.INDENT_OUTPUT).build();
        write(dir, "nested_indent", indent.writeValueAsString(new Nested()));
        JsonMapper snake = JsonMapper.builder().propertyNamingStrategy(PropertyNamingStrategies.SNAKE_CASE).build();
        write(dir, "snake", snake.writeValueAsString(new Snake()));
        JsonMapper kebab = JsonMapper.builder().propertyNamingStrategy(PropertyNamingStrategies.KEBAB_CASE).build();
        write(dir, "kebab", kebab.writeValueAsString(new Snake()));
        JsonMapper nonNull = JsonMapper.builder().changeDefaultPropertyInclusion(
                incl -> incl.withValueInclusion(JsonInclude.Include.NON_NULL)).build();
        write(dir, "default_non_null", nonNull.writeValueAsString(new Pet()));
        ObjectNode tree = mapper.createObjectNode();
        tree.put("name", "tree").put("count", 3).put("ratio", 0.5).put("ok", false).putNull("missing");
        ArrayNode items = tree.putArray("items");
        items.add(1).add("two").addObject().put("three", 3L);
        tree.putObject("empty");
        write(dir, "tree", tree.toString());
        write(dir, "tree_pretty", tree.toPrettyString());
        JsonNode parsed = mapper.readTree("{\"b\":[1,2.5,\"x\",null,true],\"a\":{\"c\":12345678901}}");
        write(dir, "tree_roundtrip", parsed.toString());
        // Reading: unknown properties are ignored by default in Jackson 3, and the record's creator runs.
        Greeting read = mapper.readValue("{\"content\":\"Hi\",\"extra\":[1,{\"x\":2}],\"id\":7}", Greeting.class);
        write(dir, "read_greeting", mapper.writeValueAsString(read));
        Owner owner = mapper.readValue("{\"firstName\":\"Jean\",\"id\":6,\"pets\":[\"Max\",\"Samantha\"]}", Owner.class);
        write(dir, "read_owner", mapper.writeValueAsString(owner));
        Vet vet = mapper.readValue("{\"firstName\":\"Linda\",\"lastName\":\"Douglas\",\"id\":3}", Vet.class);
        write(dir, "read_vet", mapper.writeValueAsString(vet));
        Numbers numbers = mapper.readValue("{\"anInt\":\"12\",\"aLong\":3.9,\"aDouble\":\"NaN\",\"flag\":\"false\",\"letter\":\"q\"}", Numbers.class);
        write(dir, "read_numbers", mapper.writeValueAsString(numbers));
        Map<String, Object> converted = mapper.convertValue(new Greeting(8, "converted"), Map.class);
        write(dir, "convert_map", mapper.writeValueAsString(converted));
    }
}
