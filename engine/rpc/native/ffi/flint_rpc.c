#include "flint_rpc.h"

#include <string.h>

#ifdef FLINT_HAS_PROTOBUF_C
#include <protobuf-c/protobuf-c.h>

enum {
    FLINT_PROTO_FIELD_LIMIT = 256,
    FLINT_PROTO_DEPTH_LIMIT = 16
};

static const ProtobufCMessageDescriptor *checked_descriptor(const flint_proto_descriptor *descriptor) {
    const ProtobufCMessageDescriptor *native = (const ProtobufCMessageDescriptor *)descriptor;
    if (native == NULL || native->magic != PROTOBUF_C__MESSAGE_DESCRIPTOR_MAGIC)
        return NULL;
    return native;
}

typedef struct descriptor_walk {
    const ProtobufCMessageDescriptor *nodes[FLINT_PROTO_FIELD_LIMIT];
    int heights[FLINT_PROTO_FIELD_LIMIT];
    size_t used;
} descriptor_walk;

static int descriptor_height(const ProtobufCMessageDescriptor *descriptor, size_t depth,
                             descriptor_walk *walk) {
    if (descriptor == NULL || depth > FLINT_PROTO_DEPTH_LIMIT ||
            descriptor->n_fields > FLINT_PROTO_FIELD_LIMIT)
        return -1;
    for (size_t index = 0; index < walk->used; ++index) {
        if (walk->nodes[index] == descriptor)
            return walk->heights[index];
    }
    if (walk->used == FLINT_PROTO_FIELD_LIMIT)
        return -1;
    const size_t index = walk->used++;
    walk->nodes[index] = descriptor;
    walk->heights[index] = -1;
    int height = 0;
    for (size_t member = 0; member < descriptor->n_fields; ++member) {
        const ProtobufCFieldDescriptor *field = &descriptor->fields[member];
        if (field->type != PROTOBUF_C_TYPE_MESSAGE)
            continue;
        const int nested = descriptor_height(field->descriptor, depth + 1, walk);
        if (nested < 0 || nested >= FLINT_PROTO_DEPTH_LIMIT)
            return -1;
        if (nested + 1 > height)
            height = nested + 1;
    }
    walk->heights[index] = height;
    return height;
}

int flint_proto_pack(const flint_proto_descriptor *descriptor, const void *message,
                    uint8_t *output, size_t capacity, size_t *written) {
    const ProtobufCMessageDescriptor *native = checked_descriptor(descriptor);
    const ProtobufCMessage *data = message;
    if (written == NULL)
        return FLINT_PROTO_INVALID;
    *written = 0;
    if (native == NULL || data == NULL || data->descriptor != native ||
            (capacity != 0 && output == NULL) || !protobuf_c_message_check(data))
        return FLINT_PROTO_INVALID;
    const size_t length = protobuf_c_message_get_packed_size(data);
    *written = length;
    if (length > capacity)
        return FLINT_PROTO_CAPACITY;
    if (length != 0 && protobuf_c_message_pack(data, output) != length)
        return FLINT_PROTO_INVALID;
    return FLINT_PROTO_OK;
}

static void *region_alloc(void *opaque, size_t size) {
    flint_proto_arena *arena = opaque;
    const uintptr_t alignment = _Alignof(max_align_t);
    const uintptr_t current = (uintptr_t)(arena->bytes + arena->used);
    const size_t padding = (size_t)((alignment - current % alignment) % alignment);
    const size_t available = arena->capacity - arena->used;
    if (size == 0)
        size = 1;
    if (padding > available || size > available - padding) {
        arena->exhausted = 1;
        return NULL;
    }
    arena->used += padding;
    void *result = arena->bytes + arena->used;
    arena->used += size;
    return result;
}

static void region_free(void *opaque, void *allocation) {
    (void)opaque;
    (void)allocation;
}

int flint_proto_unpack(const flint_proto_descriptor *descriptor, const uint8_t *input,
                      size_t input_length, void *arena_context, void **message) {
    const ProtobufCMessageDescriptor *native = checked_descriptor(descriptor);
    flint_proto_arena *arena = arena_context;
    if (message == NULL)
        return FLINT_PROTO_INVALID;
    *message = NULL;
    if (native == NULL || (input_length != 0 && input == NULL) || arena == NULL ||
            arena->bytes == NULL || arena->used > arena->capacity)
        return FLINT_PROTO_INVALID;

    descriptor_walk walk = {0};
    if (descriptor_height(native, 0, &walk) < 0)
        return FLINT_PROTO_INVALID;
    const size_t checkpoint = arena->used;
    arena->exhausted = 0;
    ProtobufCAllocator allocator = {region_alloc, region_free, arena};
    ProtobufCMessage *data = protobuf_c_message_unpack(native, &allocator, input_length, input);
    if (data == NULL || !protobuf_c_message_check(data)) {
        const int result = arena->exhausted ? FLINT_PROTO_CAPACITY : FLINT_PROTO_INVALID;
        protobuf_c_message_free_unpacked(data, &allocator);
        arena->used = checkpoint;
        return result;
    }
    *message = data;
    return FLINT_PROTO_OK;
}

void flint_proto_release(const flint_proto_descriptor *descriptor, void *message, void *arena_context) {
    const ProtobufCMessageDescriptor *native = checked_descriptor(descriptor);
    ProtobufCMessage *data = message;
    if (native == NULL || data == NULL || data->descriptor != native || arena_context == NULL)
        return;
    ProtobufCAllocator allocator = {region_alloc, region_free, arena_context};
    protobuf_c_message_free_unpacked(data, &allocator);
}
static size_t field_size(ProtobufCType type) {
    switch (type) {
    case PROTOBUF_C_TYPE_BOOL: return sizeof(protobuf_c_boolean);
    case PROTOBUF_C_TYPE_ENUM:
    case PROTOBUF_C_TYPE_INT32:
    case PROTOBUF_C_TYPE_SINT32:
    case PROTOBUF_C_TYPE_SFIXED32:
    case PROTOBUF_C_TYPE_UINT32:
    case PROTOBUF_C_TYPE_FIXED32: return sizeof(uint32_t);
    case PROTOBUF_C_TYPE_INT64:
    case PROTOBUF_C_TYPE_SINT64:
    case PROTOBUF_C_TYPE_SFIXED64:
    case PROTOBUF_C_TYPE_UINT64:
    case PROTOBUF_C_TYPE_FIXED64: return sizeof(uint64_t);
    case PROTOBUF_C_TYPE_FLOAT: return sizeof(float);
    case PROTOBUF_C_TYPE_DOUBLE: return sizeof(double);
    case PROTOBUF_C_TYPE_BYTES: return sizeof(ProtobufCBinaryData);
    case PROTOBUF_C_TYPE_STRING: return sizeof(char *);
    case PROTOBUF_C_TYPE_MESSAGE: return sizeof(ProtobufCMessage *);
    }
    return 0;
}

typedef struct typed_input {
    const flint_proto_field *fields;
    size_t count;
    const uint8_t *bytes;
    size_t byte_count;
    size_t assigned;
    flint_proto_arena *arena;
} typed_input;

static ProtobufCMessage *construct(const ProtobufCMessageDescriptor *, uint32_t, size_t, typed_input *);

static int store_scalar(const ProtobufCFieldDescriptor *field, const flint_proto_field *from, uint8_t *to,
                        size_t depth, typed_input *input) {
    const size_t width = field_size(field->type);
    switch (field->type) {
    case PROTOBUF_C_TYPE_STRING:
    case PROTOBUF_C_TYPE_BYTES: {
        if (from->start > input->byte_count || from->length > input->byte_count - from->start)
            return 0;
        const uint8_t *data = from->length == 0 ? (const uint8_t *)"" : input->bytes + from->start;
        if (field->type == PROTOBUF_C_TYPE_STRING) {
            if (from->length == SIZE_MAX || memchr(data, 0, from->length) != NULL)
                return 0;
            char *copy = region_alloc(input->arena, from->length + 1);
            if (copy == NULL)
                return 0;
            memcpy(copy, data, from->length);
            copy[from->length] = 0;
            memcpy(to, &copy, sizeof(copy));
        } else {
            ProtobufCBinaryData temporary = {from->length, (uint8_t *)data};
            memcpy(to, &temporary, sizeof(temporary));
        }
        return 1;
    }
    case PROTOBUF_C_TYPE_MESSAGE: {
        const uint32_t new_parent = (uint32_t)(from - input->fields) + 1;
        ProtobufCMessage *message = construct(field->descriptor, new_parent, depth + 1, input);
        if (message == NULL)
            return 0;
        memcpy(to, &message, sizeof(message));
        return 1;
    }
    case PROTOBUF_C_TYPE_BOOL: {
        const protobuf_c_boolean flag = from->bits != 0;
        memcpy(to, &flag, sizeof(flag));
        return 1;
    }
    case PROTOBUF_C_TYPE_FLOAT: {
        const float decimal = (float)from->decimal;
        memcpy(to, &decimal, sizeof(decimal));
        return 1;
    }
    case PROTOBUF_C_TYPE_DOUBLE:
        memcpy(to, &from->decimal, sizeof(from->decimal));
        return 1;
    default:
        if (width == sizeof(uint32_t)) {
            const uint32_t truncated = (uint32_t)from->bits;
            memcpy(to, &truncated, width);
            return 1;
        }
        if (width == sizeof(uint64_t)) {
            memcpy(to, &from->bits, width);
            return 1;
        }
        return 0;
    }
}

static ProtobufCMessage *construct(const ProtobufCMessageDescriptor *descriptor, uint32_t parent,
                                   size_t depth, typed_input *input) {
    if (depth > FLINT_PROTO_DEPTH_LIMIT || descriptor == NULL)
        return NULL;
    ProtobufCMessage *message = region_alloc(input->arena, descriptor->sizeof_message);
    if (message == NULL)
        return NULL;
    protobuf_c_message_init(descriptor, message);
    uint8_t *memory = (uint8_t *)message;
    for (size_t index = 0; index < descriptor->n_fields; ++index) {
        const ProtobufCFieldDescriptor *field = &descriptor->fields[index];
        size_t count = 0;
        for (size_t entry = 0; entry < input->count; ++entry) {
            const flint_proto_field *value = &input->fields[entry];
            if (value->parent == parent && value->number == field->id)
                ++count;
        }
        if (count == 0)
            continue;
        uint8_t *values = memory + field->offset;
        const size_t width = field_size(field->type);
        if (width == 0)
            return NULL;
        if (field->label == PROTOBUF_C_LABEL_REPEATED) {
            values = region_alloc(input->arena, width * count);
            if (values == NULL)
                return NULL;
            memcpy(memory + field->offset, &values, sizeof(values));
            memcpy(memory + field->quantifier_offset, &count, sizeof(count));
        } else if (count != 1) {
            return NULL;
        } else if (field->flags & PROTOBUF_C_FIELD_FLAG_ONEOF) {
            uint32_t active;
            memcpy(&active, memory + field->quantifier_offset, sizeof(active));
            if (active != 0)
                return NULL;
            memcpy(memory + field->quantifier_offset, &field->id, sizeof(active));
        } else if (field->label == PROTOBUF_C_LABEL_OPTIONAL && field->quantifier_offset != 0) {
            const protobuf_c_boolean present = 1;
            memcpy(memory + field->quantifier_offset, &present, sizeof(present));
        }
        size_t written = 0;
        for (size_t entry = 0; entry < input->count; ++entry) {
            const flint_proto_field *value = &input->fields[entry];
            if (value->parent != parent || value->number != field->id)
                continue;
            if (!store_scalar(field, value, values + written * width, depth, input))
                return NULL;
            ++written;
            ++input->assigned;
        }
    }
    return message;
}

static int valid_region(const flint_proto_arena *arena) {
    return arena != NULL && arena->bytes != NULL && arena->used <= arena->capacity;
}

int flint_proto_pack_fields(const flint_proto_descriptor *descriptor, const flint_proto_field *fields,
                            size_t count, const uint8_t *bytes, size_t byte_count, void *arena_context,
                            uint8_t *output, size_t capacity, size_t *written) {
    const ProtobufCMessageDescriptor *native = checked_descriptor(descriptor);
    flint_proto_arena *arena = arena_context;
    if (written == NULL)
        return FLINT_PROTO_INVALID;
    *written = 0;
    if (native == NULL || !valid_region(arena) || count > FLINT_PROTO_FIELD_LIMIT ||
            (fields == NULL && count != 0) || (bytes == NULL && byte_count != 0))
        return FLINT_PROTO_INVALID;
    for (size_t index = 0; index < count; ++index) {
        if (fields[index].number == 0 || fields[index].parent > index)
            return FLINT_PROTO_INVALID;
    }
    size_t checkpoint = arena->used;
    arena->exhausted = 0;
    typed_input input = {fields, count, bytes, byte_count, 0, arena};
    ProtobufCMessage *message = construct(native, 0, 0, &input);
    int result;
    if (message == NULL || input.assigned != count)
        result = arena->exhausted ? FLINT_PROTO_CAPACITY : FLINT_PROTO_INVALID;
    else
        result = flint_proto_pack(descriptor, message, output, capacity, written);
    arena->used = checkpoint;
    return result;
}

typedef struct typed_output {
    flint_proto_field *fields;
    size_t capacity;
    size_t count;
    const flint_proto_arena *arena;
} typed_output;

static int flatten(const ProtobufCMessage *, uint32_t, size_t, typed_output *);

static int in_region(const flint_proto_arena *arena, const void *value, size_t *offset) {
    const uintptr_t address = (uintptr_t)value;
    const uintptr_t base = (uintptr_t)arena->bytes;
    if (address < base || address - base >= arena->used)
        return 0;
    *offset = address - base;
    return 1;
}

static int load_scalar(const ProtobufCFieldDescriptor *field, const uint8_t *from, flint_proto_field *to,
                        size_t depth, typed_output *output) {
    const size_t width = field_size(field->type);
    switch (field->type) {
    case PROTOBUF_C_TYPE_STRING: {
        const char *text;
        memcpy(&text, from, sizeof(text));
        if (text == NULL || text == protobuf_c_empty_string)
            return 1;
        if (!in_region(output->arena, text, &to->start))
            return 0;
        const char *terminator = memchr(text, 0, output->arena->used - to->start);
        if (terminator == NULL)
            return 0;
        to->length = (size_t)(terminator - text);
        return 1;
    }
    case PROTOBUF_C_TYPE_BYTES: {
        ProtobufCBinaryData binary;
        memcpy(&binary, from, sizeof(binary));
        to->length = binary.len;
        return binary.len == 0 || (in_region(output->arena, binary.data, &to->start) &&
                binary.len <= output->arena->used - to->start);
    }
    case PROTOBUF_C_TYPE_MESSAGE: {
        const ProtobufCMessage *message;
        memcpy(&message, from, sizeof(message));
        return message != NULL && flatten(message, (uint32_t)(to - output->fields) + 1, depth + 1, output);
    }
    case PROTOBUF_C_TYPE_FLOAT: {
        float decimal;
        memcpy(&decimal, from, sizeof(decimal));
        to->decimal = decimal;
        return 1;
    }
    case PROTOBUF_C_TYPE_DOUBLE:
        memcpy(&to->decimal, from, sizeof(to->decimal));
        return 1;
    default:
        if (width == sizeof(uint32_t)) {
            uint32_t bits;
            memcpy(&bits, from, width);
            to->bits = bits;
            return 1;
        }
        if (width == sizeof(uint64_t)) {
            memcpy(&to->bits, from, width);
            return 1;
        }
        return 0;
    }
}

static int flatten(const ProtobufCMessage *message, uint32_t parent, size_t depth, typed_output *output) {
    if (depth > FLINT_PROTO_DEPTH_LIMIT)
        return 0;
    const ProtobufCMessageDescriptor *descriptor = message->descriptor;
    const uint8_t *memory = (const uint8_t *)message;
    for (size_t index = 0; index < descriptor->n_fields; ++index) {
        const ProtobufCFieldDescriptor *field = &descriptor->fields[index];
        size_t count = 1;
        const uint8_t *values = memory + field->offset;
        const size_t width = field_size(field->type);
        if (width == 0)
            return 0;
        if (field->label == PROTOBUF_C_LABEL_REPEATED) {
            memcpy(&count, memory + field->quantifier_offset, sizeof(count));
            memcpy(&values, values, sizeof(values));
            if (count > output->capacity - output->count)
                return 0;
        } else if (field->flags & PROTOBUF_C_FIELD_FLAG_ONEOF) {
            uint32_t active;
            memcpy(&active, memory + field->quantifier_offset, sizeof(active));
            if (active != field->id)
                continue;
        } else if (field->type == PROTOBUF_C_TYPE_MESSAGE) {
            const ProtobufCMessage *submessage;
            memcpy(&submessage, values, sizeof(submessage));
            if (submessage == NULL)
                continue;
        } else if (field->label == PROTOBUF_C_LABEL_OPTIONAL && field->quantifier_offset != 0) {
            protobuf_c_boolean present;
            memcpy(&present, memory + field->quantifier_offset, sizeof(present));
            if (!present)
                continue;
        }
        for (size_t element = 0; element < count; ++element) {
            if (output->count == output->capacity)
                return 0;
            flint_proto_field *value = &output->fields[output->count++];
            *value = (flint_proto_field){.parent = parent, .number = field->id};
            if (!load_scalar(field, values + element * width, value, depth, output))
                return 0;
        }
    }
    return 1;
}

int flint_proto_unpack_fields(const flint_proto_descriptor *descriptor, const uint8_t *input,
                              size_t input_length, void *arena_context, flint_proto_field *fields,
                              size_t capacity, size_t *count) {
    flint_proto_arena *arena = arena_context;
    if (count == NULL)
        return FLINT_PROTO_INVALID;
    *count = 0;
    if (!valid_region(arena) || capacity > FLINT_PROTO_FIELD_LIMIT || (fields == NULL && capacity != 0))
        return FLINT_PROTO_INVALID;
    const size_t checkpoint = arena->used;
    void *message;
    const int result = flint_proto_unpack(descriptor, input, input_length, arena, &message);
    if (result != FLINT_PROTO_OK)
        return result;
    typed_output output = {fields, capacity, 0, arena};
    const int complete = flatten(message, 0, 0, &output);
    flint_proto_release(descriptor, message, arena);
    if (!complete) {
        arena->used = checkpoint;
        return FLINT_PROTO_CAPACITY;
    }
    *count = output.count;
    return FLINT_PROTO_OK;
}
#endif
