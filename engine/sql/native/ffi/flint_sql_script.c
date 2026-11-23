#define _POSIX_C_SOURCE 200809L
#include "flint_sql_private.h"

#if (defined(__linux__) || defined(__APPLE__) || defined(_WIN32)) && defined(FLINT_HAS_LIBPQ)

#include <string.h>
#if defined(_WIN32)
#include "flint_port.h" /* strcasecmp (ADR-026) */
#else
#include <strings.h>
#endif

static int letter(unsigned char ch)
{
    return ch == '_' || ch >= 0x80 || (ch >= 'a' && ch <= 'z') || (ch >= 'A' && ch <= 'Z');
}

static int tag_char(unsigned char ch)
{
    return letter(ch) || (ch >= '0' && ch <= '9');
}

static int space(unsigned char ch)
{
    return ch == ' ' || (ch >= '\t' && ch <= '\r');
}

static const char *comment(const char *cursor)
{
    size_t depth = 1;
    cursor += 2;
    while (*cursor) {
        if (cursor[0] == '/' && cursor[1] == '*') {
            ++depth;
            cursor += 2;
        } else if (cursor[0] == '*' && cursor[1] == '/') {
            cursor += 2;
            if (--depth == 0)
                return cursor;
        } else
            ++cursor;
    }
    return NULL;
}

static const char *trivia(const char *cursor)
{
    while (cursor && *cursor) {
        if (space((unsigned char)*cursor)) {
            ++cursor;
        } else if (cursor[0] == '-' && cursor[1] == '-') {
            cursor += 2;
            while (*cursor && *cursor != '\n' && *cursor != '\r')
                ++cursor;
        } else if (cursor[0] == '/' && cursor[1] == '*') {
            cursor = comment(cursor);
        } else {
            break;
        }
    }
    return cursor;
}

static const char *quoted(const char *cursor, int escapes)
{
    char quote = *cursor++;
    while (*cursor) {
        char ch = *cursor++;
        if (escapes && ch == '\\' && *cursor) {
            ++cursor;
        } else if (ch == quote) {
            if (*cursor != quote)
                return cursor;
            ++cursor;
        }
    }
    return NULL;
}

static const char *dollar_quote(const char *cursor)
{
    const char *end = cursor + 1;
    if (letter((unsigned char)*end)) {
        do { ++end; } while (tag_char((unsigned char)*end));
    }
    if (*end != '$')
        return cursor + 1;
    size_t size = (size_t)(++end - cursor);
    for (const char *possible = strchr(end, '$'); possible; possible = strchr(possible + 1, '$')) {
        if (!strncmp(cursor, possible, size))
            return possible + size;
    }
    return NULL;
}

static const char *word(const char *cursor)
{
    while (tag_char((unsigned char)*cursor) || *cursor == '$')
        ++cursor;
    return cursor;
}

static int equal_word(const char *start, size_t size, const char *expected)
{
    return strlen(expected) == size && !strncasecmp(start, expected, size);
}

static int next_is(const char *cursor, const char *expected)
{
    const char *start = trivia(cursor);
    return start && equal_word(start, (size_t)(word(start) - start), expected);
}

static int transaction_control(const char *start, size_t length, const char *end)
{
    static const char *blocked[] = {"BEGIN", "START", "COMMIT", "END", "ABORT", "ROLLBACK",
                                    "SAVEPOINT", "RELEASE"};
    for (size_t index = 0; index < sizeof(blocked) / sizeof(blocked[0]); ++index) {
        if (equal_word(start, length, blocked[index]))
            return 1;
    }
    return equal_word(start, length, "PREPARE") && next_is(end, "TRANSACTION");
}

/* Scan only statement-leading control words. libpq still receives the original
 * full SQL program, including statement delimiters inside bodies and literals. */
int flint_pg_script_allowed(const char *sql, int ordinary_backslash)
{
    const char *cursor = sql;
    int first = 1;
    int escapes = 0;
    int routine = 0;
    size_t depth = 0;
    size_t atomic = 0;
    while ((cursor = trivia(cursor)) && *cursor) {
        const char *start = cursor;
        if (letter((unsigned char)*cursor)) {
            cursor = word(cursor);
            size_t length = (size_t)(cursor - start);
            if (first) {
                if (transaction_control(start, length, cursor))
                    return 0;
                first = 0;
                routine = equal_word(start, length, "CREATE");
            } else if (routine && !depth) {
                if (equal_word(start, length, "BEGIN") && next_is(cursor, "ATOMIC"))
                    ++atomic;
                else if (atomic && equal_word(start, length, "CASE"))
                    ++atomic;
                else if (atomic && equal_word(start, length, "END"))
                    --atomic;
            }
            escapes = equal_word(start, length, "E") && *cursor == '\'';
        } else if (*cursor == '\'' || *cursor == '"') {
            cursor = quoted(cursor, *cursor == '\'' && (escapes || ordinary_backslash));
            first = 0;
            escapes = 0;
        } else if (*cursor == '$') {
            cursor = dollar_quote(cursor);
            first = 0;
            escapes = 0;
        } else {
            const char token = *cursor++;
            if (token == ';' && !depth && !atomic)
                first = 1;
            else if (token == '(')
                ++depth;
            else if (token == ')' && depth)
                --depth;
            else if (first)
                first = 0;
            escapes = 0;
        }
    }
    return cursor != NULL && !atomic;
}

#endif
