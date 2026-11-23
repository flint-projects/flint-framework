// Writes the golden file that framework/hibernate-validator/tests/golden_test.d compares line for line.
// Hibernate Validator 9.1.6.Final with Jakarta Validation 3.1.1 and Expressly 6.0 (EL), as Spring Boot 4.2 resolves
// them, validates one bean; each violation prints as path<TAB>message<TAB>template<TAB>invalid value, sorted,
// because Hibernate returns a HashSet.
//   javac -cp '*' GoldenValidation.java && java -cp '*:.' GoldenValidation validation.tsv
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.time.*;
import java.util.ArrayList;
import java.util.List;
import java.util.Map;
import java.util.Optional;
import jakarta.validation.Constraint;
import jakarta.validation.ConstraintValidator;
import jakarta.validation.ConstraintValidatorContext;
import jakarta.validation.ConstraintViolation;
import jakarta.validation.Payload;
import java.lang.annotation.ElementType;
import java.lang.annotation.Retention;
import java.lang.annotation.RetentionPolicy;
import java.lang.annotation.Target;
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

    // spring-petclinic-rest's PetAgeValidation and PetAgeValidator, as written there.
    @Target({ ElementType.FIELD })
    @Retention(RetentionPolicy.RUNTIME)
    @Constraint(validatedBy = PetAgeValidator.class)
    public @interface PetAgeValidation {
        String message() default "Birth date must not be in the future or older than 50 years";
        Class<?>[] groups() default {};
        Class<? extends Payload>[] payload() default {};
    }

    public static class PetAgeValidator implements ConstraintValidator<PetAgeValidation, LocalDate> {
        @Override
        public boolean isValid(LocalDate birthDate, ConstraintValidatorContext context) {
            if (birthDate == null) {
                return true;
            }
            LocalDate today = LocalDate.now();
            if (birthDate.isAfter(today)) {
                context.disableDefaultConstraintViolation();
                context.buildConstraintViolationWithTemplate("Birth date cannot be in the future").addConstraintViolation();
                return false;
            }
            if (birthDate.isBefore(today.minusYears(50))) {
                context.disableDefaultConstraintViolation();
                context.buildConstraintViolationWithTemplate("Birth date cannot be older than 50 years")
                    .addConstraintViolation();
                return false;
            }
            return true;
        }
    }

    // A custom constraint that keeps its default violation and adds one with an EL template.
    @Target({ ElementType.FIELD })
    @Retention(RetentionPolicy.RUNTIME)
    @Constraint(validatedBy = EvenValidator.class)
    public @interface Even {
        String message() default "must be even, not ${validatedValue}";
        int divisor() default 2;
        Class<?>[] groups() default {};
        Class<? extends Payload>[] payload() default {};
    }

    public static class EvenValidator implements ConstraintValidator<Even, Integer> {
        private int divisor;
        @Override
        public void initialize(Even even) { divisor = even.divisor(); }
        @Override
        public boolean isValid(Integer value, ConstraintValidatorContext context) {
            if (value == null || value % divisor == 0) {
                return true;
            }
            context.buildConstraintViolationWithTemplate("{divisor} does not divide it").addConstraintViolation();
            return false;
        }
    }

    // The @Pattern expressions spring-petclinic-rest's DTOs declare, on non-ASCII input.
    public static class Petclinic {
        @Pattern(regexp = "^[\\p{L}]+([ '-][\\p{L}]+){0,2}$") public String spanish = "Jos\u00e9 Mar\u00eda";
        @Pattern(regexp = "^[\\p{L}]+([ '-][\\p{L}]+){0,2}$") public String chinese = "\u674e";
        @Pattern(regexp = "^[\\p{L}]+([ '-][\\p{L}]+){0,2}$") public String supplementary = "\ud835\udc9cda";
        @Pattern(regexp = "^[\\p{L}]+([ '-][\\p{L}]+){0,2}$") public String greekDigit = "\u0395\u03bb\u03ad\u03bd\u03b7 2";
        @Pattern(regexp = "^[\\p{L}]+([ '-][\\p{L}]+){0,2}$") public String combining = "Rene\u0301e";
        @Pattern(regexp = "^[\\p{L}]+([ '-][\\p{L}]+){0,2}\\.?$") public String fourParts = "Van Der Berg Smith";
        @Pattern(regexp = "[\\s\\S]*\\S[\\s\\S]*") public String blank = " \t ";
        @Pattern(regexp = "[\\s\\S]*\\S[\\s\\S]*") public String nbsp = "\u00a0";
        @Pattern(regexp = "^[\\p{L}][\\p{L}\\s\\-']{0,79}$") public String petType = "\u00dcnicorn's-pet";
        @Pattern(regexp = "^[\\p{L}][\\p{L}\\s\\-']{0,79}$") public String digitFirst = "9cats";
        @Pattern(regexp = "^[\\p{L}][\\p{L}\\s\\-&/]{0,79}$") public String specialty = "dentistry & surgery/x";
        @Pattern(regexp = "^ROLE_[A-Z][A-Z0-9_]{1,74}$") public String role = "OWNER_ADMIN";
        @Pattern(regexp = "\\P{L}+") public String notLetters = "12\u00e9";
        @PetAgeValidation public LocalDate future = LocalDate.of(2999, 1, 1);
        @PetAgeValidation public LocalDate ancient = LocalDate.of(1900, 1, 1);
        @PetAgeValidation public LocalDate fine = LocalDate.of(2020, 2, 2);
        @PetAgeValidation public LocalDate unset = null;
        @NotNull public Integer missingId = null;
        @Min(1) public Integer zeroId = 0;
        @Min(1) public Integer nullId = null;
        @Even public Integer odd = 7;
        @Even(divisor = 5) public Integer five = 10;
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
        @Past public LocalDate birthDate = LocalDate.of(3000, 1, 1);
        @Future public Instant expiry = Instant.parse("2000-01-01T00:00:00Z");
        @PastOrPresent public LocalDateTime created = LocalDateTime.of(3000, 1, 1, 0, 0);
        @FutureOrPresent public OffsetDateTime due = OffsetDateTime.of(2000, 1, 1, 0, 0, 0, 0, ZoneOffset.ofHours(2));
        @Future public LocalTime closing = LocalTime.MIN;
        @Past public ZonedDateTime okPast = ZonedDateTime.of(2000, 1, 1, 0, 0, 0, 0, ZoneOffset.UTC);
        @Future public LocalDate okFuture = LocalDate.of(3000, 1, 1);
        @PastOrPresent public Instant okNow = Instant.parse("2020-01-01T00:00:00Z");
        @Size(min = 4) public int[] scores = {1, 2, 3};
        @NotEmpty public String[] aliases = {};
        @Size(max = 1) public Map<String, Integer> limits = new java.util.LinkedHashMap<>(Map.of("a", 1));
        { limits.put("b", 2); }
        @Size(min = 1, max = 3) public long[] okArray = {7};
        @Valid public Pet[] petArray = {new Pet("Rex", null)};
        @Valid public Optional<Pet> maybePet = Optional.of(new Pet("", "dog"));
        @Valid public Map<String, Pet> petsByName = Map.of("tom", new Pet("Tom", null));
        @Valid public List<Pet> pets = new ArrayList<>(List.of(new Pet("  ", null), new Pet("Leo", "cat")));
    }

    // String.valueOf, with arrays as Arrays.toString prints them (their own toString is an identity hash).
    static String text(Object value) {
        if (value instanceof int[] a) return java.util.Arrays.toString(a);
        if (value instanceof long[] a) return java.util.Arrays.toString(a);
        if (value instanceof Object[] a) return java.util.Arrays.toString(a);
        return String.valueOf(value);
    }

    public static void main(String[] args) throws Exception {
        Validator validator = Validation.buildDefaultValidatorFactory().getValidator();
        List<String> lines = new ArrayList<>();
        for (ConstraintViolation<Owner> v : validator.validate(new Owner())) {
            lines.add(v.getPropertyPath() + "\t" + v.getMessage() + "\t" + v.getMessageTemplate() + "\t"
                    + text(v.getInvalidValue()));
        }
        for (ConstraintViolation<Petclinic> v : validator.validate(new Petclinic())) {
            lines.add(v.getPropertyPath() + "\t" + v.getMessage() + "\t" + v.getMessageTemplate() + "\t"
                    + text(v.getInvalidValue()));
        }
        lines.sort(null);
        Files.writeString(Path.of(args[0]), String.join("\n", lines) + "\n", StandardCharsets.UTF_8);
    }
}
