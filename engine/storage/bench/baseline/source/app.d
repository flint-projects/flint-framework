module app;

import core.stdc.stdio : fprintf, stderr;
import core.memory : GC;
import core.time : MonoTime;
import std.array : appender;
import std.conv : to;
import std.string : toStringz;
import storage_workload : Checksum, access, address, bucket, fillPart, key, objectType,
    parallelParts, partBytes, parts, region, report, require, secret, token;

@safe:

private struct Easy;
private struct Multi;
private struct Headers;

private struct Message
{
    int kind;
    Easy* easy;
    union
    {
        void* pointer;
        int completion;
    }
}

extern (C) private @system nothrow @nogc
{
    int curl_global_init(long);
    void curl_global_cleanup();
    Easy* curl_easy_init();
    int curl_easy_setopt(Easy*, int, ...);
    int curl_easy_getinfo(Easy*, int, ...);
    void curl_easy_reset(Easy*);
    void curl_easy_cleanup(Easy*);
    Headers* curl_slist_append(Headers*, const(char)*);
    void curl_slist_free_all(Headers*);
    Multi* curl_multi_init();
    int curl_multi_cleanup(Multi*);
    int curl_multi_add_handle(Multi*, Easy*);
    int curl_multi_remove_handle(Multi*, Easy*);
    int curl_multi_perform(Multi*, int*);
    int curl_multi_poll(Multi*, void*, uint, int, int*);
    Message* curl_multi_info_read(Multi*, int*);
}

private enum Option
{
    output = 10_001,
    url = 10_002,
    proxy = 10_004,
    credentials = 10_005,
    write = 20_011,
    body = 10_015,
    headers = 10_023,
    headerData = 10_029,
    method = 10_036,
    noRedirects = 52,
    verifyPeer = 64,
    header = 20_079,
    verifyHost = 81,
    httpVersion = 84,
    noSignal = 99,
    decode = 10_102,
    length = 30_120,
    timeout = 155,
    connectTimeout = 156,
    sign = 10_305,
}

private struct Request
{
    Easy* easy;
    Headers* headers;
    Checksum* download;
    char[8192] response;
    char[1024] etag;
    size_t used;
    size_t tagBytes;
    bool completed;
    long status;
}

private struct Pool
{
    Multi* multi;
    Request[parallelParts] requests;
    size_t count;

    @disable this(this);

    // SAFETY: The pool owns its C handles on this benchmark thread until close.
    void open(size_t size) @trusted nothrow @nogc
    {
        require(size > 0 && size <= requests.length, "invalid provider capacity");
        multi = curl_multi_init();
        require(multi !is null, "curl multi initialization failed");
        count = size;
        foreach (ref entry; requests[0 .. count])
        {
            entry.easy = curl_easy_init();
            require(entry.easy !is null, "curl easy initialization failed");
        }
    }

    // SAFETY: Request and buffers stay live and fixed through run(). The provider copies URL and method.
    void add(size_t index, string method, string destination, scope const(ubyte)[] body, string media,
            scope Checksum* digest = null) @trusted
    {
        require(index < count, "invalid provider slot");
        ref Request entry = requests[index];
        entry.used = 0;
        entry.tagBytes = 0;
        entry.completed = false;
        entry.download = digest;
        curl_easy_reset(entry.easy);
        configure(entry, method, destination);
        addHeader(entry, "Expect:");
        addHeader(entry, "X-Amz-Security-Token: " ~ token);
        if (media.length)
            addHeader(entry, "Content-Type: " ~ media);
        set(entry.easy, Option.headers, entry.headers);
        if (method == "POST" || method == "PUT")
        {
            const(ubyte)* bytes = body.length ? body.ptr : cast(const(ubyte)*) "";
            set(entry.easy, Option.length, cast(long)
                    body.length);
            set(entry.easy, Option.body, bytes);
        }
        require(curl_multi_add_handle(multi, entry.easy) == 0, "cannot queue provider transfer");
    }

    // SAFETY: All pending transfers and their scoped storage remain live on this thread.
    void run(size_t expected) @trusted nothrow @nogc
    {
        int running;
        for (;;)
        {
            require(curl_multi_perform(multi, &running) == 0, "curl transfer failed");
            if (!running)
                break;
            require(curl_multi_poll(multi, null, 0, 1000, null) == 0, "curl poll failed");
        }

        size_t observations;
        int remaining;
        while (auto result = curl_multi_info_read(multi, &remaining))
        {
            if (result.completion != 0)
                fprintf(stderr, "Pinned curl failed with status %d\n", result.completion);
            require(result.kind == 1 && result.completion == 0, "curl provider returned a transfer error");
            foreach (ref entry; requests[0 .. count])
            {
                if (entry.easy != result.easy)
                    continue;
                require(!entry.completed && curl_easy_getinfo(entry.easy, 0x20_0002,
                        &entry.status) == 0, "curl response identity is invalid");
                entry.completed = true;
                require(curl_multi_remove_handle(multi, entry.easy) == 0, "cannot retire provider transfer");
                curl_slist_free_all(entry.headers);
                entry.headers = null;
                entry.download = null;
                ++observations;
                break;
            }
        }
        require(observations == expected, "curl completion count differs");
    }

    // SAFETY: The owner releases its handles on this thread after all transfers have retired.
    void close() @trusted nothrow @nogc
    {
        foreach (ref entry; requests[0 .. count])
            curl_easy_cleanup(entry.easy);
        require(curl_multi_cleanup(multi) == 0, "curl multi teardown failed");
    }
}

private void addHeader(ref Request request, string header) @system
{
    auto added = curl_slist_append(request.headers, header.toStringz);
    require(added !is null, "curl header storage exhausted");
    request.headers = added;
}

private void configure(ref Request request, string method, string destination) @system
{
    auto handle = request.easy;
    set(handle, Option.url, destination.toStringz);
    set(handle, Option.method, method.toStringz);
    set(handle, Option.proxy, "".toStringz);
    set(handle, Option.credentials, (access ~ ":" ~ secret).toStringz);
    set(handle, Option.sign, ("aws:amz:" ~ region ~ ":s3").toStringz);
    set(handle, Option.noRedirects, 0L);
    set(handle, Option.verifyPeer, 1L);
    set(handle, Option.verifyHost, 2L);
    set(handle, Option.httpVersion, 4L);
    set(handle, Option.noSignal, 1L);
    set(handle, Option.decode, "".toStringz);
    set(handle, Option.timeout, 120_000L);
    set(handle, Option.connectTimeout, 5_000L);
    set(handle, Option.write, &receive);
    set(handle, Option.header, &header);
    set(handle, Option.output, &request);
    set(handle, Option.headerData, &request);
}

private void set(T)(Easy* handle, Option option, T value) @system nothrow @nogc
{
    require(curl_easy_setopt(handle, option, value) == 0, "cannot configure curl");
}

extern (C) private size_t receive(char* bytes, size_t size, size_t count, Request* req) @system nothrow @nogc
{
    if (size != 1)
        return 0;
    if (req.download !is null)
    {
        req.download.add(cast(const(ubyte)[]) bytes[0 .. count]);
        return count;
    }
    if (count > req.response.length - req.used)
        return 0;
    req.response[req.used .. req.used + count] = bytes[0 .. count];
    req.used += count;
    return count;
}

extern (C) private size_t header(char* bytes, size_t size, size_t count, Request* req) @system nothrow @nogc
{
    enum field = "ETag: ";
    enum suffix = 2;
    if (size != 1)
        return 0;
    if (count >= field.length + suffix && bytes[0 .. field.length] == field)
    {
        const length = count - field.length - suffix;
        if (length > req.etag.length)
            return 0;
        req.etag[0 .. length] = bytes[field.length .. field.length + length];
        req.tagBytes = length;
    }
    return count;
}

private string uploadId(ref Request response)
{
    enum prefix = "<InitiateMultipartUploadResult><UploadId>";
    enum suffix = "</UploadId></InitiateMultipartUploadResult>";
    const bytes = response.response[0 .. response.used];
    require(response.status == 200 && bytes.length > prefix.length + suffix.length
            && bytes[0 .. prefix.length] == prefix && bytes[$ - suffix.length .. $] == suffix,
            "fixture upload identity is missing");
    return bytes[prefix.length .. $ - suffix.length].idup;
}

private string sendParts(ref Pool provider, string objectUrl, string id, ubyte[][parallelParts] owners)
{
    auto completed = appender!string();
    completed.reserve(16_384);
    completed.put("<CompleteMultipartUpload xmlns=\"http://s3.amazonaws.com/doc/2006-03-01/\">");
    foreach (batch; 0 .. parts / parallelParts)
    {
        foreach (index, ref buffer; owners)
        {
            const part = cast(uint)(batch * parallelParts + index + 1);
            fillPart(part, buffer);
            provider.add(index, "PUT", objectUrl ~ "?partNumber=" ~ part.to!string ~ "&uploadId=" ~ id, buffer, null);
        }
        provider.run(parallelParts);
        foreach (index, ref response; provider.requests)
        {
            const part = cast(uint)(batch * parallelParts + index + 1);
            const number = part.to!string;
            const tag = "fixture-part-" ~ number;
            require(response.status == 200 && response.etag[0 .. response.tagBytes] == "\"" ~ tag ~ "\"",
                    "fixture part did not complete");
            completed.put("<Part><PartNumber>" ~ number ~ "</PartNumber><ETag>&quot;" ~ tag ~ "&quot;</ETag></Part>");
        }
    }
    completed.put("</CompleteMultipartUpload>");
    return completed.data;
}

// SAFETY: All curl contexts and borrowed request buffers are owned until the corresponding completed calls.
private void execute(string objectUrl) @trusted
{
    require(curl_global_init(3L) == 0, "curl initialization failed");
    scope (exit)
        curl_global_cleanup();

    Pool control;
    Pool transfer;
    control.open(1);
    transfer.open(parallelParts);
    scope (exit)
    {
        transfer.close();
        control.close();
    }

    ubyte[][parallelParts] owners;
    foreach (ref buffer; owners)
        buffer = new ubyte[partBytes];

    Checksum downloaded;
    downloaded.open();
    const allocated = GC.stats().allocatedInCurrentThread;
    const started = MonoTime.currTime;
    control.add(0, "POST", objectUrl ~ "?uploads=", null, objectType);
    control.run(1);
    const id = uploadId(control.requests[0]);
    const completion = sendParts(transfer, objectUrl, id, owners);
    control.add(0, "POST", objectUrl ~ "?uploadId=" ~ id, cast(const(ubyte)[]) completion, "application/xml");
    control.run(1);
    enum expected = "<CompleteMultipartUploadResult><ETag>\"storage-fixture-object\"</ETag>"
        ~ "</CompleteMultipartUploadResult>";
    const result = control.requests[0].response[0 .. control.requests[0].used];
    require(control.requests[0].status == 200 && result == expected, "fixture rejected multipart completion");

    const uploaded = MonoTime.currTime;
    control.add(0, "GET", objectUrl, null, null, &downloaded);
    control.run(1);
    const finished = MonoTime.currTime;
    require(control.requests[0].status == 200, "fixture download failed");
    control.add(0, "DELETE", objectUrl, null, null);
    control.run(1);
    require(control.requests[0].status == 204, "fixture cleanup failed");
    report(downloaded, started, uploaded, finished, allocated);
}

void main()
{
    execute(address() ~ "/" ~ bucket ~ "/" ~ key);
}
