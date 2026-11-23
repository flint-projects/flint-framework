// Ported from spring-framework v7.1.0: spring-jdbc/src/main/java/org/springframework/jdbc/datasource/init/ScriptUtils.java
// Copyright 2002-present the original author or authors.
// Licensed under the Apache License, Version 2.0.
// Modified by the Flint authors.
// Also ported: DatabasePopulator.java, ResourceDatabasePopulator.java, CompositeDatabasePopulator.java,
// DatabasePopulatorUtils.java, DataSourceInitializer.java, ScriptException.java, ScriptParseException.java,
// ScriptStatementFailedException.java, CannotReadScriptException.java and UncategorizedScriptException.java.

/++
`org.springframework.jdbc.datasource.init`: populating, initializing and cleaning up a database with SQL scripts, as
Boot's SQL initialization does with `schema.sql` and `data.sql` (ADR-030).

Scripts are `flint.core.io.Resource`s, read as UTF-8 text with `getContentAsString`. Spring's `EncodedResource`
overloads take the `Resource` itself, and the script encoding is recorded but only UTF-8 is read; messages describe a
script by its `getDescription()`. Spring's statement splitting, comment and quote rules are ported as written.
+/
module flint.jdbc.datasource.init;

import flint.beans.factory : DisposableBean, InitializingBean;
import flint.core.io : Resource;
import flint.dao : DataAccessException;
import flint.java.lang : IllegalArgumentException, IllegalStateException;
import flint.java.sql : Connection, SQLException, SQLWarning, Statement;
import flint.javax.sql : DataSource;
import flint.jdbc.datasource : DataSourceUtils;
import flint.slf4j : Logger, LoggerFactory;

@safe:

// ---------------------------------------------------------------------------------------------------------------
// Exceptions

/// Root of the hierarchy of data access exceptions that are related to processing of SQL scripts.
abstract class ScriptException : DataAccessException
{
    /// Create a new `ScriptException` with the given message and an optional root cause.
    this(string message, Throwable cause = null, string file = __FILE__, size_t line = __LINE__)
    {
        super(message, cause, file, line);
    }
}

/// Thrown by `ScriptUtils` if an SQL script cannot be properly parsed.
class ScriptParseException : ScriptException
{
    /// Create a new `ScriptParseException` for the script `resource` (may be null) and an optional cause.
    this(string message, Resource resource, Throwable cause = null, string file = __FILE__, size_t line = __LINE__)
    {
        super("Failed to parse SQL script from resource [" ~ (resource is null
                ? "<unknown>" : resource.getDescription()) ~ "]: " ~ message, cause, file, line);
    }
}

/// Thrown by `ScriptUtils` if a statement in an SQL script failed when executing it against the target database.
class ScriptStatementFailedException : ScriptException
{
    /// Create a new `ScriptStatementFailedException` for statement `stmtNumber` of `resource`.
    this(string stmt, int number, Resource res, Throwable cause, string file = __FILE__, size_t line = __LINE__)
    {
        super(buildErrorMessage(stmt, number, res), cause, file, line);
    }

    /// Build an error message for an SQL script execution failure, based on the supplied arguments.
    static string buildErrorMessage(string stmt, int stmtNumber, Resource resource)
    {
        import flint.engine.aot.text : decimal;

        return "Failed to execute SQL script statement #" ~ decimal(
                long(stmtNumber)) ~ " of " ~ resource.getDescription() ~ ": " ~ stmt;
    }
}

/// Thrown by `ScriptUtils` if an SQL script cannot be read.
class CannotReadScriptException : ScriptException
{
    /// Create a new `CannotReadScriptException` for `resource`.
    this(Resource resource, Throwable cause, string file = __FILE__, size_t line = __LINE__)
    {
        super("Cannot read SQL script from " ~ resource.getDescription(), cause, file, line);
    }
}

/// Thrown when we cannot determine anything more specific than "something went wrong while processing an SQL
/// script": for example, an `SQLException` from JDBC that we cannot pinpoint more precisely.
class UncategorizedScriptException : ScriptException
{
    /// Create a new `UncategorizedScriptException` with an optional root cause.
    this(string message, Throwable cause = null, string file = __FILE__, size_t line = __LINE__)
    {
        super(message, cause, file, line);
    }
}

// ---------------------------------------------------------------------------------------------------------------
// ScriptUtils

/// Generic utility methods for working with SQL scripts in conjunction with JDBC. Mainly for internal use within
/// the framework.
abstract class ScriptUtils
{
    /// Default statement separator within SQL scripts: ";".
    enum string DEFAULT_STATEMENT_SEPARATOR = ";";
    /// Fallback statement separator within SQL scripts: "\n". Used if neither a custom separator nor the
    /// `DEFAULT_STATEMENT_SEPARATOR` is present in a given script.
    enum string FALLBACK_STATEMENT_SEPARATOR = "\n";
    /// End of file (EOF) SQL statement separator: "^^^ END OF SCRIPT ^^^". The script is then one statement.
    enum string EOF_STATEMENT_SEPARATOR = "^^^ END OF SCRIPT ^^^";
    /// Default prefix for single-line comments within SQL scripts: "--".
    enum string DEFAULT_COMMENT_PREFIX = "--";
    /// Default prefixes for single-line comments within SQL scripts: `["--"]`.
    enum string[] DEFAULT_COMMENT_PREFIXES = [DEFAULT_COMMENT_PREFIX];
    /// Default start delimiter for block comments within SQL scripts: "/*".
    enum string DEFAULT_BLOCK_COMMENT_START_DELIMITER = "/*";
    /// Default end delimiter for block comments within SQL scripts: "*/".
    enum string DEFAULT_BLOCK_COMMENT_END_DELIMITER = "*/";

    private static Logger logger()
    {
        return LoggerFactory.getLogger("org.springframework.jdbc.datasource.init.ScriptUtils");
    }

    /// Execute the given SQL script using default settings for statement separators, comment delimiters, and
    /// exception handling flags.
    static void executeSqlScript(Connection connection, Resource resource)
    {
        executeSqlScript(connection, resource, false, false, DEFAULT_COMMENT_PREFIX, DEFAULT_STATEMENT_SEPARATOR,
                DEFAULT_BLOCK_COMMENT_START_DELIMITER, DEFAULT_BLOCK_COMMENT_END_DELIMITER);
    }

    /// Execute the given SQL script, with one comment prefix.
    static void executeSqlScript(Connection connection, Resource resource, bool continueOnError, bool ignoreFailedDrops,
            string commentPrefix, string separator, string blockCommentStartDelimiter, string blockCommentEndDelimiter)
    {
        executeSqlScript(connection, resource, continueOnError, ignoreFailedDrops, [commentPrefix],
                separator, blockCommentStartDelimiter, blockCommentEndDelimiter);
    }

    /++
    Execute the given SQL script. Statement separators and comments will be removed before executing individual
    statements within the supplied script. A null `separator` means `DEFAULT_STATEMENT_SEPARATOR`, falling back to
    `FALLBACK_STATEMENT_SEPARATOR` when the script contains none.
    +/
    static void executeSqlScript(Connection connection, Resource resource, bool continueOnError, bool ignoreFailedDrops,
            string[] commentPrefixes, string separator, string blockCommentStartDelimiter,
            string blockCommentEndDelimiter)
    {
        try
        {
            if (logger().isDebugEnabled())
                logger().debug_("Executing SQL script from " ~ resource.getDescription());
            string script;
            try
                script = readScript(resource, separator, commentPrefixes, blockCommentEndDelimiter);
            catch (ScriptException ex)
                throw ex;
            catch (Exception ex)
                throw new CannotReadScriptException(resource, ex);
            if (separator is null)
                separator = DEFAULT_STATEMENT_SEPARATOR;
            if (separator != EOF_STATEMENT_SEPARATOR && !containsStatementSeparator(resource, script,
                    separator, commentPrefixes, blockCommentStartDelimiter, blockCommentEndDelimiter))
                separator = FALLBACK_STATEMENT_SEPARATOR;
            string[] statements;
            splitSqlScript(resource, script, separator, commentPrefixes,
                    blockCommentStartDelimiter, blockCommentEndDelimiter, statements);
            executeStatements(connection, resource, statements, continueOnError, ignoreFailedDrops);
            if (logger().isDebugEnabled())
                logger().debug_("Executed SQL script from " ~ resource.getDescription());
        }
        catch (ScriptException ex)
            throw ex;
        catch (Exception ex)
            throw new UncategorizedScriptException(
                    "Failed to execute database script from resource [" ~ resource.getDescription() ~ "]", ex);
    }

    private static void executeStatements(Connection connection, Resource resource,
            string[] statements, bool continueOnError, bool ignoreFailedDrops)
    {
        auto stmt = connection.createStatement();
        scope (exit)
            closeQuietly(stmt);
        foreach (index, statement; statements)
        {
            const stmtNumber = cast(int) index + 1;
            try
                executeStatement(stmt, statement);
            catch (SQLException ex)
            {
                const dropStatement = startsWithIgnoreCase(trim(statement), "drop");
                if (!continueOnError && !(dropStatement && ignoreFailedDrops))
                    throw new ScriptStatementFailedException(statement, stmtNumber, resource, ex);
                if (logger().isDebugEnabled())
                    logger().debug_(ScriptStatementFailedException.buildErrorMessage(statement,
                            stmtNumber, resource), ex);
            }
        }
    }

    private static void closeQuietly(Statement stmt) nothrow
    {
        try
            stmt.close();
        catch (Exception ex)
        {
            try
                logger().trace("Could not close JDBC Statement", ex);
            catch (Exception)
            {
            }
        }
    }

    private static void executeStatement(Statement stmt, string statement)
    {
        bool hasResultSet = stmt.execute(statement);
        int updateCount = -1;
        if (logger().isDebugEnabled())
            logSqlWarnings(stmt);
        do
        {
            if (hasResultSet)
            {
                // We invoke getResultSet() to ensure the JDBC driver processes it, but we intentionally ignore the
                // returned ResultSet since we cannot do anything meaningful with it here.
                stmt.getResultSet();
                if (logger().isDebugEnabled())
                    logger().debug_("ResultSet returned for SQL: " ~ statement);
            }
            else
                updateCount = stmt.getUpdateCount();
            hasResultSet = stmt.getMoreResults();
        }
        while (hasResultSet || updateCount != -1);
    }

    private static void logSqlWarnings(Statement stmt)
    {
        import flint.engine.aot.text : decimal;

        for (auto warning = stmt.getWarnings(); warning !is null; warning = warning.getNextWarning())
        {
            const code = decimal(long(warning.getErrorCode()));
            logger().debug_("SQLWarning ignored: SQL state '" ~ warning.getSQLState()
                    ~ "', error code '" ~ code ~ "', message [" ~ warning.msg ~ "]");
        }
    }

    /// Read a script from the given resource, using the comment prefixes and statement separator, and build a
    /// string containing the lines. Lines beginning with a comment prefix are excluded, unless they contain the
    /// block comment end delimiter.
    package(flint.jdbc) static string readScript(Resource resource, string separator,
            string[] commentPrefixes, string blockCommentEndDelimiter)
    {
        string script;
        bool first = true;
        foreach (line; lines(resource.getContentAsString()))
        {
            if ((blockCommentEndDelimiter !is null && contains(line, blockCommentEndDelimiter))
                    || (commentPrefixes !is null && !startsWithAny(line, commentPrefixes, 0)))
            {
                if (!first)
                    script ~= '\n';
                script ~= line;
                first = false;
            }
        }
        return appendSeparatorIfNecessary(script, separator);
    }

    private static string appendSeparatorIfNecessary(string script, string separator)
    {
        if (separator is null)
            return script;
        const trimmed = trim(separator);
        if (trimmed.length == separator.length)
            return script;
        // The separator ends in whitespace, so we might want to see if the script is trying to end the same way.
        if (script.length >= trimmed.length && script[$ - trimmed.length .. $] == trimmed)
            return script ~ separator[trimmed.length .. $];
        return script;
    }

    /// Determine if the provided SQL script contains the specified statement separator, outside quotes and
    /// comments.
    package(flint.jdbc) static bool containsStatementSeparator(Resource resource, string script, string separator,
            string[] commentPrefixes, string blockCommentStartDelimiter, string blockCommentEndDelimiter)
    {
        auto scanner = Scanner(resource, script, separator, commentPrefixes,
                blockCommentStartDelimiter, blockCommentEndDelimiter);
        string[] none;
        return scanner.run(false, none);
    }

    /++
    Split an SQL script into separate statements delimited by the provided separator string. Each individual
    statement will be added to `statements`. Within the script, `commentPrefixes` and block comments are omitted,
    and multiple adjacent whitespace characters are collapsed into a single space, outside quotes.
    +/
    static void splitSqlScript(Resource resource, string script, string separator, string[] commentPrefixes,
            string blockCommentStartDelimiter, string blockCommentEndDelimiter, ref string[] statements)
    {
        if (trim(script).length == 0)
            throw new IllegalArgumentException("'script' must not be null or empty");
        if (separator is null)
            throw new IllegalArgumentException("'separator' must not be null");
        if (commentPrefixes.length == 0)
            throw new IllegalArgumentException("'commentPrefixes' must not be null or empty");
        foreach (commentPrefix; commentPrefixes)
            if (trim(commentPrefix).length == 0)
                throw new IllegalArgumentException("'commentPrefixes' must not contain null or empty elements");
        if (trim(blockCommentStartDelimiter).length == 0)
            throw new IllegalArgumentException("'blockCommentStartDelimiter' must not be null or empty");
        if (trim(blockCommentEndDelimiter).length == 0)
            throw new IllegalArgumentException("'blockCommentEndDelimiter' must not be null or empty");
        auto scanner = Scanner(resource, script, separator, commentPrefixes,
                blockCommentStartDelimiter, blockCommentEndDelimiter);
        scanner.run(true, statements);
    }

    /// The shared loop of `containsStatementSeparator` (no statements collected) and `splitSqlScript`.
    private struct Scanner
    {
        Resource resource;
        string script, separator;
        string[] commentPrefixes;
        string blockStart, blockEnd;

        /// Returns whether a separator was seen; collects the statements into `statements` when `collect`.
        bool run(bool collect, ref string[] statements)
        {
            string sb;
            Quotes quotes;
            size_t i;
            while (i < script.length)
            {
                const c = script[i];
                if (quotes.escapes(c) || quotes.open)
                {
                    sb ~= c;
                    ++i;
                    continue;
                }
                if (startsWithAt(script, separator, i))
                {
                    if (!collect)
                        return true;
                    // We've reached the end of the current statement
                    if (sb.length)
                        statements ~= sb;
                    sb = null;
                    i += separator.length;
                    continue;
                }
                const skipped = skipComment(i);
                if (skipped == size_t.max) // A line comment with no EOL: we must be at the end of the script, so stop here.
                    break;
                if (skipped != i)
                {
                    i = skipped + 1;
                    continue;
                }
                ++i;
                appendCollapsed(sb, c);
            }
            if (collect && trim(sb).length)
                statements ~= sb;
            return false;
        }

        /// Append `c`, collapsing a run of whitespace characters into a single space.
        private static void appendCollapsed(ref string sb, char c)
        {
            if (c == ' ' || c == '\r' || c == '\n' || c == '\t')
            {
                // Avoid multiple adjacent whitespace characters
                if (sb.length == 0 || sb[$ - 1] == ' ')
                    return;
                c = ' ';
            }
            sb ~= c;
        }

        /// The index of the last character of the comment starting at `i`; `i` when none starts there, and
        /// `size_t.max` for a line comment that runs to the end of the script.
        private size_t skipComment(size_t i)
        {
            if (startsWithAny(script, commentPrefixes, i))
            {
                // Skip over any content from the start of the comment to the EOL
                const next = indexOf(script, '\n', i);
                return next < 0 || cast(size_t) next <= i ? size_t.max : cast(size_t) next;
            }
            if (!startsWithAt(script, blockStart, i))
                return i;
            // Skip over any block comments
            const end = indexOfText(script, blockEnd, i);
            if (end < 0 || cast(size_t) end <= i)
                throw new ScriptParseException("Missing block comment end delimiter: " ~ blockEnd, resource);
            return end + blockEnd.length - 1;
        }
    }

    /// The quoting state of the scan: single and double quotes, and MySQL-style backslash escapes.
    private struct Quotes
    {
        bool single, double_, escape;

        /// Whether `c` is part of an escape; otherwise, update the quoting for `c`.
        bool escapes(char c) pure nothrow @nogc
        {
            if (escape)
            {
                escape = false;
                return true;
            }
            if (c == '\\')
            {
                escape = true;
                return true;
            }
            if (!double_ && c == '\'')
                single = !single;
            else if (!single && c == '"')
                double_ = !double_;
            return false;
        }

        /// Whether the scan is inside a quoted section (the closing quote counts as outside).
        bool open() const pure nothrow @nogc
        {
            return single || double_;
        }
    }
}

// ---------------------------------------------------------------------------------------------------------------
// Populators

/// Strategy used to populate, initialize, or clean up a database.
interface DatabasePopulator
{
    /// Populate, initialize, or clean up the database using the provided JDBC connection. Throws `ScriptException`
    /// in all cases, rather than an `SQLException`.
    void populate(Connection connection);
}

/++
Populates, initializes, or cleans up a database using SQL scripts defined in external resources. Call `addScript` to
add a single SQL script location, `addScripts` to add multiple, and the setters to configure how the scripts are
parsed and executed. Then call `populate` or `execute`.
+/
class ResourceDatabasePopulator : DatabasePopulator
{
    package(flint.jdbc) Resource[] scripts;
    private string sqlScriptEncoding;
    private string separator = ScriptUtils.DEFAULT_STATEMENT_SEPARATOR;
    private string[] commentPrefixes = ScriptUtils.DEFAULT_COMMENT_PREFIXES;
    private string blockCommentStartDelimiter = ScriptUtils.DEFAULT_BLOCK_COMMENT_START_DELIMITER;
    private string blockCommentEndDelimiter = ScriptUtils.DEFAULT_BLOCK_COMMENT_END_DELIMITER;
    private bool continueOnError;
    private bool ignoreFailedDrops;

    /// Construct a new `ResourceDatabasePopulator` with default settings.
    this()
    {
    }

    /// Construct a new `ResourceDatabasePopulator` with default settings for the supplied scripts.
    this(Resource[] scripts...)
    {
        checkScripts(scripts);
        this.scripts = scripts.dup;
    }

    /// Construct a new `ResourceDatabasePopulator` with the supplied values.
    this(bool continueOnError, bool ignoreFailedDrops, string sqlScriptEncoding, Resource[] scripts...)
    {
        this.continueOnError = continueOnError;
        this.ignoreFailedDrops = ignoreFailedDrops;
        this.sqlScriptEncoding = trim(sqlScriptEncoding).length ? sqlScriptEncoding : null;
        checkScripts(scripts);
        this.scripts = scripts.dup;
    }

    /// Add a script to execute to initialize or clean up the database.
    void addScript(Resource script)
    {
        if (script is null)
            throw new IllegalArgumentException("'script' must not be null");
        scripts ~= script;
    }

    /// Add multiple scripts to execute to initialize or clean up the database.
    void addScripts(Resource[] scripts...)
    {
        checkScripts(scripts);
        this.scripts ~= scripts;
    }

    /// Set the scripts to execute to initialize or clean up the database, replacing any previously added scripts.
    void setScripts(Resource[] scripts...)
    {
        checkScripts(scripts);
        this.scripts = scripts.dup;
    }

    private static void checkScripts(scope Resource[] scripts)
    {
        foreach (script; scripts)
            if (script is null)
                throw new IllegalArgumentException("'scripts' must not contain null elements");
    }

    /// Specify the encoding for the configured SQL scripts, if different from the platform encoding. Flint reads
    /// scripts as UTF-8.
    void setSqlScriptEncoding(string sqlScriptEncoding)
    {
        this.sqlScriptEncoding = trim(sqlScriptEncoding).length ? sqlScriptEncoding : null;
    }

    /// Specify the statement separator, if a custom one. Defaults to ";" if not specified and falls back to "\n" as
    /// a last resort; may be set to `ScriptUtils.EOF_STATEMENT_SEPARATOR` to signal that each script contains a
    /// single statement without a separator.
    void setSeparator(string separator)
    {
        this.separator = separator;
    }

    /// Set the prefix that identifies single-line comments within the SQL scripts. Defaults to "--".
    void setCommentPrefix(string commentPrefix)
    {
        if (trim(commentPrefix).length == 0)
            throw new IllegalArgumentException("'commentPrefix' must not be null or empty");
        commentPrefixes = [commentPrefix];
    }

    /// Set the prefixes that identify single-line comments within the SQL scripts. Defaults to `["--"]`.
    void setCommentPrefixes(string[] commentPrefixes...)
    {
        if (commentPrefixes.length == 0)
            throw new IllegalArgumentException("'commentPrefixes' must not be null or empty");
        foreach (prefix; commentPrefixes)
            if (prefix is null)
                throw new IllegalArgumentException("'commentPrefixes' must not contain null elements");
        this.commentPrefixes = commentPrefixes.dup;
    }

    /// Set the start delimiter that identifies block comments within the SQL scripts. Defaults to "/*".
    void setBlockCommentStartDelimiter(string blockCommentStartDelimiter)
    {
        if (trim(blockCommentStartDelimiter).length == 0)
            throw new IllegalArgumentException("'blockCommentStartDelimiter' must not be null or empty");
        this.blockCommentStartDelimiter = blockCommentStartDelimiter;
    }

    /// Set the end delimiter that identifies block comments within the SQL scripts. Defaults to "*/".
    void setBlockCommentEndDelimiter(string blockCommentEndDelimiter)
    {
        if (trim(blockCommentEndDelimiter).length == 0)
            throw new IllegalArgumentException("'blockCommentEndDelimiter' must not be null or empty");
        this.blockCommentEndDelimiter = blockCommentEndDelimiter;
    }

    /// Flag to indicate that all failures in SQL should be logged but not cause a failure. Defaults to false.
    void setContinueOnError(bool continueOnError)
    {
        this.continueOnError = continueOnError;
    }

    /// Flag to indicate that a failed SQL `DROP` statement can be ignored. Defaults to false.
    void setIgnoreFailedDrops(bool ignoreFailedDrops)
    {
        this.ignoreFailedDrops = ignoreFailedDrops;
    }

    /// Populate the database with the configured scripts and settings.
    override void populate(Connection connection)
    {
        if (connection is null)
            throw new IllegalArgumentException("'connection' must not be null");
        foreach (script; scripts)
            ScriptUtils.executeSqlScript(connection, script, continueOnError, ignoreFailedDrops,
                    commentPrefixes, separator, blockCommentStartDelimiter, blockCommentEndDelimiter);
    }

    /// Execute this `ResourceDatabasePopulator` against the given `DataSource`. Delegates to
    /// `DatabasePopulatorUtils.execute`.
    void execute(DataSource dataSource)
    {
        DatabasePopulatorUtils.execute(this, dataSource);
    }
}

/// Composite `DatabasePopulator` that delegates to a list of given `DatabasePopulator` implementations, executing
/// all scripts.
class CompositeDatabasePopulator : DatabasePopulator
{
    private DatabasePopulator[] populators;

    /// Create an empty `CompositeDatabasePopulator`.
    this()
    {
    }

    /// Create a `CompositeDatabasePopulator` with the given populators.
    this(DatabasePopulator[] populators...)
    {
        this.populators = populators.dup;
    }

    /// Specify one or more populators to delegate to.
    void setPopulators(DatabasePopulator[] populators...)
    {
        this.populators = populators.dup;
    }

    /// Add one or more populators to the list of delegates.
    void addPopulators(DatabasePopulator[] populators...)
    {
        this.populators ~= populators;
    }

    override void populate(Connection connection)
    {
        if (connection is null)
            throw new IllegalArgumentException("Connection must not be null");
        foreach (populator; populators)
            populator.populate(connection);
    }
}

/// Utility methods for executing a `DatabasePopulator`.
abstract class DatabasePopulatorUtils
{
    /// Execute the given `DatabasePopulator` against the given `DataSource`. As of Spring 5.3.11, this commits the
    /// populator's statements unless the connection takes part in a transaction.
    static void execute(DatabasePopulator populator, DataSource dataSource)
    {
        if (populator is null)
            throw new IllegalArgumentException("DatabasePopulator must not be null");
        if (dataSource is null)
            throw new IllegalArgumentException("DataSource must not be null");
        try
        {
            auto connection = DataSourceUtils.getConnection(dataSource);
            scope (exit)
                DataSourceUtils.releaseConnection(connection, dataSource);
            populator.populate(connection);
            if (!connection.getAutoCommit() && !DataSourceUtils.isConnectionTransactional(connection, dataSource))
                connection.commit();
        }
        catch (ScriptException ex)
            throw ex;
        catch (Exception ex)
            throw new UncategorizedScriptException("Failed to execute database script", ex);
    }
}

/// Used to set up a database during initialization and clean up a database during destruction.
class DataSourceInitializer : InitializingBean, DisposableBean
{
    private DataSource dataSource;
    private DatabasePopulator databasePopulator;
    private DatabasePopulator databaseCleaner;
    private bool enabled = true;

    /// The `DataSource` for the database to populate when this component is initialized and to clean up when
    /// this component is shut down.
    void setDataSource(DataSource dataSource)
    {
        this.dataSource = dataSource;
    }

    /// Set the `DatabasePopulator` to execute during the bean initialization phase.
    void setDatabasePopulator(DatabasePopulator databasePopulator)
    {
        this.databasePopulator = databasePopulator;
    }

    /// Set the `DatabasePopulator` to execute during the bean destruction phase, cleaning up the database.
    void setDatabaseCleaner(DatabasePopulator databaseCleaner)
    {
        this.databaseCleaner = databaseCleaner;
    }

    /// Flag to explicitly enable or disable the database populator and database cleaner.
    void setEnabled(bool enabled)
    {
        this.enabled = enabled;
    }

    /// Use the database populator to set up the database.
    override void afterPropertiesSet()
    {
        execute(databasePopulator);
    }

    /// Use the database cleaner to clean up the database.
    override void destroy()
    {
        execute(databaseCleaner);
    }

    private void execute(DatabasePopulator populator)
    {
        if (dataSource is null)
            throw new IllegalStateException("DataSource must be set");
        if (enabled && populator !is null)
            DatabasePopulatorUtils.execute(populator, dataSource);
    }
}

// ---------------------------------------------------------------------------------------------------------------
// Text helpers

/// The lines of `text`, as `LineNumberReader.readLine` returns them: without "\n", "\r\n" or "\r".
private string[] lines(string text)
{
    string[] result;
    size_t start;
    for (size_t i; i < text.length; ++i)
    {
        if (text[i] != '\n' && text[i] != '\r')
            continue;
        result ~= text[start .. i];
        if (text[i] == '\r' && i + 1 < text.length && text[i + 1] == '\n')
            ++i;
        start = i + 1;
    }
    if (start < text.length)
        result ~= text[start .. $];
    return result;
}

private bool startsWithAt(string text, string prefix, size_t offset) pure nothrow @nogc
{
    return prefix.length && offset + prefix.length <= text.length && text[offset .. offset + prefix.length] == prefix;
}

private bool startsWithAny(string text, string[] prefixes, size_t offset) pure nothrow @nogc
{
    foreach (prefix; prefixes)
        if (startsWithAt(text, prefix, offset))
            return true;
    return false;
}

private bool contains(string text, string needle) pure nothrow @nogc
{
    return indexOfText(text, needle, 0) >= 0;
}

private ptrdiff_t indexOf(string text, char c, size_t from) pure nothrow @nogc
{
    foreach (i; from .. text.length)
        if (text[i] == c)
            return i;
    return -1;
}

private ptrdiff_t indexOfText(string text, string needle, size_t from) pure nothrow @nogc
{
    if (needle.length == 0 || needle.length > text.length)
        return needle.length == 0 ? from : -1;
    foreach (i; from .. text.length - needle.length + 1)
        if (text[i .. i + needle.length] == needle)
            return i;
    return -1;
}

private string trim(string text) pure nothrow @nogc
{
    static bool blank(char c) pure nothrow @nogc
    {
        return c == ' ' || c == '\t' || c == '\n' || c == '\r';
    }

    size_t start, end = text.length;
    while (start < end && blank(text[start]))
        ++start;
    while (end > start && blank(text[end - 1]))
        --end;
    return text[start .. end];
}

private bool startsWithIgnoreCase(string text, string prefix) pure nothrow @nogc
{
    if (text.length < prefix.length)
        return false;
    foreach (i, c; prefix)
    {
        const t = text[i] >= 'A' && text[i] <= 'Z' ? cast(char)(text[i] + 32) : text[i];
        if (t != c)
            return false;
    }
    return true;
}
