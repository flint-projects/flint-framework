module forge_row;

import flint.engine.sql : Row;

@safe:

/// Attempt to manufacture a SQL row outside a live consumer.
Row forgeRow()
{
    return Row(1, 1);
}
