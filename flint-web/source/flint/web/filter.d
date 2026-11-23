/++
`org.springframework.web.filter`: `GenericFilterBean` and `OncePerRequestFilter`, the base classes of Spring's
servlet filters and of Spring Security's filter chain.

Ported from spring-projects/spring-framework v7.1.0,
spring-web/src/main/java/org/springframework/web/filter/ (GenericFilterBean.java, OncePerRequestFilter.java).
Copyright 2002-present the original author or authors.
Licensed under the Apache License, Version 2.0 (https://www.apache.org/licenses/LICENSE-2.0).
Modified by the Flint authors: translated to D under the rulebook. `GenericFilterBean.init` does not bind the
filter's init parameters to bean properties: that needs a `BeanWrapper` over the filter's descriptor, which is not
ported. A required property (`addRequiredProperty`) missing from the init parameters still fails `init`.
`createEnvironment` returns a `StandardEnvironment` (no `StandardServletEnvironment` yet), and there is no
`logger` field. `OncePerRequestFilter.isAsyncStarted` is false until async dispatch is ported.
+/
module flint.web.filter;

import flint.beans.factory : BeanNameAware, DisposableBean, InitializingBean;
import flint.context : EnvironmentAware;
import flint.core.env : Environment, EnvironmentCapable, StandardEnvironment;
import flint.engine.aot.any : Any;
import flint.jakarta.servlet : DispatcherType, Filter, FilterChain, FilterConfig, ServletContext,
    ServletException, ServletRequest, ServletResponse;
import flint.jakarta.servlet.http : HttpServletRequest, HttpServletResponse;
import flint.java.lang : IllegalStateException;
import flint.web.context : ServletContextAware;

@safe:

/++
`GenericFilterBean`: a `Filter` that is also a bean. It knows its bean name, environment and servlet context, and
runs `initFilterBean` both when the container initializes it as a bean and when the servlet container calls `init`.
+/
abstract class GenericFilterBean : Filter, BeanNameAware, EnvironmentAware, EnvironmentCapable,
    ServletContextAware, InitializingBean, DisposableBean
{
    private string beanName;
    private Environment environment;
    private ServletContext servletContext;
    private FilterConfig filterConfig;
    private string[] requiredProperties;

    /// Stores the bean name, which `getFilterName` returns when the filter was not initialized by a container.
    final void setBeanName(string beanName)
    {
        this.beanName = beanName;
    }

    /// Sets the `Environment` this filter runs in.
    void setEnvironment(Environment environment)
    {
        this.environment = environment;
    }

    /// The `Environment`, created on first use when none was set.
    Environment getEnvironment()
    {
        if (environment is null)
            environment = createEnvironment();
        return environment;
    }

    /// The environment created when none was set.
    protected Environment createEnvironment()
    {
        return new StandardEnvironment();
    }

    /// Stores the `ServletContext` the bean factory runs in.
    final void setServletContext(ServletContext servletContext)
    {
        this.servletContext = servletContext;
    }

    /// Calls `initFilterBean`, for a filter defined as a bean.
    void afterPropertiesSet()
    {
        initFilterBean();
    }

    /// Does nothing; subclasses release resources here.
    void destroy()
    {
    }

    /// Makes `property` a required init parameter of the filter.
    protected final void addRequiredProperty(string property)
    {
        requiredProperties ~= property;
    }

    /// Stores the filter configuration, checks the required init parameters and calls `initFilterBean`.
    /// Throws `ServletException` when a required parameter is missing.
    final void init(FilterConfig filterConfig)
    {
        this.filterConfig = filterConfig;
        string[] missing;
        foreach (property; requiredProperties)
            if (filterConfig.getInitParameter(property) is null)
                missing ~= property;
        if (missing.length != 0)
        {
            string names;
            foreach (i, name; missing)
                names ~= (i == 0 ? "" : ", ") ~ name;
            throw new ServletException("Initialization from FilterConfig for filter '" ~ filterConfig.getFilterName()
                    ~ "' failed; the following required properties were missing: " ~ names);
        }
        initFilterBean();
    }

    /// Subclass initialization, after the properties are set; does nothing by default.
    protected void initFilterBean()
    {
    }

    /// The configuration from `init`, or null for a filter that was only initialized as a bean.
    final FilterConfig getFilterConfig() pure nothrow @nogc
    {
        return filterConfig;
    }

    /// The filter name from the configuration, else the bean name.
    protected string getFilterName()
    {
        return filterConfig !is null ? filterConfig.getFilterName() : beanName;
    }

    /// The `ServletContext` set as a bean, else the configuration's. Throws `IllegalStateException` without either.
    protected ServletContext getServletContext()
    {
        if (servletContext !is null)
            return servletContext;
        if (filterConfig !is null)
            return filterConfig.getServletContext();
        throw new IllegalStateException("No ServletContext");
    }
}

/++
`OncePerRequestFilter`: a filter that runs `doFilterInternal` once per request, whatever the number of dispatches.
A request attribute named after the filter marks it as filtered while it runs, so a forward or include through the
same chain passes straight on. Error and async dispatches are skipped by default.
+/
abstract class OncePerRequestFilter : GenericFilterBean
{
    /// Appended to the filter name to name the "already filtered" request attribute.
    enum string ALREADY_FILTERED_SUFFIX = ".FILTERED";

    // WebUtils.ERROR_REQUEST_URI_ATTRIBUTE: set by the container on an error dispatch.
    private enum string errorRequestUriAttribute = "jakarta.servlet.error.request_uri";

    /// Runs `doFilterInternal` unless this request already went through this filter or the dispatch is skipped.
    /// Throws `ServletException` for a request or response that is not HTTP.
    final void doFilter(ServletRequest request, ServletResponse response, FilterChain filterChain)
    {
        auto httpRequest = cast(HttpServletRequest) request;
        auto httpResponse = cast(HttpServletResponse) response;
        if (httpRequest is null || httpResponse is null)
            throw new ServletException("OncePerRequestFilter only supports HTTP requests");
        const alreadyFilteredAttributeName = getAlreadyFilteredAttributeName();
        const hasAlreadyFilteredAttribute = !request.getAttribute(alreadyFilteredAttributeName).isNull();
        if (skipDispatch(httpRequest) || shouldNotFilter(httpRequest))
            filterChain.doFilter(request, response);
        else if (hasAlreadyFilteredAttribute)
        {
            if (request.getDispatcherType() == DispatcherType.ERROR)
            {
                doFilterNestedErrorDispatch(httpRequest, httpResponse, filterChain);
                return;
            }
            filterChain.doFilter(request, response);
        }
        else
        {
            request.setAttribute(alreadyFilteredAttributeName, Any.of(true));
            scope (exit)
                request.removeAttribute(alreadyFilteredAttributeName);
            doFilterInternal(httpRequest, httpResponse, filterChain);
        }
    }

    private bool skipDispatch(HttpServletRequest request)
    {
        if (isAsyncDispatch(request) && shouldNotFilterAsyncDispatch())
            return true;
        return !request.getAttribute(errorRequestUriAttribute).isNull() && shouldNotFilterErrorDispatch();
    }

    /// Whether the request is an async dispatch.
    protected bool isAsyncDispatch(HttpServletRequest request)
    {
        return request.getDispatcherType() == DispatcherType.ASYNC;
    }

    /// Whether request processing went async; always false until async dispatch is ported.
    protected bool isAsyncStarted(HttpServletRequest request)
    {
        return false;
    }

    /// The name of the "already filtered" attribute: the filter name, or the class name, plus `.FILTERED`.
    protected string getAlreadyFilteredAttributeName()
    {
        auto name = getFilterName();
        if (name is null)
            name = typeid(this).name;
        return name ~ ALREADY_FILTERED_SUFFIX;
    }

    /// Whether to pass this request on without filtering it; false by default.
    protected bool shouldNotFilter(HttpServletRequest request)
    {
        return false;
    }

    /// Whether async dispatches pass on unfiltered; true by default.
    protected bool shouldNotFilterAsyncDispatch()
    {
        return true;
    }

    /// Whether error dispatches pass on unfiltered; true by default.
    protected bool shouldNotFilterErrorDispatch()
    {
        return true;
    }

    /// The filter's work, run once per request.
    protected abstract void doFilterInternal(HttpServletRequest request,
            HttpServletResponse response, FilterChain filterChain);

    /// An error dispatch nested in a request this filter is already filtering: passes it on by default.
    protected void doFilterNestedErrorDispatch(HttpServletRequest request,
            HttpServletResponse response, FilterChain filterChain)
    {
        filterChain.doFilter(request, response);
    }
}
