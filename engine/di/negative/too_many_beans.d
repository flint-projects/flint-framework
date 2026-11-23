/// Negative compiler fixture for too many beans.
module too_many_beans;

import flint.arena : Error;
import flint.engine.di : AppContext;

@safe:

private struct Bean(size_t index)
{
    enum number = index;
}

/// Instantiation must reject this explicit context.
Error rejected()
{
    AppContext!(Bean!0, Bean!1, Bean!2, Bean!3, Bean!4, Bean!5, Bean!6, Bean!7, Bean!8,
            Bean!9, Bean!10, Bean!11, Bean!12, Bean!13, Bean!14, Bean!15, Bean!16, Bean!17,
            Bean!18, Bean!19, Bean!20, Bean!21, Bean!22, Bean!23, Bean!24, Bean!25, Bean!26,
            Bean!27, Bean!28, Bean!29, Bean!30, Bean!31, Bean!32, Bean!33, Bean!34, Bean!35,
            Bean!36, Bean!37, Bean!38, Bean!39, Bean!40, Bean!41, Bean!42, Bean!43, Bean!44,
            Bean!45, Bean!46, Bean!47, Bean!48, Bean!49, Bean!50, Bean!51, Bean!52, Bean!53,
            Bean!54, Bean!55, Bean!56, Bean!57, Bean!58, Bean!59, Bean!60, Bean!61, Bean!62,
            Bean!63, Bean!64, Bean!65, Bean!66, Bean!67, Bean!68, Bean!69, Bean!70, Bean!71,
            Bean!72, Bean!73, Bean!74, Bean!75, Bean!76, Bean!77, Bean!78, Bean!79, Bean!80,
            Bean!81, Bean!82, Bean!83, Bean!84, Bean!85, Bean!86, Bean!87, Bean!88, Bean!89,
            Bean!90, Bean!91, Bean!92, Bean!93, Bean!94, Bean!95, Bean!96, Bean!97,
            Bean!98, Bean!99, Bean!100, Bean!101, Bean!102, Bean!103, Bean!104, Bean!105,
            Bean!106, Bean!107, Bean!108, Bean!109, Bean!110, Bean!111, Bean!112, Bean!113,
            Bean!114, Bean!115, Bean!116, Bean!117, Bean!118, Bean!119, Bean!120, Bean!121,
            Bean!122, Bean!123, Bean!124, Bean!125, Bean!126, Bean!127, Bean!128) context;
    return context.initialize();
}
