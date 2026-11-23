// Ported from spring-framework v7.1.0: spring-jdbc/src/main/java/org/springframework/jdbc/core/namedparam/NamedParameterJdbcTemplate.java
// Copyright 2002-present the original author or authors.
// Licensed under the Apache License, Version 2.0.
// Modified by the Flint authors.
// Also ported: NamedParameterJdbcOperations.java, NamedParameterUtils.java, ParsedSql.java, SqlParameterSource.java,
// AbstractSqlParameterSource.java, MapSqlParameterSource.java, EmptySqlParameterSource.java,
// BeanPropertySqlParameterSource.java and SqlParameterSourceUtils.java.

/++
`org.springframework.jdbc.core.namedparam`: JDBC operations with named parameters (`:name`), on top of
`JdbcTemplate` (ADR-030).

Values are `Any`; Java's `Map<String, ?>` is `Map!(string, Any)` (R10). A value holding `Any[]` is an IN-list, expanded
to one placeholder per element, as Java expands an `Iterable`. `BeanPropertySqlParameterSource` reads a bean's
properties through its Flint AOT descriptor (R4). As in `flint.jdbc.core`, the generic operations of
`NamedParameterJdbcOperations` are templates over virtual erased forms that take delegates, and every `RowMapper` also
accepts a delegate (R9). `queryForStream` and `queryForRowSet` are deferred to Phase 2 with their `JdbcTemplate`
counterparts.
+/
module flint.jdbc.core.namedparam;

import flint.dao : InvalidDataAccessApiUsageException;
import flint.dao.support : DataAccessUtils;
import flint.engine.aot.any : Any;
import flint.engine.aot.descriptor : Descriptor, PropertyDescriptor, descriptorOf;
import flint.engine.aot.objects : objectToString;
import flint.java.lang : IllegalArgumentException, IllegalStateException;
import flint.java.sql : PreparedStatement, ResultSet;
import flint.java.util : ArrayList, HashMap, LinkedHashMap, List, Map;
import flint.javax.sql : DataSource;
import flint.jdbc.core : BatchPreparedStatementSetter, ColumnMapRowMapper, JdbcOperations,
    JdbcTemplate, PreparedStatementCallback, PreparedStatementCreator,
    PreparedStatementCreatorFactory,
    ResultSetExtractor, ResultSetReader,
    RowCallbackHandler, RowMapper, RowMapperResultSetExtractor, SingleColumnRowMapper, SqlParameter,
    SqlParameterValue, StatementCreatorUtils, parameterValueOf, rowLimit, rowMapper;
import flint.jdbc.support : JdbcUtils, KeyHolder;

@safe:

// ---------------------------------------------------------------------------------------------------------------
// ParsedSql and NamedParameterUtils

/// Holds information about a parsed SQL statement.
class ParsedSql
{
    private string originalSql;
    private string[] parameterNames;
    private int[2][] parameterIndexes;
    private int namedParameterCount;
    private int unnamedParameterCount;
    private int totalParameterCount;

    /// Create a new instance of the `ParsedSql` class.
    package(flint.jdbc) this(string originalSql)
    {
        this.originalSql = originalSql;
    }

    /// Return the SQL statement that is being parsed.
    package(flint.jdbc) string getOriginalSql()
    {
        return originalSql;
    }

    /// Add a named parameter parsed from this SQL statement, with its start and end index.
    package(flint.jdbc) void addNamedParameter(string parameterName, int startIndex, int endIndex)
    {
        parameterNames ~= parameterName;
        parameterIndexes ~= [startIndex, endIndex];
    }

    /// Return all the parameters (bind variables) in the parsed SQL statement. Repeated occurrences of the same
    /// parameter name are included here.
    package(flint.jdbc) string[] getParameterNames()
    {
        return parameterNames;
    }

    /// Return the parameter indexes for the specified parameter: its start and end index in the SQL.
    package(flint.jdbc) int[2] getParameterIndexes(int parameterPosition)
    {
        return parameterIndexes[parameterPosition];
    }

    package(flint.jdbc) void setNamedParameterCount(int namedParameterCount)
    {
        this.namedParameterCount = namedParameterCount;
    }

    /// Return the count of named parameters in the SQL statement. Each parameter name counts once; repeated
    /// occurrences do not count here.
    package(flint.jdbc) int getNamedParameterCount()
    {
        return namedParameterCount;
    }

    package(flint.jdbc) void setUnnamedParameterCount(int unnamedParameterCount)
    {
        this.unnamedParameterCount = unnamedParameterCount;
    }

    /// Return the count of all the unnamed parameters in the SQL statement.
    package(flint.jdbc) int getUnnamedParameterCount()
    {
        return unnamedParameterCount;
    }

    package(flint.jdbc) void setTotalParameterCount(int totalParameterCount)
    {
        this.totalParameterCount = totalParameterCount;
    }

    /// Return the total count of all the parameters in the SQL statement. Repeated occurrences of the same
    /// parameter name do count here.
    package(flint.jdbc) int getTotalParameterCount()
    {
        return totalParameterCount;
    }

    /// Exposes the original SQL String.
    override string toString() const
    {
        return originalSql;
    }
}

/++
Helper methods for named parameter parsing. Only intended for internal use within Spring's JDBC framework. References
to the same parameter name are substituted with the same placeholder; a `:` preceded by a backslash is a literal.
+/
abstract class NamedParameterUtils
{
    private static immutable string[] START_SKIP = ["'", "\"", "--", "/*", "`"];
    private static immutable string[] STOP_SKIP = ["'", "\"", "\n", "*/", "`"];
    private enum string PARAMETER_SEPARATORS = "\"':&,;()|=+-*%/\\<>^";

    /// Parse the SQL statement and locate any placeholders or named parameters. Named parameters are substituted
    /// for a JDBC placeholder.
    static ParsedSql parseSqlStatement(string sql)
    {
        if (sql is null)
            throw new IllegalArgumentException("SQL must not be null");
        auto scanner = Scanner(sql);
        scanner.scan();
        auto parsedSql = new ParsedSql(scanner.sqlToUse);
        foreach (holder; scanner.parameterList)
            parsedSql.addNamedParameter(holder.name, holder.start, holder.end);
        parsedSql.setNamedParameterCount(scanner.namedParameterCount);
        parsedSql.setUnnamedParameterCount(scanner.unnamedParameterCount);
        parsedSql.setTotalParameterCount(scanner.totalParameterCount);
        return parsedSql;
    }

    /// The parser state of `parseSqlStatement`.
    private struct Scanner
    {
        string sql;
        string sqlToUse;
        Holder[] parameterList;
        bool[string] namedParameters;
        int namedParameterCount, unnamedParameterCount, totalParameterCount, escapes;

        this(string sql)
        {
            this.sql = sql;
            sqlToUse = sql;
        }

        void scan()
        {
            size_t i;
            while (i < sql.length)
            {
                i = skipAll(i);
                if (i >= sql.length)
                    break;
                const c = sql[i];
                if (c == ':' || c == '&')
                    i = parameterAt(i);
                else if (c == '\\' && i + 1 < sql.length && sql[i + 1] == ':')
                {
                    // escaped ":" should be skipped
                    sqlToUse = sqlToUse[0 .. i - escapes] ~ sqlToUse[i - escapes + 1 .. $];
                    ++escapes;
                    i += 2;
                }
                else if (c == '?')
                    i = placeholderAt(i);
                else
                    ++i;
            }
        }

        /// Skip every comment and quoted section starting at `i`.
        private size_t skipAll(size_t i)
        {
            for (auto skip = skipCommentsAndQuotes(sql, i); skip != i && i < sql.length; skip = skipCommentsAndQuotes(
                    sql, i))
                i = skip;
            return i;
        }

        /// A `:x`, `&x` or `:{x}` parameter, or Postgres' `::` cast, at `i`; returns the index to continue from.
        private size_t parameterAt(size_t i)
        {
            const c = sql[i];
            // Postgres-style "::" casting operator should be skipped
            if (c == ':' && i + 1 < sql.length && sql[i + 1] == ':')
                return i + 2;
            return c == ':' && i + 1 < sql.length && sql[i + 1] == '{' ? braced(i) : plain(i);
        }

        /// A `?` placeholder, or Postgres' `??`, `?|` or `?&` operator, at `i`; returns the index to continue from.
        private size_t placeholderAt(size_t i)
        {
            // Postgres-style "??", "?|", "?&" operator should be skipped
            if (i + 1 < sql.length && (sql[i + 1] == '?' || sql[i + 1] == '|' || sql[i + 1] == '&'))
                return i + 2;
            ++unnamedParameterCount;
            ++totalParameterCount;
            return i + 1;
        }

        /// A `:{x}` parameter at `i`; returns the index to continue from.
        private size_t braced(size_t i)
        {
            size_t j = i + 1;
            while (sql[j] != '}')
            {
                ++j;
                if (j >= sql.length)
                    throw new InvalidDataAccessApiUsageException(
                            "Non-terminated named parameter declaration at position " ~ decimal(
                            i) ~ " in statement: " ~ sql);
                if (sql[j] == ':' || sql[j] == '{')
                    throw new InvalidDataAccessApiUsageException(
                            "Parameter name contains invalid character '" ~ sql[j] ~ "' at position " ~ decimal(
                            i) ~ " in statement: " ~ sql);
            }
            if (j - i > 2)
                add(sql[i + 2 .. j], i, j + 1);
            return j + 1;
        }

        /// A `:x` or `&x` parameter at `i`; returns the index to continue from.
        private size_t plain(size_t i)
        {
            size_t j = i + 1;
            bool paramWithSquareBrackets;
            while (j < sql.length)
            {
                const c = sql[j];
                if (isParameterSeparator(c))
                    break;
                if (c == '[')
                    paramWithSquareBrackets = true;
                else if (c == ']')
                {
                    if (!paramWithSquareBrackets)
                        break;
                    paramWithSquareBrackets = false;
                }
                ++j;
            }
            if (j - i > 1)
                add(sql[i + 1 .. j], i, j);
            return j;
        }

        private void add(string parameter, size_t start, size_t end)
        {
            if (parameter !in namedParameters)
            {
                namedParameters[parameter] = true;
                ++namedParameterCount;
            }
            parameterList ~= Holder(parameter, cast(int)(start - escapes), cast(int)(end - escapes));
            ++totalParameterCount;
        }
    }

    private struct Holder
    {
        string name;
        int start, end;
    }

    /// Skip over comments and quoted names present in an SQL statement.
    private static size_t skipCommentsAndQuotes(string statement, size_t position)
    {
        foreach (i, start; START_SKIP)
        {
            if (position + start.length > statement.length || statement[position .. position + start.length] != start)
                continue;
            const stop = STOP_SKIP[i];
            for (size_t m = position + start.length; m < statement.length; ++m)
            {
                if (statement[m] != stop[0])
                    continue;
                if (m + stop.length > statement.length) // last comment not closed properly
                    return statement.length;
                if (statement[m .. m + stop.length] == stop) // found character sequence ending comment or quote
                    return m + stop.length;
            }
            // character sequence ending comment or quote not found
            return statement.length;
        }
        return position;
    }

    private static bool isParameterSeparator(char c) pure nothrow @nogc
    {
        foreach (separator; PARAMETER_SEPARATORS)
            if (c == separator)
                return true;
        return c == ' ' || c == '\t' || c == '\n' || c == '\r' || c == '\f' || c == '\v';
    }

    /// Parse the SQL statement and locate any placeholders or named parameters. Named parameters are substituted
    /// for a JDBC placeholder, and any select list is expanded to the required number of placeholders.
    static string substituteNamedParameters(ParsedSql parsedSql, SqlParameterSource paramSource)
    {
        const originalSql = parsedSql.getOriginalSql();
        auto paramNames = parsedSql.getParameterNames();
        if (paramNames.length == 0)
            return originalSql;
        string actualSql;
        size_t lastIndex;
        foreach (i, paramName; paramNames)
        {
            const indexes = parsedSql.getParameterIndexes(cast(int) i);
            actualSql ~= originalSql[lastIndex .. indexes[0]];
            if (paramSource !is null && paramSource.hasValue(paramName))
            {
                auto value = paramSource.getValue(paramName);
                if (auto parameterValue = parameterValueOf(value))
                    value = parameterValue.getValue();
                actualSql ~= value.holds!(Any[]) ? placeholders(value.get!(Any[])) : "?";
            }
            else
                actualSql ~= "?";
            lastIndex = indexes[1];
        }
        return actualSql ~ originalSql[lastIndex .. $];
    }

    /// The placeholders of an IN-list: one per element, or a parenthesized row per element that is itself a list.
    private static string placeholders(Any[] entries)
    {
        string result;
        foreach (k, entry; entries)
        {
            if (k > 0)
                result ~= ", ";
            if (entry.holds!(Any[]))
            {
                result ~= "(";
                foreach (m; 0 .. entry.get!(Any[]).length)
                    result ~= m > 0 ? ", ?" : "?";
                result ~= ")";
            }
            else
                result ~= "?";
        }
        return result;
    }

    /// Convert parameter declarations from a `SqlParameterSource` to a corresponding array of values, in the order
    /// the parsed statement needs them.
    static Any[] buildValueArray(ParsedSql parsedSql, SqlParameterSource paramSource, List!SqlParameter declaredParams)
    {
        auto paramArray = new Any[parsedSql.getTotalParameterCount()];
        if (parsedSql.getNamedParameterCount() > 0 && parsedSql.getUnnamedParameterCount() > 0)
            throw new InvalidDataAccessApiUsageException(
                    "Not allowed to mix named and traditional ? placeholders. You have " ~ decimal(
                    parsedSql.getNamedParameterCount()) ~ " named parameter(s) and " ~ decimal(
                    parsedSql.getUnnamedParameterCount())
                    ~ " traditional placeholder(s) in statement: " ~ parsedSql.getOriginalSql());
        auto declared = declaredParams is null ? null : declaredParams.toArray();
        foreach (i, paramName; parsedSql.getParameterNames())
        {
            try
            {
                auto paramValue = paramSource.getValue(paramName);
                if (parameterValueOf(paramValue) !is null)
                    paramArray[i] = paramValue;
                else
                {
                    auto param = findParameter(declared, paramName, i);
                    paramArray[i] = param !is null ? Any.ofObject(new SqlParameterValue(param, paramValue),
                            typeid(SqlParameterValue).name) : SqlParameterSourceUtils.getTypedValue(paramSource,
                            paramName);
                }
            }
            catch (IllegalArgumentException ex)
                throw new InvalidDataAccessApiUsageException(
                        "No value supplied for the SQL parameter '" ~ paramName ~ "': " ~ ex.msg);
        }
        return paramArray;
    }

    /// Find a matching parameter in the given list of declared parameters.
    private static SqlParameter findParameter(SqlParameter[] declaredParams, string paramName, size_t paramIndex)
    {
        // First pass: Look for named parameter match.
        foreach (declaredParam; declaredParams)
            if (declaredParam.getName() == paramName)
                return declaredParam;
        // Second pass: Look for parameter index match; only accept unnamed parameters for index matches.
        if (paramIndex < declaredParams.length && declaredParams[paramIndex].getName() is null)
            return declaredParams[paramIndex];
        return null;
    }

    /// Convert parameter types from a `SqlParameterSource` into a corresponding int array.
    static int[] buildSqlTypeArray(ParsedSql parsedSql, SqlParameterSource paramSource)
    {
        auto sqlTypes = new int[parsedSql.getTotalParameterCount()];
        foreach (i, paramName; parsedSql.getParameterNames())
            sqlTypes[i] = paramSource.getSqlType(paramName);
        return sqlTypes;
    }

    /// Convert parameter declarations from a `SqlParameterSource` to a corresponding list of `SqlParameter`s.
    static List!SqlParameter buildSqlParameterList(ParsedSql parsedSql, SqlParameterSource paramSource)
    {
        auto params = new ArrayList!SqlParameter;
        foreach (paramName; parsedSql.getParameterNames())
            params.add(new SqlParameter(paramName, paramSource.getSqlType(paramName),
                    paramSource.getTypeName(paramName)));
        return params;
    }

    /// Parse the SQL statement and locate any placeholders or named parameters. Named parameters are substituted
    /// for a JDBC placeholder.
    static string parseSqlStatementIntoString(string sql)
    {
        return substituteNamedParameters(parseSqlStatement(sql), null);
    }

    /// Parse the SQL statement and substitute its named parameters, expanding IN-lists from `paramSource`.
    static string substituteNamedParameters(string sql, SqlParameterSource paramSource)
    {
        return substituteNamedParameters(parseSqlStatement(sql), paramSource);
    }

    /// Convert a `Map` of named parameter values to a corresponding array, in the order the statement needs them.
    static Any[] buildValueArray(string sql, Map!(string, Any) paramMap)
    {
        return buildValueArray(parseSqlStatement(sql), new MapSqlParameterSource(paramMap), null);
    }
}

// ---------------------------------------------------------------------------------------------------------------
// Parameter sources

/++
Interface that defines common functionality for objects that can offer parameter values for named SQL parameters,
serving as argument for `NamedParameterJdbcTemplate` operations.
+/
interface SqlParameterSource
{
    /// Constant that indicates an unknown (or unspecified) SQL type.
    enum int TYPE_UNKNOWN = JdbcUtils.TYPE_UNKNOWN;

    /// Determine whether there is a value for the specified named parameter.
    bool hasValue(string paramName);

    /// Return the parameter value for the requested named parameter. Throws `IllegalArgumentException` if there is
    /// no value for the requested parameter.
    Any getValue(string paramName);

    /// Determine the SQL type for the specified named parameter. Default: `TYPE_UNKNOWN`.
    int getSqlType(string paramName);

    /// Determine the type name for the specified named parameter. Default: null.
    string getTypeName(string paramName);

    /// Enumerate all available parameter names if possible. Default: null.
    string[] getParameterNames();

    /// The Java default bodies.
    mixin template Defaults()
    {
        /// Default: `TYPE_UNKNOWN`.
        int getSqlType(string)
        {
            return SqlParameterSource.TYPE_UNKNOWN;
        }

        /// Default: null.
        string getTypeName(string)
        {
            return null;
        }

        /// Default: null.
        string[] getParameterNames()
        {
            return null;
        }
    }
}

/// Abstract base class for `SqlParameterSource` implementations. Provides registration of SQL types per
/// parameter and a friendly `toString` representation.
abstract class AbstractSqlParameterSource : SqlParameterSource
{
    private int[string] sqlTypes;
    private string[string] typeNames;

    /// Register an SQL type for the given parameter.
    void registerSqlType(string paramName, int sqlType)
    {
        if (paramName is null)
            throw new IllegalArgumentException("Parameter name must not be null");
        sqlTypes[paramName] = sqlType;
    }

    /// Register an SQL type name for the given parameter.
    void registerTypeName(string paramName, string typeName)
    {
        if (paramName is null)
            throw new IllegalArgumentException("Parameter name must not be null");
        typeNames[paramName] = typeName;
    }

    /// Return the SQL type for the given parameter, if registered.
    override int getSqlType(string paramName)
    {
        if (paramName is null)
            throw new IllegalArgumentException("Parameter name must not be null");
        return sqlTypes.get(paramName, TYPE_UNKNOWN);
    }

    /// Return the type name for the given parameter, if registered.
    override string getTypeName(string paramName)
    {
        if (paramName is null)
            throw new IllegalArgumentException("Parameter name must not be null");
        return typeNames.get(paramName, null);
    }

    override string[] getParameterNames()
    {
        return null;
    }

    /// Enumerate the parameter names and values with their corresponding SQL type if available, or just return the
    /// simple `SqlParameterSource` implementation class name otherwise.
    override string toString()
    {
        auto simpleName = simpleNameOf(this);
        auto parameterNames = getParameterNames();
        if (parameterNames is null)
            return simpleName;
        string result = simpleName ~ " {";
        foreach (index, parameterName; parameterNames)
        {
            auto value = getValue(parameterName);
            if (auto parameterValue = parameterValueOf(value))
                value = parameterValue.getValue();
            auto typeName = getTypeName(parameterName);
            if (typeName is null)
            {
                const sqlType = getSqlType(parameterName);
                if (sqlType != TYPE_UNKNOWN)
                    typeName = decimal(sqlType);
            }
            result ~= (index ? ", " : "") ~ parameterName ~ "=" ~ (value.isNull ? "null" : value.toString());
            if (typeName !is null)
                result ~= " (type:" ~ typeName ~ ")";
        }
        return result ~ "}";
    }
}

/++
`SqlParameterSource` implementation that holds a given `Map` of parameters. This class is intended for passing in a
simple `Map` of parameter values to the methods of the `NamedParameterJdbcTemplate` class. The `addValue` methods
can be used to add values to this parameter source, and return the source for chained calls.
+/
class MapSqlParameterSource : AbstractSqlParameterSource
{
    private Map!(string, Any) values;

    /// Create an empty `MapSqlParameterSource`, with values to be added via `addValue`.
    this()
    {
        values = new LinkedHashMap!(string, Any);
    }

    /// Create a new `MapSqlParameterSource`, with one value comprised of the supplied arguments.
    this(T)(string paramName, T value)
    {
        this();
        addValue(paramName, value);
    }

    /// Create a new `MapSqlParameterSource` based on a `Map`.
    this(Map!(string, Any) values)
    {
        this();
        // Java's addValues, without a virtual call in a constructor.
        if (values !is null)
            values.forEach((string key, Any value) { addAny(key, value); });
    }

    /// Add a parameter to this parameter source (R7: any D value, or an `Any`).
    MapSqlParameterSource addValue(T)(string paramName, T value)
    {
        return addAny(paramName, toAny(value));
    }

    /// Add a parameter to this parameter source, with its SQL type.
    MapSqlParameterSource addValue(T)(string paramName, T value, int sqlType)
    {
        addAny(paramName, toAny(value));
        registerSqlType(paramName, sqlType);
        return this;
    }

    /// Add a parameter to this parameter source, with its SQL type and type name.
    MapSqlParameterSource addValue(T)(string paramName, T value, int sqlType, string typeName)
    {
        addAny(paramName, toAny(value));
        registerSqlType(paramName, sqlType);
        registerTypeName(paramName, typeName);
        return this;
    }

    private MapSqlParameterSource addAny(string paramName, Any value)
    {
        if (paramName is null)
            throw new IllegalArgumentException("Parameter name must not be null");
        values.put(paramName, value);
        if (auto parameterValue = parameterValueOf(value))
            registerSqlType(paramName, parameterValue.getSqlType());
        return this;
    }

    /// Add a `Map` of parameters to this parameter source.
    MapSqlParameterSource addValues(Map!(string, Any) values)
    {
        if (values !is null)
            values.forEach((string key, Any value) { addAny(key, value); });
        return this;
    }

    /// Return whether this parameter source has been configured with any values.
    bool hasValues()
    {
        return !values.isEmpty();
    }

    /// Expose the current parameter values as a read-only `Map`.
    Map!(string, Any) getValues()
    {
        return values;
    }

    override bool hasValue(string paramName)
    {
        return values.containsKey(paramName);
    }

    override Any getValue(string paramName)
    {
        if (!hasValue(paramName))
            throw new IllegalArgumentException("No value registered for key '" ~ paramName ~ "'");
        return values.get(paramName);
    }

    override string[] getParameterNames()
    {
        return values.keySet().toArray();
    }
}

/// A simple empty implementation of the `SqlParameterSource` interface.
class EmptySqlParameterSource : SqlParameterSource
{
    /// An instance of `EmptySqlParameterSource`. Java shares one constant; this one is stateless, and a framework
    /// module keeps no mutable module-level state, so each call returns a new instance.
    static EmptySqlParameterSource INSTANCE()
    {
        return new EmptySqlParameterSource;
    }

    override bool hasValue(string)
    {
        return false;
    }

    override Any getValue(string)
    {
        throw new IllegalArgumentException("This SqlParameterSource is empty");
    }

    override int getSqlType(string)
    {
        return TYPE_UNKNOWN;
    }

    override string getTypeName(string)
    {
        return null;
    }

    override string[] getParameterNames()
    {
        return null;
    }
}

/// The callback of the erased `execute`.
alias PreparedStatementAction = void delegate(PreparedStatement) @safe;

/// The empty parameter source of the parameterless operations.
private SqlParameterSource emptyParameters()
{
    return EmptySqlParameterSource.INSTANCE();
}

/++
`SqlParameterSource` implementation that obtains parameter values from bean properties of a given object, through the
object's Flint AOT descriptor (R4). A property's SQL type is derived from its D type unless registered.
+/
class BeanPropertySqlParameterSource : AbstractSqlParameterSource
{
    private Any bean;
    private const(Descriptor) descriptor;
    private string[] propertyNames;

    /// Create a new `BeanPropertySqlParameterSource` for the given bean.
    this(T)(T object) if (is(T == class))
    {
        if (object is null)
            throw new IllegalArgumentException("Bean object must not be null");
        this(Any.of(object), descriptorOf!T());
    }

    /// Create a new `BeanPropertySqlParameterSource` for a bean held by `bean`, described by `descriptor`: the erased
    /// engine of the template constructor.
    this(Any bean, const(Descriptor) descriptor)
    {
        this.bean = bean;
        this.descriptor = descriptor;
    }

    override bool hasValue(string paramName)
    {
        auto property = descriptor.property(paramName);
        return property !is null && property.get !is null;
    }

    override Any getValue(string paramName)
    {
        auto property = descriptor.property(paramName);
        if (property is null || property.get is null)
            throw new IllegalArgumentException("Invalid property '" ~ paramName ~ "' of bean class ["
                    ~ descriptor.name ~ "]: Bean property '" ~ paramName ~ "' is not readable");
        return property.get(bean);
    }

    /// Derives a default SQL type from the corresponding property type.
    override int getSqlType(string paramName)
    {
        const sqlType = super.getSqlType(paramName);
        if (sqlType != TYPE_UNKNOWN)
            return sqlType;
        auto property = descriptor.property(paramName);
        return property is null ? TYPE_UNKNOWN : StatementCreatorUtils.javaTypeToSqlParameterType(property.type);
    }

    override string[] getParameterNames()
    {
        return getReadablePropertyNames();
    }

    /// Provide access to the property names of the wrapped bean.
    string[] getReadablePropertyNames()
    {
        if (propertyNames is null)
            foreach (property; descriptor.properties)
                if (property.get !is null)
                    propertyNames ~= property.name;
        return propertyNames;
    }
}

/// Class that provides helper methods for the use of `SqlParameterSource`, in particular with
/// `NamedParameterJdbcTemplate`.
abstract class SqlParameterSourceUtils
{
    /// Create an array of `SqlParameterSource` objects populated with data from the values passed in (either `Map`s
    /// or bean objects). This will define what is included in a batch operation.
    static SqlParameterSource[] createBatch(Objects...)(Objects candidates)
    {
        SqlParameterSource[] batch;
        static foreach (index, Candidate; Objects)
        {
            static if (is(Candidate : SqlParameterSource))
                batch ~= candidates[index];
            else static if (is(Candidate : Map!(string, Any)))
                batch ~= new MapSqlParameterSource(candidates[index]);
            else static if (is(Candidate == E[], E))
            {
                foreach (element; candidates[index])
                    batch ~= createBatch(element);
            }
            else
                batch ~= new BeanPropertySqlParameterSource(candidates[index]);
        }
        return batch;
    }

    /// Create an array of `MapSqlParameterSource` objects populated with data from the values passed in.
    static SqlParameterSource[] createBatch(Map!(string, Any)[] valueMaps)
    {
        auto batch = new SqlParameterSource[valueMaps.length];
        foreach (i, valueMap; valueMaps)
            batch[i] = new MapSqlParameterSource(valueMap);
        return batch;
    }

    /// Create a wrapped value if parameter has type information, plain object if not.
    static Any getTypedValue(SqlParameterSource source, string parameterName)
    {
        const sqlType = source.getSqlType(parameterName);
        if (sqlType != SqlParameterSource.TYPE_UNKNOWN)
            return Any.ofObject(new SqlParameterValue(sqlType, source.getTypeName(parameterName),
                    source.getValue(parameterName)), typeid(SqlParameterValue).name);
        return source.getValue(parameterName);
    }

    /// Create a `Map` with all the parameter names in lower case, mapped to the parameter names themselves.
    static Map!(string, string) extractCaseInsensitiveParameterNames(SqlParameterSource parameterSource)
    {
        auto caseInsensitiveParameterNames = new HashMap!(string, string);
        foreach (name; parameterSource.getParameterNames())
            caseInsensitiveParameterNames.put(lower(name), name);
        return caseInsensitiveParameterNames;
    }
}

// ---------------------------------------------------------------------------------------------------------------
// NamedParameterJdbcOperations and NamedParameterJdbcTemplate

/++
Interface specifying a basic set of JDBC operations allowing the use of named parameters rather than the
traditional '?' placeholders. Implemented by `NamedParameterJdbcTemplate`.

The generic operations are templates (R4) over virtual erased forms that take delegates.
+/
interface NamedParameterJdbcOperations
{
    /// Expose the classic `JdbcTemplate` itself, if available, in particular for passing it on to other
    /// `JdbcTemplate` consumers.
    JdbcOperations getJdbcOperations();

    // Erased forms.

    /// Execute a JDBC data access operation on a `PreparedStatement` for `sql` with the given parameters.
    void execute(string sql, SqlParameterSource paramSource, scope PreparedStatementAction action);

    /// Query given SQL and parameters, reading the `ResultSet` with the given delegate.
    void query(string sql, SqlParameterSource paramSource, ResultSetReader extractor);

    // Non-generic operations.

    /// Query given SQL to create a prepared statement from SQL and a list of arguments to bind to the query,
    /// reading the `ResultSet` on a per-row basis with a `RowCallbackHandler`.
    void query(string sql, SqlParameterSource paramSource, RowCallbackHandler rch);

    /// ditto, with a `Map` of parameters.
    void query(string sql, Map!(string, Any) paramMap, RowCallbackHandler rch);

    /// Query given SQL without parameters, reading the `ResultSet` on a per-row basis.
    void query(string sql, RowCallbackHandler rch);

    /// Query given SQL and parameters, expecting a result map.
    Map!(string, Any) queryForMap(string sql, SqlParameterSource paramSource);

    /// ditto, with a `Map` of parameters.
    Map!(string, Any) queryForMap(string sql, Map!(string, Any) paramMap);

    /// Query given SQL and parameters, expecting a result list of maps: one per row.
    List!(Map!(string, Any)) queryForList(string sql, SqlParameterSource paramSource);

    /// ditto, with a `Map` of parameters.
    List!(Map!(string, Any)) queryForList(string sql, Map!(string, Any) paramMap);

    /// Issue an update via a prepared statement, binding the given arguments.
    int update(string sql, SqlParameterSource paramSource);

    /// ditto, with a `Map` of parameters.
    int update(string sql, Map!(string, Any) paramMap);

    /// Issue an update via a prepared statement, binding the given arguments, returning generated keys.
    int update(string sql, SqlParameterSource paramSource, KeyHolder generatedKeyHolder);

    /// Issue an update via a prepared statement, binding the given arguments, returning the generated keys of the
    /// given columns.
    int update(string sql, SqlParameterSource paramSource, KeyHolder generatedKeyHolder, string[] keyColumnNames);

    /// Execute a batch using the supplied SQL statement with the batch of supplied arguments.
    int[] batchUpdate(string sql, SqlParameterSource[] batchArgs);

    /// Executes a batch using the supplied SQL statement with the batch of supplied arguments.
    int[] batchUpdate(string sql, Map!(string, Any)[] batchValues);

    /// Execute a batch using the supplied SQL statement with the batch of supplied arguments, returning generated
    /// keys.
    int[] batchUpdate(string sql, SqlParameterSource[] batchArgs, KeyHolder generatedKeyHolder);

    /// ditto, for the given key columns.
    int[] batchUpdate(string sql, SqlParameterSource[] batchArgs, KeyHolder keyHolder, string[] keyColumns);

    // Generic operations (R4).

    /// Execute a JDBC data access operation, implemented as callback action working on a JDBC `PreparedStatement`.
    T execute(T)(string sql, SqlParameterSource paramSource, PreparedStatementCallback!T action)
    {
        T result;
        execute(sql, paramSource, (PreparedStatement ps) { result = action.doInPreparedStatement(ps); });
        return result;
    }

    /// ditto, with a `Map` of parameters.
    T execute(T)(string sql, Map!(string, Any) paramMap, PreparedStatementCallback!T action)
    {
        return execute(sql, new MapSqlParameterSource(paramMap), action);
    }

    /// ditto, with no parameters.
    T execute(T)(string sql, PreparedStatementCallback!T action)
    {
        return execute(sql, emptyParameters(), action);
    }

    /// Query given SQL and parameters, reading the `ResultSet` with a `ResultSetExtractor`.
    T query(T)(string sql, SqlParameterSource paramSource, ResultSetExtractor!T rse)
    {
        T result;
        query(sql, paramSource, ResultSetReader((ResultSet rs) { result = rse.extractData(rs); }));
        return result;
    }

    /// ditto, with a `Map` of parameters.
    T query(T)(string sql, Map!(string, Any) paramMap, ResultSetExtractor!T rse)
    {
        return query(sql, new MapSqlParameterSource(paramMap), rse);
    }

    /// ditto, with no parameters.
    T query(T)(string sql, ResultSetExtractor!T rse)
    {
        return query(sql, emptyParameters(), rse);
    }

    /// Query given SQL and parameters, mapping each row to a result object via a `RowMapper`.
    List!T query(T)(string sql, SqlParameterSource paramSource, RowMapper!T rowMapper)
    {
        return query(sql, paramSource, new RowMapperResultSetExtractor!T(rowMapper, 0, rowLimit(getJdbcOperations())));
    }

    /// ditto, with a `Map` of parameters.
    List!T query(T)(string sql, Map!(string, Any) paramMap, RowMapper!T rowMapper)
    {
        return query(sql, new MapSqlParameterSource(paramMap), rowMapper);
    }

    /// ditto, with no parameters.
    List!T query(T)(string sql, RowMapper!T rowMapper)
    {
        return query(sql, emptyParameters(), rowMapper);
    }

    /// Query given SQL and parameters, mapping each row with a delegate (R9).
    List!T query(T)(string sql, SqlParameterSource paramSource, T delegate(ResultSet, int) @safe mapper)
    {
        return query(sql, paramSource, .rowMapper(mapper));
    }

    /// ditto, with a `Map` of parameters.
    List!T query(T)(string sql, Map!(string, Any) paramMap, T delegate(ResultSet, int) @safe mapper)
    {
        return query(sql, new MapSqlParameterSource(paramMap), .rowMapper(mapper));
    }

    /// ditto, with no parameters.
    List!T query(T)(string sql, T delegate(ResultSet, int) @safe mapper)
    {
        return query(sql, emptyParameters(), .rowMapper(mapper));
    }

    /// Query given SQL and parameters, mapping a single result row via a `RowMapper`. Throws
    /// `IncorrectResultSizeDataAccessException` if the query does not return exactly one row.
    T queryForObject(T)(string sql, SqlParameterSource paramSource, RowMapper!T rowMapper)
    {
        return DataAccessUtils.nullableSingleResult(query(sql, paramSource,
                new RowMapperResultSetExtractor!T(rowMapper, 1)));
    }

    /// ditto, with a `Map` of parameters.
    T queryForObject(T)(string sql, Map!(string, Any) paramMap, RowMapper!T rowMapper)
    {
        return queryForObject(sql, new MapSqlParameterSource(paramMap), rowMapper);
    }

    /// Query given SQL and parameters, mapping a single result row with a delegate (R9).
    T queryForObject(T)(string sql, SqlParameterSource paramSource, T delegate(ResultSet, int) @safe mapper)
    {
        return queryForObject(sql, paramSource, .rowMapper(mapper));
    }

    /// ditto, with a `Map` of parameters.
    T queryForObject(T)(string sql, Map!(string, Any) paramMap, T delegate(ResultSet, int) @safe mapper)
    {
        return queryForObject(sql, new MapSqlParameterSource(paramMap), .rowMapper(mapper));
    }

    /// Query given SQL and parameters for a single result object of type `T` (Java's `Class<T>`, R4).
    T queryForObject(T)(string sql, SqlParameterSource paramSource)
    {
        return queryForObject(sql, paramSource, new SingleColumnRowMapper!T);
    }

    /// ditto, with a `Map` of parameters.
    T queryForObject(T)(string sql, Map!(string, Any) paramMap)
    {
        return queryForObject!T(sql, new MapSqlParameterSource(paramMap));
    }

    /// Query given SQL and parameters for a result list of `T` values (R4).
    List!T queryForList(T)(string sql, SqlParameterSource paramSource)
    {
        return query(sql, paramSource, new SingleColumnRowMapper!T);
    }

    /// ditto, with a `Map` of parameters.
    List!T queryForList(T)(string sql, Map!(string, Any) paramMap)
    {
        return queryForList!T(sql, new MapSqlParameterSource(paramMap));
    }
}

/++
Template class with a basic set of JDBC operations, allowing the use of named parameters rather than traditional '?'
placeholders. This class delegates to a wrapped `JdbcTemplate` once the substitution from named parameters to JDBC
style '?' placeholders is done at execution time. It also allows for expanding a `List` of values to the appropriate
number of placeholders.
+/
class NamedParameterJdbcTemplate : NamedParameterJdbcOperations
{
    /// Default maximum number of entries for this template's SQL cache: 256.
    enum int DEFAULT_CACHE_LIMIT = 256;

    private JdbcOperations classicJdbcTemplate;
    private int cacheLimit = DEFAULT_CACHE_LIMIT;
    private ParsedSql[string] parsedSqlCache;

    /// Create a new `NamedParameterJdbcTemplate` for the given `DataSource`. Creates a classic `JdbcTemplate` and
    /// wraps it.
    this(DataSource dataSource)
    {
        this(new JdbcTemplate(dataSource));
    }

    /// Create a new `NamedParameterJdbcTemplate` for the given classic `JdbcTemplate`.
    this(JdbcOperations classicJdbcTemplate)
    {
        if (classicJdbcTemplate is null)
            throw new IllegalArgumentException("JdbcTemplate must not be null");
        this.classicJdbcTemplate = classicJdbcTemplate;
    }

    /// Create a new `NamedParameterJdbcTemplate` for the given classic `JdbcTemplate`, sharing the SQL cache of
    /// `original`.
    this(NamedParameterJdbcTemplate original, JdbcTemplate classicJdbcTemplate)
    {
        this(classicJdbcTemplate);
        cacheLimit = original.cacheLimit;
        parsedSqlCache = original.parsedSqlCache;
    }

    override JdbcOperations getJdbcOperations()
    {
        return classicJdbcTemplate;
    }

    /// Expose the classic `JdbcTemplate` itself, if available.
    JdbcTemplate getJdbcTemplate()
    {
        auto template_ = cast(JdbcTemplate) classicJdbcTemplate;
        if (template_ is null)
            throw new IllegalStateException("No JdbcTemplate available");
        return template_;
    }

    /// Specify the maximum number of entries for this template's SQL cache. Default is 256. 0 indicates no caching,
    /// always parsing each statement.
    void setCacheLimit(int cacheLimit)
    {
        synchronized (this)
        {
            this.cacheLimit = cacheLimit;
            parsedSqlCache = null;
        }
    }

    /// Return the maximum number of entries for this template's SQL cache.
    int getCacheLimit()
    {
        return cacheLimit;
    }

    override void execute(string sql, SqlParameterSource paramSource, scope PreparedStatementAction action)
    {
        getJdbcOperations().execute(getPreparedStatementCreator(sql, paramSource), action);
    }

    override void query(string sql, SqlParameterSource paramSource, ResultSetReader extractor)
    {
        getJdbcOperations().query(getPreparedStatementCreator(sql, paramSource), null, extractor);
    }

    override void query(string sql, SqlParameterSource paramSource, RowCallbackHandler rch)
    {
        getJdbcOperations().query(getPreparedStatementCreator(sql, paramSource), rch);
    }

    override void query(string sql, Map!(string, Any) paramMap, RowCallbackHandler rch)
    {
        query(sql, new MapSqlParameterSource(paramMap), rch);
    }

    override void query(string sql, RowCallbackHandler rch)
    {
        query(sql, emptyParameters(), rch);
    }

    override Map!(string, Any) queryForMap(string sql, SqlParameterSource paramSource)
    {
        auto result = queryForObject(sql, paramSource, new ColumnMapRowMapper);
        if (result is null)
            throw new IllegalStateException("No result map");
        return result;
    }

    override Map!(string, Any) queryForMap(string sql, Map!(string, Any) paramMap)
    {
        return queryForMap(sql, new MapSqlParameterSource(paramMap));
    }

    override List!(Map!(string, Any)) queryForList(string sql, SqlParameterSource paramSource)
    {
        return query(sql, paramSource, new ColumnMapRowMapper);
    }

    override List!(Map!(string, Any)) queryForList(string sql, Map!(string, Any) paramMap)
    {
        return queryForList(sql, new MapSqlParameterSource(paramMap));
    }

    override int update(string sql, SqlParameterSource paramSource)
    {
        return getJdbcOperations().update(getPreparedStatementCreator(sql, paramSource));
    }

    override int update(string sql, Map!(string, Any) paramMap)
    {
        return update(sql, new MapSqlParameterSource(paramMap));
    }

    override int update(string sql, SqlParameterSource paramSource, KeyHolder generatedKeyHolder)
    {
        return update(sql, paramSource, generatedKeyHolder, null);
    }

    override int update(string sql, SqlParameterSource paramSource, KeyHolder generatedKeyHolder,
            string[] keyColumnNames)
    {
        auto psc = getPreparedStatementCreator(sql, paramSource, (PreparedStatementCreatorFactory pscf) {
            if (keyColumnNames !is null)
                pscf.setGeneratedKeysColumnNames(keyColumnNames);
            else
                pscf.setReturnGeneratedKeys(true);
        });
        return getJdbcOperations().update(psc, generatedKeyHolder);
    }

    override int[] batchUpdate(string sql, SqlParameterSource[] batchArgs)
    {
        if (batchArgs.length == 0)
            return [];
        auto parsedSql = getParsedSql(sql);
        auto pscf = getPreparedStatementCreatorFactory(parsedSql, batchArgs[0]);
        return getJdbcOperations().batchUpdate(pscf.getSql(), new NamedBatchSetter(parsedSql, pscf, batchArgs, false));
    }

    override int[] batchUpdate(string sql, Map!(string, Any)[] batchValues)
    {
        return batchUpdate(sql, SqlParameterSourceUtils.createBatch(batchValues));
    }

    override int[] batchUpdate(string sql, SqlParameterSource[] batchArgs, KeyHolder generatedKeyHolder)
    {
        return batchUpdate(sql, batchArgs, generatedKeyHolder, null);
    }

    override int[] batchUpdate(string sql, SqlParameterSource[] batchArgs,
            KeyHolder generatedKeyHolder, string[] keyColumnNames)
    {
        if (batchArgs.length == 0)
            return [];
        auto parsedSql = getParsedSql(sql);
        auto pscf = getPreparedStatementCreatorFactory(parsedSql, batchArgs[0]);
        if (keyColumnNames !is null)
            pscf.setGeneratedKeysColumnNames(keyColumnNames);
        else
            pscf.setReturnGeneratedKeys(true);
        auto params = NamedParameterUtils.buildValueArray(parsedSql, batchArgs[0], null);
        auto psc = pscf.newPreparedStatementCreator(params);
        // batchArgs[0] is already set by pscf.newPreparedStatementCreator().
        return getJdbcOperations().batchUpdate(psc, new NamedBatchSetter(parsedSql, pscf, batchArgs,
                true), generatedKeyHolder);
    }

    /// Build a `PreparedStatementCreator` based on the given SQL and named parameters.
    protected PreparedStatementCreator getPreparedStatementCreator(string sql, SqlParameterSource paramSource)
    {
        return getPreparedStatementCreator(sql, paramSource, null);
    }

    /// Build a `PreparedStatementCreator` based on the given SQL and named parameters, with a customizer for the
    /// `PreparedStatementCreatorFactory` (Java's `Consumer`, R9).
    protected PreparedStatementCreator getPreparedStatementCreator(string sql,
            SqlParameterSource paramSource, scope void delegate(PreparedStatementCreatorFactory) @safe customizer)
    {
        auto parsedSql = getParsedSql(sql);
        auto pscf = getPreparedStatementCreatorFactory(parsedSql, paramSource);
        if (customizer !is null)
            customizer(pscf);
        auto params = NamedParameterUtils.buildValueArray(parsedSql, paramSource, null);
        return pscf.newPreparedStatementCreator(params);
    }

    /// Obtain a parsed representation of the given SQL statement. The default implementation uses an LRU cache
    /// with an upper limit of 256 entries.
    protected ParsedSql getParsedSql(string sql)
    {
        if (sql is null)
            throw new IllegalArgumentException("SQL must not be null");
        if (cacheLimit <= 0)
            return NamedParameterUtils.parseSqlStatement(sql);
        synchronized (this)
        {
            if (auto cached = sql in parsedSqlCache)
                return *cached;
            // A bounded cache: when full, start again rather than track recency.
            if (parsedSqlCache.length >= cacheLimit)
                parsedSqlCache = null;
            auto parsedSql = NamedParameterUtils.parseSqlStatement(sql);
            parsedSqlCache[sql] = parsedSql;
            return parsedSql;
        }
    }

    /// Build a `PreparedStatementCreatorFactory` based on the given SQL and named parameters.
    protected PreparedStatementCreatorFactory getPreparedStatementCreatorFactory(ParsedSql parsedSql,
            SqlParameterSource paramSource)
    {
        auto sqlToUse = NamedParameterUtils.substituteNamedParameters(parsedSql, paramSource);
        auto declaredParameters = NamedParameterUtils.buildSqlParameterList(parsedSql, paramSource);
        return new PreparedStatementCreatorFactory(sqlToUse, declaredParameters);
    }

    alias execute = NamedParameterJdbcOperations.execute;
    alias query = NamedParameterJdbcOperations.query;
    alias queryForObject = NamedParameterJdbcOperations.queryForObject;

    /// `NamedParameterJdbcOperations.queryForList!T`, declared here so that explicit instantiation finds it beside
    /// this class's overrides.
    List!T queryForList(T)(string sql, SqlParameterSource paramSource)
    {
        return query(sql, paramSource, new SingleColumnRowMapper!T);
    }

    /// ditto
    List!T queryForList(T)(string sql, Map!(string, Any) paramMap)
    {
        return query(sql, new MapSqlParameterSource(paramMap), new SingleColumnRowMapper!T);
    }
}

/// The setter of the named-parameter batch updates.
private final class NamedBatchSetter : BatchPreparedStatementSetter
{
    private ParsedSql parsedSql;
    private PreparedStatementCreatorFactory pscf;
    private SqlParameterSource[] batchArgs;
    private bool firstAlreadySet;

    this(ParsedSql parsedSql, PreparedStatementCreatorFactory pscf, SqlParameterSource[] batchArgs, bool firstSet)
    {
        this.parsedSql = parsedSql;
        this.pscf = pscf;
        this.batchArgs = batchArgs;
        firstAlreadySet = firstSet;
    }

    override void setValues(PreparedStatement ps, int i)
    {
        if (i == 0 && firstAlreadySet)
            return;
        auto values = NamedParameterUtils.buildValueArray(parsedSql, batchArgs[i], null);
        pscf.newPreparedStatementSetter(values).setValues(ps);
    }

    override int getBatchSize()
    {
        return cast(int) batchArgs.length;
    }
}

// ---------------------------------------------------------------------------------------------------------------
// Helpers

private Any toAny(T)(T value)
{
    static if (is(T == Any))
        return value;
    else static if (is(T == typeof(null)))
        return Any.init;
    else static if (is(T : Object))
        return value is null ? Any.init : Any.ofObject(value, typeid(value).name);
    else
        return Any.of(value);
}

private string simpleNameOf(Object object)
{
    const name = typeid(object).name;
    foreach_reverse (index, ch; name)
        if (ch == '.')
            return name[index + 1 .. $];
    return name;
}

private string lower(string text)
{
    auto result = text.dup;
    foreach (ref c; result)
        if (c >= 'A' && c <= 'Z')
            c += 32;
    return result.idup;
}

private string decimal(long value)
{
    import flint.engine.aot.text : decimal;

    return decimal(value);
}
