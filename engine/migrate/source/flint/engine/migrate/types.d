/// Versioned startup migration input, options, and result.
module flint.engine.migrate.types;

@safe:

/// One SQL program with the digest of its exact original bytes.
struct Migration
{
    /// Positive migration identity, in signed database range.
    ulong versionNumber;
    /// Human-readable reason for the migration.
    string description;
    /// Complete UTF-8 SQL program.
    string sql;
    /// SHA-256 of the exact SQL bytes.
    ubyte[32] sha256;
    /// Include the SQL and history insert in their transaction.
    bool transactional = true;
}

/// History naming and acquisition policy.
struct MigrationOptions
{
    /// Unqualified SQL name for the history table.
    string historyTable = "flint_schema_history";
    /// Upper bound on acquiring the database-level lock.
    long lockTimeoutNanos = 30_000_000_000L;
    /// Check history without applying migrations.
    bool validateOnly = false;
}

/// Ordered migration progress confirmed by the database.
struct MigrationReport
{
    /// Number of input migrations.
    uint discovered;
    /// New versions confirmed during this run.
    uint applied;
    /// Highest confirmed version.
    ulong currentVersion;
}
