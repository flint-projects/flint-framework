// Ported from spring-framework v7.1.0: spring-tx/src/main/java/org/springframework/transaction/interceptor/*.java
// Copyright 2002-present the original author or authors.
// Licensed under the Apache License, Version 2.0.
// Modified by the Flint authors.

/++
`org.springframework.transaction.interceptor`: transaction attributes and their rollback rules, the part of
Spring's declarative transaction support that decides how a method's transaction runs and when it rolls back.

$(UL
    $(LI Java's checked `Exception` is D's `Exception`, and Java's unchecked `RuntimeException` is
        `flint.java.lang.RuntimeException` (R8). So by default a `RuntimeException` or a D `Error` rolls back, and
        any other `Exception` commits, as checked exceptions do in Java.)
    $(LI A rollback rule built from a type takes a `TypeInfo_Class` (`typeid(IOException)`, R4). A rule built from a
        pattern matches D's fully qualified class names, such as `flint.java.io.IOException` or `object.Exception`.)
    $(LI `resolveAttributeStrings` takes the resolver as a delegate (R9), since `StringValueResolver` is not in
        `flint:core` yet.)
    $(LI `TransactionAttributeSource`, `TransactionAspectSupport` and `TransactionInterceptor` arrive with Flint AOT's
        advice chain; the property editors arrive with `flint.beans`.)
)
+/
module flint.transaction.interceptor;

import flint.java.lang : IllegalArgumentException, RuntimeException, javaToString;
import flint.java.util : ArrayList, Collection, Collections, LinkedHashSet, List;
import flint.transaction : TransactionDefinition;
import flint.transaction.support : DefaultTransactionDefinition, DelegatingTransactionDefinition;

@safe:

/++
This interface adds a `rollbackOn` specification to `TransactionDefinition`. As custom `rollbackOn` is only possible
with AOP, it resides in the AOP-related transaction subpackage.
+/
interface TransactionAttribute : TransactionDefinition
{
    /// Return a qualifier value associated with this transaction attribute, such as a transaction manager bean
    /// name, or null.
    string getQualifier();

    /// Return labels associated with this transaction attribute, for descriptive purposes or for use in custom
    /// transaction managers.
    Collection!string getLabels();

    /// Should we roll back on the given exception?
    bool rollbackOn(Throwable ex);
}

/++
Spring's common transaction attribute implementation. Rolls back on runtime but not checked exceptions by default.
+/
class DefaultTransactionAttribute : DefaultTransactionDefinition, TransactionAttribute
{
    private string descriptor;
    private string timeoutString;
    private string qualifier;
    private Collection!string labels;

    /// Create a new `DefaultTransactionAttribute`, with default settings. Can be modified through bean property
    /// setters.
    this()
    {
        labels = Collections.emptyList!string();
    }

    /// Copy constructor. Definition can be modified through bean property setters.
    this(TransactionAttribute other)
    {
        super(other);
        labels = Collections.emptyList!string();
    }

    /// Create a new `DefaultTransactionAttribute` with the given propagation behavior.
    this(int propagationBehavior)
    {
        super(propagationBehavior);
        labels = Collections.emptyList!string();
    }

    /// Set a descriptor for this transaction attribute, such as a method name.
    void setDescriptor(string descriptor)
    {
        this.descriptor = descriptor;
    }

    /// Return a descriptor for this transaction attribute, or null if none.
    string getDescriptor()
    {
        return descriptor;
    }

    /// Set the timeout to apply, if any, as a String value that resolves to a number of seconds. If it contains a
    /// placeholder, `resolveAttributeStrings` resolves it.
    void setTimeoutString(string timeoutString)
    {
        this.timeoutString = timeoutString;
    }

    /// Return the timeout to apply, if any, as a String value that resolves to a number of seconds.
    string getTimeoutString()
    {
        return timeoutString;
    }

    /// Associate a qualifier value with this transaction attribute.
    void setQualifier(string qualifier)
    {
        this.qualifier = qualifier;
    }

    override string getQualifier()
    {
        return qualifier;
    }

    /// Associate one or more labels with this transaction attribute.
    void setLabels(Collection!string labels)
    {
        this.labels = labels;
    }

    override Collection!string getLabels()
    {
        return labels;
    }

    /++
    The default behavior is as with EJB: rollback on unchecked exception (`RuntimeException`), assuming an
    unexpected outcome outside any business rules. Additionally, we also attempt to roll back on `Error`, which is
    clearly an unexpected outcome as well. By contrast, a checked exception is considered a business exception and
    therefore a regular expected outcome of the transactional business method.
    +/
    override bool rollbackOn(Throwable ex)
    {
        return cast(RuntimeException) ex !is null || cast(Error) ex !is null;
    }

    /// Resolve attribute values that are defined as resolvable Strings: `timeoutString`, `qualifier` and
    /// `labels`. Throws `IllegalArgumentException` for an unparseable timeout.
    void resolveAttributeStrings(scope string delegate(string) @safe resolver)
    {
        string resolvedTimeout = timeoutString;
        if (hasText(resolvedTimeout))
        {
            if (resolver !is null)
                resolvedTimeout = resolver(resolvedTimeout);
            if (resolvedTimeout.length)
            {
                try
                    setTimeout(parseSeconds(resolvedTimeout));
                catch (RuntimeException ex)
                    throw new IllegalArgumentException(
                            "Invalid timeoutString value \"" ~ resolvedTimeout ~ "\"; " ~ javaToString(ex));
            }
        }
        if (resolver !is null)
        {
            if (qualifier !is null)
                qualifier = resolver(qualifier);
            auto resolvedLabels = new LinkedHashSet!string;
            foreach (label; labels.toArray())
                resolvedLabels.add(resolver(label));
            labels = resolvedLabels;
        }
    }

    /// Return an identifying description for this transaction attribute: the definition description, the
    /// qualifier and the labels.
    protected final string getAttributeDescription()
    {
        auto result = getDefinitionDescription();
        if (hasText(qualifier))
            result ~= "; '" ~ qualifier ~ "'";
        if (!labels.isEmpty())
            result ~= "; " ~ labels.toString();
        return result;
    }
}

/// Rule determining whether a given exception should cause a rollback. Multiple such rules can be applied to
/// determine whether a transaction should commit or rollback after an exception has been thrown.
class RollbackRuleAttribute
{
    import flint.java.lang : JavaObject, stringHashCode;

    /// The rollback rule for `RuntimeException`, as for EJB.
    static RollbackRuleAttribute ROLLBACK_ON_RUNTIME_EXCEPTIONS()
    {
        return new RollbackRuleAttribute(typeid(RuntimeException));
    }

    /// The rollback rule for all exceptions, checked or unchecked.
    static RollbackRuleAttribute ROLLBACK_ON_ALL_EXCEPTIONS()
    {
        return new RollbackRuleAttribute(typeid(Exception));
    }

    private string exceptionPattern;
    private const(TypeInfo_Class) exceptionType;

    /++
    Create a new instance of the `RollbackRuleAttribute` class for the given exception type (R4: `typeid(X)`). The
    rule matches that exact type and its subclasses, at their distance from it. Throws `IllegalArgumentException`
    for null or a type that is not a `Throwable`.
    +/
    this(const TypeInfo_Class exceptionType)
    {
        if (exceptionType is null)
            throw new IllegalArgumentException("'exceptionType' cannot be null");
        if (exceptionType !is typeid(Throwable) && !typeid(Throwable).isBaseOf(exceptionType))
            throw new IllegalArgumentException(
                    "Cannot construct rollback rule from [" ~ exceptionType.name ~ "]: it's not a Throwable");
        exceptionPattern = exceptionType.name;
        this.exceptionType = exceptionType;
    }

    /++
    Create a new instance of the `RollbackRuleAttribute` class for the given exception pattern. A class matches when
    its fully qualified D name contains the pattern, so give a fully qualified name to avoid unintended matches.
    Throws `IllegalArgumentException` for a null or empty pattern.
    +/
    this(string exceptionPattern)
    {
        if (!hasText(exceptionPattern))
            throw new IllegalArgumentException("'exceptionPattern' cannot be null or empty");
        this.exceptionPattern = exceptionPattern;
        this.exceptionType = null;
    }

    /// Get the configured exception name pattern that this rule uses for matching.
    string getExceptionName()
    {
        return exceptionPattern;
    }

    /// Return the depth of the superclass matching, with 0 for an exact match, or -1 if there is no match.
    int getDepth(Throwable exception)
    {
        int depth = 0;
        for (TypeInfo_Class type = typeid(exception); type !is null; type = type.base)
        {
            if (exceptionType !is null ? type is exceptionType : contains(type.name, exceptionPattern))
                return depth; // Found it!
            // If we've gone as far as we can go and haven't found it...
            if (type is typeid(Throwable))
                return -1;
            ++depth;
        }
        return -1;
    }

    /// Rules are equal when their patterns are.
    bool equals(Object other)
    {
        if (other is this)
            return true;
        auto that = cast(RollbackRuleAttribute) other;
        return that !is null && exceptionPattern == that.exceptionPattern;
    }

    /// The hash of the pattern.
    int hashCode()
    {
        return stringHashCode(exceptionPattern);
    }

    mixin JavaObject;

    override string toString()
    {
        return "RollbackRuleAttribute with pattern [" ~ exceptionPattern ~ "]";
    }
}

/// Tag subclass of `RollbackRuleAttribute` that has the opposite behavior to the `RollbackRuleAttribute`
/// superclass.
class NoRollbackRuleAttribute : RollbackRuleAttribute
{
    /// Create a new instance of the `NoRollbackRuleAttribute` class for the supplied exception type.
    this(const TypeInfo_Class exceptionType)
    {
        super(exceptionType);
    }

    /// Create a new instance of the `NoRollbackRuleAttribute` class for the supplied exception pattern.
    this(string exceptionPattern)
    {
        super(exceptionPattern);
    }

    override string toString()
    {
        return "No" ~ super.toString();
    }
}

/++
`TransactionAttribute` implementation that works out whether a given exception should cause transaction rollback by
applying a number of rollback rules, both positive and negative. If no custom rollback rules apply, this attribute
behaves like `DefaultTransactionAttribute` (rolling back on runtime exceptions).
+/
class RuleBasedTransactionAttribute : DefaultTransactionAttribute
{
    /// Prefix for rollback-on-exception rules in description strings.
    enum string PREFIX_ROLLBACK_RULE = "-";
    /// Prefix for commit-on-exception rules in description strings.
    enum string PREFIX_COMMIT_RULE = "+";

    private List!RollbackRuleAttribute rollbackRules;

    /// Create a new `RuleBasedTransactionAttribute`, with default settings.
    this()
    {
    }

    /// Copy constructor.
    this(RuleBasedTransactionAttribute other)
    {
        super(other);
        if (other.rollbackRules !is null)
        {
            rollbackRules = new ArrayList!RollbackRuleAttribute;
            foreach (rule; other.rollbackRules.toArray())
                rollbackRules.add(rule);
        }
    }

    /// Create a new `RuleBasedTransactionAttribute` with the given propagation behavior and the given list of
    /// rollback rules.
    this(int propagationBehavior, List!RollbackRuleAttribute rollbackRules)
    {
        super(propagationBehavior);
        this.rollbackRules = rollbackRules;
    }

    /// Set the list of `RollbackRuleAttribute` objects (and/or `NoRollbackRuleAttribute` objects) to apply.
    void setRollbackRules(List!RollbackRuleAttribute rollbackRules)
    {
        this.rollbackRules = rollbackRules;
    }

    /// Return the list of `RollbackRuleAttribute` objects (never null).
    List!RollbackRuleAttribute getRollbackRules()
    {
        if (rollbackRules is null)
            rollbackRules = new ArrayList!RollbackRuleAttribute;
        return rollbackRules;
    }

    /// Winning rule is the shallowest rule (that is, the closest in the inheritance hierarchy to the exception).
    /// If no rule applies (-1), return false.
    override bool rollbackOn(Throwable ex)
    {
        RollbackRuleAttribute winner = null;
        int deepest = int.max;
        if (rollbackRules !is null)
        {
            foreach (rule; rollbackRules.toArray())
            {
                const depth = rule.getDepth(ex);
                if (depth >= 0 && depth < deepest)
                {
                    deepest = depth;
                    winner = rule;
                }
            }
        }
        // User superclass behavior (rollback on unchecked) if no rule matches.
        if (winner is null)
            return super.rollbackOn(ex);
        return cast(NoRollbackRuleAttribute) winner is null;
    }

    override string toString()
    {
        auto result = getAttributeDescription();
        if (rollbackRules !is null)
        {
            foreach (rule; rollbackRules.toArray())
            {
                const sign = cast(NoRollbackRuleAttribute) rule !is null ? PREFIX_COMMIT_RULE : PREFIX_ROLLBACK_RULE;
                result ~= "," ~ sign ~ rule.getExceptionName();
            }
        }
        return result;
    }
}

/// `TransactionAttribute` implementation that delegates all calls to a given target `TransactionAttribute`
/// instance. Abstract because it is meant to be subclassed, with subclasses overriding specific methods.
abstract class DelegatingTransactionAttribute : DelegatingTransactionDefinition, TransactionAttribute
{
    private TransactionAttribute targetAttribute;

    /// Create a `DelegatingTransactionAttribute` for the given target attribute.
    this(TransactionAttribute targetAttribute)
    {
        super(targetAttribute);
        this.targetAttribute = targetAttribute;
    }

    override string getQualifier()
    {
        return targetAttribute.getQualifier();
    }

    override Collection!string getLabels()
    {
        return targetAttribute.getLabels();
    }

    override bool rollbackOn(Throwable ex)
    {
        return targetAttribute.rollbackOn(ex);
    }
}

private bool hasText(string text)
{
    foreach (ch; text)
        if (ch != ' ' && ch != '\t' && ch != '\n' && ch != '\r' && ch != '\f' && ch != '\v')
            return true;
    return false;
}

private bool contains(string haystack, string needle)
{
    if (needle.length > haystack.length)
        return false;
    foreach (start; 0 .. haystack.length - needle.length + 1)
        if (haystack[start .. start + needle.length] == needle)
            return true;
    return false;
}

/// `Integer.parseInt`: a decimal `int`, or a `RuntimeException`.
private int parseSeconds(string text)
{
    import flint.java.lang : Integer;

    return Integer.parseInt(text);
}
