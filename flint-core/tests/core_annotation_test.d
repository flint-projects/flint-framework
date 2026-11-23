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
    bool found;
    assert(AnnotationUtils.findAnnotation!Order(descriptorOf!OwnerService, found).value == 5 && found);
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
