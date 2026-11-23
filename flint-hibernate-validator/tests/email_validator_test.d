/++
Ported from hibernate/hibernate-validator 9.1.6.Final,
engine/src/test/java/org/hibernate/validator/test/internal/constraintvalidators/bv/EmailValidatorTest.java.

SPDX-License-Identifier: Apache-2.0
Copyright Red Hat Inc. and Hibernate Authors. Licensed under the Apache License, Version 2.0.

Modified by the Flint authors: `new EmailValidator().isValid(email, null)` is Flint's one dispatcher run on a D
`string` (`isValidFor`); the HV-502 custom `CharSequence` (`MyCustomStringImpl`) is a D `string`. The annotated
getter of `EmailContainerAnnotated` is an annotated field of its D twin. Flint's `ConstraintMapping` cannot add
constraints to a type (`type(...).getter(...).constraint(new EmailDef()...)`), so that half of testEmailRegExp is
gated. `DomainNameUtil.isValidEmailDomainAddress` is private to Flint's validator, so testLongEmail checks the
domain through an address.
+/
module flint.hibernate.validator.email_validator_test;

import flint.engine.aot.any : Any;
import flint.engine.aot.name : typeNameOf;
import flint.hibernate.validator.validator_test_support : isValidFor, validatorFor;
import flint.jakarta.validation : ConstraintViolation;
import flint.jakarta.validation.constraints : Email;

@safe:

// http://stackoverflow.com/questions/406230/regular-expression-to-match-string-not-containing-a-word
private enum noOrgEmailAddressRegexp = `^((?!\.org).)*$`;

private final class EmailContainerAnnotated
{
    @Email(message: "ORG addresses are not valid", regexp: noOrgEmailAddressRegexp)
    string email;
}

@("EmailValidatorTest.testNullAndEmptyString")
unittest
{
    isValidEmail("");
    isValidEmail(Any.init);
}

@("EmailValidatorTest.testValidEmail")
unittest
{
    isValidEmail("emmanuel@hibernate.org");
    isValidEmail("emmanuel@hibernate");
    isValidEmail("emma-n_uel@hibernate");
    isValidEmail("emma+nuel@hibernate.org");
    isValidEmail("emma=nuel@hibernate.org");
    isValidEmail("emmanuel@[123.12.2.11]");
    isValidEmail("*@example.net");
    isValidEmail("fred&barny@example.com");
    isValidEmail("---@example.com");
    isValidEmail("foo-bar@example.net");
    isValidEmail("mailbox.sub1.sub2@this-domain");
    isValidEmail("prettyandsimple@example.com");
    isValidEmail("very.common@example.com");
    isValidEmail("disposable.style.email.with+symbol@example.com");
    isValidEmail("other.email-with-dash@example.com");
    isValidEmail("x@example.com");
    isValidEmail("\"much.more unusual\"@example.com");
    isValidEmail("\"very.unusual.@.unusual.com\"@example.com");
    isValidEmail("\"very.(),:;<>[]\\\".VERY.\\\"very@\\\\ \\\"very\\\".unusual\"@strange.example.com");
    isValidEmail("\"some \".\" strange \".\" part*:; \"@strange.example.com");
    isValidEmail("example-indeed@strange-example.com");
    isValidEmail("admin@mailserver1");
    isValidEmail("#!$%&'*+-/=?^_`{}|~@example.org");
    isValidEmail("\"()<>[]:,;@\\\"!#$%&'-/=?^_`{}| ~.a\"@example.org");
    isValidEmail("\" \"@example.org");
    isValidEmail("example@localhost");
    isValidEmail("example@s.solutions");
    isValidEmail("user@localserver");
    isValidEmail("user@tt");
    isValidEmail("user@[IPv6:2001:DB8::1]");
    isValidEmail("xn--80ahgue5b@xn--p-8sbkgc5ag7bhce.xn--ba-lmcq");
    isValidEmail("nothing@xn--fken-gra.no");
}

@("EmailValidatorTest.testInValidEmail")
unittest
{
    isInvalidEmail("emmanuel.hibernate.org");
    isInvalidEmail("emma nuel@hibernate.org");
    isInvalidEmail("emma(nuel@hibernate.org");
    isInvalidEmail("emmanuel@");
    isInvalidEmail("emma\nnuel@hibernate.org");
    isInvalidEmail("emma@nuel@hibernate.org");
    isInvalidEmail("emma@nuel@.hibernate.org");
    isInvalidEmail("Just a string");
    isInvalidEmail("string");
    isInvalidEmail("me@");
    isInvalidEmail("@example.com");
    isInvalidEmail("me.@example.com");
    isInvalidEmail(".me@example.com");
    isInvalidEmail("me@example..com");
    isInvalidEmail("me\\@example.com");
    isInvalidEmail("Abc.example.com"); // (no @ character)
    isInvalidEmail("A@b@c@example.com"); // (only one @ is allowed outside quotation marks)
    // (none of the special characters in this local-part are allowed outside quotation marks)
    isInvalidEmail("a\"b(c)d,e:f;g<h>i[j\\k]l@example.com");
    // (quoted strings must be dot separated or the only element making up the local-part)
    isInvalidEmail("just\"not\"right@example.com");
    // (spaces, quotes, and backslashes may only exist when within quoted strings and preceded by a backslash)
    isInvalidEmail("this is\"not\\allowed@example.com");
    // (even if escaped (preceded by a backslash), spaces, quotes, and backslashes must still be contained by quotes)
    isInvalidEmail("this\\ still\\\"not\\\\allowed@example.com");
    // (double dot before @) with caveat: Gmail lets this through, Email address#Local-part the dots altogether
    isInvalidEmail("john..doe@example.com");
    isInvalidEmail("john.doe@example..com");
}

@("EmailValidatorTest.testAccent")
unittest
{
    isValidEmail("Test^Email@example.com");
}

@("EmailValidatorTest.testValidEmailCharSequence")
unittest
{
    isValidEmail("emmanuel@hibernate.org");
    isInvalidEmail("@example.com");
}

@("EmailValidatorTest.testMailWithInternationalDomainName")
unittest
{
    isValidEmail("myname@östereich.at", "A valid email address with umlaut");
    isValidEmail("θσερ@εχαμπλε.ψομ", "A valid greek email address");
    isInvalidEmail("θσερ.εχαμπλε.ψομ", "Email does not contain an @ character and should be invalid");
}

@("EmailValidatorTest.testEmailRegExp")
unittest
{
    const email = "hardy@hibernate.org";
    // ensure the plain email is valid
    isValidEmail(email);

    // add additional regexp constraint to email
    auto validator = validatorFor!EmailContainerAnnotated();
    auto container = new EmailContainerAnnotated();
    container.email = email;
    assertOrgAddressesAreNotValid(validator.validate(container));

    // now the same test with programmatic configuration
    // Gap: Flint's ConstraintMapping binds validators only; it cannot add a constraint to a type's property.
    version (FlintProgrammaticConstraintMapping)
    {
        import flint.hibernate.validator.validator_test_support : configurationFor;

        auto config = configurationFor!EmailContainerNoAnnotations();
        auto mapping = config.createConstraintMapping();
        mapping.type!EmailContainerNoAnnotations().getter("email").constraint(Email(regexp: noOrgEmailAddressRegexp,
    message: "ORG addresses are not valid"));
        config.addMapping(mapping);
        validator = config.buildValidatorFactory().getValidator();
        auto plain = new EmailContainerNoAnnotations();
        plain.email = email;
        assertOrgAddressesAreNotValid(validator.validate(plain));
    }
}

version (FlintProgrammaticConstraintMapping)
{
    private final class EmailContainerNoAnnotations
    {
        string email;
    }
}

@("EmailValidatorTest.testEmailAddressLength")
unittest
{
    isValidEmail("aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa@hibernate.org");
}

@("EmailValidatorTest.testEMailWithTrailingAt")
unittest
{
    isInvalidEmail("validation@hibernate.com@");
    isInvalidEmail("validation@hibernate.com@@");
    isInvalidEmail("validation@hibernate.com@@@");
}

@("EmailValidatorTest.testEmailWithUpTo64CharacterLocalPartIsValid")
unittest
{
    // Local part should allow up to 64 octets: https://tools.ietf.org/html/rfc5321#section-4.5.3.1.1
    foreach (length; 1 .. 65)
        isValidEmail(stringOfLength(length) ~ "@foo.com");
}

@("EmailValidatorTest.testEmailWith65CharacterLocalPartIsInvalid")
unittest
{
    isInvalidEmail(stringOfLength(65) ~ "@foo.com");
}

@("EmailValidatorTest.testEmailWithUpTo255CharacterDomainPartIsValid")
unittest
{
    // Domain part should allow up to 255
    foreach (length; 1 .. 252)
        isValidEmail("foo@" ~ domainOfLength(length) ~ ".com");
}

@("EmailValidatorTest.testEmailWith63CharactersDomainPartIsValid")
unittest
{
    isValidEmail("foo@" ~ stringOfLength(63) ~ "." ~ stringOfLength(63) ~ ".com");
}

@("EmailValidatorTest.testEmailWith256CharacterDomainPartIsInvalid")
unittest
{
    // Domain part should allow up to 255
    isInvalidEmail("foo@" ~ domainOfLength(252) ~ ".com");
}

@("EmailValidatorTest.testLongEmail")
unittest
{
    isInvalidEmail("foo@" ~ stringOfLength(5000) ~ ".com");
}

private string stringOfLength(int length) pure
{
    string s;
    foreach (i; 0 .. length)
        s ~= 'a';
    assert(s.length == length);
    return s;
}

private string domainOfLength(int length) pure
{
    string s;
    foreach (i; 0 .. length)
    {
        // we insert a dot from time to time to be sure each label of the domain name is at most 63 characters long
        if (i % 32 == 0 && i > 0 && i < length - 1)
            s ~= '.';
        else
            s ~= 'a';
    }
    assert(s.length == length);
    return s;
}

private void assertOrgAddressesAreNotValid(ConstraintViolation[] violations)
{
    assert(violations.length == 1);
    assert(violations[0].getConstraintDescriptor().getAnnotationType() == typeNameOf!Email);
    assert(violations[0].getMessage() == "ORG addresses are not valid");
}

private void isValidEmail(T)(T email, string message = "Expected %1$s to be a valid email.")
{
    assert(isValidFor(Email(), email), format(message, email));
}

private void isInvalidEmail(T)(T email, string message = "Expected %1$s to be an invalid email.")
{
    assert(!isValidFor(Email(), email), format(message, email));
}

// StringHelper.format: `%1$s` is the address.
private string format(T)(string message, T email)
{
    import std.array : replace;

    static if (is(T == Any))
        return message.replace("%1$s", "null");
    else
        return message.replace("%1$s", email);
}
