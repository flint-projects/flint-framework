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
    $(LI `TransactionInterceptor` is the runtime `Advisor` of Flint AOT's proxies (aot-contract section 7): it reads the
        merged `@Transactional` from the advised method's descriptor, which replaces Java's `Method` and the
        annotation-parsing `TransactionAttributeSource`, and runs the call in a transaction.)
    $(LI `TransactionAspectSupport` keeps the current `TransactionInfo` in a `FiberLocal`, so
        `currentTransactionStatus()` reads the calling task's transaction.)
    $(LI The property editors, the proxy factory beans and the pointcut advisors arrive with `flint.beans` and
        `flint.aop`.)
)
+/
module flint.transaction.interceptor;

import flint.core.annotation : ClassRef;
import flint.engine.aot.bean : BeanFactory;
import flint.engine.aot.descriptor : Descriptor, MethodDescriptor;
import flint.engine.aot.proxy : Advisor, Invocation, Proceed;
import flint.engine.reactor : FiberLocal;
import flint.java.lang : IllegalArgumentException, IllegalStateException, RuntimeException, javaToString;
import flint.java.util : ArrayList, Collection, Collections, LinkedHashSet, List;
import flint.slf4j : Logger, LoggerFactory;
import flint.transaction : NoTransactionException, PlatformTransactionManager,
    TransactionDefinition, TransactionManager, TransactionStatus, TransactionSystemException;
import flint.transaction.annotation : Transactional, value;
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
    private string exactTypeName;

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
    Create a new instance of the `RollbackRuleAttribute` class for the exception type a `Class`-valued annotation
    attribute names (`@Transactional(rollbackFor: [classOf!IOException])`): the rule matches the class of exactly that
    fully qualified name and its subclasses, as the `TypeInfo_Class` form does. Throws `IllegalArgumentException` for
    an empty name.
    +/
    this(ClassRef exceptionType)
    {
        if (!hasText(exceptionType.name))
            throw new IllegalArgumentException("'exceptionType' cannot be null");
        exceptionPattern = exceptionType.name;
        exactTypeName = exceptionType.name;
        this.exceptionType = null;
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
            const found = exceptionType !is null ? type is exceptionType : exactTypeName !is null
                ? type.name == exactTypeName : contains(type.name, exceptionPattern);
            if (found)
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

    /// Create a new instance of the `NoRollbackRuleAttribute` class for the exception type a `Class`-valued
    /// annotation attribute names.
    this(ClassRef exceptionType)
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

// ---------------------------------------------------------------------------------------------------------------
// Attribute sources and the transaction aspect

/++
Strategy interface used by `TransactionInterceptor` for metadata retrieval. Implementations know how to source
transaction attributes, whether from configuration or from metadata attributes at source level. Java passes a
`Method` and its target class; Flint passes the method's AOT descriptor and the target's descriptor (R4: the
descriptor replaces reflection).
+/
interface TransactionAttributeSource
{
    /// Return the transaction attribute for the given method, or null if the method is non-transactional.
    TransactionAttribute getTransactionAttribute(const(MethodDescriptor)* method, const Descriptor targetClass);
}

/++
`TransactionAttributeSource` that reads the merged `@Transactional` from a method descriptor, as Spring's
`AnnotationTransactionAttributeSource` with `SpringTransactionAnnotationParser` reads it from a `Method`. Flint AOT
has already merged method-level over class-level declarations and resolved `@AliasFor`. Attributes are cached per
method descriptor.
+/
final class DescriptorTransactionAttributeSource : TransactionAttributeSource
{
    private enum string annotationType = "flint.transaction.annotation.Transactional";
    private TransactionAttribute[const(MethodDescriptor)* ] cache;
    private bool[const(MethodDescriptor)* ] nonTransactional;

    override TransactionAttribute getTransactionAttribute(const(MethodDescriptor)* method, const Descriptor)
    {
        if (method is null)
            return null;
        synchronized (this)
        {
            if (auto cached = method in cache)
                return *cached;
            if (method in nonTransactional)
                return null;
        }
        TransactionAttribute attribute = null;
        foreach (ref merged; method.annotations)
        {
            if (merged.type == annotationType)
            {
                attribute = parseTransactionAnnotation(merged.value.get!Transactional);
                break;
            }
        }
        synchronized (this)
        {
            if (attribute is null)
                nonTransactional[method] = true;
            else
                cache[method] = attribute;
        }
        return attribute;
    }

    /// `SpringTransactionAnnotationParser.parseTransactionAnnotation`: the attribute a `@Transactional` declares.
    static RuleBasedTransactionAttribute parseTransactionAnnotation(const Transactional attributes)
    {
        auto rbta = new RuleBasedTransactionAttribute;
        rbta.setPropagationBehavior(attributes.propagation.value());
        rbta.setIsolationLevel(attributes.isolation.value());
        if (hasText(attributes.timeoutString) && attributes.timeout >= 0)
            throw new IllegalArgumentException("Specify 'timeout' or 'timeoutString', not both");
        rbta.setTimeout(attributes.timeout);
        rbta.setTimeoutString(attributes.timeoutString.length ? attributes.timeoutString : null);
        rbta.setReadOnly(attributes.readOnly);
        const qualifier = attributes.value.length ? attributes.value : attributes.transactionManager;
        rbta.setQualifier(qualifier.length ? qualifier : null);
        auto labels = new LinkedHashSet!string;
        foreach (label; attributes.label)
            labels.add(label);
        rbta.setLabels(labels);

        auto rollbackRules = new ArrayList!RollbackRuleAttribute;
        foreach (rbRule; attributes.rollbackFor)
            rollbackRules.add(new RollbackRuleAttribute(rbRule));
        foreach (rbRule; attributes.rollbackForClassName)
            rollbackRules.add(new RollbackRuleAttribute(rbRule));
        foreach (rbRule; attributes.noRollbackFor)
            rollbackRules.add(new NoRollbackRuleAttribute(rbRule));
        foreach (rbRule; attributes.noRollbackForClassName)
            rollbackRules.add(new NoRollbackRuleAttribute(rbRule));
        rbta.setRollbackRules(rollbackRules);
        return rbta;
    }
}

private shared FiberLocal!(TransactionAspectSupport.TransactionInfo) transactionInfoHolder;

/++
Base class for transactional aspects, such as `TransactionInterceptor`. This enables the underlying Spring transaction
infrastructure to be used easily to implement an aspect for any aspect system.

Subclasses are responsible for calling methods in this class in the correct order. It uses the Strategy design
pattern: a `TransactionManager` implementation performs the actual transaction management, and a
`TransactionAttributeSource` determines transaction definitions for a particular method.
+/
abstract class TransactionAspectSupport
{
    /// Logger available to subclasses.
    protected Logger logger;

    private string transactionManagerBeanName;
    private TransactionManager transactionManager;
    private TransactionAttributeSource transactionAttributeSource;
    private BeanFactory beanFactory;

    ///
    this()
    {
        logger = LoggerFactory.getLogger(typeid(this).name);
        transactionAttributeSource = new DescriptorTransactionAttributeSource;
    }

    /// Subclasses can use this to return the current `TransactionInfo`, or null.
    protected static TransactionInfo currentTransactionInfo()
    {
        return transactionInfoHolder.get();
    }

    /++
    Return the transaction status of the current method invocation. Mainly intended for code that wants to set the
    current transaction rollback-only but not throw an application exception. Throws `NoTransactionException` if
    the transaction info cannot be found, because the method was invoked outside an AOP invocation context.
    +/
    static TransactionStatus currentTransactionStatus()
    {
        auto status = currentStatusOrNull(currentTransactionInfo());
        if (status is null)
            throw new NoTransactionException("No transaction aspect-managed TransactionStatus in scope");
        return status;
    }

    private static TransactionStatus currentStatusOrNull(TransactionInfo info)
    {
        return info is null ? null : info.transactionStatus;
    }

    /// Specify the name of the default transaction manager bean.
    void setTransactionManagerBeanName(string transactionManagerBeanName)
    {
        this.transactionManagerBeanName = transactionManagerBeanName;
    }

    /// Return the name of the default transaction manager bean.
    protected final string getTransactionManagerBeanName()
    {
        return transactionManagerBeanName;
    }

    /// Specify the default transaction manager to use to drive transactions.
    void setTransactionManager(TransactionManager transactionManager)
    {
        this.transactionManager = transactionManager;
    }

    /// Return the default transaction manager, or null if unknown.
    TransactionManager getTransactionManager()
    {
        return transactionManager;
    }

    /// Set the transaction attribute source which is used to find transaction attributes.
    void setTransactionAttributeSource(TransactionAttributeSource transactionAttributeSource)
    {
        this.transactionAttributeSource = transactionAttributeSource;
    }

    /// Return the transaction attribute source.
    TransactionAttributeSource getTransactionAttributeSource()
    {
        return transactionAttributeSource;
    }

    /// Set the bean factory to use for retrieving `TransactionManager` beans.
    void setBeanFactory(BeanFactory beanFactory)
    {
        this.beanFactory = beanFactory;
    }

    /// Return the bean factory to use for retrieving `TransactionManager` beans.
    protected final BeanFactory getBeanFactory()
    {
        return beanFactory;
    }

    /// Check that required properties were set (Java's `InitializingBean.afterPropertiesSet`).
    void afterPropertiesSet()
    {
        if (getTransactionManager() is null && beanFactory is null)
            throw new IllegalStateException("Set the 'transactionManager' property or make sure to run within a "
                    ~ "BeanFactory containing a TransactionManager bean!");
        if (getTransactionAttributeSource() is null)
            throw new IllegalStateException("Either 'transactionAttributeSource' or 'transactionAttributes' is "
                    ~ "required: If there are no transactional methods, then don't use a transaction aspect.");
    }

    /++
    General delegate for around-advice-based subclasses, delegating to several other template methods on this class.
    `invocation` proceeds with the target invocation; its result travels in the AOT `Invocation`, so this erased form
    returns nothing. A `RuntimeException` or `Error` rolls back by default, as the attribute's rules decide.
    +/
    protected void invokeWithinTransaction(const(MethodDescriptor)* method,
            const Descriptor targetClass, scope void delegate() @safe invocation)
    {
        auto tas = getTransactionAttributeSource();
        auto txAttr = tas !is null ? tas.getTransactionAttribute(method, targetClass) : null;
        auto ptm = asPlatformTransactionManager(determineTransactionManager(txAttr));
        const joinpointIdentification = methodIdentification(method, targetClass);

        // Standard transaction demarcation with getTransaction and commit/rollback calls.
        auto txInfo = createTransactionIfNecessary(ptm, txAttr, joinpointIdentification);
        bool completed = false;
        // A D Error, which is not caught, still completes the transaction by its rules on the way out.
        scope (failure)
        {
            if (!completed)
            {
                completed = true;
                completeAfterError(txInfo);
            }
        }
        try
            invocation();
        catch (Exception ex)
        {
            // target invocation exception
            completed = true;
            completeTransactionAfterThrowing(txInfo, ex);
            cleanupTransactionInfo(txInfo);
            throw ex;
        }
        cleanupTransactionInfo(txInfo);
        completed = true;
        commitTransactionAfterReturning(txInfo);
    }

    /// Determine the specific transaction manager to use for the given transaction: the qualifier's bean, the
    /// configured bean name or default manager, or the single `TransactionManager` bean.
    protected TransactionManager determineTransactionManager(TransactionAttribute txAttr)
    {
        // Do not attempt to lookup tx manager if no tx attributes are set
        if (txAttr is null || beanFactory is null)
            return getTransactionManager();
        const qualifier = txAttr.getQualifier();
        if (hasText(qualifier))
            return lookupManager(qualifier);
        if (hasText(transactionManagerBeanName))
        {
            auto named = cast(TransactionManager) beanFactory.getBean(transactionManagerBeanName);
            if (named is null)
            {
                const message = "Bean '" ~ transactionManagerBeanName ~ "' is not a TransactionManager";
                throw new IllegalStateException(message);
            }
            return named;
        }
        if (auto defaultTransactionManager = getTransactionManager())
            return defaultTransactionManager;
        return lookupManager(null);
    }

    private TransactionManager lookupManager(string qualifier)
    {
        auto manager = cast(TransactionManager) beanFactory.getBeanOfType("flint.transaction.TransactionManager",
                qualifier);
        if (manager is null)
            throw new IllegalStateException("No TransactionManager found" ~ (qualifier is null
                    ? "" : " for qualifier '" ~ qualifier ~ "'"));
        return manager;
    }

    private static PlatformTransactionManager asPlatformTransactionManager(TransactionManager transactionManager)
    {
        if (transactionManager is null)
            return null;
        auto ptm = cast(PlatformTransactionManager) transactionManager;
        if (ptm is null)
            throw new IllegalStateException(
                    "Specified transaction manager is not a PlatformTransactionManager: " ~ typeid(
                    cast(Object) transactionManager).name);
        return ptm;
    }

    /// Convenience method to return a String representation of this method for use in logging: the method name
    /// qualified by its class, which is also the transaction name.
    protected string methodIdentification(const(MethodDescriptor)* method, const Descriptor targetClass)
    {
        if (method is null)
            return null;
        return targetClass is null ? method.name : targetClass.name ~ "." ~ method.name;
    }

    /// Create a transaction if necessary based on the given `TransactionAttribute`. Allows callers to perform
    /// custom `TransactionAttribute` lookups through the `TransactionAttributeSource`.
    protected TransactionInfo createTransactionIfNecessary(PlatformTransactionManager tm,
            TransactionAttribute txAttr, string joinpointIdentification)
    {
        // If no name specified, apply method identification as transaction name.
        if (txAttr !is null && txAttr.getName() is null)
            txAttr = new NamedTransactionAttribute(txAttr, joinpointIdentification);
        TransactionStatus status = null;
        if (txAttr !is null)
        {
            if (tm !is null)
                status = tm.getTransaction(txAttr);
            else if (logger.isDebugEnabled())
                logger.debug_("Skipping transactional joinpoint [" ~ joinpointIdentification
                        ~ "] because no transaction manager has been configured");
        }
        return prepareTransactionInfo(tm, txAttr, joinpointIdentification, status);
    }

    /// Prepare a `TransactionInfo` for the given attribute and status object, and bind it to the current task.
    protected TransactionInfo prepareTransactionInfo(PlatformTransactionManager tm,
            TransactionAttribute txAttr, string joinpointIdentification, TransactionStatus status)
    {
        auto txInfo = new TransactionInfo(tm, txAttr, joinpointIdentification);
        if (txAttr !is null)
        {
            // We need a transaction for this method...
            if (logger.isTraceEnabled())
                logger.trace("Getting transaction for [" ~ txInfo.getJoinpointIdentification() ~ "]");
            // The transaction manager will flag an error if an incompatible tx already exists.
            txInfo.newTransactionStatus(status);
        }
        else if (logger.isTraceEnabled())
            logger.trace(
                    "No need to create transaction for [" ~ joinpointIdentification
                    ~ "]: This method is not transactional.");
        // We always bind the TransactionInfo to the task, even if we didn't create a new transaction here. This
        // guarantees that the TransactionInfo stack will be managed correctly even if no transaction was created by
        // this aspect.
        txInfo.bindToThread();
        return txInfo;
    }

    /// Execute after successful completion of call, but not after an exception was handled. Do nothing if we
    /// didn't create a transaction.
    protected void commitTransactionAfterReturning(TransactionInfo txInfo)
    {
        if (txInfo !is null && txInfo.getTransactionStatus() !is null)
        {
            if (logger.isTraceEnabled())
                logger.trace("Completing transaction for [" ~ txInfo.getJoinpointIdentification() ~ "]");
            txInfo.getTransactionManager().commit(txInfo.getTransactionStatus());
        }
    }

    /// Handle a throwable, completing the transaction. We may commit or roll back, depending on the configuration.
    protected void completeTransactionAfterThrowing(TransactionInfo txInfo, Throwable ex)
    {
        if (txInfo is null || txInfo.getTransactionStatus() is null)
            return;
        if (logger.isTraceEnabled())
            logger.trace("Completing transaction for [" ~ txInfo.getJoinpointIdentification()
                    ~ "] after exception: " ~ javaToString(ex));
        auto manager = txInfo.getTransactionManager();
        if (txInfo.transactionAttribute !is null && txInfo.transactionAttribute.rollbackOn(ex))
        {
            try
                manager.rollback(txInfo.getTransactionStatus());
            catch (TransactionSystemException ex2)
            {
                logger.error("Application exception overridden by rollback exception", ex);
                ex2.initApplicationException(ex);
                throw ex2;
            }
            catch (Exception ex2)
            {
                logger.error("Application exception overridden by rollback exception", ex);
                throw ex2;
            }
        }
        else
        {
            // We don't roll back on this exception. Will still roll back if TransactionStatus.isRollbackOnly() is
            // true.
            try
                manager.commit(txInfo.getTransactionStatus());
            catch (TransactionSystemException ex2)
            {
                logger.error("Application exception overridden by commit exception", ex);
                ex2.initApplicationException(ex);
                throw ex2;
            }
            catch (Exception ex2)
            {
                logger.error("Application exception overridden by commit exception", ex);
                throw ex2;
            }
        }
    }

    /// Reset the `TransactionInfo` binding. Call this in all cases: exception or normal return!
    protected void cleanupTransactionInfo(TransactionInfo txInfo)
    {
        if (txInfo !is null)
            txInfo.restoreThreadLocalStatus();
    }

    private void completeAfterError(TransactionInfo txInfo) nothrow
    {
        try
        {
            cleanupTransactionInfo(txInfo);
            if (txInfo is null || txInfo.getTransactionStatus() is null)
                return;
            // Error rolls back unless a rule says otherwise; the Error itself is not available here.
            txInfo.getTransactionManager().rollback(txInfo.getTransactionStatus());
        }
        catch (Exception rollbackEx)
        {
            try
                logger.error("Error overridden by rollback exception", rollbackEx);
            catch (Exception)
            {
                // Nothing more can be reported while an Error propagates.
            }
        }
    }

    /// Opaque object used to hold transaction information. Subclasses must pass it back to methods on this class,
    /// but not see its internals.
    protected static final class TransactionInfo
    {
        private PlatformTransactionManager transactionManager;
        private TransactionAttribute transactionAttribute;
        private string joinpointIdentification;
        private TransactionStatus transactionStatus;
        private TransactionInfo oldTransactionInfo;

        ///
        this(PlatformTransactionManager transactionManager,
                TransactionAttribute transactionAttribute, string joinpointIdentification)
        {
            this.transactionManager = transactionManager;
            this.transactionAttribute = transactionAttribute;
            this.joinpointIdentification = joinpointIdentification;
        }

        /// The transaction manager. Throws `IllegalStateException` when none is set.
        PlatformTransactionManager getTransactionManager()
        {
            if (transactionManager is null)
                throw new IllegalStateException("No PlatformTransactionManager set");
            return transactionManager;
        }

        /// The transaction attribute, or null.
        TransactionAttribute getTransactionAttribute()
        {
            return transactionAttribute;
        }

        /// Return a String representation of this joinpoint (usually a Method call) for use in logging.
        string getJoinpointIdentification()
        {
            return joinpointIdentification;
        }

        /// Record the status of the transaction this info describes.
        void newTransactionStatus(TransactionStatus status)
        {
            transactionStatus = status;
        }

        /// The transaction status, or null when no transaction was created.
        TransactionStatus getTransactionStatus()
        {
            return transactionStatus;
        }

        /// Return whether a transaction was created by this aspect, or whether we just have a placeholder to keep
        /// the stack integrity.
        bool hasTransaction()
        {
            return transactionStatus !is null;
        }

        private void bindToThread()
        {
            // Expose current TransactionStatus, preserving any existing TransactionStatus for restoration after
            // this transaction is complete.
            oldTransactionInfo = transactionInfoHolder.get();
            const stored = transactionInfoHolder.set(this);
            if (stored.code != 0)
                throw new IllegalStateException("Could not store the transaction info: " ~ stored.message);
        }

        private void restoreThreadLocalStatus()
        {
            // Use stack to restore old transaction TransactionInfo. Will be null if none was set.
            if (oldTransactionInfo is null)
                transactionInfoHolder.remove();
            else
                cast(void) transactionInfoHolder.set(oldTransactionInfo);
        }

        override string toString()
        {
            return transactionAttribute !is null ? objectText(cast(Object) transactionAttribute) : "No transaction";
        }
    }
}

/// The descriptor that declares an advised method.
private final class Owner
{
    const Descriptor descriptor;

    this(const Descriptor descriptor)
    {
        this.descriptor = descriptor;
    }
}

/// The attribute `createTransactionIfNecessary` uses when the declared one names no transaction.
private final class NamedTransactionAttribute : DelegatingTransactionAttribute
{
    private string name;

    this(TransactionAttribute target, string name)
    {
        super(target);
        this.name = name;
    }

    override string getName()
    {
        return name;
    }
}

private string objectText(Object value)
{
    import flint.engine.aot.objects : objectToString;

    return objectToString(value);
}

/++
AOP advisor for declarative transaction management using the common Spring transaction infrastructure: the runtime
`Advisor` that Flint AOT's proxies run for every method with a merged `@Transactional` (aot-contract section 7).
Register it as a bean, with the default transaction manager or the bean factory to look managers up in.
+/
class TransactionInterceptor : TransactionAspectSupport, Advisor
{
    private int order = int.max;
    // The descriptor that declares each advised method, learned when the chain is built, for transaction names.
    private Owner[const(MethodDescriptor)* ] owners;

    /// Create a new `TransactionInterceptor`. The transaction manager and the bean factory still need to be set.
    this()
    {
    }

    /// Create a new `TransactionInterceptor` with the given default transaction manager.
    this(TransactionManager ptm)
    {
        setTransactionManager(ptm);
    }

    /// Create a new `TransactionInterceptor` with the given default transaction manager and attribute source.
    this(TransactionManager ptm, TransactionAttributeSource tas)
    {
        setTransactionManager(ptm);
        setTransactionAttributeSource(tas);
    }

    /// Set the order of this advisor in the advice chain; lower runs first, outermost. Default: lowest precedence.
    void setOrder(int order)
    {
        this.order = order;
    }

    /// Whether `method` carries a transaction attribute.
    override bool appliesTo(const Descriptor descriptor, const(MethodDescriptor)* method)
    {
        auto tas = getTransactionAttributeSource();
        if (tas is null || tas.getTransactionAttribute(method, descriptor) is null)
            return false;
        synchronized (this)
            owners[method] = new Owner(descriptor);
        return true;
    }

    override int getOrder()
    {
        return order;
    }

    /// Run the rest of the chain and the target within a transaction, as the method's attribute defines it.
    override void invoke(ref Invocation invocation, scope Proceed proceed)
    {
        Invocation* current = &invocation;
        Owner owner;
        synchronized (this)
        {
            if (auto found = invocation.method in owners)
                owner = *found;
        }
        invokeWithinTransaction(invocation.method, owner is null ? null : owner.descriptor, () @safe {
            proceed(*current);
        });
    }
}
