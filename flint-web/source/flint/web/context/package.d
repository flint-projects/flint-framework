/++
`org.springframework.web.context`: the servlet-context callbacks of web beans.

Ported from spring-projects/spring-framework v7.1.0,
spring-web/src/main/java/org/springframework/web/context/ServletContextAware.java.
Copyright 2002-present the original author or authors.
Licensed under the Apache License, Version 2.0 (https://www.apache.org/licenses/LICENSE-2.0).
Modified by the Flint authors: translated to D under the rulebook.
+/
module flint.web.context;

import flint.beans.factory : Aware;
import flint.jakarta.servlet : ServletContext;

@safe:

/// `ServletContextAware`: a bean that wants to know the `ServletContext` it runs in.
interface ServletContextAware : Aware
{
    /// Called after population, before initialization callbacks.
    void setServletContext(ServletContext servletContext);
}
