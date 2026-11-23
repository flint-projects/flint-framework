module flint.core.io_test;

import flint.core.io : ByteArrayResource, ClassPathResource, DefaultResourceLoader,
    DescriptiveResource, FileSystemResource, installEmbeddedResources, Resource;
import flint.java.io : FileNotFoundException;

@safe:

private immutable(ubyte)[] embeddedForTest(string path) @safe nothrow
{
    return path == "application.properties" ? cast(immutable(ubyte)[]) "server.port=9090\n" : null;
}

unittest
{
    // Embedded class path resources win, a leading slash is ignored, missing ones throw Spring's message.
    installEmbeddedResources(&embeddedForTest);
    auto props = new ClassPathResource("/application.properties");
    assert(props.exists() && props.getContentAsString() == "server.port=9090\n" && !props.isFile());
    assert(props.getDescription() == "class path resource [application.properties]");
    assert(props.getFilename() == "application.properties" && props.contentLength() == 17);
    auto missing = new ClassPathResource("no/such.txt");
    assert(!missing.exists());
    bool threw;
    try
        missing.getInputStream();
    catch (FileNotFoundException e)
        threw = e.getMessage() == "class path resource [no/such.txt] cannot be opened because it does not exist";
    assert(threw);
    auto relative = new ClassPathResource("a/b.txt").createRelative("c.txt");
    assert(relative.getDescription() == "class path resource [a/c.txt]");
    assert(new ClassPathResource("x") == new ClassPathResource("/x"));
}

unittest
{
    auto loader = new DefaultResourceLoader;
    assert(cast(ClassPathResource) loader.getResource("classpath:application.properties") !is null);
    assert(cast(FileSystemResource) loader.getResource("file:/tmp/x") !is null);
    auto bytes = new ByteArrayResource(cast(immutable(ubyte)[]) "abc", "test");
    assert(bytes.exists() && bytes.getContentAsString() == "abc"
            && bytes.getDescription() == "Byte array resource [test]");
    assert(!new DescriptiveResource("nothing").exists());
    auto file = new FileSystemResource("/no/such/flint/file.txt");
    assert(!file.exists() && file.getFilename() == "file.txt");
}
