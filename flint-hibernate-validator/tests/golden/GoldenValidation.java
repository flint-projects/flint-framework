// Writes the golden file that framework/hibernate-validator/tests/golden_test.d compares line for line.
// Hibernate Validator 9.1.6.Final with Jakarta Validation 3.1.1 and Expressly 6.0 (EL), as Spring Boot 4.2 resolves
// them, validates one bean; each violation prints as path<TAB>message<TAB>template<TAB>invalid value, sorted,
// because Hibernate returns a HashSet.
//   javac -cp '*' GoldenValidation.java && java -cp '*:.' GoldenValidation validation.tsv
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.ArrayList;
import java.util.List;
import jakarta.validation.ConstraintViolation;
import jakarta.validation.Valid;
import jakarta.validation.Validation;
import jakarta.validation.Validator;
import jakarta.validation.constraints.*;

public class GoldenValidation {
    public static class Pet {
        @NotBlank public String name;
        @NotNull public String type;
        public Pet(String name, String type) { this.name = name; this.type = type; }
    }

    public static class Owner {
        @NotBlank public String firstName = "";
        @NotNull public String lastName = null;
        @Size(min = 2, max = 30) public String city = "A";
        @Pattern(regexp = "\\d{1,10}") public String telephone = "60855510239999";
        @Email public String email = "not-an-email";
        @Email public String goodEmail = "george@example.com";
        @Min(1) public int age = 0;
        @Max(120) public long maxAge = 150;
        @Positive public int id = -3;
        @NegativeOrZero public int debt = 5;
        @PositiveOrZero public double balance = -0.5;
        @DecimalMax("99.5") public double rating = 100.0;
        @DecimalMin(value = "0", inclusive = false) public double price = 0.0;
        @Digits(integer = 3, fraction = 2) public double amount = 1234.567;
        @AssertTrue public boolean active = false;
        @AssertFalse public boolean deleted = true;
        @NotEmpty public List<String> tags = new ArrayList<>();
        @Size(max = 2) public List<String> nicknames = new ArrayList<>(List.of("a", "b", "c"));
        @Null public String nothing = "x";
        @NotBlank public String blankName = " \t";
        @Size(min = 3, message = "'${validatedValue}' must have at least {min} characters") public String code = "ab";
        @NotNull(message = "literal \\{min\\} and {min}") public String escaped = null;
        @Size(min = 1, max = 5) public String ok = "fine";
        @Valid public List<Pet> pets = new ArrayList<>(List.of(new Pet("  ", null), new Pet("Leo", "cat")));
    }

    public static void main(String[] args) throws Exception {
        Validator validator = Validation.buildDefaultValidatorFactory().getValidator();
        List<String> lines = new ArrayList<>();
        for (ConstraintViolation<Owner> v : validator.validate(new Owner())) {
            lines.add(v.getPropertyPath() + "\t" + v.getMessage() + "\t" + v.getMessageTemplate() + "\t"
                    + String.valueOf(v.getInvalidValue()));
        }
        lines.sort(null);
        Files.writeString(Path.of(args[0]), String.join("\n", lines) + "\n", StandardCharsets.UTF_8);
    }
}
