/// Filtered selection with stable item identities and indexed visible rows.
module flint.engine.widgets.list;

import flint.arena : Error, Status;
import flint.engine.style : Style, foldGraphemes;
import flint.engine.tui : Effects, Event, EventKind, Frame, KeyCode;
import flint.engine.widgets.internal : fit, paintLine;

@safe:

private enum none = size_t.max;

/// One application item in a filterable list.
struct ListItem
{
    /// Stable application identity.
    ulong id;
    /// Display label used for filtering.
    string label;
    /// Keep visible while excluding selection.
    bool disabled;
}

/// A list of immutable item snapshots with a cached filter.
struct List
{
    /// Replace the slice to publish a new item snapshot.
    ListItem[] items;
    /// Selected item index, or size_t.max when none is selectable.
    size_t selected;
    /// Canonical case-folded substring filter input.
    string filter;

    private ListItem[] cachedItems;
    private string cachedFilter;
    private size_t[] matches;
    private ulong remembered;
    private bool rememberedSet;
    private bool initialized;

    /// Refresh snapshot identity as needed and move through enabled choices.
    void update(Event event, ref Effects)
    {
        const sameItems = cachedItems is items;
        if ((!initialized || sameItems) && selected < items.length && !items[selected].disabled)
        {
            remembered = items[selected].id;
            rememberedSet = true;
        }
        if (!initialized || !sameItems || cachedFilter != filter)
        {
            cachedItems = items;
            cachedFilter = filter;
            matches = filter.length == 0 ? null : filtered(items, filter);
            initialized = true;
            restore();
        }
        else if (selected != none && (selected >= items.length || items[selected].disabled || current(matches) == none))
            restore();

        if (event.kind == EventKind.key)
            move(event.key.code);
        rememberedSet = selected < items.length;
        if (rememberedSet)
            remembered = items[selected].id;
    }

    private void restore()
    {
        selected = none;
        const count = filter.length == 0 ? items.length : matches.length;
        foreach (index; 0 .. count)
        {
            const item = original(matches, index);
            if (items[item].disabled)
                continue;
            if (selected == none)
                selected = item;
            if (rememberedSet && items[item].id == remembered)
            {
                selected = item;
                break;
            }
            if (!rememberedSet)
                break;
        }
    }

    private void move(KeyCode key)
    {
        const count = filter.length == 0 ? items.length : matches.length;
        const start = current(matches);
        if (start == none || count == 0)
            return;
        switch (key)
        {
        case KeyCode.home:
            choose(0, count, true);
            break;
        case KeyCode.end:
            choose(count - 1, count, false);
            break;
        case KeyCode.up:
            if (start != 0)
                choose(start - 1, count, false);
            break;
        case KeyCode.down:
            if (start + 1 < count)
                choose(start + 1, count, true);
            break;
        case KeyCode.pageUp:
            choose(start < 20 ? 0 : start - 20, count, true, start);
            break;
        case KeyCode.pageDown:
            choose(count - 1 - start < 20 ? count - 1 : start + 20, count, false, start);
            break;
        default:
            break;
        }
    }

    private void choose(size_t index, size_t count, bool forward, size_t stop = none)
    {
        while (index != stop)
        {
            const candidate = original(matches, index);
            if (!items[candidate].disabled)
            {
                selected = candidate;
                return;
            }
            if (forward ? index + 1 == count : index == 0)
                return;
            index = forward ? index + 1 : index - 1;
        }
    }

    private size_t original(scope const(size_t)[] indices, size_t ordinal) const pure nothrow @nogc
    {
        return filter.length == 0 ? ordinal : indices[ordinal];
    }

    private size_t current(scope const(size_t)[] indices) const pure nothrow @nogc
    {
        if (selected >= items.length)
            return none;
        if (filter.length == 0)
            return selected;
        size_t left;
        size_t right = indices.length;
        while (left < right)
        {
            const middle = left + (right - left) / 2;
            if (indices[middle] < selected)
                left = middle + 1;
            else
                right = middle;
        }
        return left < indices.length && indices[left] == selected ? left : none;
    }

    /// Draw the visible window of the selected snapshot.
    Error view(ref Frame frame, uint column, uint row, uint width, uint height) const
    {
        return viewMarked(frame, column, row, width, height, []);
    }

    /// Draw marks supplied by an application with multiple selections.
    package(flint) Error viewMarked(ref Frame frame, uint column, uint row, uint width, uint height,
            scope const(bool)[] marked) const
    {
        const area = fit(frame, column, row, width, height);
        if (!area.ok() || area.value.columns == 0 || area.value.rows == 0)
            return area.error;
        const indices = cachedItems is items && cachedFilter == filter ? matches : filtered(items, filter);
        const count = filter.length == 0 ? items.length : indices.length;
        const active = current(indices);
        const visible = area.value.rows;
        const first = active != none && active >= visible ? active - visible + 1 : 0;
        foreach (index; first .. first + (count - first < visible ? count - first : visible))
        {
            const at = original(indices, index);
            const status = paintItem(frame, column, row + cast(uint)(index - first),
                    area.value.columns, items[at], active == index, at < marked.length && marked[at]);
            if (status.code != Status.ok)
                return status;
        }
        return Error.init;
    }
}

private Error paintItem(ref Frame frame, uint column, uint row, uint width, scope const ref ListItem item,
        bool active, bool marked)
{
    Style style;
    style.bold = active && !item.disabled;
    const prefix = item.disabled ? "- " : active ? (marked ? ">+" : "> ") : marked ? "+ " : "  ";
    const marker = frame.put(column, row, prefix[0 .. (width < 2 ? width : 2)], style);
    if (marker.code != Status.ok || width <= 2)
        return marker;
    return paintLine(frame, column + 2, row, width - 2, item.label, style);
}

private size_t[] filtered(scope const(ListItem)[] items, string query)
{
    string keyword;
    if (query.length == 0 || !foldGraphemes(query, keyword))
        return null;
    size_t[] visible;
    foreach (index, ref const item; items)
    {
        if (keyword.length != 0 && asciiLabel(item.label) ? asciiContains(item.label,
                keyword) : foldedContains(item.label, keyword))
            visible ~= index;
    }
    return visible;
}

private bool foldedContains(scope const(char)[] label, scope const(char)[] keyword)
{
    string name;
    return foldGraphemes(label, name) && containsBytes(name, keyword);
}

// Byte-wise substring test, the case-sensitive std.string.indexOf(...) >= 0 on two UTF-8 strings.
private bool containsBytes(scope const(char)[] text, scope const(char)[] part) pure nothrow @nogc
{
    if (part.length > text.length)
        return false;
    foreach (start; 0 .. text.length - part.length + 1)
    {
        if (text[start .. start + part.length] == part)
            return true;
    }
    return false;
}

private enum asciiLabelLimit = 1_048_576;

/// Short ASCII labels fold to themselves except for A-Z, so they need no Unicode provider call.
private bool asciiLabel(scope const(char)[] label) pure nothrow @nogc
{
    if (label.length > asciiLabelLimit)
        return false;
    foreach (ch; label)
        if (ch >= 0x80)
            return false;
    return true;
}

/// Search a case-folded keyword in an ASCII label without materializing the folded label.
private bool asciiContains(scope const(char)[] label, scope const(char)[] keyword) pure nothrow @nogc
{
    foreach (ch; keyword)
        if (ch >= 0x80)
            return false;
    if (keyword.length > label.length)
        return false;
    foreach (start; 0 .. label.length - keyword.length + 1)
    {
        size_t matched;
        while (matched < keyword.length && lower(label[start + matched]) == keyword[matched])
            ++matched;
        if (matched == keyword.length)
            return true;
    }
    return false;
}

private char lower(char ch) pure nothrow @nogc
{
    return ch >= 'A' && ch <= 'Z' ? cast(char)(ch + ('a' - 'A')) : ch;
}
