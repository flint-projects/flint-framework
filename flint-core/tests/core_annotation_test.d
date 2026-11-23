module flint.core.annotation_test;

import flint.core : Ordered, OrderComparator;
import flint.core.annotation : AliasFor, classOf, Order;
import flint.core.annotation.types : AnnotationAwareOrderComparator, AnnotationUtils, MergedAnnotations;
import flint.engine.aot.descriptor : DescriptorTable, descriptorOf;

@safe:

private struct Component
{
    string value;
}

@Component private struct Service
{
    @AliasFor(null, classOf!Component) string value;
}

@Service("ownerService") @Order(5) private final class OwnerService
{
}

private final class FirstOrdered : Ordered
{
    int getOrder()
    {
        return 1;
    }
}

unittest
{
    auto annotations = MergedAnnotations.from(descriptorOf!OwnerService);
    assert(annotations.isPresent!Component && !annotations.isDirectlyPresent!Component);
    assert(annotations.isDirectlyPresent!Service);
    auto component = annotations.get!Component();
    assert(component.isMetaPresent && component.getDistance() == 1 && component.synthesize().value == "ownerService");
    assert(!annotations.get!AliasFor().isPresent && annotations.get!AliasFor().getDistance() == -1);
    assert(annotations.get!Order().synthesize().value == 5);
    assert(AnnotationUtils.isAnnotationDeclaredLocally!Order(descriptorOf!OwnerService));
}

unittest
{
    auto table = new DescriptorTable;
    table.add(descriptorOf!OwnerService);
    auto comparator = new AnnotationAwareOrderComparator(table);
    Object service = new OwnerService, first = new FirstOrdered, plain = new Object;
    assert(comparator.compare(first, service) < 0 && comparator.compare(service, plain) < 0);
    assert(OrderComparator.INSTANCE().compare(service, plain) == 0);
}

unittest
{
    // MethodParameter over an AOT ArgumentSpec, and conversion to a type known by name.
    import flint.core : MethodParameter;
    import flint.core.convert.support : DefaultConversionService;
    import flint.engine.aot.any : Any;
    import flint.engine.aot.descriptor : MergedAnnotation;
    import flint.engine.aot.mapping : ArgumentKind, ArgumentSpec;

    ArgumentSpec spec = {
        kind: ArgumentKind.requestParam, name: "id", type: "flint.java.util.Optional!long",
        annotations: [MergedAnnotation("flint.core.annotation.Order", Any.of(Order(3)), 0)]
    };
    auto parameter = new MethodParameter(spec, 0, "OwnerController.getOwner");
    assert(parameter.getParameterName() == "id" && parameter.isOptional());
    assert(parameter.getNestedParameterType() == "long" && parameter.hasParameterAnnotation!Order);
    assert(parameter.getParameterAnnotation("flint.core.annotation.Order").value.get!(const Order).value == 3);
    assert(parameter.toString() == "method 'OwnerController.getOwner' parameter 0");
    auto service = new DefaultConversionService;
    assert(service.convert(Any.of("42"), "int").get!int == 42);
}
