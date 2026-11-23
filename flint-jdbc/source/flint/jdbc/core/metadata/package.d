// Ported from spring-framework v7.1.0: spring-jdbc/src/main/java/org/springframework/jdbc/core/metadata/TableMetaDataContext.java
// Copyright 2002-present the original author or authors.
// Licensed under the Apache License, Version 2.0.
// Modified by the Flint authors.
// Also ported: TableMetaDataProvider.java, TableParameterMetaData.java, GenericTableMetaDataProvider.java,
// PostgresTableMetaDataProvider.java and TableMetaDataProviderFactory.java.

/++
`org.springframework.jdbc.core.metadata`, the table part: what `SimpleJdbcInsert` learns about a table from the
driver's `DatabaseMetaData` (its columns and their SQL types) to build its insert statement (ADR-030).

The Flint driver serves SQLite and PostgreSQL, so the providers are the generic one and PostgreSQL's; the Oracle,
Derby, HSQL and MySQL providers, and the call (stored procedure) metadata, are not ported.
+/
module flint.jdbc.core.metadata;

import flint.dao : DataAccessResourceFailureException, InvalidDataAccessApiUsageException;
import flint.engine.aot.any : Any;
import flint.java.sql : Connection, DatabaseMetaData, ResultSet, SQLException, Types;
import flint.java.util : ArrayList, List, Map;
import flint.javax.sql : DataSource;
import flint.jdbc.core : SqlTypeValue;
import flint.jdbc.core.namedparam : SqlParameterSource, SqlParameterSourceUtils;
import flint.jdbc.datasource : DataSourceUtils;
import flint.jdbc.support : JdbcUtils;
import flint.slf4j : Logger, LoggerFactory;

@safe:

/// Holder of meta-data for a specific parameter that is used for table processing.
class TableParameterMetaData
{
    private string parameterName;
    private int sqlType;
    private bool nullable;

    /// Constructor taking all the properties.
    this(string columnName, int sqlType, bool nullable)
    {
        parameterName = columnName;
        this.sqlType = sqlType;
        this.nullable = nullable;
    }

    /// Return the parameter name.
    string getParameterName()
    {
        return parameterName;
    }

    /// Return the parameter SQL type.
    int getSqlType()
    {
        return sqlType;
    }

    /// Return whether the parameter/column is nullable.
    bool isNullable()
    {
        return nullable;
    }
}

/// Interface specifying the API to be implemented by a class providing table meta-data. This is intended for
/// internal use by the Simple JDBC classes.
interface TableMetaDataProvider
{
    /// Initialize using the database meta-data provided.
    void initializeWithMetaData(DatabaseMetaData databaseMetaData);

    /// Initialize using provided database meta-data, table and column information.
    void initializeWithTableColumnMetaData(DatabaseMetaData databaseMetaData, string catalogName,
            string schemaName, string tableName);

    /// Get the table name formatted based on meta-data information.
    string tableNameToUse(string tableName);

    /// Get the column name formatted based on meta-data information.
    string columnNameToUse(string columnName);

    /// Get the catalog name formatted based on meta-data information.
    string catalogNameToUse(string catalogName);

    /// Get the schema name formatted based on meta-data information.
    string schemaNameToUse(string schemaName);

    /// Provide any modification of the catalog name passed in to match the meta-data currently used.
    string metaDataCatalogNameToUse(string catalogName);

    /// Provide any modification of the schema name passed in to match the meta-data currently used.
    string metaDataSchemaNameToUse(string schemaName);

    /// Are we using the meta-data for the table columns?
    bool isTableColumnMetaDataUsed();

    /// Does this database support the JDBC feature for retrieving generated keys?
    bool isGetGeneratedKeysSupported();

    /// Does this database support a simple query to retrieve generated keys when the JDBC feature for retrieving
    /// generated keys is not supported?
    bool isGetGeneratedKeysSimulated();

    /// Get the simple query to retrieve generated keys.
    string getSimpleQueryForGetGeneratedKey(string tableName, string keyColumnName);

    /// Does this database support a column name String array for retrieving generated keys?
    bool isGeneratedKeysColumnNameArraySupported();

    /// Get the table parameter meta-data that is currently used.
    List!TableParameterMetaData getTableParameterMetaData();

    /// Get the string used to quote SQL identifiers.
    string getIdentifierQuoteString();
}

/++
A generic implementation of the `TableMetaDataProvider` interface which should provide enough features for all
supported databases.
+/
class GenericTableMetaDataProvider : TableMetaDataProvider
{
    private string userName;
    private string databaseVersion;
    private bool tableColumnMetaDataUsed;
    private bool getGeneratedKeysSupported = true;
    private bool generatedKeysColumnNameArraySupported = true;
    private bool storesUpperCaseIdentifiers = true;
    private bool storesLowerCaseIdentifiers;
    private string identifierQuoteString = " ";
    private List!TableParameterMetaData tableParameterMetaData;

    /// Constructor used to initialize with provided database meta-data.
    protected this(DatabaseMetaData databaseMetaData)
    {
        userName = databaseMetaData.getUserName();
        tableParameterMetaData = new ArrayList!TableParameterMetaData;
    }

    private static Logger logger()
    {
        return LoggerFactory.getLogger("org.springframework.jdbc.core.metadata.TableMetaDataProvider");
    }

    override void initializeWithMetaData(DatabaseMetaData databaseMetaData)
    {
        try
        {
            setGetGeneratedKeysSupported(databaseMetaData.supportsGetGeneratedKeys());
            setGeneratedKeysColumnNameArraySupported(isGetGeneratedKeysSupported());
            databaseVersion = databaseMetaData.getDatabaseProductVersion();
            setStoresUpperCaseIdentifiers(databaseMetaData.storesUpperCaseIdentifiers());
            setStoresLowerCaseIdentifiers(databaseMetaData.storesLowerCaseIdentifiers());
            identifierQuoteString = databaseMetaData.getIdentifierQuoteString();
        }
        catch (SQLException ex)
            logger().warn("Error retrieving database meta-data: " ~ ex.msg);
    }

    override void initializeWithTableColumnMetaData(DatabaseMetaData databaseMetaData,
            string catalogName, string schemaName, string tableName)
    {
        tableColumnMetaDataUsed = true;
        locateTableAndProcessMetaData(databaseMetaData, catalogName, schemaName, tableName);
    }

    override List!TableParameterMetaData getTableParameterMetaData()
    {
        return tableParameterMetaData;
    }

    override string tableNameToUse(string tableName)
    {
        return identifierNameToUse(tableName);
    }

    override string columnNameToUse(string columnName)
    {
        return identifierNameToUse(columnName);
    }

    override string catalogNameToUse(string catalogName)
    {
        return identifierNameToUse(catalogName);
    }

    override string schemaNameToUse(string schemaName)
    {
        return identifierNameToUse(schemaName);
    }

    private string identifierNameToUse(string identifierName)
    {
        if (identifierName is null)
            return null;
        if (isStoresUpperCaseIdentifiers())
            return upper(identifierName);
        if (isStoresLowerCaseIdentifiers())
            return lower(identifierName);
        return identifierName;
    }

    override string metaDataCatalogNameToUse(string catalogName)
    {
        return catalogNameToUse(catalogName);
    }

    override string metaDataSchemaNameToUse(string schemaName)
    {
        return schemaNameToUse(schemaName !is null ? schemaName : getDefaultSchema());
    }

    /// Provide access to the default schema for subclasses.
    protected string getDefaultSchema()
    {
        return userName;
    }

    /// Provide access to the version info for subclasses.
    protected string getDatabaseVersion()
    {
        return databaseVersion;
    }

    override bool isTableColumnMetaDataUsed()
    {
        return tableColumnMetaDataUsed;
    }

    /// Specify whether a column name array is supported for generated keys.
    void setGetGeneratedKeysSupported(bool getGeneratedKeysSupported)
    {
        this.getGeneratedKeysSupported = getGeneratedKeysSupported;
    }

    override bool isGetGeneratedKeysSupported()
    {
        return getGeneratedKeysSupported;
    }

    override bool isGetGeneratedKeysSimulated()
    {
        return false;
    }

    override string getSimpleQueryForGetGeneratedKey(string, string)
    {
        return null;
    }

    /// Specify whether a column name array is supported for generated keys.
    void setGeneratedKeysColumnNameArraySupported(bool generatedKeysColumnNameArraySupported)
    {
        this.generatedKeysColumnNameArraySupported = generatedKeysColumnNameArraySupported;
    }

    override bool isGeneratedKeysColumnNameArraySupported()
    {
        return generatedKeysColumnNameArraySupported;
    }

    /// Specify whether the database stores identifiers in upper case.
    void setStoresUpperCaseIdentifiers(bool storesUpperCaseIdentifiers)
    {
        this.storesUpperCaseIdentifiers = storesUpperCaseIdentifiers;
    }

    /// Get whether the database stores identifiers in upper case.
    bool isStoresUpperCaseIdentifiers()
    {
        return storesUpperCaseIdentifiers;
    }

    /// Specify whether the database stores identifiers in lower case.
    void setStoresLowerCaseIdentifiers(bool storesLowerCaseIdentifiers)
    {
        this.storesLowerCaseIdentifiers = storesLowerCaseIdentifiers;
    }

    /// Get whether the database stores identifiers in lower case.
    bool isStoresLowerCaseIdentifiers()
    {
        return storesLowerCaseIdentifiers;
    }

    override string getIdentifierQuoteString()
    {
        return identifierQuoteString;
    }

    /// Method supporting the meta-data processing for a table.
    private void locateTableAndProcessMetaData(DatabaseMetaData databaseMetaData, string catalogName,
            string schemaName, string tableName)
    {
        TableMetaData[string] tableMeta;
        ResultSet tables;
        try
        {
            tables = databaseMetaData.getTables(catalogNameToUse(catalogName),
                    schemaNameToUse(schemaName), tableNameToUse(tableName), null);
            while (tables !is null && tables.next())
            {
                auto tmd = TableMetaData(tables.getString("TABLE_CAT"),
                        tables.getString("TABLE_SCHEM"), tables.getString("TABLE_NAME"));
                const key = tmd.schemaName !is null ? upper(tmd.schemaName) : userName !is null ? upper(userName) : "";
                tableMeta[key] = tmd;
            }
        }
        catch (SQLException ex)
            logger().warn("Error while accessing table meta-data results: " ~ ex.msg);
        JdbcUtils.closeResultSet(tables);
        if (tableMeta.length == 0)
            logger().info("Unable to locate table meta-data for '" ~ tableName ~ "': column names must be provided");
        else
            processTableColumns(databaseMetaData, findTableMetaData(schemaName, tableName, tableMeta));
    }

    private TableMetaData findTableMetaData(string schemaName, string tableName, TableMetaData[string] tableMeta)
    {
        if (schemaName !is null)
        {
            if (auto tmd = upper(schemaName) in tableMeta)
                return *tmd;
            throw new DataAccessResourceFailureException(
                    "Unable to locate table meta-data for '" ~ tableName ~ "' in the '" ~ schemaName ~ "' schema");
        }
        if (tableMeta.length == 1)
            return tableMeta.values[0];
        const userKey = userName !is null ? upper(userName) : "";
        foreach (candidate; [getDefaultSchema(), userKey, "PUBLIC", "DBO"])
            if (auto tmd = candidate in tableMeta)
                return *tmd;
        throw new DataAccessResourceFailureException(
                "Unable to locate table meta-data for '" ~ tableName ~ "' in the default schema");
    }

    /// Method supporting the meta-data processing for a table's columns.
    private void processTableColumns(DatabaseMetaData databaseMetaData, TableMetaData tmd)
    {
        ResultSet tableColumns;
        const metaDataCatalogName = metaDataCatalogNameToUse(tmd.catalogName);
        const metaDataSchemaName = metaDataSchemaNameToUse(tmd.schemaName);
        const metaDataTableName = tableNameToUse(tmd.tableName);
        if (logger().isDebugEnabled())
            logger().debug_(
                    "Retrieving meta-data for " ~ metaDataCatalogName ~ "/" ~ metaDataSchemaName
                    ~ "/" ~ metaDataTableName);
        try
        {
            tableColumns = databaseMetaData.getColumns(metaDataCatalogName, metaDataSchemaName,
                    metaDataTableName, null);
            while (tableColumns !is null && tableColumns.next())
            {
                const columnName = tableColumns.getString("COLUMN_NAME");
                int dataType = tableColumns.getInt("DATA_TYPE");
                if (dataType == Types.DECIMAL && tableColumns.getString("TYPE_NAME") == "NUMBER"
                        && tableColumns.getInt("DECIMAL_DIGITS") == 0)
                    dataType = Types.NUMERIC;
                tableParameterMetaData.add(new TableParameterMetaData(columnName, dataType,
                        tableColumns.getBoolean("NULLABLE")));
            }
        }
        catch (SQLException ex)
        {
            logger().warn("Error while retrieving meta-data for table columns. Consider specifying explicit column "
                    ~ "names -- for example, via SimpleJdbcInsert#usingColumns().", ex);
            tableParameterMetaData.clear();
        }
        JdbcUtils.closeResultSet(tableColumns);
    }

    private static struct TableMetaData
    {
        string catalogName, schemaName, tableName;
    }
}

/// The PostgreSQL-specific implementation of `TableMetaDataProvider`. Supports a feature for retrieving generated
/// keys without the JDBC 3.0 `getGeneratedKeys` support.
class PostgresTableMetaDataProvider : GenericTableMetaDataProvider
{
    /// Create a provider for the given PostgreSQL meta-data.
    this(DatabaseMetaData databaseMetaData)
    {
        super(databaseMetaData);
    }

    override string metaDataCatalogNameToUse(string catalogName)
    {
        return catalogName;
    }

    override string metaDataSchemaNameToUse(string schemaName)
    {
        return schemaName !is null ? schemaName : getDefaultSchema();
    }

    override bool isGetGeneratedKeysSimulated()
    {
        return true;
    }

    override string getSimpleQueryForGetGeneratedKey(string, string keyColumnName)
    {
        return "RETURNING " ~ keyColumnName;
    }
}

/// Factory used to create a `TableMetaDataProvider` implementation based on the type of database being used.
final class TableMetaDataProviderFactory
{
    private this()
    {
    }

    /// Create a `TableMetaDataProvider` based on the database meta-data.
    static TableMetaDataProvider createMetaDataProvider(DataSource dataSource, TableMetaDataContext context)
    {
        auto con = DataSourceUtils.getConnection(dataSource);
        scope (exit)
            DataSourceUtils.releaseConnection(con, dataSource);
        try
        {
            auto databaseMetaData = con.getMetaData();
            if (databaseMetaData is null)
                throw new DataAccessResourceFailureException(
                        "DatabaseMetaData returned by Connection [" ~ typeid(cast(Object) con).name ~ "] was null");
            const databaseProductName = JdbcUtils.commonDatabaseName(databaseMetaData.getDatabaseProductName());
            TableMetaDataProvider provider = databaseProductName == "PostgreSQL" ? new PostgresTableMetaDataProvider(
                    databaseMetaData) : new GenericProvider(databaseMetaData);
            provider.initializeWithMetaData(databaseMetaData);
            if (context.isAccessTableColumnMetaData())
                provider.initializeWithTableColumnMetaData(databaseMetaData,
                        context.getCatalogName(), context.getSchemaName(), context.getTableName());
            return provider;
        }
        catch (SQLException ex)
            throw new DataAccessResourceFailureException("Error retrieving database meta-data", ex);
    }
}

/// `GenericTableMetaDataProvider` with a public constructor, for the factory.
private final class GenericProvider : GenericTableMetaDataProvider
{
    this(DatabaseMetaData databaseMetaData)
    {
        super(databaseMetaData);
    }
}

/++
Class to manage context meta-data used for the configuration and execution of operations on a database table.
+/
class TableMetaDataContext
{
    private string tableName;
    private string catalogName;
    private string schemaName;
    private bool accessTableColumnMetaData = true;
    private bool overrideIncludeSynonymsDefault;
    private bool quoteIdentifiers;
    private TableMetaDataProvider metaDataProvider;
    private string[] tableColumns;
    private bool generatedKeyColumnsUsed;

    /// Set the name of the table for this context.
    void setTableName(string tableName)
    {
        this.tableName = tableName;
    }

    /// Get the name of the table for this context.
    string getTableName()
    {
        return tableName;
    }

    /// Set the name of the catalog for this context.
    void setCatalogName(string catalogName)
    {
        this.catalogName = catalogName;
    }

    /// Get the name of the catalog for this context.
    string getCatalogName()
    {
        return catalogName;
    }

    /// Set the name of the schema for this context.
    void setSchemaName(string schemaName)
    {
        this.schemaName = schemaName;
    }

    /// Get the name of the schema for this context.
    string getSchemaName()
    {
        return schemaName;
    }

    /// Specify whether we should access table column meta-data.
    void setAccessTableColumnMetaData(bool accessTableColumnMetaData)
    {
        this.accessTableColumnMetaData = accessTableColumnMetaData;
    }

    /// Are we accessing table meta-data?
    bool isAccessTableColumnMetaData()
    {
        return accessTableColumnMetaData;
    }

    /// Specify whether we should override default for accessing synonyms.
    void setOverrideIncludeSynonymsDefault(bool override_)
    {
        overrideIncludeSynonymsDefault = override_;
    }

    /// Are we overriding include synonyms default?
    bool isOverrideIncludeSynonymsDefault()
    {
        return overrideIncludeSynonymsDefault;
    }

    /// Specify whether we are quoting SQL identifiers.
    void setQuoteIdentifiers(bool quoteIdentifiers)
    {
        this.quoteIdentifiers = quoteIdentifiers;
    }

    /// Are we quoting identifiers?
    bool isQuoteIdentifiers()
    {
        return quoteIdentifiers;
    }

    /// Get a List of the table column names.
    List!string getTableColumns()
    {
        auto columns = new ArrayList!string;
        foreach (column; tableColumns)
            columns.add(column);
        return columns;
    }

    /// Process the current meta-data with the provided configuration options.
    void processMetaData(DataSource dataSource, string[] declaredColumns, string[] generatedKeyNames)
    {
        metaDataProvider = TableMetaDataProviderFactory.createMetaDataProvider(dataSource, this);
        tableColumns = reconcileColumnsToUse(declaredColumns, generatedKeyNames);
    }

    private TableMetaDataProvider obtainMetaDataProvider()
    {
        if (metaDataProvider is null)
            throw new imported!"flint.java.lang".IllegalStateException(
                    "No TableMetaDataProvider - call processMetaData first");
        return metaDataProvider;
    }

    /// Compare columns created from meta-data with declared columns and return a reconciled list.
    protected string[] reconcileColumnsToUse(string[] declaredColumns, string[] generatedKeyNames)
    {
        if (generatedKeyNames.length > 0)
            generatedKeyColumnsUsed = true;
        bool[string] keys;
        foreach (key; generatedKeyNames)
            keys[upper(key)] = true;
        if (declaredColumns.length)
        {
            string[] overlapping;
            foreach (column; declaredColumns)
                if (upper(column) in keys)
                    overlapping ~= column;
            if (overlapping.length)
                throw new InvalidDataAccessApiUsageException("Declared columns " ~ listText(
                        overlapping) ~ " must not overlap with generated key columns");
            return declaredColumns.dup;
        }
        string[] columns;
        foreach (meta; obtainMetaDataProvider().getTableParameterMetaData().toArray())
            if (upper(meta.getParameterName()) !in keys)
                columns ~= meta.getParameterName();
        return columns;
    }

    /// Match the provided column names and values with the list of columns used.
    List!Any matchInParameterValuesWithInsertColumns(SqlParameterSource parameterSource)
    {
        auto values = new ArrayList!Any;
        auto caseInsensitiveParameterNames = SqlParameterSourceUtils.extractCaseInsensitiveParameterNames(
                parameterSource);
        foreach (column; tableColumns)
        {
            const lowerCaseName = lower(column);
            const propertyName = JdbcUtils.convertUnderscoreNameToPropertyName(column);
            if (parameterSource.hasValue(column))
                values.add(SqlParameterSourceUtils.getTypedValue(parameterSource, column));
            else if (parameterSource.hasValue(lowerCaseName))
                values.add(SqlParameterSourceUtils.getTypedValue(parameterSource, lowerCaseName));
            else if (parameterSource.hasValue(propertyName))
                values.add(SqlParameterSourceUtils.getTypedValue(parameterSource, propertyName));
            else if (caseInsensitiveParameterNames.containsKey(lowerCaseName))
                values.add(SqlParameterSourceUtils.getTypedValue(parameterSource,
                        caseInsensitiveParameterNames.get(lowerCaseName)));
            else
                values.add(Any.init);
        }
        return values;
    }

    /// Match the provided column names and values with the list of columns used.
    List!Any matchInParameterValuesWithInsertColumns(Map!(string, Any) inParameters)
    {
        auto values = new ArrayList!Any;
        foreach (column; tableColumns)
        {
            auto value = inParameters.containsKey(column) ? inParameters.get(column) : Any.init;
            if (value.isNull && inParameters.containsKey(lower(column)))
                value = inParameters.get(lower(column));
            if (value.isNull)
                inParameters.forEach((string key, Any candidate) {
                    if (value.isNull && lower(key) == lower(column))
                        value = candidate;
                });
            values.add(value);
        }
        return values;
    }

    /// Build the insert string based on configuration and meta-data information.
    string createInsertString(string[] generatedKeyNames...)
    {
        bool[string] keys;
        foreach (key; generatedKeyNames)
            keys[upper(key)] = true;
        const quote = isQuoteIdentifiers() ? obtainMetaDataProvider().getIdentifierQuoteString() : null;
        const quoting = quote !is null && trim(quote).length > 0;
        string quoted(string item)
        {
            return quoting ? quote ~ item ~ quote : item;
        }

        string insertStatement = "INSERT INTO ";
        if (catalogName !is null)
            insertStatement ~= quoted(catalogName) ~ ".";
        if (schemaName !is null)
            insertStatement ~= quoted(schemaName) ~ ".";
        insertStatement ~= quoted(tableName) ~ " (";
        int columnCount;
        foreach (columnName; tableColumns)
        {
            if (upper(columnName) in keys)
                continue;
            if (++columnCount > 1)
                insertStatement ~= ", ";
            insertStatement ~= quoted(columnName);
        }
        insertStatement ~= ") VALUES(";
        if (columnCount < 1 && !generatedKeyColumnsUsed)
        {
            string message = "Unable to locate columns for table '" ~ tableName
                ~ "' so an insert statement can't be generated.";
            if (isAccessTableColumnMetaData())
                message ~= " Consider specifying explicit column names -- for example, via "
                    ~ "SimpleJdbcInsert#usingColumns().";
            throw new InvalidDataAccessApiUsageException(message);
        }
        foreach (i; 0 .. columnCount)
            insertStatement ~= i ? ", ?" : "?";
        return insertStatement ~ ")";
    }

    /// Build the array of `Types` based on configuration and meta-data information.
    int[] createInsertTypes()
    {
        auto types = new int[tableColumns.length];
        TableParameterMetaData[string] parameterMap;
        foreach (tpmd; obtainMetaDataProvider().getTableParameterMetaData().toArray())
            parameterMap[upper(tpmd.getParameterName())] = tpmd;
        foreach (index, column; tableColumns)
        {
            auto tpmd = column is null ? null : parameterMap.get(upper(column), null);
            types[index] = tpmd !is null ? tpmd.getSqlType() : SqlTypeValue.TYPE_UNKNOWN;
        }
        return types;
    }

    /// Does this database support the JDBC feature for retrieving generated keys?
    bool isGetGeneratedKeysSupported()
    {
        return obtainMetaDataProvider().isGetGeneratedKeysSupported();
    }

    /// Does this database support simple query to retrieve generated keys when the JDBC feature for retrieving
    /// generated keys is not supported?
    bool isGetGeneratedKeysSimulated()
    {
        return obtainMetaDataProvider().isGetGeneratedKeysSimulated();
    }

    /// Does this database support a simple query to retrieve generated keys?
    string getSimpleQueryForGetGeneratedKey(string tableName, string keyColumnName)
    {
        return obtainMetaDataProvider().getSimpleQueryForGetGeneratedKey(tableName, keyColumnName);
    }

    /// Is a column name String array for retrieving generated keys supported?
    bool isGeneratedKeysColumnNameArraySupported()
    {
        return obtainMetaDataProvider().isGeneratedKeysColumnNameArraySupported();
    }
}

private string upper(string text)
{
    auto result = text.dup;
    foreach (ref c; result)
        if (c >= 'a' && c <= 'z')
            c -= 32;
    return result.idup;
}

private string lower(string text)
{
    auto result = text.dup;
    foreach (ref c; result)
        if (c >= 'A' && c <= 'Z')
            c += 32;
    return result.idup;
}

private string trim(string text) pure nothrow @nogc
{
    size_t start, end = text.length;
    while (start < end && text[start] == ' ')
        ++start;
    while (end > start && text[end - 1] == ' ')
        --end;
    return text[start .. end];
}

private string listText(string[] items)
{
    string result = "[";
    foreach (index, item; items)
        result ~= (index ? ", " : "") ~ item;
    return result ~ "]";
}
