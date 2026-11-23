/// Embedded resources and explicit HTML trust.
module flint.engine.templates.types;

import flint.arena : Buffer;

@safe:

/// Name of an embedded template resource.
struct HtmlTemplate
{
    /// Relative resource path on the configured compiler import paths.
    string fileName;
}

/// Sanitized HTML owned by an approved adapter.
struct TrustedHtml
{
    private Buffer content;

    @disable this(Buffer);

    package(flint.engine.templates) Buffer handle() const pure nothrow @nogc
    {
        return content;
    }
}
