module flint.engine.style.types;

@safe:

/// Red, green and blue components of a terminal color.
struct Color
{
    /// Red channel.
    ubyte red;
    /// Green channel.
    ubyte green;
    /// Blue channel.
    ubyte blue;
}

/// Alignment within the available cells or rows.
enum Alignment : ubyte
{
    start,
    center,
    end
}

/// Border glyph set.
enum Border : ubyte
{
    none,
    plain,
    rounded,
    double_
}

/// Space on the four sides of a block.
struct Insets
{
    /// Rows above the content.
    uint top;
    /// Cells to the right of the content.
    uint right;
    /// Rows below the content.
    uint bottom;
    /// Cells to the left of the content.
    uint left;
}

/// Layout and ANSI styling for one terminal block.
struct Style
{
    /// Text color.
    Color foreground;
    /// Background color.
    Color background;
    /// Space inside the border.
    Insets padding;
    /// Space outside the border.
    Insets margin;
    /// Border glyph set to draw.
    Border border;
    /// Per-row text alignment.
    Alignment horizontal;
    /// Text alignment in an explicitly sized block.
    Alignment vertical;
    /// Enable bold text.
    bool bold;
    /// Enable italic text.
    bool italic;
    /// Enable underlined text.
    bool underline;
}

/// Display width of the widest line and number of logical lines.
struct TextMetrics
{
    /// Width in terminal cells.
    uint cells;
    /// Number of logical lines.
    uint lines;
}
