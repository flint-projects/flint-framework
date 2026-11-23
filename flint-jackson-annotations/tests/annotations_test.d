/// The Jackson annotation UDAs keep Java's element defaults and the value-first shorthand (rulebook R2).
module annotations_test;

import flint.jackson.annotation;

@safe:

@JsonPropertyOrder(["id", "name"]) @JsonInclude(JsonInclude.Include.NON_NULL)
@JsonIgnoreProperties(ignoreUnknown : true)
private struct Owner
{
    @JsonProperty("owner_id") long id;
    @JsonProperty(value : "name", access:
            JsonProperty.Access.READ_ONLY) string name;
    @JsonIgnore string password;
    @JsonAlias(["mail", "e-mail"]) string email;
    @JsonFormat(shape : JsonFormat.Shape.STRING, pattern:
            "yyyy-MM-dd") string birthDate;
}

// The first UDA of type T on `symbol`: a value as written, or T.init for a bare type.
private template first(T, alias symbol)
{
    static T find()
    {
        foreach (attribute; __traits(getAttributes, symbol))
        {
            static if (is(typeof(attribute) == T))
                return attribute;
            else static if (is(attribute == T))
                return T.init;
        }
        assert(false, "missing " ~ T.stringof);
    }

    enum first = find();
}

@("Java's defaults: a bare UDA reads as T.init with every element at its default")
unittest
{
    static assert(JsonProperty.init.value == JsonProperty.USE_DEFAULT_NAME && JsonProperty.init.index == -1);
    static assert(JsonProperty.init.access == JsonProperty.Access.AUTO && !JsonProperty.init.required);
    static assert(JsonProperty.init.isRequired == OptBoolean.DEFAULT);
    static assert(JsonIgnore.init.value && JsonValue.init.value && JsonRawValue.init.value);
    static assert(JsonInclude.init.value == JsonInclude.Include.ALWAYS
            && JsonInclude.init.content == JsonInclude.Include.ALWAYS);
    static assert(JsonFormat.init.shape == JsonFormat.Shape.ANY && JsonFormat.init.locale == "##default");
    static assert(JsonFormat.init.timezone == JsonFormat.DEFAULT_TIMEZONE && JsonFormat.init.radix == -1);
    static assert(JsonCreator.init.mode == JsonCreator.Mode.DEFAULT);
    static assert(JsonSetter.init.nulls == Nulls.DEFAULT && JsonMerge.init.value == OptBoolean.TRUE);
    static assert(JsonBackReference.init.value == "defaultReference");
    static assert(JsonAutoDetect.init.fieldVisibility == JsonAutoDetect.Visibility.DEFAULT);
}

@("value-first and named arguments set only the elements given")
unittest
{
    enum id = first!(JsonProperty, Owner.id);
    static assert(id.value == "owner_id" && id.access == JsonProperty.Access.AUTO);
    enum name = first!(JsonProperty, Owner.name);
    static assert(name.value == "name" && name.access == JsonProperty.Access.READ_ONLY);
    static assert(first!(JsonIgnore, Owner.password).value);
    static assert(first!(JsonAlias, Owner.email).value == ["mail", "e-mail"]);
    enum format = first!(JsonFormat, Owner.birthDate);
    static assert(format.shape == JsonFormat.Shape.STRING && format.pattern == "yyyy-MM-dd");
    static assert(format.with_.length == 0);
}

@("type-level annotations")
unittest
{
    static assert(first!(JsonPropertyOrder, Owner).value == ["id", "name"]);
    static assert(!first!(JsonPropertyOrder, Owner).alphabetic);
    static assert(first!(JsonInclude, Owner).value == JsonInclude.Include.NON_NULL);
    enum ignore = first!(JsonIgnoreProperties, Owner);
    static assert(ignore.ignoreUnknown && ignore.value.length == 0 && !ignore.allowGetters);
}

@("enum constants keep Java's order")
unittest
{
    static assert(JsonInclude.Include.NON_EMPTY == 3 && JsonFormat.Shape.POJO == 11);
    static assert(PropertyAccessor.CREATOR == 4 && PropertyAccessor.ALL == 7);
    static assert(JsonFormat.Feature.ADJUST_DATES_TO_CONTEXT_TIME_ZONE == 10);
}
