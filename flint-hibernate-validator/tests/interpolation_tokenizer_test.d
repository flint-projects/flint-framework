/++
Flint tests: the message tokenizer (TokenCollector and its parser states), each template interpolated by
Hibernate Validator 9.1.6.Final on Java 21 for `@Size(min = 2, message = ...)` on the String "x":

    a $$ {min} $                               -> a $$ 2 $
    x ${min} y                                 -> x $2 y      (`$` is text in the parameter pass)
    \${min}                                    -> $2
    {min                                       -> {min        (unbalanced: the template is kept)
    a } {min}                                  -> a } {min}
    {a{b}} {min}                               -> {a{b}} {min} (nested)
    v=${validatedValue}, \{min\}, $\{min}      -> unchanged   (`$\{min}` leaves an unbalanced `}` in the EL pass)
    ${'{'} {max}                               -> unchanged   (no quoting inside terms)
    trailing \                                 -> trailing \
+/
module flint.hibernate.validator.interpolation_tokenizer_test;

import flint.hibernate.validator.validator_test_support : validatorFor;
import flint.jakarta.validation.constraints : Size;

@safe:

private string interpolated(string template_)()
{
    static final class Bean
    {
        @Size(min: 2, message: template_)
        string v = "x";
    }

    auto violations = validatorFor!Bean().validate(new Bean());
    assert(violations.length == 1);
    return violations[0].getMessage();
}

@("the tokenizer treats `$`, escapes and unbalanced braces as Hibernate's does")
unittest
{
    assert(interpolated!"a $$ {min} $"() == "a $$ 2 $");
    assert(interpolated!"x ${min} y"() == "x $2 y");
    assert(interpolated!`\${min}`() == "$2");
    assert(interpolated!"{min"() == "{min");
    assert(interpolated!"a } {min}"() == "a } {min}");
    assert(interpolated!"{a{b}} {min}"() == "{a{b}} {min}");
    assert(interpolated!`v=${validatedValue}, \{min\}, $\{min}`() == `v=${validatedValue}, \{min\}, $\{min}`);
    assert(interpolated!"${'{'} {max}"() == "${'{'} {max}");
    assert(interpolated!`trailing \`() == `trailing \`);
}
