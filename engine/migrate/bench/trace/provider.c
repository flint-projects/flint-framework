/* Link the probe with --wrap to observe actual provider operations independently. */
#include <libpq-fe.h>
#include <sqlite3.h>
#include <stdio.h>
#include <string.h>

static int trace(unsigned event, void *context, void *stmt, void *sql)
{
    (void)context;
    (void)sql;
    if (event != SQLITE_TRACE_STMT)
        return 0;
    const char *query = sqlite3_sql(stmt);
    if (query && (!strncmp(query, "SELECT", 6) || !strcmp(query, "BEGIN IMMEDIATE") || !strcmp(query, "ROLLBACK")))
        fprintf(stderr, "sqlite %s\n", query);
    return 0;
}

int __real_sqlite3_open_v2(const char *, sqlite3 **, int, const char *);
int __wrap_sqlite3_open_v2(const char *path, sqlite3 **db, int flags, const char *vfs)
{
    int status = __real_sqlite3_open_v2(path, db, flags, vfs);
    if (status == SQLITE_OK)
        sqlite3_trace_v2(*db, SQLITE_TRACE_STMT, trace, NULL);
    return status;
}

int __real_PQsendPrepare(PGconn *, const char *, const char *, int, const Oid *);
int __wrap_PQsendPrepare(PGconn *conn, const char *name, const char *sql, int count, const Oid *types)
{
    int status = __real_PQsendPrepare(conn, name, sql, count, types);
    if (status)
        fprintf(stderr, "postgres prepare %s %s\n", name, sql);
    return status;
}

int __real_PQsendQueryPrepared(PGconn *, const char *, int, const char *const *, const int *, const int *, int);
int __wrap_PQsendQueryPrepared(PGconn *conn, const char *name, int count,
                             const char *const *text, const int *lengths, const int *formats, int results)
{
    int status = __real_PQsendQueryPrepared(conn, name, count, text, lengths, formats, results);
    if (status)
        fprintf(stderr, "postgres execute %s\n", name);
    return status;
}
